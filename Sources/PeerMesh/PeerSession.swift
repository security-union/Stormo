import Foundation

/// The primary PeerMesh API: discovery, invitation, membership, and data
/// exchange with nearby peers (design document §7).
///
/// MPC-simple by default: one line to construct, encryption always on,
/// zero-configuration trust (FR-21 `.automatic`), no pairing ceremony.
///
/// ```swift
/// let session = PeerSession(name: "Dario's iPhone", service: "_myapp._udp")
/// try await session.startAdvertising()
/// for await event in session.discoveries { ... }
/// ```
///
/// Architecture (DD-6): all protocol decisions live in the sans-I/O
/// `ProtocolEngine`; this actor is the runtime shell — it feeds transport and
/// app inputs into the engine and executes the returned effects (connect,
/// send, timers, app events) against the injected `PeerTransport`.
public actor PeerSession {
    public let identity: PeerIdentity
    public let service: ServiceDescriptor
    public let topology: SessionTopology
    public let trust: TrustPolicy

    private let transport: any PeerTransport
    private var engine: ProtocolEngine

    // MARK: Event streams (DD-4: AsyncSequence-first, no delegates in the core)

    nonisolated public let discoveries: AsyncStream<DiscoveryEvent>
    nonisolated public let invitations: AsyncStream<Invitation>
    nonisolated public let membership: AsyncStream<MembershipEvent>
    nonisolated public let messages: AsyncStream<InboundMessage>

    private let discoveriesContinuation: AsyncStream<DiscoveryEvent>.Continuation
    private let invitationsContinuation: AsyncStream<Invitation>.Continuation
    private let membershipContinuation: AsyncStream<MembershipEvent>.Continuation
    private let messagesContinuation: AsyncStream<InboundMessage>.Continuation

    // MARK: Runtime state (driver bookkeeping only — no protocol decisions)

    private var connections: [PeerID: any PeerConnection] = [:]
    private var receiveTasks: [PeerID: Task<Void, Never>] = [:]
    private var timers: [ProtocolEngine.TimerKey: Task<Void, Never>] = [:]
    private var knownEndpoints: [PeerID: DiscoveredPeer] = [:]
    private var inviteWaiters: [PeerID: CheckedContinuation<SessionPeer, Error>] = [:]
    private var inboundTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?

    // MARK: Construction

    /// Zero-configuration entry point: identity is loaded or created
    /// automatically, topology defaults to a 32-peer full mesh, trust defaults
    /// to `.automatic`.
    public init(
        name: String,
        service: ServiceDescriptor,
        topology: SessionTopology = .default,
        trust: TrustPolicy = .automatic
    ) {
        self.init(
            identity: PeerIdentity.loadOrCreate(name: name),
            service: service,
            topology: topology,
            trust: trust
        )
    }

    /// Full-control entry point (custom identity or transport injection; the
    /// latter is how PeerMeshTestKit runs sessions without radios, QA-8).
    public init(
        identity: PeerIdentity,
        service: ServiceDescriptor,
        topology: SessionTopology = .default,
        trust: TrustPolicy = .automatic,
        transport: (any PeerTransport)? = nil
    ) {
        self.identity = identity
        self.service = service
        self.topology = topology
        self.trust = trust
        self.transport = transport ?? QUICTransport()
        self.engine = ProtocolEngine(localPeer: identity.id)

        (self.discoveries, self.discoveriesContinuation) = AsyncStream.makeStream()
        (self.invitations, self.invitationsContinuation) = AsyncStream.makeStream()
        (self.membership, self.membershipContinuation) = AsyncStream.makeStream()
        (self.messages, self.messagesContinuation) = AsyncStream.makeStream()
    }

    // MARK: Discovery and advertising (FR-1..FR-5)

    public func startAdvertising(metadata: [String: String] = [:]) async throws {
        try await transport.startAdvertising(
            service: service, metadata: metadata, identity: identity)
        guard inboundTask == nil else { return }
        let stream = transport.inboundConnections
        inboundTask = Task { [weak self] in
            for await connection in stream {
                await self?.adopt(connection)
            }
        }
    }

    public func stopAdvertising() async {
        await transport.stopAdvertising()
    }

    public func startBrowsing() async throws {
        guard browseTask == nil else { return }
        let stream = try await transport.discoveries(service: service)
        browseTask = Task { [weak self] in
            for await event in stream {
                await self?.handleDiscovery(event)
            }
        }
    }

    public func stopBrowsing() async {
        browseTask?.cancel()
        browseTask = nil
        await transport.stopBrowsing()
    }

    // MARK: Invitation (FR-6..FR-9)

    /// Invite a discovered peer; resolves when the peer accepts, throws on
    /// decline, timeout, or connection loss.
    @discardableResult
    public func invite(
        _ peer: DiscoveredPeer,
        context: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> SessionPeer {
        knownEndpoints[peer.id] = peer
        return try await withCheckedThrowingContinuation { continuation in
            guard inviteWaiters[peer.id] == nil else {
                continuation.resume(throwing: PeerMeshError.unimplemented("concurrent invite to same peer"))
                return
            }
            inviteWaiters[peer.id] = continuation
            run(.command(.invite(peer.id, context: context, timeout: timeout)))
        }
    }

    // MARK: Data exchange (FR-15..FR-18)

    public func send(
        _ payload: Data,
        to recipients: Recipients = .all,
        delivery: Delivery = .reliable
    ) async throws {
        guard !engine.members.isEmpty else { throw PeerMeshError.peerUnreachable(identity.id) }
        run(.command(.send(payload, to: recipients, delivery: delivery)))
    }

    /// Transfer a file to a peer on a dedicated stream, disk-to-disk, with
    /// bounded memory (FR-17, QA-3).
    public func sendResource(at url: URL, to peer: PeerID) async throws -> ResourceTransfer {
        // TODO(Step 4): TransferOffer signal + transferChunk stream (DD-7).
        throw PeerMeshError.unimplemented("sendResource")
    }

    /// Open a named bidirectional byte stream with a peer (FR-18).
    public func openStream(_ label: String, with peer: PeerID) async throws -> any PeerByteStream {
        // TODO(Step 4): StreamOpen signal + appStream stream (DD-7).
        throw PeerMeshError.unimplemented("openStream")
    }

    /// Currently admitted session members (excluding the local peer).
    public var members: Set<PeerID> { engine.members }

    // MARK: Lifecycle

    /// Leave the session and release all radio resources (FR-5, C-5).
    public func disconnect() async {
        run(.command(.leave))
        inboundTask?.cancel()
        browseTask?.cancel()
        for task in receiveTasks.values { task.cancel() }
        for timer in timers.values { timer.cancel() }
        receiveTasks.removeAll()
        timers.removeAll()
        await transport.stopAdvertising()
        await transport.stopBrowsing()
        discoveriesContinuation.finish()
        invitationsContinuation.finish()
        membershipContinuation.finish()
        messagesContinuation.finish()
    }

    // MARK: - Engine loop (the sans-I/O boundary, DD-6)

    /// Feed one input into the engine and execute the resulting effects.
    private func run(_ input: ProtocolEngine.Input) {
        for effect in engine.handle(input) {
            execute(effect)
        }
    }

    private func execute(_ effect: ProtocolEngine.Effect) {
        switch effect {
        case .connect(let peerID):
            guard let endpoint = knownEndpoints[peerID] else {
                // Roster gossip may name peers we haven't discovered yet
                // (TODO Phase 1: mesh join via endpoint exchange). For the
                // invitation path this means: never discovered → unreachable.
                run(.connectionClosed(peerID))
                return
            }
            Task { [transport, identity, trust] in
                do {
                    let connection = try await transport.connect(
                        to: endpoint, identity: identity, trust: trust)
                    await self.adopt(connection)
                } catch {
                    await self.run(.connectionClosed(peerID))
                }
            }

        case .sendSignal(let signal, let peer):
            guard let connection = connections[peer] else { return }
            let bytes = SignalCodec.encode(signal)
            Task { try? await connection.sendSignal(bytes) }

        case .sendData(let payload, let peer, let delivery):
            guard let connection = connections[peer] else { return }
            Task { try? await connection.sendData(payload, delivery: delivery) }

        case .startTimer(let key, let duration):
            timers[key]?.cancel()
            timers[key] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.timerFired(key)
            }

        case .cancelTimer(let key):
            timers.removeValue(forKey: key)?.cancel()

        case .closeConnection(let peer):
            let connection = connections.removeValue(forKey: peer)
            receiveTasks.removeValue(forKey: peer)?.cancel()
            Task { await connection?.close() }

        case .emit(let event):
            deliver(event)
        }
    }

    private func deliver(_ event: ProtocolEngine.Event) {
        switch event {
        case .invitationReceived(let inviter, let context):
            let keyHash = connections[inviter]?.remoteKeyHash ?? inviter.keyHash
            let invitation = Invitation(
                from: inviter,
                context: context,
                inviterKeyHash: keyHash,
                accept: { [weak self] in await self?.respond(to: inviter, accept: true) },
                decline: { [weak self] in await self?.respond(to: inviter, accept: false) }
            )
            invitationsContinuation.yield(invitation)

        case .peerJoined(let peer):
            membershipContinuation.yield(.joined(SessionPeer(id: peer)))
            inviteWaiters.removeValue(forKey: peer)?.resume(returning: SessionPeer(id: peer))

        case .peerLeft(let peer):
            membershipContinuation.yield(.left(peer))

        case .invitationFailed(let peer, let reason):
            let error: PeerMeshError
            switch reason {
            case .declined: error = PeerMeshError.invitationDeclined
            case .timedOut: error = PeerMeshError.invitationTimedOut
            case .connectionLost: error = PeerMeshError.peerUnreachable(peer)
            }
            inviteWaiters.removeValue(forKey: peer)?.resume(throwing: error)

        case .messageReceived(let payload, let sender, let delivery):
            messagesContinuation.yield(
                InboundMessage(sender: sender, payload: payload, delivery: delivery))
        }
    }

    // MARK: - Inputs from the world

    private func adopt(_ connection: any PeerConnection) {
        let peer = connection.remotePeer
        connections[peer] = connection
        let events = connection.events
        receiveTasks[peer] = Task { [weak self] in
            for await event in events {
                await self?.handleConnectionEvent(event, from: peer)
            }
        }
        run(.connectionEstablished(peer))
    }

    private func handleConnectionEvent(_ event: PeerConnectionEvent, from peer: PeerID) {
        switch event {
        case .signal(let bytes):
            do {
                let signal = try SignalCodec.decode(bytes)
                run(.signal(signal, from: peer))
            } catch {
                // DD-5 rule 3: malformed signaling is connection-fatal.
                execute(.closeConnection(peer))
                run(.connectionClosed(peer))
            }
        case .data(let payload, let delivery):
            run(.dataReceived(payload, from: peer, delivery: delivery))
        case .closed:
            connections.removeValue(forKey: peer)
            receiveTasks.removeValue(forKey: peer)?.cancel()
            run(.connectionClosed(peer))
        }
    }

    private func handleDiscovery(_ event: DiscoveryEvent) {
        switch event {
        case .found(let peer), .updated(let peer):
            knownEndpoints[peer.id] = peer
        case .lost(let id):
            knownEndpoints.removeValue(forKey: id)
        }
        discoveriesContinuation.yield(event)
    }

    private func respond(to peer: PeerID, accept: Bool) {
        run(.command(.respondToInvitation(from: peer, accept: accept)))
    }

    private func timerFired(_ key: ProtocolEngine.TimerKey) {
        timers.removeValue(forKey: key)
        run(.timerFired(key))
    }
}

/// Handle to an in-flight resource transfer (FR-17).
public struct ResourceTransfer: Sendable {
    public let id: UUID
    public let progress: Progress
}

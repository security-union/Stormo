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
    /// Incoming resource transfers (FR-17): `.started` / `.finished` / `.failed`,
    /// mirroring MPC's `didStartReceivingResource` / `didFinishReceivingResource`.
    nonisolated public let resources: AsyncStream<ResourceEvent>
    /// Application byte streams opened by remote peers (FR-18).
    nonisolated public let incomingStreams: AsyncStream<(label: String, from: PeerID, stream: any PeerByteStream)>

    private let discoveriesContinuation: AsyncStream<DiscoveryEvent>.Continuation
    private let invitationsContinuation: AsyncStream<Invitation>.Continuation
    private let membershipContinuation: AsyncStream<MembershipEvent>.Continuation
    private let messagesContinuation: AsyncStream<InboundMessage>.Continuation
    private let resourcesContinuation: AsyncStream<ResourceEvent>.Continuation
    private let incomingStreamsContinuation: AsyncStream<(label: String, from: PeerID, stream: any PeerByteStream)>.Continuation

    // MARK: Runtime state (driver bookkeeping only — no protocol decisions)

    private var connections: [PeerID: any PeerConnection] = [:]
    private var receiveTasks: [PeerID: Task<Void, Never>] = [:]
    private var streamTasks: [PeerID: Task<Void, Never>] = [:]
    private var timers: [ProtocolEngine.TimerKey: Task<Void, Never>] = [:]
    private var knownEndpoints: [PeerID: DiscoveredPeer] = [:]
    private var inviteWaiters: [PeerID: CheckedContinuation<SessionPeer, Error>] = [:]
    private var inboundTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?

    // Ordered delivery (DD-7). Outbound: a per-peer sequence counter stamped on
    // `.reliableOrdered` sends. Inbound: a per-peer reorder buffer that releases
    // strictly in sequence order. Reliable transport never loses, so the buffer
    // only absorbs reordering; overflow past the cap is connection-fatal.
    private var outboundSequence: [PeerID: UInt64] = [:]
    private var expectedInboundSequence: [PeerID: UInt64] = [:]
    private var reorderBuffer: [PeerID: [UInt64: Data]] = [:]
    private let reorderBufferCap = 4096

    // Resource-transfer matching (FR-17): a `transferChunk` stream is paired to
    // its `TransferOffer` by transfer id; either may arrive first.
    private var pendingOffers: [UUID: (name: String, totalBytes: UInt64, from: PeerID)] = [:]
    private var pendingChunkStreams: [UUID: any PeerByteStream] = [:]

    // App-byte-stream matching (FR-18): an `appStream` is paired to its
    // `StreamOpen` announcement by label (FIFO per peer).
    private var pendingStreamOpens: [PeerID: [String]] = [:]
    private var pendingAppStreams: [PeerID: [(label: String, stream: any PeerByteStream)]] = [:]

    private static let resourceChunkSize = 256 * 1024

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
        (self.resources, self.resourcesContinuation) = AsyncStream.makeStream()
        (self.incomingStreams, self.incomingStreamsContinuation) = AsyncStream.makeStream()
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
    /// bounded memory (FR-17, QA-3). Announces the transfer on the control
    /// stream (`TransferOffer`), then streams the file in 256 KB chunks on a
    /// dedicated `transferChunk` stream. Cancel via ``ResourceTransfer/progress``.
    public func sendResource(at url: URL, to peer: PeerID, name resourceName: String? = nil) async throws -> ResourceTransfer {
        guard engine.members.contains(peer), let connection = connections[peer] else {
            throw PeerMeshError.peerUnreachable(peer)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let totalBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let name = resourceName ?? url.lastPathComponent
        let id = UUID()

        let progress = Progress(totalUnitCount: Int64(totalBytes))
        progress.isCancellable = true

        // Announce on the control stream (FR-17); the receiver's engine emits
        // `.transferOffered` and pairs it with the chunk stream by `id`.
        try await connection.sendSignal(
            SignalCodec.encode(.transferOffer(id: id, name: name, totalBytes: totalBytes)))

        let writer = try await connection.openOutgoingStream(
            header: StreamHeaderInfo(kind: .transferChunk, transferID: id))

        Task.detached {
            await Self.streamResource(
                from: url, to: writer, chunkSize: Self.resourceChunkSize, progress: progress)
        }
        return ResourceTransfer(id: id, progress: progress)
    }

    /// Open a named bidirectional byte stream with a peer (FR-18). Announces it
    /// on the control stream (`StreamOpen`), then opens the dedicated `appStream`.
    public func openStream(_ label: String, with peer: PeerID) async throws -> any PeerByteStream {
        guard engine.members.contains(peer), let connection = connections[peer] else {
            throw PeerMeshError.peerUnreachable(peer)
        }
        try await connection.sendSignal(SignalCodec.encode(.streamOpen(label: label)))
        return try await connection.openOutgoingStream(
            header: StreamHeaderInfo(kind: .appStream, label: label))
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
        for task in streamTasks.values { task.cancel() }
        for timer in timers.values { timer.cancel() }
        receiveTasks.removeAll()
        streamTasks.removeAll()
        timers.removeAll()
        await transport.stopAdvertising()
        await transport.stopBrowsing()
        discoveriesContinuation.finish()
        invitationsContinuation.finish()
        membershipContinuation.finish()
        messagesContinuation.finish()
        resourcesContinuation.finish()
        incomingStreamsContinuation.finish()
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
            // Assign the per-peer FIFO sequence synchronously (in send order)
            // for `.reliableOrdered`; it rides with the payload as
            // `StreamHeader.sequence` (DD-7). Plain reliable/datagram carry nil.
            let sequence: UInt64?
            if delivery == .reliableOrdered {
                let next = outboundSequence[peer, default: 0]
                outboundSequence[peer] = next + 1
                sequence = next
            } else {
                sequence = nil
            }
            Task { try? await connection.sendData(payload, delivery: delivery, sequence: sequence) }

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
            let connection = connections[peer]
            forgetConnection(peer)
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

        case .transferOffered(let id, let name, let totalBytes, let from):
            pendingOffers[id] = (name: name, totalBytes: totalBytes, from: from)
            matchTransfer(id)

        case .streamOpened(let label, let from):
            pendingStreamOpens[from, default: []].append(label)
            matchAppStream(from)
        }
    }

    // MARK: - Resource transfer & app streams (FR-17, FR-18)

    /// Pairs a `transferChunk` stream with its `TransferOffer` and, once both
    /// are present, starts the disk-to-disk receive (bounded memory, QA-3).
    private func matchTransfer(_ id: UUID) {
        guard let offer = pendingOffers[id], let stream = pendingChunkStreams[id] else { return }
        pendingOffers.removeValue(forKey: id)
        pendingChunkStreams.removeValue(forKey: id)

        let progress = Progress(totalUnitCount: Int64(offer.totalBytes))
        progress.isCancellable = true
        resourcesContinuation.yield(.started(name: offer.name, from: offer.from, progress: progress))

        let continuation = resourcesContinuation
        Task.detached {
            await Self.receiveResource(
                stream: stream, name: offer.name, from: offer.from,
                totalBytes: offer.totalBytes, progress: progress, into: continuation)
        }
    }

    /// Surfaces an `appStream` once its `StreamOpen` announcement (membership-
    /// gated by the engine) has also arrived (FR-18).
    private func matchAppStream(_ peer: PeerID) {
        guard var opens = pendingStreamOpens[peer], var streams = pendingAppStreams[peer] else {
            return
        }
        var index = 0
        while index < streams.count {
            if let openIndex = opens.firstIndex(of: streams[index].label) {
                opens.remove(at: openIndex)
                let matched = streams.remove(at: index)
                incomingStreamsContinuation.yield((label: matched.label, from: peer, stream: matched.stream))
            } else {
                index += 1
            }
        }
        pendingStreamOpens[peer] = opens.isEmpty ? nil : opens
        pendingAppStreams[peer] = streams.isEmpty ? nil : streams
    }

    /// Streams a file to a peer in fixed-size chunks (sender side, QA-3).
    /// Cancellation (`Progress.cancel()`) stops early and FINs the stream, which
    /// the receiver detects as an incomplete transfer.
    private static func streamResource(
        from url: URL,
        to writer: any PeerByteStream,
        chunkSize: Int,
        progress: Progress
    ) async {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            await writer.finish()
            return
        }
        defer { try? handle.close() }
        while !progress.isCancelled {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            do {
                try await writer.write(chunk)
            } catch {
                break
            }
            progress.completedUnitCount += Int64(chunk.count)
        }
        await writer.finish()
    }

    /// Receives a transfer disk-to-disk into a temp file (receiver side, QA-3),
    /// surfacing `.finished` on completion or `.failed` on cancellation/loss.
    private static func receiveResource(
        stream: any PeerByteStream,
        name: String,
        from: PeerID,
        totalBytes: UInt64,
        progress: Progress,
        into continuation: AsyncStream<ResourceEvent>.Continuation
    ) async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            continuation.yield(.failed(name: name, from: from, error: PeerMeshError.resourceTransferIncomplete))
            return
        }

        var received: UInt64 = 0
        var failure: Error?
        do {
            for try await chunk in stream.incoming {
                if progress.isCancelled { break }
                try handle.write(contentsOf: chunk)
                received += UInt64(chunk.count)
                progress.completedUnitCount = Int64(received)
            }
        } catch {
            failure = error
        }
        try? handle.close()

        if failure == nil, !progress.isCancelled, received == totalBytes {
            continuation.yield(.finished(name: name, from: from, at: tempURL))
        } else {
            try? FileManager.default.removeItem(at: tempURL)
            continuation.yield(.failed(
                name: name, from: from,
                error: failure ?? PeerMeshError.resourceTransferIncomplete))
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
        let streams = connection.incomingStreams
        streamTasks[peer] = Task { [weak self] in
            for await (header, stream) in streams {
                await self?.handleIncomingStream(header, stream, from: peer)
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
        case .data(let payload, let delivery, let sequence):
            if delivery == .reliableOrdered, let sequence {
                deliverOrdered(payload, sequence: sequence, from: peer)
            } else {
                run(.dataReceived(payload, from: peer, delivery: delivery))
            }
        case .closed:
            forgetConnection(peer)
            run(.connectionClosed(peer))
        }
    }

    /// Releases `.reliableOrdered` messages strictly in sequence order (DD-7).
    /// Reliable transport never loses, so the buffer only absorbs reordering;
    /// exceeding the cap means the peer is misbehaving → connection-fatal.
    private func deliverOrdered(_ payload: Data, sequence: UInt64, from peer: PeerID) {
        var expected = expectedInboundSequence[peer, default: 0]
        guard sequence >= expected else { return }  // duplicate — cannot happen on reliable
        var buffer = reorderBuffer[peer, default: [:]]
        buffer[sequence] = payload

        if buffer.count > reorderBufferCap {
            reorderBuffer[peer] = nil
            expectedInboundSequence[peer] = nil
            execute(.closeConnection(peer))
            run(.connectionClosed(peer))
            return
        }

        while let next = buffer.removeValue(forKey: expected) {
            run(.dataReceived(next, from: peer, delivery: .reliableOrdered))
            expected += 1
        }
        reorderBuffer[peer] = buffer
        expectedInboundSequence[peer] = expected
    }

    private func handleIncomingStream(
        _ header: StreamHeaderInfo, _ stream: any PeerByteStream, from peer: PeerID
    ) {
        switch header.kind {
        case .transferChunk:
            guard let id = header.transferID else { return }
            pendingChunkStreams[id] = stream
            matchTransfer(id)
        case .appStream:
            let label = header.label ?? stream.label
            pendingAppStreams[peer, default: []].append((label: label, stream: stream))
            matchAppStream(peer)
        case .message, .orderedMessage:
            // Messages arrive as `.data` connection events, not dedicated streams.
            break
        }
    }

    /// Drops all per-peer runtime bookkeeping for a closed connection.
    private func forgetConnection(_ peer: PeerID) {
        connections.removeValue(forKey: peer)
        receiveTasks.removeValue(forKey: peer)?.cancel()
        streamTasks.removeValue(forKey: peer)?.cancel()
        outboundSequence.removeValue(forKey: peer)
        expectedInboundSequence.removeValue(forKey: peer)
        reorderBuffer.removeValue(forKey: peer)
        pendingStreamOpens.removeValue(forKey: peer)
        pendingAppStreams.removeValue(forKey: peer)
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

/// An incoming resource transfer's lifecycle (FR-17), mirroring MPC's
/// `didStartReceivingResource` / `didFinishReceivingResource` semantics.
///
/// `@unchecked Sendable`: `Progress` is a Foundation reference type (already
/// treated as sendable by ``ResourceTransfer``) and the `.failed` error is an
/// `any Error` we only ever populate with sendable value types.
public enum ResourceEvent: @unchecked Sendable {
    /// The transfer began; observe/cancel via `progress`.
    case started(name: String, from: PeerID, progress: Progress)
    /// The transfer completed; the file is at `at` (a temp URL the app owns).
    case finished(name: String, from: PeerID, at: URL)
    /// The transfer failed or was cancelled; any partial temp file is discarded.
    case failed(name: String, from: PeerID, error: any Error)
}

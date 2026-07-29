import Foundation
import Stormo

/// In-process transport for tests and mesh simulation (QA-8): exercises the
/// full runtime — discovery, invitation, membership, messaging — with no
/// radios, so multi-peer sessions run in CI.
///
/// All `InMemoryTransport` instances sharing a `Hub` see each other's
/// advertisements, as if on one network segment.
public final class InMemoryTransport: PeerTransport, @unchecked Sendable {

    // MARK: Hub — a simulated network segment

    public actor Hub {
        struct Advertisement {
            let service: ServiceDescriptor
            let metadata: [String: String]
            let identity: PeerIdentity
            let inbound: AsyncStream<any PeerConnection>.Continuation
        }

        private var advertisements: [PeerID: Advertisement] = [:]
        private var browsers: [UUID: (service: ServiceDescriptor, continuation: AsyncStream<DiscoveryEvent>.Continuation)] = [:]

        public init() {}

        func advertise(
            service: ServiceDescriptor,
            metadata: [String: String],
            identity: PeerIdentity,
            inbound: AsyncStream<any PeerConnection>.Continuation
        ) {
            let ad = Advertisement(
                service: service, metadata: metadata, identity: identity, inbound: inbound)
            advertisements[identity.id] = ad
            let peer = DiscoveredPeer(id: identity.id, metadata: metadata)
            for (_, browser) in browsers where browser.service == service {
                browser.continuation.yield(.found(peer))
            }
        }

        func withdraw(_ peerID: PeerID) {
            guard let ad = advertisements.removeValue(forKey: peerID) else { return }
            for (_, browser) in browsers where browser.service == ad.service {
                browser.continuation.yield(.lost(peerID))
            }
        }

        func browse(service: ServiceDescriptor) -> AsyncStream<DiscoveryEvent> {
            let token = UUID()
            let (stream, continuation) = AsyncStream<DiscoveryEvent>.makeStream()
            continuation.onTermination = { _ in
                Task { await self.endBrowse(token) }
            }
            browsers[token] = (service, continuation)
            // Replay peers already advertising (Bonjour semantics).
            for ad in advertisements.values where ad.service == service {
                continuation.yield(.found(DiscoveredPeer(id: ad.identity.id, metadata: ad.metadata)))
            }
            return stream
        }

        private func endBrowse(_ token: UUID) {
            browsers.removeValue(forKey: token)
        }

        /// Broker a connection pair: dialer gets one end, the advertiser's
        /// inbound stream receives the other.
        func connect(to peerID: PeerID, from identity: PeerIdentity) throws -> any PeerConnection {
            guard let ad = advertisements[peerID] else {
                throw StormoError.peerUnreachable(peerID)
            }
            let (dialerEnd, listenerEnd) = InMemoryConnection.pair(
                dialer: identity, listener: ad.identity)
            ad.inbound.yield(listenerEnd)
            return dialerEnd
        }
    }

    // MARK: Transport conformance

    private let hub: Hub
    public let inboundConnections: AsyncStream<any PeerConnection>
    private let inboundContinuation: AsyncStream<any PeerConnection>.Continuation
    private let advertisedPeer = Locked<PeerID?>(nil)

    public init(hub: Hub) {
        self.hub = hub
        (self.inboundConnections, self.inboundContinuation) = AsyncStream.makeStream()
    }

    public func startAdvertising(
        service: ServiceDescriptor,
        metadata: [String: String],
        identity: PeerIdentity
    ) async throws {
        advertisedPeer.value = identity.id
        await hub.advertise(
            service: service, metadata: metadata, identity: identity,
            inbound: inboundContinuation)
    }

    public func stopAdvertising() async {
        guard let peer = advertisedPeer.value else { return }
        advertisedPeer.value = nil
        await hub.withdraw(peer)
    }

    public func discoveries(service: ServiceDescriptor) async throws -> AsyncStream<DiscoveryEvent> {
        await hub.browse(service: service)
    }

    public func stopBrowsing() async {}

    public func connect(
        to peer: DiscoveredPeer,
        identity: PeerIdentity,
        trust: TrustPolicy
    ) async throws -> any PeerConnection {
        try await hub.connect(to: peer.id, from: identity)
    }
}

// MARK: - In-memory connection pair

/// One end of a brokered in-memory connection. Bytes yielded on one end's
/// send methods surface as events on the other end's stream — the entire
/// "network" is two AsyncStream continuations.
final class InMemoryConnection: PeerConnection, @unchecked Sendable {
    let remotePeer: PeerID
    let remoteKeyHash: Data
    let events: AsyncStream<PeerConnectionEvent>
    let incomingStreams: AsyncStream<(StreamHeaderInfo, any PeerByteStream)>

    private let ownContinuation: AsyncStream<PeerConnectionEvent>.Continuation
    private let incomingStreamsContinuation: AsyncStream<(StreamHeaderInfo, any PeerByteStream)>.Continuation
    private let partnerBox = Locked<InMemoryConnection?>(nil)
    private let closed = Locked<Bool>(false)

    private init(remote: PeerIdentity) {
        self.remotePeer = remote.id
        self.remoteKeyHash = remote.id.keyHash
        (self.events, self.ownContinuation) = AsyncStream.makeStream()
        (self.incomingStreams, self.incomingStreamsContinuation) = AsyncStream.makeStream()
    }

    static func pair(
        dialer: PeerIdentity, listener: PeerIdentity
    ) -> (dialerEnd: InMemoryConnection, listenerEnd: InMemoryConnection) {
        let dialerEnd = InMemoryConnection(remote: listener)
        let listenerEnd = InMemoryConnection(remote: dialer)
        dialerEnd.partnerBox.value = listenerEnd
        listenerEnd.partnerBox.value = dialerEnd
        return (dialerEnd, listenerEnd)
    }

    func sendSignal(_ bytes: Data) async throws {
        guard !closed.value, let partner = partnerBox.value else {
            throw StormoError.peerUnreachable(remotePeer)
        }
        partner.ownContinuation.yield(.signal(bytes))
    }

    func sendData(_ payload: Data, delivery: Delivery, sequence: UInt64?) async throws {
        guard !closed.value, let partner = partnerBox.value else {
            throw StormoError.peerUnreachable(remotePeer)
        }
        partner.ownContinuation.yield(.data(payload, delivery, sequence: sequence))
    }

    func openOutgoingStream(header: StreamHeaderInfo) async throws -> any PeerByteStream {
        guard !closed.value, let partner = partnerBox.value else {
            throw StormoError.peerUnreachable(remotePeer)
        }
        // The dedicated stream is a paired byte pipe; the writer stays local,
        // the reader surfaces on the partner's incomingStreams (with the header).
        let (writerEnd, readerEnd) = InMemoryByteStream.pair(label: header.label ?? "")
        partner.incomingStreamsContinuation.yield((header, readerEnd))
        return writerEnd
    }

    func close() async {
        guard !closed.value else { return }
        closed.value = true
        if let partner = partnerBox.value {
            partner.ownContinuation.yield(.closed)
            partner.ownContinuation.finish()
            partner.incomingStreamsContinuation.finish()
        }
        // Driver contract (matches QUICConnection): BOTH ends observe an
        // explicit `.closed`, including the side that initiated it.
        ownContinuation.yield(.closed)
        ownContinuation.finish()
        incomingStreamsContinuation.finish()
        partnerBox.value = nil
    }
}

// MARK: - In-memory byte stream pair (FR-17 / FR-18)

/// One end of a dedicated byte stream. `write` yields to the partner's
/// `incoming`; `finish` FINs it. Back-pressure is API-shaped (writes are
/// `async` and cancellation-aware); the in-memory buffer itself is unbounded.
final class InMemoryByteStream: PeerByteStream, @unchecked Sendable {
    let label: String
    let incoming: AsyncThrowingStream<Data, Error>

    private let incomingContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let partnerBox = Locked<InMemoryByteStream?>(nil)
    private let finished = Locked<Bool>(false)

    private init(label: String) {
        self.label = label
        (self.incoming, self.incomingContinuation) = AsyncThrowingStream.makeStream()
    }

    static func pair(label: String) -> (writerEnd: InMemoryByteStream, readerEnd: InMemoryByteStream) {
        let a = InMemoryByteStream(label: label)
        let b = InMemoryByteStream(label: label)
        a.partnerBox.value = b
        b.partnerBox.value = a
        return (a, b)
    }

    func write(_ data: Data) async throws {
        guard !finished.value, let partner = partnerBox.value else {
            throw StormoError.resourceTransferIncomplete
        }
        partner.incomingContinuation.yield(data)
    }

    func finish() async {
        guard !finished.value else { return }
        finished.value = true
        partnerBox.value?.incomingContinuation.finish()  // FIN delimits the payload
        partnerBox.value = nil
    }
}

// MARK: - Reordering decorator (test-only)

/// Wraps any `PeerTransport` and deliberately **reorders application data**
/// events on delivery, to prove ordered delivery (DD-7) works. Control signals
/// and dedicated streams pass through untouched (only `.data` events are
/// shuffled). Consecutive data messages are delivered with alternating delays
/// so adjacent messages swap: `.reliableOrdered` is put back in order by the
/// runtime's reorder buffer, while plain `.reliable` surfaces out of order.
public final class ReorderingTransport: PeerTransport, @unchecked Sendable {
    private let base: any PeerTransport
    private let longDelay: UInt64
    private let shortDelay: UInt64
    public let inboundConnections: AsyncStream<any PeerConnection>

    /// - Parameters:
    ///   - base: the transport whose deliveries are reordered.
    ///   - longDelayNanos/shortDelayNanos: alternating per-message delays; the
    ///     gap between them must dominate inter-arrival jitter for a reliable swap.
    public init(
        base: any PeerTransport,
        longDelayNanos: UInt64 = 80_000_000,
        shortDelayNanos: UInt64 = 5_000_000
    ) {
        self.base = base
        self.longDelay = longDelayNanos
        self.shortDelay = shortDelayNanos
        let (stream, continuation) = AsyncStream<any PeerConnection>.makeStream()
        self.inboundConnections = stream
        let long = longDelayNanos
        let short = shortDelayNanos
        let baseInbound = base.inboundConnections
        Task {
            for await connection in baseInbound {
                continuation.yield(ReorderingConnection(
                    base: connection, longDelay: long, shortDelay: short))
            }
            continuation.finish()
        }
    }

    public func startAdvertising(
        service: ServiceDescriptor, metadata: [String: String], identity: PeerIdentity
    ) async throws {
        try await base.startAdvertising(service: service, metadata: metadata, identity: identity)
    }

    public func stopAdvertising() async { await base.stopAdvertising() }

    public func discoveries(service: ServiceDescriptor) async throws -> AsyncStream<DiscoveryEvent> {
        try await base.discoveries(service: service)
    }

    public func stopBrowsing() async { await base.stopBrowsing() }

    public func connect(
        to peer: DiscoveredPeer, identity: PeerIdentity, trust: TrustPolicy
    ) async throws -> any PeerConnection {
        let connection = try await base.connect(to: peer, identity: identity, trust: trust)
        return ReorderingConnection(base: connection, longDelay: longDelay, shortDelay: shortDelay)
    }
}

final class ReorderingConnection: PeerConnection, @unchecked Sendable {
    private let base: any PeerConnection
    let events: AsyncStream<PeerConnectionEvent>

    var remotePeer: PeerID { base.remotePeer }
    var remoteKeyHash: Data { base.remoteKeyHash }
    var incomingStreams: AsyncStream<(StreamHeaderInfo, any PeerByteStream)> { base.incomingStreams }

    init(base: any PeerConnection, longDelay: UInt64, shortDelay: UInt64) {
        self.base = base
        let (stream, continuation) = AsyncStream<PeerConnectionEvent>.makeStream()
        self.events = stream
        let baseEvents = base.events
        Task {
            var dataIndex = 0
            var pending: [Task<Void, Never>] = []
            for await event in baseEvents {
                switch event {
                case .data:
                    let delay = (dataIndex % 2 == 0) ? longDelay : shortDelay
                    dataIndex += 1
                    pending.append(Task {
                        try? await Task.sleep(nanoseconds: delay)
                        continuation.yield(event)
                    })
                case .signal:
                    continuation.yield(event)  // control order preserved
                case .closed:
                    for task in pending { await task.value }
                    continuation.yield(.closed)
                    continuation.finish()
                    return
                }
            }
            for task in pending { await task.value }
            continuation.finish()
        }
    }

    func sendSignal(_ bytes: Data) async throws { try await base.sendSignal(bytes) }

    func sendData(_ payload: Data, delivery: Delivery, sequence: UInt64?) async throws {
        try await base.sendData(payload, delivery: delivery, sequence: sequence)
    }

    func openOutgoingStream(header: StreamHeaderInfo) async throws -> any PeerByteStream {
        try await base.openOutgoingStream(header: header)
    }

    func close() async { await base.close() }
}

import Foundation
import PeerMesh

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
                throw PeerMeshError.peerUnreachable(peerID)
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

    private let ownContinuation: AsyncStream<PeerConnectionEvent>.Continuation
    private let partnerBox = Locked<InMemoryConnection?>(nil)
    private let closed = Locked<Bool>(false)

    private init(remote: PeerIdentity) {
        self.remotePeer = remote.id
        self.remoteKeyHash = remote.id.keyHash
        (self.events, self.ownContinuation) = AsyncStream.makeStream()
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
            throw PeerMeshError.peerUnreachable(remotePeer)
        }
        partner.ownContinuation.yield(.signal(bytes))
    }

    func sendData(_ payload: Data, delivery: Delivery) async throws {
        guard !closed.value, let partner = partnerBox.value else {
            throw PeerMeshError.peerUnreachable(remotePeer)
        }
        partner.ownContinuation.yield(.data(payload, delivery))
    }

    func close() async {
        guard !closed.value else { return }
        closed.value = true
        if let partner = partnerBox.value {
            partner.ownContinuation.yield(.closed)
            partner.ownContinuation.finish()
        }
        ownContinuation.finish()
        partnerBox.value = nil
    }
}

/// Minimal lock box for transport-internal state.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) {
        self.stored = value
    }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

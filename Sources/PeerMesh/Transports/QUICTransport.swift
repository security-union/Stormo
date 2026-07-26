import Foundation
import PeerMeshProtocol

#if canImport(Network)
import Network
#endif

#if canImport(Security)
import Security
#endif

/// Primary transport (DD-1): one QUIC connection per peer pair over
/// `NWConnectionGroup` + `NWMultiplexGroup` (Spike S-3), Bonjour discovery via
/// `NWListener`/`NWBrowser`, peer-to-peer Wi-Fi via `includePeerToPeer` (FR-3).
///
/// Validated on `127.0.0.1` (tier 2, DD-6): the same end-to-end suite that runs
/// over `InMemoryTransport` runs over real QUIC here. AWDL on hardware is tier 3
/// (Spike S-1). If S-1 fails, `TCPTLSTransport` is promoted (design doc §8).
///
/// See `docs/spike-results.md` for the S-3 (multiplex) and S-6 (stream churn)
/// findings and the TLS-identity situation under `swift test`.
#if canImport(Network) && canImport(Security)
public final class QUICTransport: PeerTransport, @unchecked Sendable {

    // MARK: Configuration

    /// A host-supplied TLS identity (opaque). Lets an app with keychain
    /// entitlements inject a `SecIdentity` directly, bypassing the driver's own
    /// identity assembly (see ``Configuration/tlsProvider``).
    public final class TLSIdentity: @unchecked Sendable {
        let local: QUICLocalIdentity
        /// - Returns: `nil` if the `SecIdentity` cannot be wrapped for TLS.
        public init?(secIdentity: SecIdentity) {
            guard let identityT = sec_identity_create(secIdentity) else { return nil }
            self.local = QUICLocalIdentity(secIdentity: identityT)
        }
    }

    public struct Configuration: Sendable {
        /// How peers find each other. `.bonjour` is production (FR-1/FR-2);
        /// `.rendezvous` is a deterministic direct-endpoint path for CI/tests
        /// (loopback), independent of mDNS.
        public enum Discovery: Sendable {
            case bonjour
            case rendezvous(Rendezvous)
        }

        public var discovery: Discovery

        /// Optional hook to supply the local TLS identity. When `nil`, the driver
        /// forms one itself (entitled data-protection keychain, else — on macOS —
        /// a transient file keychain; see `docs/spike-results.md`). Hosts running
        /// with keychain entitlements can inject a `SecIdentity` here.
        public var tlsProvider: (@Sendable (PeerIdentity, TrustPolicy) throws -> TLSIdentity)?

        public init(
            discovery: Discovery = .bonjour,
            tlsProvider: (@Sendable (PeerIdentity, TrustPolicy) throws -> TLSIdentity)? = nil
        ) {
            self.discovery = discovery
            self.tlsProvider = tlsProvider
        }
    }

    // MARK: PeerTransport surface

    public let inboundConnections: AsyncStream<any PeerConnection>
    private let inboundContinuation: AsyncStream<any PeerConnection>.Continuation

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "dev.securityunion.peermesh.quic")

    // Advertiser state.
    private let listenerBox = Locked<NWListener?>(nil)
    private let listenerIdentity = Locked<QUICLocalIdentity?>(nil)
    private let advertisedPeer = Locked<PeerID?>(nil)

    // Browser state + the per-transport endpoint registry (item 2): browse
    // results (Bonjour TXT or rendezvous) → endpoints, keyed by PeerID, so
    // `connect(to:)` can dial a `DiscoveredPeer` that carries only id+metadata.
    private let browserBox = Locked<NWBrowser?>(nil)
    private let endpoints = Locked<[PeerID: NWEndpoint]>([:])
    private let seenPeers = Locked<Set<PeerID>>([])

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        (self.inboundConnections, self.inboundContinuation) = AsyncStream.makeStream()
    }

    /// Whether a local TLS identity can be formed for `identity` in this process
    /// (see `docs/spike-results.md`). A bare `swift test` process has no keychain
    /// entitlement; on macOS the driver falls back to a transient file keychain,
    /// so this is `true`. On platforms with no entitlement-free route it is
    /// `false` — QUIC tests should skip cleanly and hosts should inject a
    /// `SecIdentity` via ``Configuration/tlsProvider``.
    public static func isTLSIdentityAvailable(for identity: PeerIdentity) -> Bool {
        guard let local = try? QUICTLS.makeLocalIdentity(for: identity) else { return false }
        local.dispose()
        return true
    }

    /// Human-readable outcome of attempting to form the local TLS identity —
    /// "OK", or the failure reason (per resolution path). For diagnostics and
    /// test-skip messages; the boolean twin is ``isTLSIdentityAvailable(for:)``.
    public static func tlsIdentityDiagnostic(for identity: PeerIdentity) -> String {
        do {
            let local = try QUICTLS.makeLocalIdentity(for: identity)
            local.dispose()
            return "OK"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Advertising (FR-1, FR-3, FR-5)

    public func startAdvertising(
        service: ServiceDescriptor,
        metadata: [String: String],
        identity: PeerIdentity
    ) async throws {
        let localIdentity = try makeLocalIdentity(for: identity)
        listenerIdentity.value = localIdentity

        let params = QUICTLS.parameters(localIdentity: localIdentity, trust: .automatic, isListener: true)
        // Peer-to-peer Wi-Fi (FR-3) is a Bonjour/AWDL concern; enabling it on the
        // loopback rendezvous path prevents the listener from accepting 127.0.0.1
        // connections, so it is gated to the Bonjour (production) path.
        let isBonjour: Bool
        if case .bonjour = configuration.discovery { isBonjour = true } else { isBonjour = false }
        params.includePeerToPeer = isBonjour

        let listener = try NWListener(using: params)
        if isBonjour {
            listener.service = NWListener.Service(
                name: String(identity.id.base58String.prefix(24)),
                type: service.type,
                txtRecord: makeTXTRecord(identity: identity, metadata: metadata))
        }

        let localPeer = identity.id
        let queue = self.queue
        let inbound = self.inboundContinuation
        listener.newConnectionGroupHandler = { group in
            QUICConnection.accept(group: group, localPeer: localPeer, queue: queue) { connection in
                inbound.yield(connection)
            }
        }

        listenerBox.value = listener
        advertisedPeer.value = localPeer

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let done = Locked(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if done.compareAndSet(expected: false, new: true) { cont.resume() }
                case .failed(let error):
                    if done.compareAndSet(expected: false, new: true) { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        // Register the bound endpoint for the direct-endpoint path.
        if case .rendezvous(let rendezvous) = configuration.discovery, let port = listener.port {
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            await rendezvous.advertise(
                service: service, peer: localPeer, endpoint: endpoint, metadata: metadata)
        }
    }

    public func stopAdvertising() async {
        listenerBox.value?.cancel()
        listenerBox.value = nil
        if let peer = advertisedPeer.value, case .rendezvous(let rendezvous) = configuration.discovery {
            await rendezvous.withdraw(peer)
        }
        advertisedPeer.value = nil
        listenerIdentity.value?.dispose()
        listenerIdentity.value = nil
    }

    // MARK: Browsing (FR-2, FR-5)

    public func discoveries(service: ServiceDescriptor) async throws -> AsyncStream<DiscoveryEvent> {
        switch configuration.discovery {
        case .rendezvous(let rendezvous):
            return await rendezvous.browse(service: service, sink: endpoints)
        case .bonjour:
            return bonjourDiscoveries(service: service)
        }
    }

    private func bonjourDiscoveries(service: ServiceDescriptor) -> AsyncStream<DiscoveryEvent> {
        let (stream, continuation) = AsyncStream<DiscoveryEvent>.makeStream()
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: service.type, domain: nil), using: params)
        let endpoints = self.endpoints
        let seen = self.seenPeers

        browser.browseResultsChangedHandler = { results, _ in
            var live = Set<PeerID>()
            for result in results {
                guard
                    case .bonjour(let txt) = result.metadata,
                    let peer = Self.peerID(fromTXT: txt)
                else { continue }
                live.insert(peer)
                endpoints.withLock { $0[peer] = result.endpoint }
                // FR-2: dedup across interfaces — emit `.found` once per PeerID.
                let isNew = seen.withLock { set -> Bool in
                    guard !set.contains(peer) else { return false }
                    set.insert(peer); return true
                }
                if isNew {
                    continuation.yield(.found(DiscoveredPeer(id: peer, metadata: Self.metadata(fromTXT: txt))))
                }
            }
            // Emit `.lost` for peers that disappeared from all interfaces.
            let gone = seen.withLock { set -> [PeerID] in
                let missing = set.subtracting(live)
                set.subtract(missing)
                return Array(missing)
            }
            for peer in gone {
                endpoints.withLock { $0[peer] = nil }
                continuation.yield(.lost(peer))
            }
        }
        browserBox.value = browser
        continuation.onTermination = { _ in browser.cancel() }
        browser.start(queue: queue)
        return stream
    }

    public func stopBrowsing() async {
        browserBox.value?.cancel()
        browserBox.value = nil
    }

    // MARK: Connecting (FR-12)

    public func connect(
        to peer: DiscoveredPeer,
        identity: PeerIdentity,
        trust: TrustPolicy
    ) async throws -> any PeerConnection {
        let endpoint: NWEndpoint?
        switch configuration.discovery {
        case .rendezvous(let rendezvous):
            endpoint = await rendezvous.endpoint(for: peer.id) ?? endpoints.value[peer.id]
        case .bonjour:
            endpoint = endpoints.value[peer.id]
        }
        guard let endpoint else { throw PeerMeshError.peerUnreachable(peer.id) }

        let localIdentity = try makeLocalIdentity(for: identity)
        return try await QUICConnection.dial(
            to: endpoint,
            localPeer: identity.id,
            remote: peer.id,
            localIdentity: localIdentity,
            trust: trust,
            queue: queue)
    }

    // MARK: Helpers

    private func makeLocalIdentity(for identity: PeerIdentity) throws -> QUICLocalIdentity {
        if let provider = configuration.tlsProvider {
            return try provider(identity, .automatic).local
        }
        return try QUICTLS.makeLocalIdentity(for: identity)
    }

    // MARK: TXT record encoding (Bonjour)

    private static let txtKeyHashField = "pm_kh"
    private static let txtNameField = "pm_dn"

    private func makeTXTRecord(identity: PeerIdentity, metadata: [String: String]) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt[Self.txtKeyHashField] = identity.id.keyHash.map { String(format: "%02x", $0) }.joined()
        txt[Self.txtNameField] = identity.id.displayName
        for (key, value) in metadata where key != Self.txtKeyHashField && key != Self.txtNameField {
            txt[key] = value
        }
        return txt
    }

    private static func peerID(fromTXT txt: NWTXTRecord) -> PeerID? {
        guard let hex = txt[txtKeyHashField], let keyHash = Data(hexString: hex) else { return nil }
        let name = txt[txtNameField] ?? ""
        return PeerID(keyHash: keyHash, displayName: name)
    }

    private static func metadata(fromTXT txt: NWTXTRecord) -> [String: String] {
        var out: [String: String] = [:]
        for key in txt.dictionary.keys where key != txtKeyHashField && key != txtNameField {
            if let value = txt[key] { out[key] = value }
        }
        return out
    }
}

// MARK: - Rendezvous (deterministic direct-endpoint discovery for CI/tests)

/// A shared coordinator that maps advertised `PeerID`s to their bound QUIC
/// endpoints — the direct-endpoint discovery path (item 2/7). Mirrors
/// ``InMemoryTransport/Hub`` semantics (advertisement replay, discovery
/// fan-out) but carries **real** loopback endpoints, so the same end-to-end
/// suite drives real QUIC without depending on mDNS.
public actor Rendezvous {
    struct Entry {
        let service: ServiceDescriptor
        let endpoint: NWEndpoint
        let metadata: [String: String]
    }

    private var entries: [PeerID: Entry] = [:]
    private var browsers: [UUID: (service: ServiceDescriptor, continuation: AsyncStream<DiscoveryEvent>.Continuation, sink: Locked<[PeerID: NWEndpoint]>)] = [:]

    public init() {}

    func advertise(service: ServiceDescriptor, peer: PeerID, endpoint: NWEndpoint, metadata: [String: String]) {
        entries[peer] = Entry(service: service, endpoint: endpoint, metadata: metadata)
        let discovered = DiscoveredPeer(id: peer, metadata: metadata)
        for browser in browsers.values where browser.service == service {
            browser.sink.withLock { $0[peer] = endpoint }
            browser.continuation.yield(.found(discovered))
        }
    }

    func withdraw(_ peer: PeerID) {
        guard let entry = entries.removeValue(forKey: peer) else { return }
        for browser in browsers.values where browser.service == entry.service {
            browser.sink.withLock { $0[peer] = nil }
            browser.continuation.yield(.lost(peer))
        }
    }

    func browse(service: ServiceDescriptor, sink: Locked<[PeerID: NWEndpoint]>) -> AsyncStream<DiscoveryEvent> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<DiscoveryEvent>.makeStream()
        continuation.onTermination = { _ in Task { await self.endBrowse(token) } }
        browsers[token] = (service, continuation, sink)
        // Replay peers already advertising (Bonjour semantics).
        for (peer, entry) in entries where entry.service == service {
            sink.withLock { $0[peer] = entry.endpoint }
            continuation.yield(.found(DiscoveredPeer(id: peer, metadata: entry.metadata)))
        }
        return stream
    }

    func endpoint(for peer: PeerID) -> NWEndpoint? { entries[peer]?.endpoint }

    private func endBrowse(_ token: UUID) { browsers.removeValue(forKey: token) }
}

// MARK: - Hex helper

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index ... index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        self = Data(bytes)
    }
}

#else

/// Fallback for platforms without Network/Security: the QUIC driver is
/// unavailable; `PeerSession` must be constructed with an explicit transport.
public struct QUICTransport: PeerTransport {
    public let inboundConnections: AsyncStream<any PeerConnection> = AsyncStream { _ in }
    public init() {}
    public func startAdvertising(service: ServiceDescriptor, metadata: [String: String], identity: PeerIdentity) async throws {
        throw PeerMeshError.unimplemented("QUICTransport requires Network.framework")
    }
    public func stopAdvertising() async {}
    public func discoveries(service: ServiceDescriptor) async throws -> AsyncStream<DiscoveryEvent> {
        throw PeerMeshError.unimplemented("QUICTransport requires Network.framework")
    }
    public func stopBrowsing() async {}
    public func connect(to peer: DiscoveredPeer, identity: PeerIdentity, trust: TrustPolicy) async throws -> any PeerConnection {
        throw PeerMeshError.unimplemented("QUICTransport requires Network.framework")
    }
}

#endif

import Foundation

/// Pluggable transport backend (FR-25, QA-7).
///
/// Drivers contain no protocol decisions (DD-6): they move bytes, surface
/// connections, and report lifecycle. Implementations: `QUICTransport`
/// (primary, DD-1), `TCPTLSTransport` (contingency, pending Spike S-1),
/// `WiFiAwareTransport` (post-1.0), and `InMemoryTransport` in
/// PeerMeshTestKit (QA-8).
public protocol PeerTransport: Sendable {
    /// Advertise the service with metadata (Bonjour TXT record) on all
    /// eligible paths, including peer-to-peer Wi-Fi (FR-1, FR-3).
    func startAdvertising(
        service: ServiceDescriptor,
        metadata: [String: String],
        identity: PeerIdentity
    ) async throws

    /// Stop advertising and release radio resources promptly (FR-5).
    func stopAdvertising() async

    /// Connections accepted while advertising. Each is secured (FR-19) but
    /// not yet authorized — the invitation handshake runs on top (FR-8).
    var inboundConnections: AsyncStream<any PeerConnection> { get }

    /// Browse for peers advertising `service`; events are deduplicated across
    /// network interfaces (FR-2).
    func discoveries(service: ServiceDescriptor) async throws -> AsyncStream<DiscoveryEvent>

    /// Stop browsing and release radio resources promptly (FR-5).
    func stopBrowsing() async

    /// Open a secured connection to a discovered peer (dial side of FR-12).
    func connect(
        to peer: DiscoveredPeer,
        identity: PeerIdentity,
        trust: TrustPolicy
    ) async throws -> any PeerConnection
}

/// Events surfaced by a single peer-pair connection.
public enum PeerConnectionEvent: Sendable {
    /// Encoded control-plane signal (control stream, DD-5). The runtime
    /// decodes via ``SignalCodec`` and feeds the engine.
    case signal(Data)
    /// Application data (per-message stream or datagram, DD-7).
    case data(Data, Delivery)
    /// The connection ended (peer closed, reset, or transport failure).
    case closed
}

/// A single secured peer-pair connection. One per pair (FR-12); all session
/// concerns multiplex over it (DD-1): signals on the control stream, each
/// reliable message on its own stream, datagrams for `.datagram` delivery.
public protocol PeerConnection: Sendable {
    var remotePeer: PeerID { get }
    /// SHA-256 of the remote peer's presented public key (TrustPolicy
    /// bookkeeping, FR-22).
    var remoteKeyHash: Data { get }

    /// Inbound events. Yields `.closed` exactly once at end of life.
    var events: AsyncStream<PeerConnectionEvent> { get }

    /// Send an encoded signal on the control stream (ordered, DD-5).
    func sendSignal(_ bytes: Data) async throws
    /// Send application data (DD-7: `.reliable`/`.reliableOrdered` = own
    /// stream; `.datagram` = QUIC datagram).
    func sendData(_ payload: Data, delivery: Delivery) async throws

    func close() async
}

/// A dedicated bidirectional byte stream with explicit back-pressure (FR-18).
/// TODO(Phase 2): opened via the connection once transfer/stream signaling lands.
public protocol PeerByteStream: Sendable {
    var label: String { get }
    func write(_ data: Data) async throws
    func finish() async
    var incoming: AsyncThrowingStream<Data, Error> { get }
}

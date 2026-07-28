import Foundation

/// Pluggable transport backend (FR-25, QA-7).
///
/// Drivers contain no protocol decisions (DD-6): they move bytes, surface
/// connections, and report lifecycle. Implementations: `QUICTransport`
/// (primary, DD-1), `TCPTLSTransport` (contingency, pending Spike S-1),
/// `WiFiAwareTransport` (post-1.0), and `InMemoryTransport` in
/// StromoTestKit (QA-8).
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
    /// Application data (per-message stream or datagram, DD-7). For
    /// `.reliableOrdered` the sender's `StreamHeader.sequence` travels with the
    /// payload (`sequence`); the runtime's per-peer reorder buffer releases in
    /// order. `.reliable`/`.datagram` carry `nil`.
    case data(Data, Delivery, sequence: UInt64?)
    /// The connection ended (peer closed, reset, or transport failure).
    case closed
}

/// In-memory mirror of `Schemas/stream_header.fbs` (DD-7). Every dedicated
/// (non-control) stream is announced with one of these. The QUIC driver
/// serializes it as the size-prefixed FlatBuffers `StreamHeader` prologue of
/// the stream; the InMemory driver passes the struct through directly.
///
/// Field mapping to `stream_header.fbs`:
/// `kind` ↔ `StreamKind`, `sequence` ↔ `sequence`, `transferID` ↔ 16-byte
/// `transfer_id`, `label` ↔ `label`.
public struct StreamHeaderInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `StreamKind.Message` — reliable message, unordered (FR-15).
        case message
        /// `StreamKind.OrderedMessage` — reliable FIFO message (FR-15).
        case orderedMessage
        /// `StreamKind.TransferChunk` — resource-transfer stream (FR-17).
        case transferChunk
        /// `StreamKind.AppStream` — application byte stream (FR-18).
        case appStream
        /// `StreamKind.Datagram` — unreliable-semantics message (FR-16) on
        /// the message channel (floor-compatible mapping; TODO(datagrams)).
        case datagram
    }

    public var kind: Kind
    /// FIFO sequence, meaningful for `.orderedMessage`.
    public var sequence: UInt64?
    /// Pairs a `.transferChunk` stream with its `TransferOffer` signal.
    public var transferID: UUID?
    /// Stream label, meaningful for `.appStream`.
    public var label: String?

    public init(
        kind: Kind,
        sequence: UInt64? = nil,
        transferID: UUID? = nil,
        label: String? = nil
    ) {
        self.kind = kind
        self.sequence = sequence
        self.transferID = transferID
        self.label = label
    }
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
    /// stream; `.datagram` = QUIC datagram). For `.reliableOrdered` the runtime
    /// supplies the per-peer `sequence` that becomes `StreamHeader.sequence`;
    /// `.reliable`/`.datagram` pass `nil`.
    func sendData(_ payload: Data, delivery: Delivery, sequence: UInt64?) async throws

    /// Open a dedicated outgoing stream (FR-17 resource transfer, FR-18 app
    /// byte streams). `header` becomes the stream's `StreamHeader` prologue on
    /// QUIC (DD-7); the returned writer streams the payload with back-pressure.
    func openOutgoingStream(header: StreamHeaderInfo) async throws -> any PeerByteStream

    /// Dedicated streams opened by the remote peer, paired with the decoded
    /// `StreamHeader` that introduced them (FR-17, FR-18).
    var incomingStreams: AsyncStream<(StreamHeaderInfo, any PeerByteStream)> { get }

    func close() async
}

extension PeerConnection {
    /// Convenience for callers that don't carry an ordering sequence
    /// (`.reliable` / `.datagram`).
    public func sendData(_ payload: Data, delivery: Delivery) async throws {
        try await sendData(payload, delivery: delivery, sequence: nil)
    }
}

/// A dedicated bidirectional byte stream with explicit back-pressure (FR-18).
/// Opened via ``PeerConnection/openOutgoingStream(header:)``; the remote peer
/// receives it on ``PeerConnection/incomingStreams``.
public protocol PeerByteStream: Sendable {
    var label: String { get }
    func write(_ data: Data) async throws
    func finish() async
    var incoming: AsyncThrowingStream<Data, Error> { get }
}

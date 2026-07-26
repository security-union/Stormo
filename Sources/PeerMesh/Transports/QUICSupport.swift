import Foundation
import FlatBuffers
import PeerMeshProtocol

#if canImport(Network)
import Network
#endif

#if canImport(Security)
import Security
#endif

// MARK: - Errors

/// Driver-internal failures for the QUIC transport (DD-1). None of these are
/// protocol decisions (DD-6) — they describe transport plumbing outcomes.
enum QUICError: Error, Sendable, LocalizedError {
    /// The secured connection ended before the expected bytes arrived.
    case connectionClosed
    /// A framed read hit EOF/FIN mid-frame.
    case shortRead
    /// The peer's presented key hash (TLS cert) did not match its PeerHello.
    case identityMismatch
    /// No TLS identity could be formed for the local peer (see
    /// ``QUICTransport/Configuration/tlsProvider``).
    case tlsIdentityUnavailable(String)
    /// A dedicated stream announced a malformed `StreamHeader` (DD-5 discipline).
    case malformedStreamHeader
    case listenerFailed(String)
    /// A Bonjour `.service` endpoint could not be resolved to a concrete
    /// address for the multiplex-group dial (failure mode 12).
    case serviceResolutionFailed

    // NSError bridging renumbers payload cases (tlsIdentityUnavailable
    // surfaces as "error 0"), hiding the diagnostic string entirely —
    // LocalizedError puts the actual reason in localizedDescription.
    var errorDescription: String? {
        switch self {
        case .connectionClosed: return "PeerMesh QUIC: connection closed"
        case .shortRead: return "PeerMesh QUIC: stream ended mid-frame"
        case .identityMismatch: return "PeerMesh QUIC: peer key hash does not match its certificate"
        case .tlsIdentityUnavailable(let reason):
            return "PeerMesh QUIC: no local TLS identity — \(reason)"
        case .malformedStreamHeader: return "PeerMesh QUIC: malformed stream header"
        case .listenerFailed(let reason): return "PeerMesh QUIC: listener failed — \(reason)"
        case .serviceResolutionFailed:
            return "PeerMesh QUIC: Bonjour service endpoint did not resolve"
        }
    }
}

#if canImport(Network) && canImport(Security)

// MARK: - Diagnostic logging (env-gated: QUIC_DEBUG, optional QUIC_DEBUG_LOG)

let quicDebugEnabled = ProcessInfo.processInfo.environment["QUIC_DEBUG"] != nil
let quicDebugLogPath = ProcessInfo.processInfo.environment["QUIC_DEBUG_LOG"]
func quicDebug(_ s: @autoclosure () -> String) {
    guard quicDebugEnabled else { return }
    let line = "\(Date().timeIntervalSince1970) [drv] \(s())"
    print(line)  // stdout: visible in xcodebuild/console even when sandboxed
    guard let path = quicDebugLogPath else { return }
    let url = URL(fileURLWithPath: path)
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close()
    } else {
        try? Data((line + "\n").utf8).write(to: url)
    }
}

// MARK: - Length-prefixed framing (control + dedicated-stream prologue)

/// Wire framing shared by the control stream and the dedicated-stream prologue
/// (DD-5/DD-7): a big-endian `UInt32` length prefix followed by that many bytes.
enum QUICFraming {
    /// Hard cap on a single framed unit (matches ``SignalCodec`` control cap).
    static let maxFrame = 1 << 20  // 1 MiB

    static func lengthPrefix(_ count: Int) -> Data {
        var be = UInt32(count).bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    /// The one-byte stream discriminator written as the very first byte of every
    /// stream so the receiver can classify without relying on open-order.
    enum StreamTag: UInt8 {
        case control = 0x00
        case dedicated = 0x01
    }
}

// MARK: - Async wrappers over NWConnection

/// Send `data` on `connection`, awaiting the framework's back-pressure ack
/// (DD-7: `PeerByteStream.write` is back-pressured). `isComplete` FINs the
/// stream after this send.
func quicSend(_ connection: NWConnection, _ data: Data, isComplete: Bool = false) async throws {
    quicDebug("quicSend: \(data.count)B complete=\(isComplete) state=\(connection.state)")
    // Two-step FIN (the empirically reliable Network.framework pattern):
    // payload rides the default context; the FIN is a separate empty
    // `.finalMessage` send. Sending payload *with* `.finalMessage` was
    // observed to deliver nothing to the peer's receive on QUIC streams, and
    // `isComplete` on the default context never surfaces stream completion.
    if !data.isEmpty {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        quicDebug("send ERROR \(error)")
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                })
        }
    }
    if isComplete {
        await quicFinish(connection)
    }
}

/// FIN the stream (empty final segment).
func quicFinish(_ connection: NWConnection) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        connection.send(
            content: nil, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in
                cont.resume()
            })
    }
}

/// Start a stream we received from `newConnectionHandler` (advertiser side).
/// Such streams become receivable immediately and do **not** fire a `.ready`
/// transition, so we start them (attaching a failure observer) and receive
/// directly rather than awaiting readiness.
func quicStartReceiving(_ connection: NWConnection, queue: DispatchQueue, onFailure: @escaping @Sendable () -> Void) {
    connection.stateUpdateHandler = { state in
        switch state {
        case .failed, .cancelled: onFailure()
        default: break
        }
    }
    connection.start(queue: queue)
}

/// Read exactly `count` bytes (for length-prefix and framed bodies). Throws
/// ``QUICError/shortRead`` on FIN/EOF before `count` bytes.
func quicReceiveExactly(_ connection: NWConnection, _ count: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
        connection.receive(minimumIncompleteLength: count, maximumLength: count) {
            data, _, _, error in
            if let error { cont.resume(throwing: error); return }
            if let data, data.count == count { cont.resume(returning: data); return }
            cont.resume(throwing: QUICError.shortRead)
        }
    }
}

/// Read one opportunistic chunk (payload-to-FIN loops). Returns the bytes (may
/// be empty) and whether the stream is now complete (FIN).
func quicReceiveChunk(_ connection: NWConnection, maxLength: Int = 1 << 16) async throws -> (Data, Bool) {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Bool), Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) {
            data, _, isComplete, error in
            if let error { cont.resume(throwing: error); return }
            cont.resume(returning: (data ?? Data(), isComplete))
        }
    }
}

/// Read one length-prefixed frame. Throws on FIN before/mid frame.
func quicReceiveFrame(_ connection: NWConnection) async throws -> Data {
    let header = try await quicReceiveExactly(connection, 4)
    let length = Int(header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
    guard length > 0, length <= QUICFraming.maxFrame else { throw QUICError.malformedStreamHeader }
    return try await quicReceiveExactly(connection, length)
}

/// Await an NWConnection reaching `.ready` (or throw on failure/cancel).
///
/// Bounded (`timeout`, default 10 s): when the underlying tunnel/AWDL path has
/// silently died, new streams sit in `.preparing` forever — sends must FAIL
/// fast rather than queue unbounded retries (the mid-session stall produced a
/// pile-up of ~150 stuck streams all timing out together 30 s later).
/// Post-completion state transitions are not re-logged (that pile-up also
/// flooded the log with one `failed` line per stuck stream).
func quicAwaitReady(
    _ connection: NWConnection, queue: DispatchQueue, timeout: TimeInterval = 10
) async throws {
    let done = Locked(false)
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        queue.asyncAfter(deadline: .now() + timeout) {
            if done.compareAndSet(expected: false, new: true) {
                quicDebug("stream ready TIMEOUT after \(timeout)s — failing send")
                connection.cancel()
                cont.resume(throwing: QUICError.connectionClosed)
            }
        }
        connection.stateUpdateHandler = { state in
            if !done.value { quicDebug("stream state=\(state)") }
            switch state {
            case .ready:
                if done.compareAndSet(expected: false, new: true) { cont.resume() }
            case .failed(let error):
                if done.compareAndSet(expected: false, new: true) { cont.resume(throwing: error) }
            case .cancelled:
                if done.compareAndSet(expected: false, new: true) {
                    cont.resume(throwing: QUICError.connectionClosed)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A stream handed over already `.ready` will never fire a transition.
        if case .ready = connection.state {
            if done.compareAndSet(expected: false, new: true) { cont.resume() }
        }
    }
}

/// Resolve a Bonjour `.service` endpoint to the concrete `hostPort` it names,
/// using a throwaway UDP connection (readiness = flow assigned; no bytes sent).
///
/// Failure mode 12: `NWMultiplexGroup` accepts only concrete endpoints before
/// macOS 26 / iOS 26 — handing it a `.service` endpoint traps in libnetwork
/// ("invalid endpoint type for multiplex group"). Plain `NWConnection` resolves
/// `.service` endpoints on every supported OS, and its ready path carries the
/// resolved remote address (scoped, so AWDL link-local routes survive).
func quicResolveServiceEndpoint(
    _ endpoint: NWEndpoint,
    includePeerToPeer: Bool,
    queue: DispatchQueue,
    timeout: TimeInterval = 10
) async throws -> NWEndpoint {
    let params = NWParameters.udp
    // Must match the group dial's p2p setting or resolution may pick an
    // interface the dial cannot use.
    params.includePeerToPeer = includePeerToPeer
    let probe = NWConnection(to: endpoint, using: params)
    let done = Locked(false)
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWEndpoint, Error>) in
        queue.asyncAfter(deadline: .now() + timeout) {
            if done.compareAndSet(expected: false, new: true) {
                quicDebug("resolve TIMEOUT after \(timeout)s")
                probe.cancel()
                cont.resume(throwing: QUICError.serviceResolutionFailed)
            }
        }
        probe.stateUpdateHandler = { state in
            if !done.value { quicDebug("resolve state=\(state)") }
            switch state {
            case .ready:
                let resolved = probe.currentPath?.remoteEndpoint
                probe.cancel()
                if done.compareAndSet(expected: false, new: true) {
                    if let resolved {
                        quicDebug("resolve: \(endpoint) -> \(resolved)")
                        cont.resume(returning: resolved)
                    } else {
                        cont.resume(throwing: QUICError.serviceResolutionFailed)
                    }
                }
            case .failed(let error):
                probe.cancel()
                if done.compareAndSet(expected: false, new: true) {
                    cont.resume(throwing: error)
                }
            case .cancelled:
                if done.compareAndSet(expected: false, new: true) {
                    cont.resume(throwing: QUICError.serviceResolutionFailed)
                }
            default:
                break
            }
        }
        probe.start(queue: queue)
    }
}

// MARK: - Peer identity from the authenticated TLS handshake

/// Extract the peer's leaf-certificate DER from a ready QUIC connection's TLS
/// metadata (authenticated by the handshake — FR-19/FR-22).
func quicPeerCertificateDER(_ connection: NWConnection) -> Data? {
    guard
        let md = connection.metadata(definition: NWProtocolQUIC.definition)
            as? NWProtocolQUIC.Metadata
    else { return nil }
    var leaf: Data?
    sec_protocol_metadata_access_peer_certificate_chain(md.securityProtocolMetadata) { secCert in
        if leaf == nil {
            let cert = sec_certificate_copy_ref(secCert).takeRetainedValue()
            leaf = SecCertificateCopyData(cert) as Data
        }
    }
    return leaf
}

// MARK: - PeerHello (driver-level identity bootstrap)

/// The first control-stream frame in each direction. Carries the sender's full
/// ``PeerID`` (key hash + display name).
///
/// Why this exists (Spike S-3 note): TLS authenticates the peer's **key** (its
/// key hash is recovered from the presented certificate), but the certificate
/// does not carry the cosmetic `displayName`. `InMemoryTransport` receives both
/// full identities at pairing time; on real QUIC the accepting side would
/// otherwise only know the dialer's key hash. `PeerHello` reconstructs the same
/// information the reference transport gets for free. It is a transport-level
/// identity bootstrap, **not** a protocol decision (DD-6): the key hash is
/// cross-checked against the TLS-authenticated certificate, and `displayName` is
/// cosmetic (never used for trust — see ``PeerID``).
enum PeerHello {
    static func encode(_ peer: PeerID) -> Data {
        var out = Data()
        var khLen = UInt16(peer.keyHash.count).bigEndian
        out.append(withUnsafeBytes(of: &khLen) { Data($0) })
        out.append(peer.keyHash)
        out.append(Data(peer.displayName.utf8))
        return out
    }

    static func decode(_ data: Data) -> PeerID? {
        guard data.count >= 2 else { return nil }
        let khLen = Int(data.prefix(2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
        guard data.count >= 2 + khLen else { return nil }
        let keyHash = data.subdata(in: 2 ..< 2 + khLen)
        let nameData = data.subdata(in: 2 + khLen ..< data.count)
        let name = String(data: nameData, encoding: .utf8) ?? ""
        return PeerID(keyHash: keyHash, displayName: name)
    }
}

// MARK: - StreamHeader (DD-7) FlatBuffers codec

/// Serializes/parses the size-prefixed FlatBuffers `StreamHeader` that prefixes
/// every dedicated stream (DD-7). Mirrors ``SignalCodec`` discipline: build with
/// the generated type; parse with the verifier (hard caps, DD-5).
enum QUICStreamHeaderCodec {

    /// Driver-internal marker (in the otherwise-unused `label` of a `.message`
    /// stream) meaning "this reliable stream stands in for a `.datagram`".
    ///
    /// RFC 9221 QUIC datagrams (`NWProtocolQUIC.Options.isDatagram`) are
    /// macOS 13 / iOS 16 — **below the floor** (iOS 15 / macOS 12). To keep the
    /// tier-2 loopback driver floor-compatible while preserving delivery
    /// semantics end-to-end, `.datagram` sends ride a dedicated stream carrying
    /// this marker; on loopback there is no loss, so behavior is indistinguishable
    /// for correctness. True datagram flows are the on-radio refinement (S-1).
    static let datagramMarker = "\u{01}pm-datagram"

    static func encode(_ info: StreamHeaderInfo) -> Data {
        var fbb = FlatBufferBuilder(initialSize: 128)
        let labelOffset = info.label.map { fbb.create(string: $0) } ?? Offset()
        var transferOffset = Offset()
        if let id = info.transferID {
            let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
            transferOffset = fbb.createVector(bytes)
        }
        let root = PeerMesh_Wire_StreamHeader.createStreamHeader(
            &fbb,
            kind: wireKind(info.kind),
            sequence: info.sequence ?? 0,
            transferIdVectorOffset: transferOffset,
            labelOffset: labelOffset)
        fbb.finish(offset: root)
        return Data(fbb.sizedByteArray)
    }

    static func decode(_ data: Data) throws -> StreamHeaderInfo {
        var buffer = ByteBuffer(data: data)
        let root: PeerMesh_Wire_StreamHeader
        do {
            root = try getCheckedRoot(
                byteBuffer: &buffer,
                options: VerifierOptions(maxDepth: 16, maxTableCount: 64, maxApparentSize: 1 << 16))
        } catch {
            throw QUICError.malformedStreamHeader
        }
        let kind = infoKind(root.kind)
        let sequence: UInt64? = (root.kind == .orderedmessage) ? root.sequence : nil
        var transferID: UUID?
        let tid = root.transferId
        if tid.count == 16 {
            transferID = tid.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
        }
        return StreamHeaderInfo(kind: kind, sequence: sequence, transferID: transferID, label: root.label)
    }

    private static func wireKind(_ kind: StreamHeaderInfo.Kind) -> PeerMesh_Wire_StreamKind {
        switch kind {
        case .message: return .message
        case .orderedMessage: return .orderedmessage
        case .transferChunk: return .transferchunk
        case .appStream: return .appstream
        }
    }

    private static func infoKind(_ kind: PeerMesh_Wire_StreamKind) -> StreamHeaderInfo.Kind {
        switch kind {
        case .message, .unknown: return .message
        case .orderedmessage: return .orderedMessage
        case .transferchunk: return .transferChunk
        case .appstream: return .appStream
        }
    }
}

#endif

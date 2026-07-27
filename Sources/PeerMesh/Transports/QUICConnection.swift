import Foundation
import PeerMeshProtocol

#if canImport(Network)
import Network
#endif

#if canImport(Network) && canImport(Security)

/// A single secured peer-pair connection over one QUIC connection (DD-1),
/// multiplexed with `NWConnectionGroup` + `NWMultiplexGroup` (Spike S-3
/// resolution — see `docs/spike-results.md`):
///
/// - **control stream** — the first bidirectional stream (dialer-opened, tagged
///   `0x00`): a `PeerHello` frame in each direction, then length-prefixed
///   `SignalCodec` bytes (DD-5).
/// - **dedicated streams** — every reliable message, resource transfer, and app
///   byte stream rides its own stream (tagged `0x01`): a length-prefixed
///   `StreamHeader` (DD-7) then payload to FIN.
///
/// `NWConnection(from:)` opens outbound streams (`extract()` is only the
/// macOS 12 fallback — see ``openGroupStream()``); `newConnectionHandler`
/// surfaces inbound ones.
final class QUICConnection: PeerConnection, @unchecked Sendable {
    /// Leak accounting for dedicated message streams (failure mode 13): every
    /// opened handle must eventually be retired — the churn soak asserts the
    /// counters converge, so zombie streams fail CI instead of shipping.
    static let dedicatedOpened = Locked(0)
    static let dedicatedRetired = Locked(0)

    /// Fired once on terminal close (before streams finish); used by `accept`
    /// to release the pending-inbound retention.
    var onTerminated: (@Sendable () -> Void)?

    // MARK: PeerConnection surface

    var remotePeer: PeerID { remotePeerBox.value }
    var remoteKeyHash: Data { remoteKeyHashBox.value }
    let events: AsyncStream<PeerConnectionEvent>
    let incomingStreams: AsyncStream<(StreamHeaderInfo, any PeerByteStream)>

    // MARK: State

    private let group: NWConnectionGroup
    private let queue: DispatchQueue
    private let localPeer: PeerID
    private let ownedIdentity: QUICLocalIdentity?  // dialer owns its per-dial identity

    private let control: Locked<NWConnection?> = Locked(nil)
    private let controlWriter = ControlWriter()
    private let messagesWriter = MessagesWriter()
    private let remotePeerBox: Locked<PeerID>
    private let remoteKeyHashBox: Locked<Data>
    private let closed = Locked(false)

    private let eventsContinuation: AsyncStream<PeerConnectionEvent>.Continuation
    private let incomingStreamsContinuation: AsyncStream<(StreamHeaderInfo, any PeerByteStream)>.Continuation

    private init(
        group: NWConnectionGroup,
        queue: DispatchQueue,
        localPeer: PeerID,
        remotePeer: PeerID,
        remoteKeyHash: Data,
        ownedIdentity: QUICLocalIdentity?
    ) {
        self.group = group
        self.queue = queue
        self.localPeer = localPeer
        self.ownedIdentity = ownedIdentity
        self.remotePeerBox = Locked(remotePeer)
        self.remoteKeyHashBox = Locked(remoteKeyHash)
        (self.events, self.eventsContinuation) = AsyncStream.makeStream()
        (self.incomingStreams, self.incomingStreamsContinuation) = AsyncStream.makeStream()
    }

    // MARK: - Stream creation

    /// Open a NEW outgoing QUIC stream within the group.
    ///
    /// `NWConnection(from:)` is the supported stream-creation API and is
    /// REQUIRED on the iOS-family network stack (iOS, Catalyst): streams
    /// produced by `group.extract()` there report `.ready` but never transmit
    /// — the peer sees the QUIC connection reach `connected` and then time
    /// out waiting for bytes (observed on-device and as the Catalyst
    /// in-process stall; see docs/spike-results.md). `extract()` behaves on
    /// pure macOS 12, so it remains only as the pre-macOS-13 fallback.
    private func openGroupStream() -> NWConnection? {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, macCatalyst 16.0, *) {
            return NWConnection(from: group)
        }
        return group.extract()
    }

    // MARK: - Outbound (dialer)

    /// Dial a peer and complete the control-stream identity bootstrap.
    static func dial(
        to endpoint: NWEndpoint,
        localPeer: PeerID,
        remote: PeerID,
        localIdentity: QUICLocalIdentity,
        trust: TrustPolicy,
        queue: DispatchQueue,
        includePeerToPeer: Bool = false
    ) async throws -> QUICConnection {
        let params = QUICTLS.parameters(localIdentity: localIdentity, trust: trust, isListener: false)
        // Apple sets includePeerToPeer on listener, browser, AND the outgoing
        // connection (TN3213/TicTacToe) — without it here, an AWDL-discovered
        // peer is unreachable even after discovery succeeds.
        params.includePeerToPeer = includePeerToPeer
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: params)
        let connection = QUICConnection(
            group: group, queue: queue, localPeer: localPeer,
            remotePeer: remote, remoteKeyHash: remote.keyHash, ownedIdentity: localIdentity)

        // The group needs its newConnectionHandler installed before start (else
        // it never drives the connection). Advertiser-initiated dedicated streams
        // arrive here.
        connection.installIncomingStreamHandler(isInbound: false)
        quicDebug("dial: start group")
        try await connection.startGroupAndWaitReady()
        quicDebug("dial: group ready")

        guard let control = connection.openGroupStream() else { throw QUICError.connectionClosed }
        connection.control.value = control
        try await quicAwaitReady(control, queue: queue)
        quicDebug("dial: control ready")

        // Authenticated key hash from the TLS handshake (FR-22).
        let der = quicPeerCertificateDER(control)
        if let der, let keyHash = TrustEvaluator.keyHash(fromCertificateDER: der) {
            guard keyHash == remote.keyHash else { throw QUICError.identityMismatch }
            connection.remoteKeyHashBox.value = keyHash
        }

        // Identity bootstrap: send our PeerHello (tagged control), read theirs.
        try await connection.controlWriter.send(control, tag: .control, frame: PeerHello.encode(localPeer))
        quicDebug("dial: sent hello")
        let helloFrame = try await quicReceiveFrame(control)
        quicDebug("dial: got hello")
        guard let hello = PeerHello.decode(helloFrame) else { throw QUICError.malformedStreamHeader }
        try quicRequireCompatibleVersion(hello.version)
        // Adopt the peer's real display name: AWDL name-only discovery dials
        // with a hash-prefix placeholder (PeerID equality is key-hash-only, so
        // this is purely cosmetic enrichment).
        if hello.peer.keyHash == remote.keyHash {
            connection.remotePeerBox.value = hello.peer
        }

        connection.startControlReadLoop(control)
        connection.observeGroupTermination()
        return connection
    }

    // MARK: - Inbound (advertiser)

    /// Wrap an accepted `NWConnectionGroup` (from `NWListener.newConnectionGroupHandler`).
    /// The connection is *not* surfaced to the caller until its control stream's
    /// `PeerHello` has been read, so `remotePeer` is final before adoption.
    /// Pending inbound connections, retained strongly until the control-stream
    /// handshake completes (or the group dies). Without this the freshly
    /// created `QUICConnection` has no strong owner between `accept()`
    /// returning and `onReady` firing — all handlers capture it weakly — so it
    /// deallocates and every incoming stream is silently dropped.
    private static let pendingInbound = Locked<[ObjectIdentifier: QUICConnection]>([:])

    static func accept(
        group: NWConnectionGroup,
        localPeer: PeerID,
        queue: DispatchQueue,
        onReady: @escaping @Sendable (QUICConnection) -> Void
    ) {
        let placeholder = PeerID(keyHash: Data(), displayName: "")
        let connection = QUICConnection(
            group: group, queue: queue, localPeer: localPeer,
            remotePeer: placeholder, remoteKeyHash: Data(), ownedIdentity: nil)

        quicDebug("accept: group arrived")
        let token = ObjectIdentifier(connection)
        Self.pendingInbound.withLock { $0[token] = connection }
        let release: @Sendable () -> Void = {
            Self.pendingInbound.withLock { _ = $0.removeValue(forKey: token) }
        }

        let readyFired = Locked(false)
        connection.installIncomingStreamHandler(isInbound: true) { [weak connection] control in
            guard let connection else { return }
            Task {
                do {
                    quicDebug("accept: completing inbound control")
                    try await connection.completeInboundControl(control)
                    quicDebug("accept: inbound control done, remote=\(connection.remotePeer)")
                    if readyFired.compareAndSet(expected: false, new: true) {
                        onReady(connection)
                        release()  // adopted: PeerSession holds it now
                    }
                } catch {
                    quicDebug("accept: inbound control error \(error)")
                    connection.finishClosed()
                    release()
                }
            }
        }
        connection.onTerminated = release  // group failed before handshake
        connection.observeGroupTermination()
        group.start(queue: queue)
    }

    /// Advertiser side of the identity bootstrap on the dialer-opened control
    /// stream: read the dialer's `PeerHello`, cross-check its key hash against the
    /// authenticated certificate, then answer with our own `PeerHello`.
    private func completeInboundControl(_ control: NWConnection) async throws {
        // `control` was already brought to `.ready` by `classifyIncomingStream`
        // (awaiting ready again would hang — state handlers fire only on
        // transitions).
        self.control.value = control

        let certKeyHash = quicPeerCertificateDER(control)
            .flatMap { TrustEvaluator.keyHash(fromCertificateDER: $0) }

        let helloFrame = try await quicReceiveFrame(control)
        guard let hello = PeerHello.decode(helloFrame) else { throw QUICError.malformedStreamHeader }
        try quicRequireCompatibleVersion(hello.version)
        if let certKeyHash {
            guard certKeyHash == hello.peer.keyHash else { throw QUICError.identityMismatch }
        }
        remotePeerBox.value = hello.peer
        remoteKeyHashBox.value = certKeyHash ?? hello.peer.keyHash

        try await controlWriter.send(control, tag: nil, frame: PeerHello.encode(localPeer))
        startControlReadLoop(control)
    }

    // MARK: - Group lifecycle

    private func startGroupAndWaitReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let done = Locked(false)
            group.stateUpdateHandler = { [weak self] state in
                quicDebug("dial group state=\(state)")
                switch state {
                case .ready:
                    if done.compareAndSet(expected: false, new: true) { cont.resume() }
                case .failed(let error):
                    if done.compareAndSet(expected: false, new: true) { cont.resume(throwing: error) }
                    self?.finishClosed()
                case .cancelled:
                    if done.compareAndSet(expected: false, new: true) {
                        cont.resume(throwing: QUICError.connectionClosed)
                    }
                    self?.finishClosed()
                default:
                    break
                }
            }
            group.start(queue: queue)
        }
    }

    /// After setup, keep watching for the group ending (peer close / reset).
    private func observeGroupTermination() {
        group.stateUpdateHandler = { [weak self] state in
            quicDebug("group(termination-observer) state=\(state)")
            switch state {
            case .failed, .cancelled:
                self?.finishClosed()
            default:
                break
            }
        }
    }

    // MARK: - Incoming streams

    private func installIncomingStreamHandler(
        isInbound: Bool,
        controlHandler: (@Sendable (NWConnection) -> Void)? = nil
    ) {
        group.newConnectionHandler = { [weak self] stream in
            quicDebug("newConnectionHandler fired isInbound=\(isInbound)")
            guard let self else { return }
            Task { await self.classifyIncomingStream(stream, isInbound: isInbound, controlHandler: controlHandler) }
        }
    }

    private func classifyIncomingStream(
        _ stream: NWConnection,
        isInbound: Bool,
        controlHandler: (@Sendable (NWConnection) -> Void)?
    ) async {
        do {
            quicStartReceiving(stream, queue: queue) { [weak self] in self?.finishClosed() }
            quicDebug("classify: reading tag")
            let tagByte = try await quicReceiveExactly(stream, 1)
            let tag = QUICFraming.StreamTag(rawValue: tagByte[tagByte.startIndex])
            quicDebug("classify: tag=\(String(describing: tag)) isInbound=\(isInbound)")
            switch tag {
            case .control where isInbound:
                controlHandler?(stream)
            case .dedicated:
                try await handleDedicatedStream(stream)
            case .messages:
                try await messageChannelReadLoop(stream)
            default:
                stream.cancel()  // unexpected (e.g. control on the dialer side)
            }
        } catch {
            stream.cancel()
        }
    }

    /// The peer's message channel: framed [header][payload] units for the
    /// connection's lifetime. The loop ends on FIN/error; the channel is as
    /// load-bearing as the control stream, so classify's failure path closing
    /// the connection is correct here.
    private func messageChannelReadLoop(_ stream: NWConnection) async throws {
        quicDebug("messages channel: inbound")
        while true {
            let headerFrame = try await quicReceiveFrame(stream)
            let header = try QUICStreamHeaderCodec.decode(headerFrame)
            let payload = try await quicReceiveFrame(stream, allowEmpty: true)
            let sequence = (header.kind == .orderedMessage) ? header.sequence : nil
            eventsContinuation.yield(.data(payload, deliveryFor(header), sequence: sequence))
        }
    }

    /// Read the `StreamHeader` prologue (DD-7) and dispatch: message/ordered/
    /// datagram streams surface as `.data` events; transfer/app streams surface
    /// on `incomingStreams` as byte streams.
    private func handleDedicatedStream(_ stream: NWConnection) async throws {
        let headerFrame = try await quicReceiveFrame(stream)
        let header = try QUICStreamHeaderCodec.decode(headerFrame)
        quicDebug("dedicated: header kind=\(header.kind) seq=\(String(describing: header.sequence))")

        switch header.kind {
        case .message, .orderedMessage:
            Self.dedicatedOpened.withLock { $0 += 1 }
            defer {
                // Receiver half of failure mode 13: the stream is spent once
                // FIN is read (or the read threw); this retire is what
                // releases the sender's wait.
                quicRetire(stream)
                Self.dedicatedRetired.withLock { $0 += 1 }
            }
            let delivery = deliveryFor(header)
            let sequence = (header.kind == .orderedMessage) ? header.sequence : nil
            var payload = Data()
            while true {
                let (chunk, isComplete) = try await quicReceiveChunk(stream)
                payload.append(chunk)
                quicDebug("dedicated: chunk \(chunk.count)B complete=\(isComplete)")
                if isComplete { break }
            }
            quicDebug("dedicated: yielding data \(payload.count)B")
            eventsContinuation.yield(.data(payload, delivery, sequence: sequence))

        case .transferChunk, .appStream:
            let label = header.label ?? ""
            let byteStream = QUICByteStream(
                label: label, connection: stream, queue: queue, startReceiveLoop: true)
            incomingStreamsContinuation.yield((header, byteStream))
        }
    }

    /// `.datagram` sends ride a `.message` stream carrying the datagram marker
    /// (floor-compatibility, see ``QUICStreamHeaderCodec/datagramMarker``).
    private func deliveryFor(_ header: StreamHeaderInfo) -> Delivery {
        switch header.kind {
        case .orderedMessage: return .reliableOrdered
        case .message:
            return header.label == QUICStreamHeaderCodec.datagramMarker ? .datagram : .reliable
        default: return .reliable
        }
    }

    // MARK: - Control read loop

    private func startControlReadLoop(_ control: NWConnection) {
        Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    let frame = try await quicReceiveFrame(control)
                    self.eventsContinuation.yield(.signal(frame))
                }
            } catch {
                self.finishClosed()
            }
        }
    }

    // MARK: - Sending

    func sendSignal(_ bytes: Data) async throws {
        guard !closed.value, let control = control.value else { throw QUICError.connectionClosed }
        try await controlWriter.send(control, tag: nil, frame: bytes)
    }

    /// Payloads above this ride a dedicated stream instead of the message
    /// channel: bulk must never head-of-line block messaging (QA-4), and the
    /// channel's framed reads are capped at `QUICFraming.maxFrame`.
    static let channelMaxPayload = QUICFraming.maxFrame

    func sendData(_ payload: Data, delivery: Delivery, sequence: UInt64?) async throws {
        guard !closed.value else { throw QUICError.connectionClosed }
        let header: StreamHeaderInfo
        switch delivery {
        case .reliable:
            header = StreamHeaderInfo(kind: .message)
        case .reliableOrdered:
            header = StreamHeaderInfo(kind: .orderedMessage, sequence: sequence)
        case .datagram:
            header = StreamHeaderInfo(kind: .message, label: QUICStreamHeaderCodec.datagramMarker)
        }
        if payload.count > Self.channelMaxPayload {
            try await sendDataOnDedicatedStream(payload, header: header)
            return
        }
        // Messages ride the persistent channel (failure mode 13: per-message
        // streams exhaust the connection's lifetime stream budget).
        try await messagesWriter.send(
            headerBytes: QUICStreamHeaderCodec.encode(header),
            payload: payload,
            open: { [self] in try await openMessagesStream() })
    }

    /// Dedicated-stream fallback for oversized messages (FR-15 allows 16 MB).
    private func sendDataOnDedicatedStream(_ payload: Data, header: StreamHeaderInfo) async throws {
        let stream = try await openDedicatedStream(header: header)
        Self.dedicatedOpened.withLock { $0 += 1 }
        do {
            try await quicSend(stream, payload, isComplete: true)
        } catch {
            quicRetire(stream)  // abort — the peer discards partial reads
            Self.dedicatedRetired.withLock { $0 += 1 }
            throw error
        }
        // Failure mode 13: retire only once the peer ends the stream (the
        // receiver's retire propagates as a receive error here). The awaited
        // write-close means processed-by-the-stack, not delivered — a cancel
        // issued now aborts the queued payload. Detached: send() latency
        // stays payload-only.
        Task {
            _ = try? await quicReceiveChunk(stream)
            quicRetire(stream)
            Self.dedicatedRetired.withLock { $0 += 1 }
        }
    }

    /// Open this side's message channel: tag `0x02`, then framed messages for
    /// the connection's lifetime.
    private func openMessagesStream() async throws -> NWConnection {
        guard let stream = openGroupStream() else { throw QUICError.connectionClosed }
        try await quicAwaitReady(stream, queue: queue)
        try await quicSend(stream, Data([QUICFraming.StreamTag.messages.rawValue]))
        quicDebug("messages channel: opened")
        return stream
    }

    func openOutgoingStream(header: StreamHeaderInfo) async throws -> any PeerByteStream {
        let stream = try await openDedicatedStream(header: header)
        return QUICByteStream(
            label: header.label ?? "", connection: stream, queue: queue, startReceiveLoop: true)
    }

    /// Extract a new stream, start it, and write the `0x01` tag + length-prefixed
    /// `StreamHeader` prologue (DD-7). Returns the ready stream positioned at the
    /// payload.
    private func openDedicatedStream(header: StreamHeaderInfo) async throws -> NWConnection {
        guard let stream = openGroupStream() else {
            quicDebug("openDedicated: openGroupStream returned nil (kind=\(header.kind))")
            throw QUICError.connectionClosed
        }
        quicDebug("openDedicated: opened, awaiting ready (kind=\(header.kind))")
        try await quicAwaitReady(stream, queue: queue)
        quicDebug("openDedicated: ready")
        let headerBytes = QUICStreamHeaderCodec.encode(header)
        var prologue = Data([QUICFraming.StreamTag.dedicated.rawValue])
        prologue.append(QUICFraming.lengthPrefix(headerBytes.count))
        prologue.append(headerBytes)
        try await quicSend(stream, prologue)
        return stream
    }

    // MARK: - Close

    func close() async {
        guard closed.compareAndSet(expected: false, new: true) else { return }
        onTerminated?()
        await messagesWriter.close()
        control.value?.cancel()
        group.cancel()
        eventsContinuation.yield(.closed)
        eventsContinuation.finish()
        incomingStreamsContinuation.finish()
        ownedIdentity?.dispose()
    }

    /// Idempotent close triggered by transport-side failure (peer reset, group end).
    private func finishClosed() {
        guard closed.compareAndSet(expected: false, new: true) else { return }
        onTerminated?()
        eventsContinuation.yield(.closed)
        eventsContinuation.finish()
        incomingStreamsContinuation.finish()
        group.cancel()
        ownedIdentity?.dispose()
    }
}

// MARK: - Serial control-stream writer (FIFO wire order for DD-5 signaling)

/// Serializes control-stream writes so invitation/roster signals keep total
/// order (DD-5), independent of how many tasks call `sendSignal` concurrently.
private actor ControlWriter {
    func send(_ connection: NWConnection, tag: QUICFraming.StreamTag?, frame: Data) async throws {
        quicDebug("writer: sending frame tag=\(String(describing: tag)) \(frame.count)B")
        var out = Data()
        if let tag { out.append(tag.rawValue) }
        out.append(QUICFraming.lengthPrefix(frame.count))
        out.append(frame)
        try await quicSend(connection, out)
    }
}

/// Owns this side's persistent message channel: opens it lazily on first send
/// and serializes writes, so concurrent `send` calls interleave whole
/// [header][payload] units, never partial frames.
private actor MessagesWriter {
    private var stream: NWConnection?

    func send(
        headerBytes: Data, payload: Data, open: () async throws -> NWConnection
    ) async throws {
        if stream == nil { stream = try await open() }
        guard let stream else { throw QUICError.connectionClosed }
        var out = Data()
        out.append(QUICFraming.lengthPrefix(headerBytes.count))
        out.append(headerBytes)
        out.append(QUICFraming.lengthPrefix(payload.count))
        out.append(payload)
        do {
            try await quicSend(stream, out)
        } catch {
            // Channel died with the send un-framed on the wire — retire it;
            // the next send opens a fresh channel.
            quicRetire(stream)
            self.stream = nil
            throw error
        }
    }

    func close() {
        if let stream { quicRetire(stream) }
        stream = nil
    }
}

#endif

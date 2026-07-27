import Foundation

#if canImport(Network)
import Network
#endif

#if canImport(Network) && canImport(Security)

/// A dedicated bidirectional QUIC stream exposed as a ``PeerByteStream`` (FR-17,
/// FR-18). The `StreamHeader` prologue (DD-7) is written/consumed by
/// ``QUICConnection`` before this wrapper takes over the raw payload; FIN
/// delimits the payload.
final class QUICByteStream: PeerByteStream, @unchecked Sendable {
    let label: String
    let incoming: AsyncThrowingStream<Data, Error>

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let incomingContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let finished = Locked(false)
    private let readDone = Locked(false)

    /// - Parameter startReceiveLoop: when true, spins a payload-to-FIN read loop
    ///   feeding `incoming`. (The header has already been consumed by the caller.)
    init(label: String, connection: NWConnection, queue: DispatchQueue, startReceiveLoop: Bool) {
        self.label = label
        self.connection = connection
        self.queue = queue
        (self.incoming, self.incomingContinuation) = AsyncThrowingStream.makeStream()
        if startReceiveLoop {
            // The task retains self: deinit cannot fire while a read loop is
            // live, so consumers may iterate `incoming` without also keeping
            // the stream object alive.
            Task { [self] in
                await Self.pump(connection, incomingContinuation)
                // Full close returns QUIC stream credit (failure mode 13).
                readDone.value = true
                if finished.value { quicRetire(connection) }
            }
        } else {
            readDone.value = true
            incomingContinuation.finish()
        }
    }

    /// RAII backstop: runs once the owner dropped the stream AND no read loop
    /// is live. `cancel` is idempotent; fully-closed duplex streams already
    /// cancelled in `finish`/pump completion.
    deinit { quicRetire(connection) }

    private static func pump(
        _ connection: NWConnection,
        _ continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        do {
            while true {
                let (chunk, isComplete) = try await quicReceiveChunk(connection)
                if !chunk.isEmpty { continuation.yield(chunk) }
                if isComplete { break }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    func write(_ data: Data) async throws {
        guard !finished.value else { throw QUICError.connectionClosed }
        try await quicSend(connection, data)
    }

    func finish() async {
        guard !finished.value else { return }
        finished.value = true
        await quicFinish(connection)
        if readDone.value { quicRetire(connection) }
    }
}

#endif

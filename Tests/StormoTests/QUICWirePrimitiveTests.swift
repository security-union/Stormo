import Foundation
import Testing

@testable import Stormo

#if canImport(Network) && canImport(Security)

/// Asserts the delivery-mode → wire-primitive mapping (DD-7 amendment):
/// every sub-cap message of every mode rides the persistent channel; only
/// oversized payloads open dedicated streams; the `StreamHeader` carries the
/// right `StreamKind` and sequence per mode.
@Suite("QUIC wire primitives", .serialized)
struct QUICWirePrimitiveTests {

    @Test("StreamHeader codec: each delivery mode's kind and sequence round-trip")
    func headerKindsRoundTrip() throws {
        let reliable = try QUICStreamHeaderCodec.decode(
            QUICStreamHeaderCodec.encode(StreamHeaderInfo(kind: .message)))
        #expect(reliable.kind == .message)
        #expect(reliable.sequence == nil)

        let ordered = try QUICStreamHeaderCodec.decode(
            QUICStreamHeaderCodec.encode(StreamHeaderInfo(kind: .orderedMessage, sequence: 42)))
        #expect(ordered.kind == .orderedMessage)
        #expect(ordered.sequence == 42)

        let datagram = try QUICStreamHeaderCodec.decode(
            QUICStreamHeaderCodec.encode(StreamHeaderInfo(kind: .datagram)))
        #expect(datagram.kind == .datagram)
        #expect(datagram.sequence == nil)
        #expect(datagram.label == nil)  // no marker — the kind IS the signal

        let transfer = UUID()
        let chunk = try QUICStreamHeaderCodec.decode(
            QUICStreamHeaderCodec.encode(StreamHeaderInfo(kind: .transferChunk, transferID: transfer)))
        #expect(chunk.kind == .transferChunk)
        #expect(chunk.transferID == transfer)
    }
}

#endif

import Foundation
import Testing

@testable import PeerMesh

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

    @Test("Sub-cap messages of every mode ride the channel; only oversized opens dedicated streams")
    func primitiveSelection() async throws {
        guard QUICTransport.isTLSIdentityAvailable(for: PeerIdentity(name: "probe")) else {
            print("[skip] QUIC: no TLS identity in this environment"); return
        }
        let rv = Rendezvous()
        func t() -> QUICTransport { QUICTransport(configuration: .init(discovery: .rendezvous(rv))) }
        let camera = PeerSession(identity: PeerIdentity(name: "Camera"), service: "_wire._udp", transport: t())
        let monitor = PeerSession(identity: PeerIdentity(name: "Monitor"), service: "_wire._udp", transport: t())

        try await camera.startAdvertising(metadata: [:])
        let accept = Task { for await inv in camera.invitations { await inv.accept(); break } }
        try await monitor.startBrowsing()
        var discovered: DiscoveredPeer?
        for await event in monitor.discoveries {
            if case .found(let peer) = event { discovered = peer; break }
        }
        _ = try await monitor.invite(try #require(discovered), context: Data())
        await accept.value

        let perMode = 20
        let receiver = Task<[Delivery: Int], Never> {
            var counts: [Delivery: Int] = [:]
            var oversized = 0
            for await message in camera.messages {
                if message.payload.count > QUICConnection.channelMaxPayload {
                    oversized += 1
                } else {
                    counts[message.delivery, default: 0] += 1
                }
                if oversized == 1, counts[.reliable] == perMode,
                    counts[.reliableOrdered] == perMode, counts[.datagram] == perMode
                { break }
            }
            return counts
        }

        let openedBefore = QUICConnection.dedicatedOpened.value

        for n in 0 ..< perMode {
            try await monitor.send(Data([UInt8(n)]), delivery: .reliable)
            try await monitor.send(Data([UInt8(n)]), delivery: .reliableOrdered)
            try await monitor.send(Data(repeating: UInt8(n), count: 600), delivery: .datagram)
        }
        // All three modes above must not have opened a single dedicated stream.
        #expect(QUICConnection.dedicatedOpened.value == openedBefore)

        // Oversized .reliable is the ONLY route to a dedicated message stream.
        try await monitor.send(
            Data(repeating: 0xE0, count: QUICConnection.channelMaxPayload + 1), delivery: .reliable)

        let counts = await receiver.value
        #expect(counts[.reliable] == perMode)
        #expect(counts[.reliableOrdered] == perMode)
        #expect(counts[.datagram] == perMode)
        #expect(QUICConnection.dedicatedOpened.value == openedBefore + 2)  // sender + receiver handles

        await monitor.disconnect()
        await camera.disconnect()
    }
}

#endif

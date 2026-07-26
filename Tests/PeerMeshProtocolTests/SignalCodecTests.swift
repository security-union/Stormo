import Foundation
import Testing

@testable import PeerMeshProtocol

@Suite("SignalCodec — verified zero-copy boundary (DD-5)")
struct SignalCodecTests {

    // 34-byte libp2p multihash (0x12 0x20 + 32-byte digest); the wire codec
    // requires the multihash length (DD-8).
    let alice = PeerID(
        keyHash: Data([0x12, 0x20]) + Data(repeating: 0x0A, count: 32),
        displayName: "Alice")

    @Test("Wire round-trip: encode → decode reads the same fields in place")
    func roundTrip() throws {
        let context = Data("room-42".utf8)
        let original = Signal.invite(inviter: alice, context: context)

        let wire = SignalCodec.encode(original)
        let decoded = try SignalCodec.decode(wire)

        #expect(decoded == original)  // byte-identical
        #expect(decoded.root.protocolVersion == SignalCodec.protocolVersion)
        guard case .invite(let view) = decoded.body else {
            Issue.record("expected invite body")
            return
        }
        #expect(view.inviter?.peerID == alice)
        #expect(Data(view.context) == context)
    }

    @Test("Verifier rejects malformed bytes as malformedSignal, never traps")
    func rejectsGarbage() {
        let garbage = Data((0..<64).map { _ in UInt8.random(in: .min ... .max) })
        #expect(throws: PeerMeshError.malformedSignal) {
            _ = try SignalCodec.decode(garbage)
        }
        #expect(throws: PeerMeshError.malformedSignal) {
            _ = try SignalCodec.decode(Data())
        }
    }

    @Test("Size cap enforced before any parsing (DD-5 rule 3)")
    func sizeCap() {
        let oversized = Data(count: SignalCodec.maxControlMessageSize + 1)
        #expect(throws: PeerMeshError.malformedSignal) {
            _ = try SignalCodec.decode(oversized)
        }
    }

    @Test("Roster round-trips through zero-copy views")
    func rosterRoundTrip() throws {
        let peers = (1...5).map {
            PeerID(
                keyHash: Data([0x12, 0x20]) + Data(repeating: UInt8($0), count: 32),
                displayName: "Peer \($0)")
        }
        let decoded = try SignalCodec.decode(
            SignalCodec.encode(.inviteResponse(accepted: true, roster: peers)))

        guard case .inviteResponse(let view) = decoded.body else {
            Issue.record("expected inviteResponse body")
            return
        }
        let roundTripped = (0..<view.rosterCount).compactMap { view.roster(at: $0)?.peerID }
        #expect(roundTripped == peers)
    }
}

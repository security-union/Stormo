import Foundation
import Testing

@testable import PeerMesh
import PeerMeshProtocol

#if canImport(Network) && canImport(Security)

@Suite("PeerHello — FlatBuffers identity bootstrap (DD-5)")
struct PeerHelloCodecTests {

    private let multihash = Data([0x12, 0x20]) + Data((0 ..< 32).map(UInt8.init))

    @Test("Round-trips a full PeerID")
    func roundTrip() {
        let id = PeerID(keyHash: multihash, displayName: "Camera")
        let decoded = PeerHello.decode(PeerHello.encode(id))
        #expect(decoded == id)
        #expect(decoded?.displayName == "Camera")
    }

    @Test("Malformed bytes are rejected as nil, never trap")
    func malformed() {
        #expect(PeerHello.decode(Data()) == nil)
        #expect(PeerHello.decode(Data([0xFF, 0x00, 0x01])) == nil)
        #expect(PeerHello.decode(Data(repeating: 0xAB, count: 512)) == nil)
    }

    @Test("Non-multihash key hash is rejected (34-byte contract)")
    func wrongKeyHashLength() {
        let bad = PeerID(keyHash: Data(repeating: 1, count: 8), displayName: "X")
        #expect(PeerHello.decode(PeerHello.encode(bad)) == nil)
    }
}

#endif

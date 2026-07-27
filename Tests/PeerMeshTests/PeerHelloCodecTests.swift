import Foundation
import Testing

@testable import PeerMesh
import PeerMeshProtocol

#if canImport(Network) && canImport(Security)

@Suite("PeerHello — FlatBuffers identity bootstrap (DD-5)")
struct PeerHelloCodecTests {

    private let multihash = Data([0x12, 0x20]) + Data((0 ..< 32).map(UInt8.init))

    @Test("Round-trips a full PeerID and stamps the current protocol version")
    func roundTrip() {
        let id = PeerID(keyHash: multihash, displayName: "Camera")
        let decoded = PeerHello.decode(PeerHello.encode(id))
        #expect(decoded?.peer == id)
        #expect(decoded?.peer.displayName == "Camera")
        #expect(decoded?.version == ProtocolVersion.current)
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

    // Gate tests pin BOTH sides explicitly — they must not couple to
    // ProtocolVersion.current, or bumping it breaks them spuriously.

    @Test("Version gate: same major passes, different major throws the typed error")
    func versionGate() throws {
        let local = ProtocolVersion(major: 3, minor: 0, patch: 0)
        try quicRequireCompatibleVersion(
            ProtocolVersion(major: 3, minor: 9, patch: 9), local: local)

        let newer = ProtocolVersion(major: 4, minor: 0, patch: 0)
        do {
            try quicRequireCompatibleVersion(newer, local: local)
            Issue.record("expected protocolVersionMismatch")
        } catch let error as QUICError {
            // The diagnostic must name both versions and tell THIS side to upgrade.
            let text = error.localizedDescription
            #expect(text.contains("local 3.0.0"))
            #expect(text.contains("4.0.0"))
            #expect(text.contains("this device needs an app upgrade"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Version gate: older-major peer throws with the peer-must-upgrade diagnostic")
    func versionGateOlderPeer() {
        do {
            try quicRequireCompatibleVersion(
                ProtocolVersion(major: 2, minor: 9, patch: 0),
                local: ProtocolVersion(major: 3, minor: 0, patch: 0))
            Issue.record("expected protocolVersionMismatch")
        } catch let error as QUICError {
            // Remote major is LOWER — the other side is the one that upgrades.
            let text = error.localizedDescription
            #expect(text.contains("2.9.0"))
            #expect(text.contains("local 3.0.0"))
            #expect(text.contains("the peer needs an app upgrade"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("A newer-minor hello from a future peer still decodes and passes the gate")
    func newerMinorInterop() throws {
        let local = ProtocolVersion(major: 1, minor: 0, patch: 0)
        let future = ProtocolVersion(major: 1, minor: 7, patch: 2)
        let id = PeerID(keyHash: multihash, displayName: "Future")
        let decoded = try #require(PeerHello.decode(PeerHello.encode(id, version: future)))
        #expect(decoded.version == future)
        try quicRequireCompatibleVersion(decoded.version, local: local)
    }
}

#endif

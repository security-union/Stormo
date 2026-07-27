import Testing

@testable import PeerMeshProtocol

@Suite("ProtocolVersion — semver interop rule")
struct ProtocolVersionTests {

    @Test("Same major is compatible regardless of minor/patch")
    func sameMajor() {
        let v1 = ProtocolVersion(major: 1, minor: 0, patch: 0)
        #expect(v1.isCompatible(with: ProtocolVersion(major: 1, minor: 9, patch: 3)))
        #expect(ProtocolVersion(major: 1, minor: 9, patch: 3).isCompatible(with: v1))
    }

    @Test("Different major is incompatible in both directions")
    func differentMajor() {
        let v1 = ProtocolVersion(major: 1, minor: 5, patch: 0)
        let v2 = ProtocolVersion(major: 2, minor: 0, patch: 0)
        #expect(!v1.isCompatible(with: v2))
        #expect(!v2.isCompatible(with: v1))
    }

    @Test("Pre-semver peers (unstamped hello, 0.0.0) are incompatible with 1.x")
    func preSemverPeer() {
        let unstamped = ProtocolVersion(major: 0, minor: 0, patch: 0)
        #expect(!ProtocolVersion.current.isCompatible(with: unstamped))
    }

    @Test("Renders as dotted semver")
    func rendering() {
        #expect(ProtocolVersion(major: 1, minor: 2, patch: 3).description == "1.2.3")
    }
}

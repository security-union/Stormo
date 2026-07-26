import Foundation
import Testing

@testable import PeerMesh

@Suite("PeerMesh core scaffolding")
struct PeerMeshTests {

    @Test("Identity derives PeerID from public key hash")
    func identityDerivesPeerID() {
        let identity = PeerIdentity(name: "Test Device")
        #expect(identity.id.displayName == "Test Device")
        #expect(identity.id.keyHash.count == 34)  // libp2p multihash (0x12 0x20 + SHA-256)
        #expect(identity.id.keyHash.prefix(2) == Data([0x12, 0x20]))  // sha2-256, len 32
    }

    @Test("Distinct identities never collide on keyHash, even with equal names")
    func peerIDsAreKeyDerived() {
        let a = PeerIdentity(name: "Same Name")
        let b = PeerIdentity(name: "Same Name")
        #expect(a.id != b.id)  // FR-20: names carry no identity
    }

    @Test("Zero-configuration session construction (MPC-ergonomics parity)")
    func zeroConfigConstruction() async {
        let session = PeerSession(name: "Dario's iPhone", service: "_myapp._udp")
        #expect(await session.service.type == "_myapp._udp")
        if case .fullMesh(let maxPeers) = await session.topology {
            #expect(maxPeers == 32)  // FR-10 default
        } else {
            Issue.record("default topology should be .fullMesh(maxPeers: 32)")
        }
        if case .automatic = await session.trust {
            // FR-21: default requires zero configuration
        } else {
            Issue.record("default trust should be .automatic")
        }
        await session.disconnect()
    }

    @Test("Unimplemented Phase 1 surface throws, not traps")
    func unimplementedSurfaceThrows() async {
        let hub = InMemoryTransport.Hub()
        let session = PeerSession(
            identity: PeerIdentity(name: "T"),
            service: "_t._udp",
            transport: InMemoryTransport(hub: hub)
        )
        await #expect(throws: PeerMeshError.self) {
            try await session.send(Data([0x01]))
        }
        await session.disconnect()
    }

    @Test("Signal codec constants match DD-5 discipline")
    func signalCodecDiscipline() {
        #expect(SignalCodec.maxControlMessageSize == 64 * 1024)
        #expect(SignalCodec.protocolVersion == 1)
    }
}

import PeerMeshTestKit

#if canImport(Network) && canImport(Security)
extension PeerMeshTests {
    @Test("Invalid Bonjour service types are rejected loudly, not silently")
    func bonjourTypeValidation() throws {
        // The class of bug that reached physical devices: a bare MPC-style
        // type registers nothing, silently. It must throw instead.
        #expect(throws: (any Error).self) {
            try QUICTransport.validateBonjourType("remotecam")
        }
        #expect(throws: (any Error).self) {
            try QUICTransport.validateBonjourType("_waytoolongservicename._udp")
        }
        #expect(throws: (any Error).self) {
            try QUICTransport.validateBonjourType("_x._quic")
        }
        try QUICTransport.validateBonjourType("_remotecam._udp")
        try QUICTransport.validateBonjourType("_pmdemo._tcp")
    }
}
#endif

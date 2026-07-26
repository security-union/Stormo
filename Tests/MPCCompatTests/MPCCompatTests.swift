import Foundation
import Testing

@testable import MPCCompat
import PeerMesh

@Suite("MPCCompat shim scaffolding")
struct MPCCompatTests {

    @Test("MultipeerSession constructs with MCSession-shaped API")
    func sessionConstruction() {
        let session = MultipeerSession(peer: "Test Device", service: "_compat._udp")
        #expect(session.myPeerID.displayName == "Test Device")
        #expect(session.connectedPeers.isEmpty)
        #expect(session.legacyPeerLimit == false)  // 8-peer cap lifted by default (FR-24)
    }

    @Test("send throws (not traps) before Phase 2 bridging")
    func sendThrowsUnimplemented() {
        let session = MultipeerSession(peer: "T", service: "_compat._udp")
        #expect(throws: PeerMeshError.self) {
            try session.send(Data([0x01]), toPeers: [], with: .reliable)
        }
    }

    @Test("Advertiser and browser mirror MPC construction shape")
    func advertiserAndBrowserConstruction() {
        let peer = PeerIdentity(name: "T").id
        let advertiser = NearbyServiceAdvertiser(
            peer: peer, discoveryInfo: ["room": "lobby"], serviceType: "_compat._udp")
        let browser = NearbyServiceBrowser(peer: peer, serviceType: "_compat._udp")
        #expect(advertiser.discoveryInfo?["room"] == "lobby")
        #expect(browser.serviceType == "_compat._udp")
    }
}

extension MPCCompatTests {
    @Test("MPC-style bare service types translate to Bonjour registration types")
    func serviceTypeTranslation() {
        #expect(CompatCore.bonjourType(fromMPCServiceType: "remotecam") == "_remotecam._udp")
        #expect(CompatCore.bonjourType(fromMPCServiceType: "_already._udp") == "_already._udp")
        #expect(CompatCore.bonjourType(fromMPCServiceType: "_custom._tcp") == "_custom._tcp")
    }
}

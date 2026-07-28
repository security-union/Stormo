import Foundation
import Testing

@testable import MPCCompat
import Stormo

@Suite("MPCCompat shim")
struct MPCCompatTests {

    @Test("MultipeerSession constructs with MCSession-shaped API")
    func sessionConstruction() {
        let session = MultipeerSession(peer: "Test Device", service: "_compat._udp")
        #expect(session.myPeerID.displayName == "Test Device")
        #expect(session.connectedPeers.isEmpty)
    }

    @Test("send on an unattached session throws (no route), not traps")
    func sendWithoutRouteThrows() {
        // A session with no advertiser/browser attached has no CompatCore and
        // thus no route; send must surface that as a throw, not a trap.
        let session = MultipeerSession(peer: "T", service: "_compat._udp")
        #expect(throws: StormoError.self) {
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

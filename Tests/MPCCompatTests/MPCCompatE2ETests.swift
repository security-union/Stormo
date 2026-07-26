import Foundation
import Testing

@testable import MPCCompat
import PeerMesh
import PeerMeshTestKit

/// End-to-end bridge tests over `InMemoryTransport` (a shared `Hub`), no radios.
///
/// Reproduces remote-shutter's exact usage of the compat surface: a
/// `MultipeerSession` + `NearbyServiceAdvertiser` on one device, a
/// `MultipeerSession` + `NearbyServiceBrowser` on another (each trio built with
/// one shared `PeerID`), the browser inviting, the advertiser auto-accepting via
/// `invitationHandler(true, session)`, and delegate callbacks for state + data.
///
/// All waits are event-driven off delegate-fed `AsyncStream`s — no sleeps.
@Suite("MPCCompat end-to-end over InMemoryTransport")
struct MPCCompatE2ETests {

    static let service = "_compat._udp"

    // MARK: Delegate-recording test doubles

    final class SessionRecorder: MultipeerSessionDelegate, @unchecked Sendable {
        let states: AsyncStream<(PeerID, MultipeerSession.PeerState)>
        let data: AsyncStream<(Data, PeerID)>
        let resourceStarts: AsyncStream<(String, PeerID)>
        let resourceFinishes: AsyncStream<(String, URL?, Error?)>
        private let statesIn: AsyncStream<(PeerID, MultipeerSession.PeerState)>.Continuation
        private let dataIn: AsyncStream<(Data, PeerID)>.Continuation
        private let resourceStartsIn: AsyncStream<(String, PeerID)>.Continuation
        private let resourceFinishesIn: AsyncStream<(String, URL?, Error?)>.Continuation

        init() {
            (states, statesIn) = AsyncStream.makeStream()
            (data, dataIn) = AsyncStream.makeStream()
            (resourceStarts, resourceStartsIn) = AsyncStream.makeStream()
            (resourceFinishes, resourceFinishesIn) = AsyncStream.makeStream()
        }

        func session(_ session: MultipeerSession, peer peerID: PeerID, didChange state: MultipeerSession.PeerState) {
            statesIn.yield((peerID, state))
        }
        func session(_ session: MultipeerSession, didReceive data: Data, fromPeer peerID: PeerID) {
            dataIn.yield((data, peerID))
        }
        func session(_ session: MultipeerSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: PeerID) {}
        func session(_ session: MultipeerSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: PeerID, with progress: Progress) {
            resourceStartsIn.yield((resourceName, peerID))
        }
        func session(_ session: MultipeerSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: PeerID, at localURL: URL?, withError error: Error?) {
            resourceFinishesIn.yield((resourceName, localURL, error))
        }
    }

    /// Auto-accepts every invitation with the supplied session, exactly like
    /// remote-shutter's `invitationHandler(true, session)`.
    final class AutoAcceptAdvertiserRecorder: NearbyServiceAdvertiserDelegate, @unchecked Sendable {
        let sessionToAccept: MultipeerSession
        let received: AsyncStream<PeerID>
        private let receivedIn: AsyncStream<PeerID>.Continuation

        init(accepting session: MultipeerSession) {
            self.sessionToAccept = session
            (received, receivedIn) = AsyncStream.makeStream()
        }

        func advertiser(
            _ advertiser: NearbyServiceAdvertiser,
            didReceiveInvitationFromPeer peerID: PeerID,
            withContext context: Data?,
            invitationHandler: @escaping @Sendable (Bool, MultipeerSession?) -> Void
        ) {
            invitationHandler(true, sessionToAccept)
            receivedIn.yield(peerID)
        }
        func advertiser(_ advertiser: NearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}
    }

    final class BrowserRecorder: NearbyServiceBrowserDelegate, @unchecked Sendable {
        let found: AsyncStream<(PeerID, [String: String]?)>
        let lost: AsyncStream<PeerID>
        private let foundIn: AsyncStream<(PeerID, [String: String]?)>.Continuation
        private let lostIn: AsyncStream<PeerID>.Continuation

        init() {
            (found, foundIn) = AsyncStream.makeStream()
            (lost, lostIn) = AsyncStream.makeStream()
        }

        func browser(_ browser: NearbyServiceBrowser, foundPeer peerID: PeerID, withDiscoveryInfo info: [String: String]?) {
            foundIn.yield((peerID, info))
        }
        func browser(_ browser: NearbyServiceBrowser, lostPeer peerID: PeerID) {
            lostIn.yield(peerID)
        }
        func browser(_ browser: NearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {}
    }

    // MARK: Helpers

    /// Await the first `.connected`/`.notConnected` transition (ignoring the
    /// intermediate `.connecting`) from a session recorder.
    private func firstState(
        _ recorder: SessionRecorder,
        matching target: MultipeerSession.PeerState
    ) async -> PeerID? {
        for await (peer, state) in recorder.states where state == target {
            return peer
        }
        return nil
    }

    // MARK: Tests

    @Test("Full remote-shutter flow: discover, invite, accept, exchange, disconnect")
    func fullBridgeLifecycle() async throws {
        let hub = InMemoryTransport.Hub()
        let peerA = PeerID(displayName: "DeviceA")
        let peerB = PeerID(displayName: "DeviceB")
        let transportA = InMemoryTransport(hub: hub)
        let transportB = InMemoryTransport(hub: hub)

        // Device A: session + advertiser sharing peerA.
        let sessionA = MultipeerSession(peer: peerA, service: Self.service, transport: transportA)
        let recorderA = SessionRecorder()
        sessionA.delegate = recorderA
        let advDelegate = AutoAcceptAdvertiserRecorder(accepting: sessionA)
        let advertiser = NearbyServiceAdvertiser(
            peer: peerA, discoveryInfo: ["role": "camera"], serviceType: Self.service, transport: transportA)
        advertiser.delegate = advDelegate
        advertiser.startAdvertisingPeer()

        // Device B: session + browser sharing peerB.
        let sessionB = MultipeerSession(peer: peerB, service: Self.service, transport: transportB)
        let recorderB = SessionRecorder()
        sessionB.delegate = recorderB
        let browserDelegate = BrowserRecorder()
        let browser = NearbyServiceBrowser(peer: peerB, serviceType: Self.service, transport: transportB)
        browser.delegate = browserDelegate
        browser.startBrowsingForPeers()

        // B finds A (with discovery info).
        var foundPeer: PeerID?
        for await (peer, info) in browserDelegate.found {
            #expect(info?["role"] == "camera")
            foundPeer = peer
            break
        }
        let cameraPeer = try #require(foundPeer)
        #expect(cameraPeer.displayName == "DeviceA")

        // B invites A; A's advertiser auto-accepts with (true, session).
        browser.invitePeer(cameraPeer, to: sessionB, withContext: nil, timeout: 10)

        // Both delegates reach .connected.
        let connectedOnA = try #require(await firstState(recorderA, matching: .connected))
        #expect(connectedOnA.displayName == "DeviceB")
        let connectedOnB = try #require(await firstState(recorderB, matching: .connected))
        #expect(connectedOnB.displayName == "DeviceA")
        #expect(sessionA.connectedPeers.count == 1)
        #expect(sessionB.connectedPeers.count == 1)

        // B -> A reliable data.
        let reliablePayload = Data([0xCA, 0xFE])
        try sessionB.send(reliablePayload, toPeers: sessionB.connectedPeers, with: .reliable)
        var gotOnA: Data?
        for await (data, from) in recorderA.data {
            #expect(from.displayName == "DeviceB")
            gotOnA = data
            break
        }
        #expect(gotOnA == reliablePayload)

        // A -> B unreliable data.
        let unreliablePayload = Data([0x60])
        try sessionA.send(unreliablePayload, toPeers: sessionA.connectedPeers, with: .unreliable)
        var gotOnB: Data?
        for await (data, from) in recorderB.data {
            #expect(from.displayName == "DeviceA")
            gotOnB = data
            break
        }
        #expect(gotOnB == unreliablePayload)

        // B disconnects; A observes .notConnected.
        sessionB.disconnect()
        let departedOnA = try #require(await firstState(recorderA, matching: .notConnected))
        #expect(departedOnA.displayName == "DeviceB")
        #expect(sessionA.connectedPeers.isEmpty)
    }

    @Test("Resource transfer through the MC-shaped API (remote-shutter video path)")
    func resourceTransferBridge() async throws {
        let hub = InMemoryTransport.Hub()
        let peerA = PeerID(displayName: "CameraDev")
        let peerB = PeerID(displayName: "MonitorDev")
        let transportA = InMemoryTransport(hub: hub)
        let transportB = InMemoryTransport(hub: hub)

        let sessionA = MultipeerSession(peer: peerA, service: Self.service, transport: transportA)
        let recorderA = SessionRecorder()
        sessionA.delegate = recorderA
        let advDelegate = AutoAcceptAdvertiserRecorder(accepting: sessionA)
        let advertiser = NearbyServiceAdvertiser(
            peer: peerA, discoveryInfo: nil, serviceType: Self.service, transport: transportA)
        advertiser.delegate = advDelegate
        advertiser.startAdvertisingPeer()

        let sessionB = MultipeerSession(peer: peerB, service: Self.service, transport: transportB)
        let recorderB = SessionRecorder()
        sessionB.delegate = recorderB
        let browserDelegate = BrowserRecorder()
        let browser = NearbyServiceBrowser(peer: peerB, serviceType: Self.service, transport: transportB)
        browser.delegate = browserDelegate
        browser.startBrowsingForPeers()

        var foundPeer: PeerID?
        for await (peer, _) in browserDelegate.found {
            foundPeer = peer
            break
        }
        browser.invitePeer(try #require(foundPeer), to: sessionB, withContext: nil, timeout: 10)
        _ = try #require(await firstState(recorderB, matching: .connected))
        _ = try #require(await firstState(recorderA, matching: .connected))

        // "Video" file: 1 MB of deterministic bytes, exactly like remote-shutter
        // shipping a recording via sendResource.
        let payload = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compat-video-\(UUID().uuidString).mov")
        try payload.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let completion = AsyncStream<Error?>.makeStream()
        let progress = sessionB.sendResource(
            at: sourceURL, withName: "take-42.mov",
            toPeer: try #require(sessionB.connectedPeers.first)
        ) { error in
            completion.continuation.yield(error)
        }
        #expect(progress != nil)

        // Receiver-side delegate lifecycle: didStart, then didFinish with a URL.
        var startedName: String?
        for await (name, _) in recorderA.resourceStarts {
            startedName = name
            break
        }
        #expect(startedName == "take-42.mov")

        var finishedURL: URL?
        for await (name, url, error) in recorderA.resourceFinishes {
            #expect(name == "take-42.mov")
            #expect(error == nil)
            finishedURL = url
            break
        }
        let received = try Data(contentsOf: try #require(finishedURL))
        #expect(received == payload)

        // Sender completion handler fires without error.
        for await error in completion.stream {
            #expect(error == nil)
            break
        }

        sessionB.disconnect()
        sessionA.disconnect()
    }

    @Test("Advertiser, browser, and session with one PeerID share one CompatCore")
    func sharedCoreForOnePeer() {
        let peer = PeerID(displayName: "Shared")
        let transport = InMemoryTransport(hub: InMemoryTransport.Hub())
        let advertiser = NearbyServiceAdvertiser(
            peer: peer, discoveryInfo: nil, serviceType: Self.service, transport: transport)
        let browser = NearbyServiceBrowser(peer: peer, serviceType: Self.service, transport: transport)

        // Resolving either resolves the SAME core (registry keyed on peer+service).
        #expect(advertiser.core === browser.core)

        // A session bound via the browser adopts that shared core.
        let session = MultipeerSession(peer: peer, service: Self.service, transport: transport)
        session.bind(to: browser.core)
        #expect(session.core === advertiser.core)
    }
}

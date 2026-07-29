import Foundation
import Testing

@testable import MPCCompat
import Stormo
import StormoTestKit

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

        // Sender-side progress bar (MCSession parity): the returned Progress
        // must count BYTES and end complete — not a 0-or-1 proxy.
        let senderProgress = try #require(progress)
        #expect(senderProgress.totalUnitCount == Int64(payload.count))
        #expect(senderProgress.completedUnitCount == Int64(payload.count))
        #expect(senderProgress.fractionCompleted == 1.0)

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

#if os(macOS)
extension MPCCompatE2ETests {
    /// Bounded wait for the first matching stream element — reconnect
    /// regressions never fire the awaited callback, so fail instead of hang.
    private func first<T: Sendable>(
        of stream: AsyncStream<T>,
        within seconds: TimeInterval,
        where predicate: @escaping @Sendable (T) -> Bool
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                for await element in stream where predicate(element) { return element }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
    }
    /// Remote-shutter's retry pattern over the PRODUCTION transport path
    /// (real QUIC + Bonjour, no injected transport): connect, disconnect
    /// (MCSession-style session rebuild), then RE-invite the same discovered
    /// peer WITHOUT re-browsing. Regression for the device bug where
    /// disconnect tore down discovery + the endpoint registry, making every
    /// retry fail instantly ("browser has already been cancelled").
    @Test("Disconnect then re-invite over real QUIC (MCSession retry semantics)")
    func reinviteAfterDisconnectOverQUIC() async throws {
        setenv("STORMO_NO_P2P", "1", 1)
        let probe = PeerIdentity(name: "compat-retry-probe")
        guard QUICTransport.isTLSIdentityAvailable(for: probe) else {
            print("[skip] no TLS identity in this environment"); return
        }
        let service = "_pmretry\(UInt16.random(in: 1000...9999))._udp"
        let peerA = PeerID(displayName: "RetryCam")
        let peerB = PeerID(displayName: "RetryMon")

        let sessionA = MultipeerSession(peer: peerA, service: service)
        let recorderA = SessionRecorder()
        sessionA.delegate = recorderA
        let advDelegate = AutoAcceptAdvertiserRecorder(accepting: sessionA)
        let advertiser = NearbyServiceAdvertiser(
            peer: peerA, discoveryInfo: nil, serviceType: service)
        advertiser.delegate = advDelegate
        advertiser.startAdvertisingPeer()

        let sessionB = MultipeerSession(peer: peerB, service: service)
        let recorderB = SessionRecorder()
        sessionB.delegate = recorderB
        let browserDelegate = BrowserRecorder()
        let browser = NearbyServiceBrowser(peer: peerB, serviceType: service)
        browser.delegate = browserDelegate
        browser.startBrowsingForPeers()

        var found: PeerID?
        for await (peer, _) in browserDelegate.found {
            if peer.displayName == "RetryCam" { found = peer; break }
        }
        let target = try #require(found)

        // Round 1: connect.
        browser.invitePeer(target, to: sessionB, withContext: nil, timeout: 25)
        var stateB = await firstState(recorderB, matching: .connected)
        #expect(stateB != nil, "round 1 must connect")

        // MCSession-style rebuild: disconnect, survivor sees .notConnected.
        sessionB.disconnect()
        let departed = await firstState(recorderA, matching: .notConnected)
        #expect(departed != nil, "camera must observe the departure")

        // Round 2: RE-invite the SAME discovered peer, no fresh browsing.
        // Under the old teardown semantics this failed instantly (endpoint
        // registry destroyed with the session).
        browser.invitePeer(target, to: sessionB, withContext: nil, timeout: 25)
        stateB = await firstState(recorderB, matching: .connected)
        #expect(stateB != nil, "re-invite after disconnect must connect again")

        sessionB.disconnect()
        sessionA.disconnect()
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
    }

    /// Scanning-screen revisit: stop+start browsing on the same objects must
    /// re-find a still-advertising peer (regression: browse dedup swallowed
    /// the re-find). The advertiser deliberately keeps running — a record
    /// flap would evict the dedup entry and mask the bug.
    @Test("Rescan after disconnect re-finds and reconnects (scanning-screen revisit)")
    func rescanAfterDisconnectOverQUIC() async throws {
        setenv("STORMO_NO_P2P", "1", 1)
        let probe = PeerIdentity(name: "compat-rescan-probe")
        guard QUICTransport.isTLSIdentityAvailable(for: probe) else {
            print("[skip] no TLS identity in this environment"); return
        }
        let service = "_pmrescan\(UInt16.random(in: 1000...9999))._udp"
        let peerA = PeerID(displayName: "RescanCam")
        let peerB = PeerID(displayName: "RescanMon")

        let sessionA = MultipeerSession(peer: peerA, service: service)
        let recorderA = SessionRecorder()
        sessionA.delegate = recorderA
        let advDelegate = AutoAcceptAdvertiserRecorder(accepting: sessionA)
        let advertiser = NearbyServiceAdvertiser(
            peer: peerA, discoveryInfo: ["role": "camera"], serviceType: service)
        advertiser.delegate = advDelegate
        advertiser.startAdvertisingPeer()

        let sessionB = MultipeerSession(peer: peerB, service: service)
        let recorderB = SessionRecorder()
        sessionB.delegate = recorderB
        let browserDelegate = BrowserRecorder()
        let browser = NearbyServiceBrowser(peer: peerB, serviceType: service)
        browser.delegate = browserDelegate
        browser.startBrowsingForPeers()

        // Match by displayName: the local `peerA` handle does not share the
        // advertiser's persisted key hash.
        let round1 = await first(of: browserDelegate.found, within: 15) { $0.0.displayName == "RescanCam" }
        let target = try #require(round1?.0, "round 1 must discover the camera")
        browser.invitePeer(target, to: sessionB, withContext: nil, timeout: 25)
        #expect(await firstState(recorderB, matching: .connected) != nil, "round 1 must connect")

        sessionB.disconnect()
        #expect(await firstState(recorderA, matching: .notConnected) != nil,
                "camera must observe the departure")

        browser.stopBrowsingForPeers()
        browser.startBrowsingForPeers()

        let refound = await first(of: browserDelegate.found, within: 15) { $0.0.displayName == "RescanCam" }
        #expect(refound != nil, "restarted browse must re-find the advertising camera")

        browser.invitePeer(target, to: sessionB, withContext: nil, timeout: 25)
        #expect(await firstState(recorderB, matching: .connected) != nil,
                "round 2 must reconnect after the rescan")

        sessionB.disconnect()
        sessionA.disconnect()
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
    }

    /// Camera-side revisit: stop, NEW compat advertiser on the same core,
    /// start (no awaits between) — then a re-invite accepted with freshly
    /// rebuilt sessions on both sides must connect.
    @Test("Camera re-advertise cycle after disconnect accepts a new invite")
    func cameraReadvertiseAfterDisconnectOverQUIC() async throws {
        setenv("STORMO_NO_P2P", "1", 1)
        let probe = PeerIdentity(name: "compat-readv-probe")
        guard QUICTransport.isTLSIdentityAvailable(for: probe) else {
            print("[skip] no TLS identity in this environment"); return
        }
        let service = "_pmreadv\(UInt16.random(in: 1000...9999))._udp"
        let peerA = PeerID(displayName: "ReadvCam")
        let peerB = PeerID(displayName: "ReadvMon")

        let sessionA = MultipeerSession(peer: peerA, service: service)
        let recorderA = SessionRecorder()
        sessionA.delegate = recorderA
        let advDelegate = AutoAcceptAdvertiserRecorder(accepting: sessionA)
        var advertiser = NearbyServiceAdvertiser(
            peer: peerA, discoveryInfo: ["role": "camera"], serviceType: service)
        advertiser.delegate = advDelegate
        advertiser.startAdvertisingPeer()

        let sessionB = MultipeerSession(peer: peerB, service: service)
        let recorderB = SessionRecorder()
        sessionB.delegate = recorderB
        let browserDelegate = BrowserRecorder()
        let browser = NearbyServiceBrowser(peer: peerB, serviceType: service)
        browser.delegate = browserDelegate
        browser.startBrowsingForPeers()

        let round1 = await first(of: browserDelegate.found, within: 15) { $0.0.displayName == "ReadvCam" }
        let target = try #require(round1?.0, "round 1 must discover the camera")
        browser.invitePeer(target, to: sessionB, withContext: nil, timeout: 25)
        #expect(await firstState(recorderB, matching: .connected) != nil, "round 1 must connect")
        sessionB.disconnect()
        #expect(await firstState(recorderA, matching: .notConnected) != nil,
                "camera must observe the departure")

        advertiser.stopAdvertisingPeer()
        advertiser = NearbyServiceAdvertiser(
            peer: peerA, discoveryInfo: ["role": "camera"], serviceType: service)
        advertiser.startAdvertisingPeer()

        // rebuildSessionIfIdle on both sides: round 2 uses fresh MCSessions.
        let sessionA2 = MultipeerSession(peer: peerA, service: service)
        let recorderA2 = SessionRecorder()
        sessionA2.delegate = recorderA2
        let advDelegate2 = AutoAcceptAdvertiserRecorder(accepting: sessionA2)
        advertiser.delegate = advDelegate2

        let sessionB2 = MultipeerSession(peer: peerB, service: service)
        let recorderB2 = SessionRecorder()
        sessionB2.delegate = recorderB2

        browser.invitePeer(target, to: sessionB2, withContext: nil, timeout: 25)
        #expect(await firstState(recorderB2, matching: .connected) != nil,
                "re-invite after the camera's advertiser cycle must connect")

        sessionB.disconnect()
        sessionA.disconnect()
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
    }

    /// Repeated `startAdvertisingPeer()` must not leak the previous listener:
    /// an orphaned listener keeps its Bonjour record registered after stop —
    /// a ghost peer browsers keep finding but that can never accept.
    @Test("Double start then stop leaves no ghost advertiser")
    func advertiserRestartLeavesNoGhostListener() async throws {
        setenv("STORMO_NO_P2P", "1", 1)
        let probe = PeerIdentity(name: "compat-ghost-probe")
        guard QUICTransport.isTLSIdentityAvailable(for: probe) else {
            print("[skip] no TLS identity in this environment"); return
        }
        let service = "_pmghost\(UInt16.random(in: 1000...9999))._udp"
        let peerA = PeerID(displayName: "GhostCam")
        let peerB = PeerID(displayName: "GhostMon")

        let advertiser = NearbyServiceAdvertiser(
            peer: peerA, discoveryInfo: nil, serviceType: service)
        advertiser.startAdvertisingPeer()
        advertiser.startAdvertisingPeer()

        let browserDelegate = BrowserRecorder()
        let browser = NearbyServiceBrowser(peer: peerB, serviceType: service)
        browser.delegate = browserDelegate
        browser.startBrowsingForPeers()

        let found = await first(of: browserDelegate.found, within: 15) { $0.0.displayName == "GhostCam" }
        let ghostID = try #require(found?.0, "advertiser must be discoverable before the stop")

        // One stop must fully withdraw the record; with a leaked first
        // listener it never disappears.
        advertiser.stopAdvertisingPeer()
        let lost = await first(of: browserDelegate.lost, within: 15) { $0 == ghostID }
        #expect(lost != nil, "stopAdvertisingPeer must withdraw the Bonjour record")

        browser.stopBrowsingForPeers()
    }
}
#endif

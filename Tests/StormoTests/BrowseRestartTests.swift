import Foundation
import Testing

import Stormo

/// Browse-session lifecycle over real Bonjour: stopping and restarting
/// browsing must behave like a fresh browser (MC parity — remote-shutter's
/// scanning screen calls stop+start on every revisit).
#if os(macOS)
@Suite("Browse restart over real Bonjour", .serialized)
struct BrowseRestartTests {

    /// Bounded wait for the first matching discovery event. Dedup regressions
    /// simply never emit, so the wait needs a deadline that fails the test
    /// instead of hanging it.
    private func firstEvent(
        of stream: AsyncStream<DiscoveryEvent>,
        within seconds: TimeInterval,
        where predicate: @escaping @Sendable (DiscoveryEvent) -> Bool
    ) async -> DiscoveryEvent? {
        await withTaskGroup(of: DiscoveryEvent?.self) { group in
            group.addTask {
                for await event in stream where predicate(event) { return event }
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

    /// The field regression behind remote-shutter's stuck scanner: the plain
    /// `.bonjour` browse (the ONLY kind that surfaces peers over AWDL — TXT
    /// browsing is unreliable there, failure mode 8) deduped re-finds against
    /// a transport-lifetime `seenPeers` set, so a restarted browse session
    /// never re-emitted `.found` for a peer that was still advertising. The
    /// loopback masking: TXT enrichment re-fires `.updated` from its
    /// per-stream state, so compat-level tests pass while AWDL devices stay
    /// blind. Assert the plain path directly: a NEW browse session must
    /// re-surface a still-advertised peer as `.found`.
    @Test("Restarted browse re-emits .found for a still-advertised peer")
    func browseRestartRefindsAdvertisedPeer() async throws {
        guard QUICTransport.isTLSIdentityAvailable(for: PeerIdentity(name: "probe")) else {
            print("[skip] QUIC: no TLS identity in this environment"); return
        }
        setenv("STORMO_NO_P2P", "1", 1)
        let service = ServiceDescriptor(type: "_pmrf\(UInt16.random(in: 1000...9999))._udp")

        let camIdentity = PeerIdentity(name: "RefindCam")
        let target = camIdentity.id
        let camTransport = QUICTransport(configuration: .init(discovery: .bonjour))
        try await camTransport.startAdvertising(
            service: service, metadata: [:], identity: camIdentity)

        let monTransport = QUICTransport(configuration: .init(discovery: .bonjour))

        // Browse session 1: the camera surfaces (either browse kind).
        let session1 = try await monTransport.discoveries(service: service)
        let seen1 = await firstEvent(of: session1, within: 15) { event in
            switch event {
            case .found(let peer), .updated(let peer): return peer.id == target
            case .lost: return false
            }
        }
        #expect(seen1 != nil, "session 1 must discover the advertised peer")

        // Stop browsing the way PeerSession does: the consumer goes away and
        // the transport is told to stop. The camera keeps advertising.
        await monTransport.stopBrowsing()

        // Browse session 2: a fresh session must re-surface the peer as
        // `.found` — `.updated` alone only reaches AWDL-less consumers.
        let session2 = try await monTransport.discoveries(service: service)
        let refound = await firstEvent(of: session2, within: 15) { event in
            if case .found(let peer) = event { return peer.id == target }
            return false
        }
        #expect(refound != nil,
                "restarted browse must re-emit .found for the still-advertised peer")

        await monTransport.stopBrowsing()
        await camTransport.stopAdvertising()
    }
}
#endif

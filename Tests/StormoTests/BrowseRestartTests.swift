import Foundation
import Testing

import Stormo

/// Browse-session lifecycle over real Bonjour: stopping and restarting
/// browsing must behave like a fresh browser (MC parity — remote-shutter's
/// scanning screen calls stop+start on every revisit).
#if os(macOS)
@Suite("Browse restart over real Bonjour", .serialized)
struct BrowseRestartTests {

    /// Bounded wait for the first matching discovery event — dedup
    /// regressions never emit, so fail instead of hang.
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

    /// A NEW browse session must re-surface a still-advertised peer as
    /// `.found` — over AWDL the plain browse is the only source of finds
    /// (failure mode 8), so a TXT-only `.updated` is not enough. Regression:
    /// transport-lifetime dedup swallowed the re-find.
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

        await monTransport.stopBrowsing()

        // Session 2 must re-surface the peer as `.found` specifically.
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

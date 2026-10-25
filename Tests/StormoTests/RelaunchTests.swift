import Foundation
import Testing

import Stormo
import StormoTestKit

/// App relaunch (tier 2): a peer's process dies WITHOUT a leave — no close,
/// no goodbye — and comes back with the same persisted identity. The survivor
/// still lists the old session as a member and still holds its connection.
/// The reborn peer's fresh invite must replace the dead session, not be
/// dropped as a duplicate, and the replaced connection must never tear down
/// its successor.
@Suite("PeerSession — relaunch with a persisted identity")
struct RelaunchTests {

    @Test("A re-invite from the same identity replaces the stale session")
    func relaunchReinvite() async throws {
        let hub = InMemoryTransport.Hub()
        let phoneIdentity = PeerIdentity(name: "Phone")  // persisted across the "relaunch"

        let mac = PeerSession(
            identity: PeerIdentity(name: "Mac"),
            service: "_relaunch._udp",
            transport: InMemoryTransport(hub: hub))
        try await mac.startAdvertising()

        // The app's policy: every invitation is accepted, forever.
        let acceptTask = Task {
            for await invitation in mac.invitations { await invitation.accept() }
        }
        // Record the Mac's membership history for the final assertion.
        let membershipLog = MembershipLog()
        let membershipTask = Task {
            for await event in mac.membership {
                switch event {
                case .joined: await membershipLog.append("joined")
                case .left, .unreachable: await membershipLog.append("left")
                case .identityChanged: break
                }
            }
        }

        // Launch 1: the phone finds the Mac and joins.
        let launch1 = PeerSession(
            identity: phoneIdentity,
            service: "_relaunch._udp",
            transport: InMemoryTransport(hub: hub))
        try await launch1.startBrowsing()
        let foundOnce = try #require(await firstFound(launch1))
        _ = try await launch1.invite(foundOnce, timeout: 2)
        #expect(await mac.members == [phoneIdentity.id])

        // The process is killed: no leave, no close. The Mac's connection to
        // launch 1 stays open and its membership entry stays stale.

        // Launch 2: same identity, fresh session, fresh transport.
        let launch2 = PeerSession(
            identity: phoneIdentity,
            service: "_relaunch._udp",
            transport: InMemoryTransport(hub: hub))
        try await launch2.startBrowsing()
        let foundAgain = try #require(await firstFound(launch2))

        // Pre-fix this invite was silently dropped (already a member) and
        // timed out; the phone could rejoin nothing it had joined before.
        _ = try await launch2.invite(foundAgain, timeout: 2)
        #expect(await mac.members == [phoneIdentity.id])

        // The membership carries the NEW connection: a message from the Mac
        // must land in launch 2's inbox, not the dead session's.
        let inbox = Task<InboundMessage?, Never> {
            for await message in launch2.messages { return message }
            return nil
        }
        try await mac.send(Data([0xBE, 0xEF]), to: .all, delivery: .reliable)
        let delivered = try #require(await inbox.value)
        #expect(delivered.payload == Data([0xBE, 0xEF]))

        // The old session died and the new one joined, in that order.
        let deadline = Date().addingTimeInterval(2)
        while await membershipLog.entries != ["joined", "left", "joined"], Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await membershipLog.entries == ["joined", "left", "joined"])

        acceptTask.cancel()
        membershipTask.cancel()
        await mac.disconnect()
        await launch2.disconnect()
    }

    private actor MembershipLog {
        var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
    }

    private func firstFound(_ session: PeerSession) async -> DiscoveredPeer? {
        for await event in session.discoveries {
            if case .found(let peer) = event { return peer }
        }
        return nil
    }
}

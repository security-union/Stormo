import Foundation
import Testing

import Stormo
import StormoTestKit

/// Tier-2 runtime tests for the suspension grace protocol (C-5): the full
/// announce → freeze (transport-level kill, no goodbye) → hold → resume/expiry
/// loop over `InMemoryTransport`, using `KillSwitchTransport` to sever links
/// the way iOS suspension does — silently.
@Suite("Suspension grace over InMemoryTransport")
struct SuspensionRuntimeTests {

    /// Bounded wait for the first membership event matching `predicate` —
    /// a missing event must fail the test, not hang the suite.
    private func firstMembership(
        of stream: AsyncStream<MembershipEvent>,
        within seconds: TimeInterval,
        where predicate: @escaping @Sendable (MembershipEvent) -> Bool
    ) async -> MembershipEvent? {
        await withTaskGroup(of: MembershipEvent?.self) { group in
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

    @Test("Backgrounded peer suspends, survives the silent link kill, and resumes")
    func suspendKillResume() async throws {
        let hub = InMemoryTransport.Hub()
        // peer-0 is the backgrounder: it invited peer-1 (formMesh: i < j), so
        // it retains the endpoint its resume re-dial needs.
        let killable = KillSwitchTransport(base: InMemoryTransport(hub: hub))
        let backgrounder = PeerSession(
            identity: PeerIdentity(name: "peer-0"), service: "_susp._udp", transport: killable)
        let observer = PeerSession(
            identity: PeerIdentity(name: "peer-1"), service: "_susp._udp",
            transport: InMemoryTransport(hub: hub))
        _ = try await formMesh([backgrounder, observer])
        let backgrounderID = await backgrounder.identity.id
        let observerMembership = await observer.membership

        // Wait for the notice before killing — the freeze must not race the
        // signal onto a dead link.
        await backgrounder.announceSuspension(gracePeriod: 8)
        let suspendedEvent = await firstMembership(of: observerMembership, within: 5) {
            if case .suspended(let id) = $0 { return id == backgrounderID }
            return false
        }
        #expect(suspendedEvent != nil, "observer must see the suspension notice")

        // iOS freezes the app: every link dies silently, no protocol goodbye.
        await killable.kill()
        try await Task.sleep(nanoseconds: 300_000_000)

        // Grace holds membership on BOTH sides.
        #expect(await observer.members.count == 1, "suspended member must survive the kill")
        #expect(await backgrounder.members.count == 1, "frozen side keeps its members too")

        await backgrounder.resume()
        let resumedEvent = await firstMembership(of: observerMembership, within: 5) {
            if case .resumed(let member) = $0 { return member.id == backgrounderID }
            return false
        }
        #expect(resumedEvent != nil, "observer must see the resume")

        // The revived link carries traffic.
        let observerInbox = await observer.messages
        try await backgrounder.send(Data([0xB0]), to: .all, delivery: .reliable)
        let got = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                for await message in observerInbox { return message.payload }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let winner = await group.next() ?? nil
            group.cancelAll()
            return winner
        }
        #expect(got == Data([0xB0]), "post-resume send must reach the observer")

        await backgrounder.disconnect()
        await observer.disconnect()
    }

    @Test("Grace expiry without a resume becomes a normal departure")
    func graceExpiryDeparts() async throws {
        let hub = InMemoryTransport.Hub()
        let killable = KillSwitchTransport(base: InMemoryTransport(hub: hub))
        let backgrounder = PeerSession(
            identity: PeerIdentity(name: "peer-0"), service: "_suspx._udp", transport: killable)
        let observer = PeerSession(
            identity: PeerIdentity(name: "peer-1"), service: "_suspx._udp",
            transport: InMemoryTransport(hub: hub))
        _ = try await formMesh([backgrounder, observer])
        let backgrounderID = await backgrounder.identity.id
        let observerMembership = await observer.membership

        await backgrounder.announceSuspension(gracePeriod: 1)
        let suspendedEvent = await firstMembership(of: observerMembership, within: 5) {
            if case .suspended(let id) = $0 { return id == backgrounderID }
            return false
        }
        #expect(suspendedEvent != nil, "observer must see the suspension notice")
        await killable.kill()

        // No resume: after the ~1 s grace the suspension becomes .left.
        let leftEvent = await firstMembership(of: observerMembership, within: 6) {
            if case .left(let id) = $0 { return id == backgrounderID }
            return false
        }
        #expect(leftEvent != nil, "grace expiry must surface as a departure")
        #expect(await observer.members.isEmpty)

        await backgrounder.disconnect()
        await observer.disconnect()
    }
}

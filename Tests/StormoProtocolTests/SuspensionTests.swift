import Foundation
import Testing

@testable import StormoProtocol

/// Tier-1 tests (DD-6) for the suspension grace protocol (C-5): iOS
/// backgrounding kills QUIC connections in ~5 s, so a peer that announced
/// `Suspend` must be treated as suspended — not departed — until its grace
/// window expires or it reconnects. Time is an input: the tests fire timers.
@Suite("ProtocolEngine — suspension grace (C-5)")
struct SuspensionTests {

    static func makePeer(_ name: String, byte: UInt8) -> PeerID {
        PeerID(
            keyHash: Data([0x12, 0x20]) + Data(repeating: byte, count: 32),
            displayName: name)
    }

    let alice = Self.makePeer("Alice", byte: 0x0A)
    let bob = Self.makePeer("Bob", byte: 0x0B)

    /// Drive `peer` through connect+invite+accept (mirrors the tier-1 helper).
    private func engineWithMember(_ local: PeerID, member: PeerID) -> ProtocolEngine {
        var engine = ProtocolEngine(localPeer: local)
        _ = engine.handle(.connectionEstablished(member))
        _ = engine.handle(.signal(.invite(inviter: member, context: nil), from: member))
        _ = engine.handle(.command(.respondToInvitation(from: member, accept: true)))
        return engine
    }

    // MARK: The spec repro — without Suspend, connectionClosed = peerLeft

    @Test("Suspend notice: the following connection loss is NOT a departure")
    func suspendedCloseKeepsMembership() {
        var engine = engineWithMember(alice, member: bob)

        let noticed = engine.handle(.signal(.suspend(graceMs: 30_000), from: bob))
        #expect(noticed == [
            .startTimer(.suspension(bob), duration: 30),
            .emit(.peerSuspended(bob)),
        ])

        // The ~5 s QUIC idle timeout closes the connection. Suspended member:
        // no peerLeft, membership intact.
        let closed = engine.handle(.connectionClosed(bob))
        #expect(closed == [])
        #expect(engine.members.contains(bob))
    }

    @Test("Grace expiry turns the suspension into a departure")
    func graceExpiryDeparts() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.signal(.suspend(graceMs: 30_000), from: bob))
        _ = engine.handle(.connectionClosed(bob))

        let expired = engine.handle(.timerFired(.suspension(bob)))
        #expect(expired == [.emit(.peerLeft(bob))])
        #expect(engine.members.isEmpty)

        // The timer is one-shot: a stale second fire is a no-op.
        #expect(engine.handle(.timerFired(.suspension(bob))) == [])
    }

    @Test("Reconnect within grace resumes silently — membership never lapsed")
    func reconnectWithinGraceResumes() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.signal(.suspend(graceMs: 30_000), from: bob))
        _ = engine.handle(.connectionClosed(bob))

        let reconnect = engine.handle(.connectionEstablished(bob))
        #expect(reconnect == [
            .cancelTimer(.suspension(bob)),
            .emit(.peerResumed(bob)),
        ])
        #expect(engine.members.contains(bob))

        // A later (stale) grace timer must not evict the resumed member.
        #expect(engine.handle(.timerFired(.suspension(bob))) == [])
        #expect(engine.members.contains(bob))

        // And a NORMAL close after the resume is a real departure again.
        let closed = engine.handle(.connectionClosed(bob))
        #expect(closed == [.emit(.peerLeft(bob))])
    }

    @Test("Local suspend announces to connected members and arms local grace")
    func localSuspendAnnounces() {
        var engine = engineWithMember(alice, member: bob)

        let effects = engine.handle(.command(.suspend(grace: 60)))
        #expect(effects == [
            .sendSignal(.suspend(graceMs: 60_000), to: bob),
            .startTimer(.suspension(bob), duration: 60),
        ])

        // Our own connection losses while frozen must not evict members.
        _ = engine.handle(.connectionClosed(bob))
        #expect(engine.members.contains(bob))
    }

    @Test("Resume re-dials suspended members whose connections died")
    func resumeRedials() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.command(.suspend(grace: 60)))
        _ = engine.handle(.connectionClosed(bob))

        let effects = engine.handle(.command(.resume))
        #expect(effects == [.connect(to: bob)])

        // The re-dial completing resumes the member.
        let reconnected = engine.handle(.connectionEstablished(bob))
        #expect(reconnected == [
            .cancelTimer(.suspension(bob)),
            .emit(.peerResumed(bob)),
        ])
    }

    @Test("Resume with the connection still alive sheds the suspension in place")
    func resumeWithLiveConnection() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.command(.suspend(grace: 60)))

        // No close happened (short background): no re-dial, just cleanup.
        #expect(engine.handle(.command(.resume)) == [.cancelTimer(.suspension(bob))])
        #expect(engine.members.contains(bob))

        // A genuine close after that is a real departure again.
        #expect(engine.handle(.connectionClosed(bob)) == [.emit(.peerLeft(bob))])
    }

    @Test("Grace expiry never evicts a member whose connection is alive")
    func expiryWithLiveConnectionIsNoop() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.signal(.suspend(graceMs: 30_000), from: bob))

        // The link never dropped (short background) and the suspender has no
        // resume trigger to send — only this timer runs. It must not depart
        // a live member.
        #expect(engine.handle(.timerFired(.suspension(bob))) == [])
        #expect(engine.members.contains(bob))

        // Suspension shed: the next close is a normal departure.
        #expect(engine.handle(.connectionClosed(bob)) == [.emit(.peerLeft(bob))])
    }

    @Test("A remote's requested grace is clamped to the configured maximum")
    func graceClampedToMaximum() {
        var engine = engineWithMember(alice, member: bob)
        let effects = engine.handle(.signal(.suspend(graceMs: 3_600_000), from: bob))
        #expect(effects == [
            .startTimer(.suspension(bob), duration: 120),
            .emit(.peerSuspended(bob)),
        ])
    }

    @Test("Suspend from a non-member is ignored (membership gate, DD-6)")
    func suspendFromNonMemberIgnored() {
        var engine = ProtocolEngine(localPeer: alice)
        _ = engine.handle(.connectionEstablished(bob))
        #expect(engine.handle(.signal(.suspend(graceMs: 30_000), from: bob)) == [])
    }

    @Test("Leave clears suspensions — stale grace timers no-op")
    func leaveClearsSuspensions() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.signal(.suspend(graceMs: 30_000), from: bob))
        _ = engine.handle(.command(.leave))
        #expect(engine.handle(.timerFired(.suspension(bob))) == [])
        #expect(engine.members.isEmpty)
    }

    @Test("Suspend signal round-trips the wire codec")
    func suspendSignalRoundTrip() throws {
        let signal = Signal.suspend(graceMs: 45_000)
        let decoded = try SignalCodec.decode(signal.encoded)
        guard case .suspend(let view) = decoded.body else {
            Issue.record("expected .suspend body, got \(decoded.body)")
            return
        }
        #expect(view.graceMs == 45_000)
    }
}

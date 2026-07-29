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
        #expect(expired == [.cancelTimer(.resumeRetry(bob)), .emit(.peerLeft(bob))])
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
            .cancelTimer(.resumeRetry(bob)),
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

    @Test("Local suspend announces and marks — no timers on a process about to freeze")
    func localSuspendAnnounces() {
        var engine = engineWithMember(alice, member: bob)

        let effects = engine.handle(.command(.suspend(grace: 60)))
        #expect(effects == [.sendSignal(.suspend(graceMs: 60_000), to: bob)])

        // Our own connection losses while frozen must not evict members.
        _ = engine.handle(.connectionClosed(bob))
        #expect(engine.members.contains(bob))
    }

    @Test("Resume re-dials suspended members whose connections died")
    func resumeRedials() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.command(.suspend(grace: 60)))
        _ = engine.handle(.connectionClosed(bob))

        // Wake-up arms both clocks: the fixed-rate re-dial and the grace,
        // which runs from NOW (the frozen process never ran timers).
        let effects = engine.handle(.command(.resume))
        #expect(effects == [
            .connect(to: bob),
            .startTimer(.resumeRetry(bob), duration: 1),
            .startTimer(.suspension(bob), duration: 60),
        ])

        // The re-dial completing resumes the member and stops the loop.
        let reconnected = engine.handle(.connectionEstablished(bob))
        #expect(reconnected == [
            .cancelTimer(.suspension(bob)),
            .cancelTimer(.resumeRetry(bob)),
            .emit(.peerResumed(bob)),
        ])
    }

    @Test("Resume re-dial ticks at a fixed rate until reconnect")
    func resumeRetriesAtFixedRate() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.command(.suspend(grace: 60)))
        _ = engine.handle(.connectionClosed(bob))
        _ = engine.handle(.command(.resume))

        // The dial fails (radio not back yet): membership held, and each
        // tick re-dials and re-arms — fixed rate, no backoff.
        _ = engine.handle(.connectionClosed(bob))
        #expect(engine.members.contains(bob))
        let tick = engine.handle(.timerFired(.resumeRetry(bob)))
        #expect(tick == [
            .connect(to: bob),
            .startTimer(.resumeRetry(bob), duration: 1),
        ])

        // Reconnect stops the loop: a stale tick is a no-op.
        _ = engine.handle(.connectionEstablished(bob))
        #expect(engine.handle(.timerFired(.resumeRetry(bob))) == [])
    }

    @Test("Resume re-dial dies with the suspension")
    func resumeRetryStopsOnExpiryAndLeave() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.command(.suspend(grace: 60)))
        _ = engine.handle(.connectionClosed(bob))
        _ = engine.handle(.command(.resume))

        // Grace expiry evicts the member; the next tick must go quiet.
        _ = engine.handle(.timerFired(.suspension(bob)))
        #expect(engine.handle(.timerFired(.resumeRetry(bob))) == [])

        // Same after leave.
        var engine2 = engineWithMember(alice, member: bob)
        _ = engine2.handle(.command(.suspend(grace: 60)))
        _ = engine2.handle(.connectionClosed(bob))
        _ = engine2.handle(.command(.resume))
        _ = engine2.handle(.command(.leave))
        #expect(engine2.handle(.timerFired(.resumeRetry(bob))) == [])
    }

    @Test("Resume on a surviving link ANNOUNCES — the peer has no reconnect to see")
    func resumeWithLiveConnection() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.command(.suspend(grace: 60)))

        // No close happened (short background). The peer is holding us under
        // grace and will never observe a reconnect, so say we are back.
        #expect(engine.handle(.command(.resume)) == [.sendSignal(.resume(), to: bob)])
        #expect(engine.members.contains(bob))

        // A genuine close after that is a real departure again.
        #expect(engine.handle(.connectionClosed(bob)) == [.emit(.peerLeft(bob))])
    }

    @Test("Grace expiry on a live link resumes the member, never departs it")
    func expiryWithLiveConnectionResumes() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.signal(.suspend(graceMs: 30_000), from: bob))

        // The link never dropped and the Resume never arrived (lost, or the
        // peer never called resume). Expiry must free the app from waiting,
        // not depart a member we are demonstrably connected to.
        #expect(engine.handle(.timerFired(.suspension(bob))) == [.emit(.peerResumed(bob))])
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

    @Test("Resume signal clears a grace hold on a link that never dropped")
    func inboundResumeClearsHold() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.signal(.suspend(graceMs: 30_000), from: bob))

        let effects = engine.handle(.signal(.resume(), from: bob))
        #expect(effects == [
            .cancelTimer(.suspension(bob)),
            .cancelTimer(.resumeRetry(bob)),
            .emit(.peerResumed(bob)),
        ])
        #expect(engine.members.contains(bob))

        // Not holding anything: a stray Resume is inert.
        #expect(engine.handle(.signal(.resume(), from: bob)) == [])
    }

    /// Device bug: the remote app was killed and relaunched while the camera
    /// still held it (grace, or an unnoticed death). Identity is persisted, so
    /// it re-invited as the SAME PeerID — and the engine dropped the invite as
    /// a duplicate member, so the camera never answered and the relaunched app
    /// could never reconnect.
    @Test("A relaunched member's fresh invite is a rejoin, not a duplicate")
    func reinviteFromMemberIsRejoin() {
        var engine = engineWithMember(alice, member: bob)
        _ = engine.handle(.signal(.suspend(graceMs: 60_000), from: bob))
        _ = engine.handle(.connectionClosed(bob))
        #expect(engine.members.contains(bob), "held under grace")

        // The relaunched process dials in and invites afresh.
        _ = engine.handle(.connectionEstablished(bob))
        let effects = engine.handle(.signal(.invite(inviter: bob, context: nil), from: bob))
        #expect(effects.contains(.emit(.peerLeft(bob))), "the old session really did end")
        #expect(effects.contains(.emit(.invitationReceived(from: bob, context: nil))),
                "…and the newcomer must be offered to the app")

        // Accepting completes the rejoin.
        let accepted = engine.handle(.command(.respondToInvitation(from: bob, accept: true)))
        #expect(accepted.contains(.emit(.peerJoined(bob))))
        #expect(engine.members.contains(bob))
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

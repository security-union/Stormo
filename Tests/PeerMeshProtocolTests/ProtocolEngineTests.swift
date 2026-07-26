import Foundation
import Testing

@testable import PeerMeshProtocol

/// Tier-1 tests (DD-6): the complete invitation protocol exercised with NO
/// transport — no QUIC, no sockets, no async, no clocks. Two engines wired
/// back-to-back in memory; timers fire when the test says so.
@Suite("ProtocolEngine — sans-I/O invitation protocol")
struct ProtocolEngineTests {

    static func makePeer(_ name: String, byte: UInt8) -> PeerID {
        PeerID(keyHash: Data(repeating: byte, count: 32), displayName: name)
    }

    let alice = Self.makePeer("Alice", byte: 0x0A)
    let bob = Self.makePeer("Bob", byte: 0x0B)

    @Test("Full invitation handshake completes with no transport")
    func fullHandshake() {
        var inviter = ProtocolEngine(localPeer: alice)
        var invitee = ProtocolEngine(localPeer: bob)
        let context = Data("room-42".utf8)

        // Alice invites Bob: engine asks the driver to connect.
        let step1 = inviter.handle(.command(.invite(bob, context: context, timeout: nil)))
        #expect(step1 == [.connect(to: bob)])

        // Driver reports the secured connection; engine sends the invite and
        // arms the timeout (FR-8, FR-9).
        let step2 = inviter.handle(.connectionEstablished(bob))
        #expect(step2 == [
            .sendSignal(.invite(inviter: alice, context: context), to: bob),
            .startTimer(.invitation(bob), duration: 30),
        ])

        // "Deliver" the invite to Bob's engine — this is the whole transport
        // in tier 1: copying a value from one effect list to the other engine.
        invitee.connectionsEstablish(with: alice)
        let step3 = invitee.handle(.signal(.invite(inviter: alice, context: context), from: alice))
        #expect(step3 == [.emit(.invitationReceived(from: alice, context: context))])

        // Bob accepts: roster comes back in one round-trip (FR-13).
        let step4 = invitee.handle(.command(.respondToInvitation(from: alice, accept: true)))
        #expect(step4.contains(.emit(.peerJoined(alice))))
        guard case .sendSignal(let response, to: alice) = step4.first,
            case .inviteResponse(let view) = response.body
        else {
            Issue.record("expected inviteResponse to Alice, got \(step4)")
            return
        }
        // Zero-copy reads: `view` points into the verified buffer.
        #expect(view.accepted)
        let roster = (0..<view.rosterCount).compactMap { view.roster(at: $0)?.peerID }
        #expect(roster.contains(bob))

        // Deliver the acceptance to Alice: timer cancelled, membership final.
        // (Feeding the *same* Signal Bob produced — as the wire would.)
        let step5 = inviter.handle(.signal(response, from: bob))
        #expect(step5.contains(.cancelTimer(.invitation(bob))))
        #expect(step5.contains(.emit(.peerJoined(bob))))
        #expect(inviter.members == [bob])
        #expect(invitee.members == [alice])
    }

    @Test("Invitation timeout (FR-9) — no waiting 30 seconds")
    func invitationTimeout() {
        var inviter = ProtocolEngine(localPeer: alice)
        _ = inviter.handle(.command(.invite(bob, context: nil, timeout: nil)))
        _ = inviter.handle(.connectionEstablished(bob))

        // Time is an input, not a clock: the test decides the timer fires.
        let effects = inviter.handle(.timerFired(.invitation(bob)))
        #expect(effects == [
            .emit(.invitationFailed(bob, reason: .timedOut)),
            .closeConnection(bob),
        ])
        #expect(inviter.members.isEmpty)
    }

    @Test("Declined invitation cleans up half-open state")
    func declinedInvitation() {
        var inviter = ProtocolEngine(localPeer: alice)
        _ = inviter.handle(.command(.invite(bob, context: nil, timeout: nil)))
        _ = inviter.handle(.connectionEstablished(bob))

        let effects = inviter.handle(
            .signal(.inviteResponse(accepted: false, roster: []), from: bob))
        #expect(effects == [
            .cancelTimer(.invitation(bob)),
            .emit(.invitationFailed(bob, reason: .declined)),
            .closeConnection(bob),
        ])
    }

    @Test("Messages fan out to members only; non-members are dropped")
    func messagingRespectsMembership() {
        var engine = ProtocolEngine(localPeer: alice)

        // Before membership: nothing to send, inbound dropped.
        #expect(engine.handle(.command(.send(Data([1]), to: .all, delivery: .reliable))).isEmpty)
        #expect(engine.handle(.dataReceived(Data([2]), from: bob, delivery: .reliable)).isEmpty)

        // Join Bob, then both directions flow.
        engine.admit(bob)
        #expect(engine.handle(.command(.send(Data([1]), to: .all, delivery: .datagram)))
            == [.sendData(Data([1]), to: bob, delivery: .datagram)])
        #expect(engine.handle(.dataReceived(Data([2]), from: bob, delivery: .reliable))
            == [.emit(.messageReceived(Data([2]), from: bob, delivery: .reliable))])
    }

    @Test("Peer departure never disturbs remaining members (FR-14)")
    func churnIsolation() {
        var engine = ProtocolEngine(localPeer: alice)
        let carol = Self.makePeer("Carol", byte: 0x0C)
        engine.admit(bob)
        engine.admit(carol)

        let effects = engine.handle(.connectionClosed(bob))
        #expect(effects == [.emit(.peerLeft(bob))])
        #expect(engine.members == [carol])
    }

    @Test("Dial tie-break is deterministic and asymmetric (FR-12)")
    func dialTieBreak() {
        #expect(ProtocolEngine.shouldDial(from: alice, to: bob))
        #expect(!ProtocolEngine.shouldDial(from: bob, to: alice))
    }
}

// MARK: - Test-only conveniences

extension ProtocolEngine {
    /// Drive a peer through connect+invite+accept in one call (test helper).
    fileprivate mutating func admit(_ peer: PeerID) {
        _ = handle(.connectionEstablished(peer))
        _ = handle(.signal(.invite(inviter: peer, context: nil), from: peer))
        _ = handle(.command(.respondToInvitation(from: peer, accept: true)))
    }

    fileprivate mutating func connectionsEstablish(with peer: PeerID) {
        _ = handle(.connectionEstablished(peer))
    }
}

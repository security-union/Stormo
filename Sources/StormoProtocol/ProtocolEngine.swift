import Foundation

/// The sans-I/O session protocol state machine (DD-6).
///
/// `ProtocolEngine` is pure and deterministic: no sockets, no clocks, no async.
/// The runtime shell (or a test) feeds it ``Input`` values and executes the
/// returned ``Effect`` values. Time never originates inside the engine —
/// timeouts are requested via ``Effect/startTimer(_:duration:)`` and delivered
/// back via ``Input/timerFired(_:)``.
///
/// Two engines wired back-to-back in memory exercise the complete protocol
/// with no transport at all (test tier 1, DD-6).
public struct ProtocolEngine: Sendable {

    // MARK: Inputs

    public enum Input: Sendable, Equatable {
        /// An application command.
        case command(Command)
        /// The driver established a secured connection to a peer (encrypted,
        /// not yet authorized — FR-8).
        case connectionEstablished(PeerID)
        /// The driver lost or closed the connection to a peer.
        case connectionClosed(PeerID)
        /// A verified control-plane signal arrived from a peer (DD-5).
        case signal(Signal, from: PeerID)
        /// Application data arrived from a peer.
        case dataReceived(Data, from: PeerID, delivery: Delivery)
        /// A timer previously requested via `.startTimer` expired.
        case timerFired(TimerKey)
    }

    public enum Command: Sendable, Equatable {
        /// `timeout` nil → `Configuration.invitationTimeout`.
        case invite(PeerID, context: Data?, timeout: TimeInterval?)
        case respondToInvitation(from: PeerID, accept: Bool)
        case send(Data, to: Recipients, delivery: Delivery)
        case leave
        /// Local app about to background (C-5): announce, and treat members'
        /// connection losses as suspensions for `grace`, not departures.
        case suspend(grace: TimeInterval)
        /// Local app foregrounded: re-dial suspended members with dead links.
        case resume
    }

    // MARK: Effects

    public enum Effect: Sendable, Equatable {
        /// Open a secured connection to a peer (driver work).
        case connect(to: PeerID)
        /// Encode (SignalCodec) and send a control-plane signal.
        case sendSignal(Signal, to: PeerID)
        /// Send application data.
        case sendData(Data, to: PeerID, delivery: Delivery)
        case startTimer(TimerKey, duration: TimeInterval)
        case cancelTimer(TimerKey)
        case closeConnection(PeerID)
        /// Surface an event to the application.
        case emit(Event)
    }

    public enum TimerKey: Hashable, Sendable {
        case invitation(PeerID)
        /// Grace window (C-5): expiry turns a suspended member into a departure.
        case suspension(PeerID)
        /// Fixed-rate resume re-dial tick; stops on reconnect or grace expiry.
        case resumeRetry(PeerID)
    }

    public enum Event: Sendable, Equatable {
        case invitationReceived(from: PeerID, context: Data?)
        case invitationFailed(PeerID, reason: InvitationFailure)
        case peerJoined(PeerID)
        case peerLeft(PeerID)
        /// Member announced suspension (C-5): still a member; no `peerLeft`
        /// until the grace window expires.
        case peerSuspended(PeerID)
        /// Suspended member reconnected within grace; membership never lapsed.
        case peerResumed(PeerID)
        case messageReceived(Data, from: PeerID, delivery: Delivery)
        /// A member announced a resource transfer on the control stream (FR-17).
        /// The runtime matches the paired `transferChunk` stream by `id` and
        /// performs the disk-to-disk transfer — the engine never touches files.
        case transferOffered(id: UUID, name: String, totalBytes: UInt64, from: PeerID)
        /// A member announced an application byte stream (FR-18). The runtime
        /// matches the paired `appStream` by `label` and surfaces it.
        case streamOpened(label: String, from: PeerID)
    }

    public enum InvitationFailure: Sendable, Equatable {
        case declined
        case timedOut
        case connectionLost
    }

    // MARK: Configuration and state

    public struct Configuration: Sendable {
        public var invitationTimeout: TimeInterval
        /// Ceiling on requested suspension grace — a remote must not park
        /// itself as a zombie member forever.
        public var maxSuspensionGrace: TimeInterval
        /// Fixed interval between resume re-dials (no backoff by design —
        /// the loop ends at reconnect or grace expiry).
        public var resumeRetryInterval: TimeInterval

        public init(invitationTimeout: TimeInterval = 30,
                    maxSuspensionGrace: TimeInterval = 120,
                    resumeRetryInterval: TimeInterval = 1) {
            self.invitationTimeout = invitationTimeout
            self.maxSuspensionGrace = maxSuspensionGrace
            self.resumeRetryInterval = resumeRetryInterval
        }
    }

    public let localPeer: PeerID
    public let configuration: Configuration

    /// Admitted session members (FR-10). Excludes the local peer.
    public private(set) var members: Set<PeerID> = []

    private var connections: Set<PeerID> = []
    // Peer -> invite context, for invitations WE initiated. Entry lifecycle: added
    // on `.invite` (with the invitation timer), sent on `connectionEstablished`,
    // and removed on exactly one terminal outcome — accepted/declined response,
    // timeout, connection loss, or `.leave`. Its presence is the "invite in
    // flight" flag the whole invitation state machine keys off.
    private var pendingOutgoing: [PeerID: Data?] = [:]
    // Zero-copy (DD-5/DD-6): retain the verified Signal (≤64 KB buffer) rather
    // than copying fields out of it.
    private var pendingIncoming: [PeerID: Signal] = [:]
    // Members under a suspension grace window (C-5); cleared by reconnect or
    // by the suspension timer turning them into departures.
    private var suspended: Set<PeerID> = []
    // The clamped grace announced by OUR `.suspend`, consumed by `.resume` to
    // arm grace timers at wake — the frozen side never runs timers.
    private var localSuspensionGrace: TimeInterval?

    public init(localPeer: PeerID, configuration: Configuration = Configuration()) {
        self.localPeer = localPeer
        self.configuration = configuration
    }

    /// Deterministic dial-direction tie-break (FR-12): of two peers that
    /// discover each other simultaneously, only the one with the
    /// lexicographically lower key hash dials.
    public static func shouldDial(from local: PeerID, to remote: PeerID) -> Bool {
        local.keyHash.lexicographicallyPrecedes(remote.keyHash)
    }

    // MARK: The transition function

    public mutating func handle(_ input: Input) -> [Effect] {
        switch input {
        case .command(let command):
            return handle(command)

        case .connectionEstablished(let peer):
            connections.insert(peer)
            // A suspended member reconnecting within grace resumes silently.
            if suspended.remove(peer) != nil {
                return [
                    .cancelTimer(.suspension(peer)),
                    .cancelTimer(.resumeRetry(peer)),
                    .emit(.peerResumed(peer)),
                ]
            }
            // If we initiated for a pending invitation, send it now (FR-8: the
            // invite travels only over the secured connection). The invitation
            // timer was armed when the invite command was issued — it covers
            // the dial too, so a hanging dial fails the invite instead of
            // waiting forever.
            if let context = pendingOutgoing[peer] {
                return [.sendSignal(.invite(inviter: localPeer, context: context), to: peer)]
            }
            return []

        case .connectionClosed(let peer):
            connections.remove(peer)
            var effects: [Effect] = []
            if pendingOutgoing.removeValue(forKey: peer) != nil {
                effects.append(.cancelTimer(.invitation(peer)))
                effects.append(.emit(.invitationFailed(peer, reason: .connectionLost)))
            }
            pendingIncoming.removeValue(forKey: peer)
            if suspended.contains(peer) {
                // Expected loss: membership survives until grace expiry.
            } else if members.remove(peer) != nil {
                // FR-14: one peer's departure never disturbs the rest.
                effects.append(.emit(.peerLeft(peer)))
            }
            return effects

        case .signal(let signal, let peer):
            return handle(signal, from: peer)

        case .dataReceived(let data, let peer, let delivery):
            guard members.contains(peer) else { return [] }  // not admitted: drop
            return [.emit(.messageReceived(data, from: peer, delivery: delivery))]

        case .timerFired(.invitation(let peer)):
            guard pendingOutgoing.removeValue(forKey: peer) != nil else { return [] }
            return [
                .emit(.invitationFailed(peer, reason: .timedOut)),
                .closeConnection(peer),  // FR-9: half-open state cleanup
            ]

        case .timerFired(.suspension(let peer)):
            // Grace expired → departure. Never while the connection is alive:
            // a short background can end without the link dropping, and the
            // observer side has no resume trigger, only this timer.
            guard suspended.remove(peer) != nil else { return [] }
            // Link alive: the peer never actually went away (or its Resume was
            // lost). Report it back, never leave the app waiting.
            if connections.contains(peer) { return [.emit(.peerResumed(peer))] }
            guard members.remove(peer) != nil else { return [] }
            return [
                .cancelTimer(.resumeRetry(peer)),
                .emit(.peerLeft(peer)),
            ]

        case .timerFired(.resumeRetry(let peer)):
            // Fixed-rate re-dial while resuming; dies with the suspension.
            guard suspended.contains(peer), members.contains(peer),
                !connections.contains(peer)
            else { return [] }
            return [
                .connect(to: peer),
                .startTimer(.resumeRetry(peer), duration: configuration.resumeRetryInterval),
            ]
        }
    }

    private mutating func handle(_ command: Command) -> [Effect] {
        switch command {
        case .invite(let peer, let context, let timeout):
            guard !members.contains(peer), pendingOutgoing[peer] == nil else { return [] }
            pendingOutgoing[peer] = context
            let duration = timeout ?? configuration.invitationTimeout
            // The timer arms HERE — covering the dial as well as the
            // handshake — so a transport that hangs (radio limbo, filtered
            // UDP) surfaces as a timed-out invitation, never an infinite wait.
            if connections.contains(peer) {
                return [
                    .sendSignal(.invite(inviter: localPeer, context: context), to: peer),
                    .startTimer(.invitation(peer), duration: duration),
                ]
            }
            return [
                .connect(to: peer),
                .startTimer(.invitation(peer), duration: duration),
            ]

        case .respondToInvitation(let peer, let accept):
            guard pendingIncoming.removeValue(forKey: peer) != nil else { return [] }
            guard accept else {
                return [
                    .sendSignal(.inviteResponse(accepted: false, roster: []), to: peer),
                    .closeConnection(peer),
                ]
            }
            members.insert(peer)
            let roster = [localPeer] + members.sorted { $0.keyHash.lexicographicallyPrecedes($1.keyHash) }
            var effects: [Effect] = [
                .sendSignal(.inviteResponse(accepted: true, roster: roster), to: peer),
                .emit(.peerJoined(peer)),
            ]
            // Gossip the new member to the rest of the mesh (FR-13). Epoch is a
            // monotonic member count for now — sufficient for single-inviter
            // growth; concurrent-admission epoch reconciliation is future work.
            for member in members where member != peer {
                effects.append(.sendSignal(
                    .rosterUpdate(members: roster, epoch: UInt64(roster.count)), to: member))
            }
            return effects

        case .send(let data, let recipients, let delivery):
            let targets: [PeerID]
            switch recipients {
            case .all: targets = Array(members)
            case .peer(let peer): targets = members.contains(peer) ? [peer] : []
            case .peers(let peers): targets = peers.filter(members.contains)
            }
            return targets
                .sorted { $0.keyHash.lexicographicallyPrecedes($1.keyHash) }
                .map { .sendData(data, to: $0, delivery: delivery) }

        case .leave:
            let open = connections
            members.removeAll()
            connections.removeAll()
            pendingOutgoing.removeAll()
            pendingIncoming.removeAll()
            suspended.removeAll()  // stale suspension timers no-op on fire
            localSuspensionGrace = nil
            return open
                .sorted { $0.keyHash.lexicographicallyPrecedes($1.keyHash) }
                .map { .closeConnection($0) }

        case .suspend(let grace):
            // Mark ALL members suspended and say goodbye — nothing else. The
            // process is about to freeze, so NO timers arm here: the marks
            // keep queued connection-closed inputs from evicting members, and
            // `.resume` (the next time our code provably runs) starts the
            // grace clock.
            let duration = min(grace, configuration.maxSuspensionGrace)
            localSuspensionGrace = duration
            let signal = Signal.suspend(graceMs: UInt64(duration * 1000))
            var effects: [Effect] = []
            for member in members.sorted(by: { $0.keyHash.lexicographicallyPrecedes($1.keyHash) }) {
                suspended.insert(member)
                if connections.contains(member) {
                    effects.append(.sendSignal(signal, to: member))
                }
            }
            return effects

        case .resume:
            // Wake-up: re-dial suspended members with dead links at a fixed
            // rate, bounded by a grace timer that starts NOW (grace runs from
            // wake, not from the announce); live links just shed their marks.
            let grace = localSuspensionGrace ?? configuration.maxSuspensionGrace
            localSuspensionGrace = nil
            var effects: [Effect] = []
            let marked = members
                .filter(suspended.contains)
                .sorted { $0.keyHash.lexicographicallyPrecedes($1.keyHash) }
            for member in marked {
                if connections.contains(member) {
                    // The link survived the freeze, so there is no reconnect
                    // for the peer to observe — say so explicitly or it waits
                    // forever.
                    suspended.remove(member)
                    effects.append(.sendSignal(.resume(), to: member))
                } else {
                    effects.append(.connect(to: member))
                    effects.append(.startTimer(
                        .resumeRetry(member), duration: configuration.resumeRetryInterval))
                    effects.append(.startTimer(.suspension(member), duration: grace))
                }
            }
            return effects
        }
    }

    private mutating func handle(_ signal: Signal, from peer: PeerID) -> [Effect] {
        // Reads below go through generated views into the verified buffer —
        // in place, zero-copy (DD-5/DD-6). Copies happen only at the two
        // permitted boundaries: app handoff (invite context) and identity
        // fields persisted into engine state (`peerID`).
        switch signal.body {
        case .invite(let invite):
            guard !members.contains(peer) else { return [] }
            guard let inviter = invite.inviter?.peerID else { return [] }
            pendingIncoming[peer] = signal  // retain the buffer, not a copy
            let context = invite.hasContext ? Data(invite.context) : nil  // app-ownership copy
            return [.emit(.invitationReceived(from: inviter, context: context))]

        case .inviteResponse(let response):
            guard pendingOutgoing.removeValue(forKey: peer) != nil else { return [] }
            var effects: [Effect] = [.cancelTimer(.invitation(peer))]
            guard response.accepted else {
                effects.append(.emit(.invitationFailed(peer, reason: .declined)))
                effects.append(.closeConnection(peer))
                return effects
            }
            members.insert(peer)
            effects.append(.emit(.peerJoined(peer)))
            // Dial roster members we don't know yet, tie-break deciding
            // direction (FR-12).
            // TODO(mesh-join): these dials should carry a session-join handshake,
            // not a fresh invitation (see also the .connect executor note).
            for index in 0..<response.rosterCount {
                guard let member = response.roster(at: index)?.peerID else { continue }
                if member != localPeer, !members.contains(member),
                    Self.shouldDial(from: localPeer, to: member)
                {
                    effects.append(.connect(to: member))
                }
            }
            return effects

        case .rosterUpdate(let update):
            guard members.contains(peer) else { return [] }
            var effects: [Effect] = []
            for index in 0..<update.membersCount {
                guard let member = update.members(at: index)?.peerID else { continue }
                if member != localPeer, !members.contains(member),
                    Self.shouldDial(from: localPeer, to: member)
                {
                    effects.append(.connect(to: member))
                }
            }
            return effects

        case .codeConfirm:
            // TODO(pairing-code): `.pairingCode` transcript verification (DD-2, S-4).
            return []

        case .transferOffer(let offer):
            // Membership-gate (DD-6): announcements from non-members are ignored.
            guard members.contains(peer) else { return [] }
            guard let id = offer.transferID, let name = offer.name else { return [] }
            return [.emit(.transferOffered(
                id: id, name: name, totalBytes: offer.totalBytes, from: peer))]

        case .streamOpen(let open):
            guard members.contains(peer) else { return [] }
            guard let label = open.label else { return [] }
            return [.emit(.streamOpened(label: label, from: peer))]

        case .suspend(let suspend):
            // Membership-gate (DD-6); clamp the requested grace.
            guard members.contains(peer) else { return [] }
            let duration = min(
                TimeInterval(suspend.graceMs) / 1000, configuration.maxSuspensionGrace)
            suspended.insert(peer)
            return [
                .startTimer(.suspension(peer), duration: duration),
                .emit(.peerSuspended(peer)),
            ]

        case .resume:
            // Only meaningful for a member we are holding under grace.
            guard members.contains(peer), suspended.remove(peer) != nil else { return [] }
            return [
                .cancelTimer(.suspension(peer)),
                .cancelTimer(.resumeRetry(peer)),
                .emit(.peerResumed(peer)),
            ]

        case .unrecognized:
            // Forward compatibility (QA-11, DD-5 rule 1): ignore-and-log.
            return []
        }
    }
}

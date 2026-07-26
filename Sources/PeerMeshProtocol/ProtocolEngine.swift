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
        case keepAlive(PeerID)
    }

    public enum Event: Sendable, Equatable {
        case invitationReceived(from: PeerID, context: Data?)
        case invitationFailed(PeerID, reason: InvitationFailure)
        case peerJoined(PeerID)
        case peerLeft(PeerID)
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

        public init(invitationTimeout: TimeInterval = 30) {
            self.invitationTimeout = invitationTimeout
        }
    }

    public let localPeer: PeerID
    public let configuration: Configuration

    /// Admitted session members (FR-10). Excludes the local peer.
    public private(set) var members: Set<PeerID> = []

    private var connections: Set<PeerID> = []
    private var pendingOutgoing: [PeerID: Data?] = [:]   // peer -> invite context
    private var pendingTimeouts: [PeerID: TimeInterval] = [:]
    // Zero-copy (DD-5/DD-6): retain the verified Signal (≤64 KB buffer) rather
    // than copying fields out of it.
    private var pendingIncoming: [PeerID: Signal] = [:]

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
            // If we initiated for a pending invitation, send it now (FR-8:
            // the invite travels only over the secured connection).
            if let context = pendingOutgoing[peer] {
                return [
                    .sendSignal(.invite(inviter: localPeer, context: context), to: peer),
                    .startTimer(
                        .invitation(peer),
                        duration: pendingTimeouts[peer] ?? configuration.invitationTimeout),
                ]
            }
            return []

        case .connectionClosed(let peer):
            connections.remove(peer)
            var effects: [Effect] = []
            if pendingOutgoing.removeValue(forKey: peer) != nil {
                pendingTimeouts.removeValue(forKey: peer)
                effects.append(.cancelTimer(.invitation(peer)))
                effects.append(.emit(.invitationFailed(peer, reason: .connectionLost)))
            }
            pendingIncoming.removeValue(forKey: peer)
            if members.remove(peer) != nil {
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
            pendingTimeouts.removeValue(forKey: peer)
            return [
                .emit(.invitationFailed(peer, reason: .timedOut)),
                .closeConnection(peer),  // FR-9: half-open state cleanup
            ]

        case .timerFired(.keepAlive):
            // TODO(Phase 1): liveness probing (FR-14 unreachable detection).
            return []
        }
    }

    private mutating func handle(_ command: Command) -> [Effect] {
        switch command {
        case .invite(let peer, let context, let timeout):
            guard !members.contains(peer), pendingOutgoing[peer] == nil else { return [] }
            pendingOutgoing[peer] = context
            pendingTimeouts[peer] = timeout ?? configuration.invitationTimeout
            if connections.contains(peer) {
                return [
                    .sendSignal(.invite(inviter: localPeer, context: context), to: peer),
                    .startTimer(.invitation(peer), duration: pendingTimeouts[peer] ?? configuration.invitationTimeout),
                ]
            }
            return [.connect(to: peer)]

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
            // Gossip the new member to the rest of the mesh (FR-13).
            // TODO(Phase 1): epoch management beyond a single counter.
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
            pendingTimeouts.removeAll()
            pendingIncoming.removeAll()
            return open
                .sorted { $0.keyHash.lexicographicallyPrecedes($1.keyHash) }
                .map { .closeConnection($0) }
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
            pendingTimeouts.removeValue(forKey: peer)
            var effects: [Effect] = [.cancelTimer(.invitation(peer))]
            guard response.accepted else {
                effects.append(.emit(.invitationFailed(peer, reason: .declined)))
                effects.append(.closeConnection(peer))
                return effects
            }
            members.insert(peer)
            effects.append(.emit(.peerJoined(peer)))
            // Dial roster members we don't know yet, tie-break deciding
            // direction (FR-12). TODO(Phase 1): those dials carry a session
            // join handshake, not a fresh invitation.
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

        case .keepAlive:
            return []

        case .codeConfirm:
            // TODO(Phase 2): `.pairingCode` transcript verification (DD-2, S-4).
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

        case .unrecognized:
            // Forward compatibility (QA-11, DD-5 rule 1): ignore-and-log.
            return []
        }
    }
}

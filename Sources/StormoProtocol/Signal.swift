import FlatBuffers
import Foundation

// Ergonomic aliases for the flatc-generated types (namespace Stormo.Wire).
public typealias WireSignal = Stormo_Wire_Signal
public typealias WireSignalBody = Stormo_Wire_SignalBody
public typealias WirePeerInfo = Stormo_Wire_PeerInfo
public typealias WireInvite = Stormo_Wire_Invite
public typealias WireInviteResponse = Stormo_Wire_InviteResponse
public typealias WireCodeConfirm = Stormo_Wire_CodeConfirm
public typealias WireRosterUpdate = Stormo_Wire_RosterUpdate
public typealias WireKeepAlive = Stormo_Wire_KeepAlive
public typealias WireTransferOffer = Stormo_Wire_TransferOffer
public typealias WireStreamOpen = Stormo_Wire_StreamOpen
public typealias WireTransferId = Stormo_Wire_TransferId

/// A control-plane message: a verified FlatBuffers buffer read **in place**
/// (DD-5, DD-6). Zero-copy discipline:
///
/// - Inbound bytes are verified once (``SignalCodec/decode(_:)``) and never
///   unpacked; all field access goes through the generated views into the
///   retained buffer. The engine stores `Signal` values in its state (buffers
///   are capped at 64 KB) rather than copying fields out.
/// - Copies are permitted at exactly two boundaries: handing a payload to the
///   application (which must own its data), and persisting identity fields
///   (key hash / display name) into long-lived engine state.
///
/// Thread safety: the wrapped buffer is immutable after construction, which is
/// what justifies `@unchecked Sendable`. Never expose a mutable view.
public struct Signal: @unchecked Sendable, Equatable {
    /// Canonical encoded form — written to the wire as-is, also the basis of
    /// equality (the builder is deterministic for identical inputs).
    public let encoded: Data

    /// Root view into the retained buffer. All reads are zero-copy.
    public let root: WireSignal

    /// Trusted-local fast path: wraps bytes produced by our own builder.
    init(trustedEncoded encoded: Data) {
        self.encoded = encoded
        var buffer = ByteBuffer(data: encoded)
        self.root = getRoot(byteBuffer: &buffer) as WireSignal
    }

    /// Verified path — only ``SignalCodec`` calls this, after `getCheckedRoot`.
    init(verified encoded: Data, root: WireSignal) {
        self.encoded = encoded
        self.root = root
    }

    public static func == (lhs: Signal, rhs: Signal) -> Bool {
        lhs.encoded == rhs.encoded
    }

    // MARK: Zero-copy body access

    /// The message body as an enum of *views* — each case wraps a generated
    /// accessor struct pointing into the buffer, not extracted values.
    public enum Body {
        case invite(WireInvite)
        case inviteResponse(WireInviteResponse)
        case codeConfirm(WireCodeConfirm)
        case rosterUpdate(WireRosterUpdate)
        case keepAlive(WireKeepAlive)
        case transferOffer(WireTransferOffer)
        case streamOpen(WireStreamOpen)
        /// Absent or unrecognized union variant (forward compatibility, QA-11):
        /// ignored-and-logged, never fatal (DD-5 rule 1).
        case unrecognized
    }

    public var body: Body {
        switch root.bodyType {
        case .invite:
            return root.body(type: WireInvite.self).map(Body.invite) ?? .unrecognized
        case .inviteresponse:
            return root.body(type: WireInviteResponse.self).map(Body.inviteResponse) ?? .unrecognized
        case .codeconfirm:
            return root.body(type: WireCodeConfirm.self).map(Body.codeConfirm) ?? .unrecognized
        case .rosterupdate:
            return root.body(type: WireRosterUpdate.self).map(Body.rosterUpdate) ?? .unrecognized
        case .keepalive:
            return root.body(type: WireKeepAlive.self).map(Body.keepAlive) ?? .unrecognized
        case .transferoffer:
            return root.body(type: WireTransferOffer.self).map(Body.transferOffer) ?? .unrecognized
        case .streamopen:
            return root.body(type: WireStreamOpen.self).map(Body.streamOpen) ?? .unrecognized
        case .none_:
            return .unrecognized
        }
    }

    // MARK: Builders (serialize once; the buffer built here IS the wire bytes)

    public static func invite(inviter: PeerID, context: Data?) -> Signal {
        build(.invite) { fbb in
            let inviterOffset = createPeerInfo(inviter, in: &fbb)
            let contextOffset = context.map { fbb.createVector(bytes: $0) } ?? Offset()
            return WireInvite.createInvite(
                &fbb, inviterOffset: inviterOffset, contextVectorOffset: contextOffset)
        }
    }

    public static func inviteResponse(accepted: Bool, roster: [PeerID]) -> Signal {
        build(.inviteresponse) { fbb in
            let rosterOffset = createRoster(roster, in: &fbb)
            return WireInviteResponse.createInviteResponse(
                &fbb, accepted: accepted, rosterVectorOffset: rosterOffset)
        }
    }

    public static func codeConfirm(transcriptMAC: Data) -> Signal {
        build(.codeconfirm) { fbb in
            let mac = fbb.createVector(bytes: transcriptMAC)
            return WireCodeConfirm.createCodeConfirm(&fbb, transcriptMacVectorOffset: mac)
        }
    }

    public static func rosterUpdate(members: [PeerID], epoch: UInt64) -> Signal {
        build(.rosterupdate) { fbb in
            let membersOffset = createRoster(members, in: &fbb)
            return WireRosterUpdate.createRosterUpdate(
                &fbb, membersVectorOffset: membersOffset, epoch: epoch)
        }
    }

    public static func keepAlive(timestampMS: UInt64) -> Signal {
        build(.keepalive) { fbb in
            WireKeepAlive.createKeepAlive(&fbb, timestampMs: timestampMS)
        }
    }

    public static func transferOffer(id: UUID, name: String, totalBytes: UInt64) -> Signal {
        build(.transferoffer) { fbb in
            let nameOffset = fbb.create(string: name)
            return WireTransferOffer.createTransferOffer(
                &fbb, transferId: WireTransferId(id), nameOffset: nameOffset,
                totalBytes: totalBytes)
        }
    }

    public static func streamOpen(label: String) -> Signal {
        build(.streamopen) { fbb in
            let labelOffset = fbb.create(string: label)
            return WireStreamOpen.createStreamOpen(&fbb, labelOffset: labelOffset)
        }
    }

    private static func build(
        _ bodyType: WireSignalBody,
        _ makeBody: (inout FlatBufferBuilder) -> Offset
    ) -> Signal {
        var fbb = FlatBufferBuilder(initialSize: 256)
        let bodyOffset = makeBody(&fbb)
        let rootOffset = WireSignal.createSignal(
            &fbb,
            bodyType: bodyType,
            bodyOffset: bodyOffset)
        fbb.finish(offset: rootOffset)
        return Signal(trustedEncoded: Data(fbb.sizedByteArray))
    }

    private static func createPeerInfo(_ peer: PeerID, in fbb: inout FlatBufferBuilder) -> Offset {
        let keyHash = fbb.createVector(bytes: peer.keyHash)
        let name = fbb.create(string: peer.displayName)
        return WirePeerInfo.createPeerInfo(
            &fbb, keyHashVectorOffset: keyHash, displayNameOffset: name)
    }

    private static func createRoster(_ peers: [PeerID], in fbb: inout FlatBufferBuilder) -> Offset {
        let offsets = peers.map { createPeerInfo($0, in: &fbb) }
        return fbb.createVector(ofOffsets: offsets)
    }
}

extension WirePeerInfo {
    /// Materializes the identity into engine state — one of the two permitted
    /// copy boundaries (identity fields must outlive the signal buffer).
    public var peerID: PeerID? {
        guard keyHashCount == 34, let name = displayName else { return nil }
        return PeerID(keyHash: Data(keyHash), displayName: name)
    }
}

extension WireTransferOffer {
    /// The offer's `TransferId` as a `UUID` (FR-17) — the runtime uses it to
    /// pair the offer with its `transferChunk` stream.
    public var transferID: UUID? {
        transferId?.uuidValue
    }
}

extension WireTransferId {
    /// The two 8-byte halves of `uuid_t`, in memory order.
    public init(_ uuid: UUID) {
        let (hi, lo) = withUnsafeBytes(of: uuid.uuid) {
            ($0.loadUnaligned(as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        self.init(hi: hi, lo: lo)
    }

    public var uuidValue: UUID {
        var bytes = (hi, lo)
        return withUnsafeBytes(of: &bytes) { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}

// Data-plane stream header (DD-7). Every non-control QUIC stream starts with
// a size-prefixed StreamHeader; FIN delimits the payload.
public typealias WireStreamHeader = Stormo_Wire_StreamHeader
public typealias WireStreamKind = Stormo_Wire_StreamKind

/// Delivery semantics for data (FR-15, FR-16, DD-7).
public enum Delivery: Sendable, Equatable {
    /// The `.datagram` payload cap (FR-16, sender-visible). QUIC DATAGRAM
    /// frames cannot fragment, so a datagram is bounded by path MTU; 1200 is
    /// the conservative floor across IPv4/IPv6 paths. Enforced at `send`.
    public static let maxDatagramPayload = 1_200

    /// Guaranteed delivery on a dedicated unidirectional QUIC stream per
    /// message (MoQ pattern, DD-7). Ordering across messages is NOT
    /// guaranteed — messages never head-of-line-block each other.
    case reliable
    /// Guaranteed delivery AND FIFO order per sender–receiver pair
    /// (`StreamHeader.sequence` + receiver reorder buffer). MPC behavioral
    /// parity; `MPCCompat` maps MCSession's `.reliable` here.
    case reliableOrdered
    /// Droppable, unordered, low-latency — true datagram semantics, so the
    /// payload must fit one datagram: sends over ``maxDatagramPayload`` throw
    /// ``StormoError/datagramTooLarge(bytes:limit:)``. For larger droppable
    /// data, send `.reliable` and supersede at the application layer.
    case datagram
}

/// Recipient selector for send operations.
public enum Recipients: Sendable, Equatable {
    case all
    case peer(PeerID)
    case peers([PeerID])
}

public enum StormoError: Error, Sendable, Equatable {
    /// A surface that is deliberately not wired up yet on this platform or build.
    /// The associated string names it; each call site carries a comment pointing
    /// at the relevant TODO ledger entry (see CLAUDE.md). Current uses: the
    /// `MPCCompat` `NSStream` bridge (ledger: compat-nsstream-bridge) and the
    /// no-Network.framework `QUICTransport` fallback.
    case unimplemented(String)
    /// Local Network permission denied or restricted (FR-4).
    case localNetworkPermissionDenied
    case invitationTimedOut
    case invitationDeclined
    /// An invite to a peer is already in flight; the framework enforces one
    /// concurrent invitation per peer (FR-6).
    case invitationAlreadyPending(PeerID)
    case peerUnreachable(PeerID)
    /// A `.datagram` send exceeded ``Delivery/maxDatagramPayload`` (FR-16):
    /// datagrams cannot fragment. Use `.reliable` for payloads this size.
    case datagramTooLarge(bytes: Int, limit: Int)
    /// Inbound signaling failed FlatBuffers verification (DD-5 rule 3).
    case malformedSignal
    /// A resource transfer ended before all announced bytes arrived — sender
    /// cancellation or connection loss (FR-17). The partial temp file is discarded.
    case resourceTransferIncomplete
    /// A per-peer ordered-message reorder buffer exceeded its cap; the peer is
    /// reordering beyond what a reliable transport can justify (DD-7).
    case reorderBufferOverflow
}

// NSError bridging renumbers payload cases (failure mode 11) — LocalizedError
// keeps the diagnostic in localizedDescription.
extension StormoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unimplemented(let surface):
            return "Stormo: \(surface) is not implemented"
        case .localNetworkPermissionDenied:
            return "Stormo: Local Network permission denied"
        case .invitationTimedOut:
            return "Stormo: invitation timed out"
        case .invitationDeclined:
            return "Stormo: invitation declined"
        case .invitationAlreadyPending(let peer):
            return "Stormo: an invitation to \(peer.displayName) is already pending"
        case .peerUnreachable(let peer):
            return "Stormo: peer \(peer.displayName) is unreachable"
        case .datagramTooLarge(let bytes, let limit):
            return "Stormo: .datagram payload is \(bytes) bytes; datagrams cannot exceed \(limit) bytes (they never fragment) — use .reliable for payloads this size"
        case .malformedSignal:
            return "Stormo: inbound signal failed verification"
        case .resourceTransferIncomplete:
            return "Stormo: resource transfer ended before all bytes arrived"
        case .reorderBufferOverflow:
            return "Stormo: ordered-message reorder buffer overflowed"
        }
    }
}

import FlatBuffers
import Foundation

// Ergonomic aliases for the flatc-generated types (namespace PeerMesh.Wire).
public typealias WireSignal = PeerMesh_Wire_Signal
public typealias WireSignalBody = PeerMesh_Wire_SignalBody
public typealias WirePeerInfo = PeerMesh_Wire_PeerInfo
public typealias WireInvite = PeerMesh_Wire_Invite
public typealias WireInviteResponse = PeerMesh_Wire_InviteResponse
public typealias WireCodeConfirm = PeerMesh_Wire_CodeConfirm
public typealias WireRosterUpdate = PeerMesh_Wire_RosterUpdate
public typealias WireKeepAlive = PeerMesh_Wire_KeepAlive
public typealias WireTransferOffer = PeerMesh_Wire_TransferOffer
public typealias WireStreamOpen = PeerMesh_Wire_StreamOpen

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
            let idBytes = withUnsafeBytes(of: id.uuid) { Data($0) }
            let idOffset = fbb.createVector(bytes: idBytes)
            let nameOffset = fbb.create(string: name)
            return WireTransferOffer.createTransferOffer(
                &fbb, transferIdVectorOffset: idOffset, nameOffset: nameOffset,
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
            protocolVersion: SignalCodec.protocolVersion,
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
        guard keyHashCount == 32, let name = displayName else { return nil }
        return PeerID(keyHash: Data(keyHash), displayName: name)
    }
}

// Data-plane stream header (DD-7). Every non-control QUIC stream starts with
// a size-prefixed StreamHeader; FIN delimits the payload.
public typealias WireStreamHeader = PeerMesh_Wire_StreamHeader
public typealias WireStreamKind = PeerMesh_Wire_StreamKind

/// Delivery semantics for data (FR-15, FR-16, DD-7).
public enum Delivery: Sendable, Equatable {
    /// Guaranteed delivery on a dedicated unidirectional QUIC stream per
    /// message (MoQ pattern, DD-7). Ordering across messages is NOT
    /// guaranteed — messages never head-of-line-block each other.
    case reliable
    /// Guaranteed delivery AND FIFO order per sender–receiver pair
    /// (`StreamHeader.sequence` + receiver reorder buffer). MPC behavioral
    /// parity; `MPCCompat` maps MCSession's `.reliable` here.
    case reliableOrdered
    /// Low-latency QUIC datagram (RFC 9221); droppable, unordered.
    case datagram
}

/// Recipient selector for send operations.
public enum Recipients: Sendable, Equatable {
    case all
    case peer(PeerID)
    case peers([PeerID])
}

public enum PeerMeshError: Error, Sendable, Equatable {
    /// Scaffolding placeholder: the API surface exists, the engine is Phase 1 work.
    case unimplemented(String)
    /// Local Network permission denied or restricted (FR-4).
    case localNetworkPermissionDenied
    case invitationTimedOut
    case invitationDeclined
    case peerUnreachable(PeerID)
    /// Inbound signaling failed FlatBuffers verification (DD-5 rule 3).
    case malformedSignal
}

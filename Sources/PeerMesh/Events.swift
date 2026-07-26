import Foundation

/// A peer discovered while browsing (FR-2), before any session relationship.
///
/// Equatable/Hashable are explicit (not compiler-derived): they compose
/// `PeerID`'s key-hash-only semantics with the metadata, and explicit
/// implementations avoid cross-module derived-conformance symbols — whose
/// removal Swift's incremental builds fail to track (stale-`.o` link errors
/// in consuming apps).
public struct DiscoveredPeer: Sendable, Hashable {
    public let id: PeerID
    /// The peer's advertised metadata (Bonjour TXT record contents, FR-1).
    public let metadata: [String: String]

    public init(id: PeerID, metadata: [String: String]) {
        self.id = id
        self.metadata = metadata
    }

    public static func == (lhs: DiscoveredPeer, rhs: DiscoveredPeer) -> Bool {
        lhs.id == rhs.id && lhs.metadata == rhs.metadata
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// A member of an active session. Identity semantics follow `PeerID`
/// (key-hash-only); explicit conformances for the same incremental-build
/// reason as `DiscoveredPeer`.
public struct SessionPeer: Sendable, Hashable {
    public let id: PeerID

    public init(id: PeerID) {
        self.id = id
    }

    public static func == (lhs: SessionPeer, rhs: SessionPeer) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Discovery stream events (FR-2).
public enum DiscoveryEvent: Sendable {
    case found(DiscoveredPeer)
    case updated(DiscoveredPeer)
    case lost(PeerID)
}

/// Session membership events (FR-10, FR-13, FR-14).
public enum MembershipEvent: Sendable {
    case joined(SessionPeer)
    case left(PeerID)
    case unreachable(PeerID)
    /// A previously known peer reconnected with a different key (TrustPolicy.automatic
    /// continuity warning, FR-21).
    case identityChanged(PeerID, previousKeyHash: Data)
}

/// An inbound reliable message or datagram (FR-15, FR-16).
public struct InboundMessage: Sendable {
    public let sender: PeerID
    public let payload: Data
    public let delivery: Delivery
}

/// An invitation received while advertising (FR-7).
public struct Invitation: Sendable {
    public let from: PeerID
    /// Opaque application context supplied by the inviter (FR-6). Delivered
    /// only over the encrypted channel (FR-8).
    public let context: Data?

    /// The inviter's TLS-authenticated public-key hash, surfaced to the app
    /// before it admits the peer (FR-22 — the verification-callback parity with
    /// MPC's `didReceiveCertificate`). Equals ``from``'s `keyHash` under
    /// `.automatic` trust; it is a distinct field because an app running
    /// `.pinned`/`.pairingCode` verifies against this authenticated value rather
    /// than the self-reported identity. Part of the public FR-22 surface even
    /// though PeerMesh's own consumers (MPCCompat/UI) do not yet read it.
    public let inviterKeyHash: Data

    public let accept: @Sendable () async -> Void
    public let decline: @Sendable () async -> Void
}

import Foundation

/// A peer discovered while browsing (FR-2), before any session relationship.
public struct DiscoveredPeer: Sendable, Hashable {
    public let id: PeerID
    /// The peer's advertised metadata (Bonjour TXT record contents, FR-1).
    public let metadata: [String: String]

    public init(id: PeerID, metadata: [String: String]) {
        self.id = id
        self.metadata = metadata
    }
}

/// A member of an active session.
public struct SessionPeer: Sendable, Hashable {
    public let id: PeerID

    public init(id: PeerID) {
        self.id = id
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

    /// Certificate/key hash of the inviter, available to the app before
    /// admission (FR-22).
    public let inviterKeyHash: Data

    public let accept: @Sendable () async -> Void
    public let decline: @Sendable () async -> Void
}

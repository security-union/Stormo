import Foundation

/// A peer's identity within a session.
///
/// Unlike `MCPeerID`, a `PeerID` is derived from the peer's public key (FR-20):
/// `keyHash` is the SHA-256 digest of the peer's P-256 public key, so a peer
/// cannot impersonate another peer's identity by choosing the same display name.
public struct PeerID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// SHA-256 of the peer's P-256 public key (raw representation).
    public let keyHash: Data

    /// Human-readable name chosen by the peer. Display only — never used for trust.
    public let displayName: String

    public init(keyHash: Data, displayName: String) {
        self.keyHash = keyHash
        self.displayName = displayName
    }

    public var description: String {
        "\(displayName) [\(keyHash.prefix(4).map { String(format: "%02x", $0) }.joined())…]"
    }
}

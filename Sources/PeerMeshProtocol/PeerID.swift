import Foundation

/// A peer's identity within a session.
///
/// Unlike `MCPeerID`, a `PeerID` is derived from the peer's public key (FR-20,
/// DD-8): `keyHash` is the libp2p-compatible multihash of the peer's P-256
/// public key, so a peer cannot impersonate another peer's identity by choosing
/// the same display name.
///
/// `keyHash` is a 34-byte multihash — `0x12 0x20` followed by the 32-byte
/// SHA-256 digest of the libp2p `PublicKey` protobuf. See ``LibP2PIdentity`` for
/// the exact byte layout. Its textual form (``base58String``) is the familiar
/// `Qm…` PeerID string.
public struct PeerID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// libp2p multihash of the peer's P-256 public key (34 bytes: `0x12 0x20` +
    /// SHA-256 digest). See ``LibP2PIdentity`` for the layout.
    public let keyHash: Data

    /// Human-readable name chosen by the peer. Display only — never used for trust.
    public let displayName: String

    public init(keyHash: Data, displayName: String) {
        self.keyHash = keyHash
        self.displayName = displayName
    }

    /// The base58btc textual form of the PeerID (`Qm…`), i.e. base58btc of the
    /// ``keyHash`` multihash. Matches the libp2p PeerID string representation.
    public var base58String: String {
        LibP2PIdentity.base58btc(keyHash)
    }

    public var description: String {
        let short = base58String
        let prefix = short.count > 8 ? String(short.prefix(8)) : short
        return "\(displayName) [\(prefix)…]"
    }
}

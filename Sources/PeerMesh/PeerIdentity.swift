import CryptoKit
import Foundation

/// The local device's long-lived cryptographic identity (FR-20, DD-2).
///
/// A P-256 keypair whose public-key hash *is* the peer ID. Presented to peers
/// as a self-signed certificate during the QUIC handshake; trust is established
/// by the session's ``TrustPolicy``, never by the certificate chain.
public struct PeerIdentity: Sendable {
    public let id: PeerID
    let privateKey: P256.Signing.PrivateKey

    /// Creates a new ephemeral identity. Prefer ``loadOrCreate(name:)``, which
    /// persists the identity so peers recognize this device across sessions.
    public init(name: String) {
        let key = P256.Signing.PrivateKey()
        self.privateKey = key
        self.id = PeerID(
            keyHash: Data(SHA256.hash(data: key.publicKey.rawRepresentation)),
            displayName: name
        )
    }

    /// Loads the persisted identity for this device, creating one on first use.
    ///
    /// `.automatic` trust (FR-21) depends on identity continuity: a stable key
    /// is what lets the framework warn when a known peer's key changes.
    ///
    /// - TODO: Phase 1 — persist in Keychain (Secure Enclave-backed where
    ///   available); currently returns a fresh ephemeral identity.
    public static func loadOrCreate(name: String) throws -> PeerIdentity {
        // TODO(Phase 1): Keychain persistence + Secure Enclave.
        PeerIdentity(name: name)
    }
}

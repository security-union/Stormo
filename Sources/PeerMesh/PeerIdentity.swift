import CryptoKit
import Foundation

/// The local device's long-lived cryptographic identity (FR-20, DD-2).
///
/// A P-256 keypair whose public-key multihash *is* the peer ID (DD-8). Presented
/// to peers as a self-signed certificate during the QUIC handshake; trust is
/// established by the session's ``TrustPolicy``, never by the certificate chain.
///
/// The private key may live in software (exportable, used by CI/tests and as the
/// keychain fallback) or in the Secure Enclave (non-exportable — the private key
/// can never produce a `derRepresentation`, only the public key can; that is
/// fine, the identity signs in place).
public struct PeerIdentity: Sendable {
    public let id: PeerID

    /// The private signing key, in whichever backing store it lives.
    let key: SigningKey

    /// A P-256 signing key that may be software-backed or Secure Enclave-backed.
    enum SigningKey: Sendable {
        case software(P256.Signing.PrivateKey)
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)

        var publicKey: P256.Signing.PublicKey {
            switch self {
            case .software(let k): return k.publicKey
            case .secureEnclave(let k): return k.publicKey
            }
        }
    }

    /// The DER-encoded SubjectPublicKeyInfo of this identity's public key.
    var publicKeyDER: Data { key.publicKey.derRepresentation }

    init(name: String, key: SigningKey) {
        self.key = key
        self.id = PeerID(
            keyHash: LibP2PIdentity.peerIDMultihash(p256SPKIDER: key.publicKey.derRepresentation),
            displayName: name
        )
    }

    /// Creates a new ephemeral, software-backed identity. Prefer
    /// ``loadOrCreate(name:)``, which persists the identity so peers recognize
    /// this device across sessions.
    public init(name: String) {
        self.init(name: name, key: .software(P256.Signing.PrivateKey()))
    }

    /// Loads the persisted identity for this device, creating one on first use.
    ///
    /// `.automatic` trust (FR-21) depends on identity continuity: a stable key
    /// is what lets the framework warn when a known peer's key changes.
    ///
    /// Uses ``KeychainIdentityStore`` by default. Any keychain error degrades
    /// gracefully to a fresh **ephemeral** identity — this call never crashes and
    /// never prompts the user.
    public static func loadOrCreate(name: String) -> PeerIdentity {
        #if canImport(Security)
        let store = KeychainIdentityStore()
        do {
            if let existing = try store.load(name: name) { return existing }
            // Secure Enclave-backed where available (only the keychain path can
            // create a non-exportable enclave key).
            let created = store.makeIdentity(name: name)
            try store.save(created)
            return created
        } catch {
            // Never crash, never prompt: degrade to a fresh ephemeral identity.
            return PeerIdentity(name: name)
        }
        #else
        return PeerIdentity(name: name)
        #endif
    }

    /// Loads-or-creates the identity from a caller-provided ``IdentityStore``.
    ///
    /// Tests and CI inject a ``FileIdentityStore`` here to keep the suite
    /// hermetic (never touching the real keychain).
    public static func loadOrCreate(name: String, store: IdentityStore) throws -> PeerIdentity {
        if let existing = try store.load(name: name) {
            return existing
        }
        let created = PeerIdentity(name: name)
        try store.save(created)
        return created
    }
}

import CryptoKit
import Foundation
import X509

/// The outcome of evaluating a peer's certificate against a ``TrustPolicy``.
public enum TrustDecision: Sendable, Equatable {
    /// Admit the peer; `keyHash` is its libp2p multihash PeerID (DD-8), to be
    /// recorded for future TOFU continuity checks (FR-22).
    case accept(keyHash: Data)

    /// Admit the peer, but its key changed since last seen — the app SHOULD
    /// surface a TOFU continuity warning (FR-21). `previous` is the last-seen
    /// key hash for this peer.
    case acceptWithIdentityChange(keyHash: Data, previous: Data)

    /// Reject the peer at the TLS layer.
    case reject(reason: String)
}

/// Pure, transport-free trust evaluation for a peer certificate (DD-2, FR-21,
/// FR-22).
///
/// This function contains *only* the policy logic — no Network.framework, no
/// `sec_protocol` types — so it is fully unit-testable with fixture certificates.
/// The QUIC transport's `sec_protocol_options_set_verify_block` calls into this
/// after extracting the peer's leaf certificate DER.
public enum TrustEvaluator {

    /// Evaluates a peer's leaf certificate against `policy`.
    ///
    /// - Parameters:
    ///   - certificateDER: The peer's DER-encoded leaf certificate.
    ///   - policy: The session ``TrustPolicy``.
    ///   - knownPeers: TOFU continuity map, **keyed by the peer's claimed PeerID
    ///     hash** with the value being the **last-seen key hash** for that peer.
    ///     For steady-state `.automatic`, key and value are the same until a key
    ///     rotation is observed. Pass `[:]` when continuity is not tracked.
    /// - Returns: the ``TrustDecision``.
    public static func evaluatePeer(
        certificateDER: Data,
        policy: TrustPolicy,
        knownPeers: [Data: Data] = [:]
    ) -> TrustDecision {
        switch policy {
        case .pinned(let certificates):
            // Byte-for-byte match against a pinned certificate (or issuing CA).
            let matches = certificates.contains { $0 == certificateDER }
            guard matches else {
                return .reject(reason: "certificate does not match any pinned entry")
            }
            guard let keyHash = keyHash(fromCertificateDER: certificateDER) else {
                return .reject(reason: "pinned certificate has an unextractable P-256 key")
            }
            return .accept(keyHash: keyHash)

        case .pairingCode:
            // DD-2: the TLS layer accepts the self-signed cert unconditionally;
            // the short-code (transcript-bound) verification happens later on the
            // control stream, not here. We still require a well-formed P-256 key.
            guard let keyHash = keyHash(fromCertificateDER: certificateDER) else {
                return .reject(reason: "certificate has an unextractable P-256 key")
            }
            return .accept(keyHash: keyHash)

        case .automatic:
            // MPC-ergonomics parity: accept and record. TOFU continuity warning
            // fires if a known peer's key changed (FR-21).
            guard let keyHash = keyHash(fromCertificateDER: certificateDER) else {
                return .reject(reason: "certificate has an unextractable P-256 key")
            }
            if let previous = knownPeers[keyHash], previous != keyHash {
                return .acceptWithIdentityChange(keyHash: keyHash, previous: previous)
            }
            return .accept(keyHash: keyHash)
        }
    }

    /// Extracts the P-256 public key from a DER certificate and computes its
    /// libp2p multihash PeerID (DD-8) — the same encoding used everywhere else.
    /// Returns `nil` if the cert is malformed or not a P-256 key.
    public static func keyHash(fromCertificateDER der: Data) -> Data? {
        guard
            let certificate = try? Certificate(derEncoded: Array(der)),
            let p256 = P256.Signing.PublicKey(certificate.publicKey)
        else {
            return nil
        }
        return LibP2PIdentity.peerIDMultihash(p256SPKIDER: p256.derRepresentation)
    }
}

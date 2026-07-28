import CryptoKit
import Foundation
import SwiftASN1
import X509

#if canImport(Security)
import Security
#endif

/// Self-signed X.509 certificate generation for a ``PeerIdentity`` (DD-2, FR-20).
///
/// The certificate exists only to satisfy the QUIC/TLS 1.3 handshake — trust is
/// established by the session's ``TrustPolicy``, never by the chain. Per DD-2 the
/// validity window is **deliberately ignored** by verification, so it is set
/// wide (notBefore = yesterday, notAfter = +100 years) purely to avoid any
/// clock-skew rejection by the TLS stack.
public enum IdentityCertificate {

    public enum CertificateError: Error {
        case unsupportedKeyType
        #if canImport(Security)
        case secItemStatus(OSStatus)
        case identityNotFound
        case certificateCreationFailed
        #endif
    }

    /// ~100 years, in seconds (validity is ignored by verification, DD-2).
    private static let hundredYears: TimeInterval = 100 * 365.25 * 24 * 60 * 60
    private static let oneDay: TimeInterval = 24 * 60 * 60

    /// Builds the self-signed `Certificate` for `identity`. Pure — no keychain,
    /// no I/O — so it is unit-testable without entitlements.
    public static func makeCertificate(for identity: PeerIdentity) throws -> Certificate {
        let name = try DistinguishedName {
            CommonName(identity.id.base58String)
        }
        let issuerKey = certificatePrivateKey(for: identity)

        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(identity.key.publicKey),
            notValidBefore: Date(timeIntervalSinceNow: -oneDay),
            notValidAfter: Date(timeIntervalSinceNow: hundredYears),
            issuer: name,
            subject: name,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: issuerKey
        )
    }

    /// DER-encodes the self-signed certificate for `identity`.
    public static func makeCertificateDER(for identity: PeerIdentity) throws -> Data {
        let cert = try makeCertificate(for: identity)
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        return Data(serializer.serializedBytes)
    }

    /// Wraps the identity's private key for swift-certificates signing. Supports
    /// both software and Secure Enclave keys (the latter signs in place).
    private static func certificatePrivateKey(for identity: PeerIdentity) -> Certificate.PrivateKey {
        switch identity.key {
        case .software(let key):
            return Certificate.PrivateKey(key)
        case .secureEnclave(let key):
            return Certificate.PrivateKey(key)
        }
    }
}

#if canImport(Security)

extension IdentityCertificate {
    /// Imports the identity's key + self-signed certificate into the
    /// data-protection keychain and returns the resulting `SecIdentity`, for use
    /// with `sec_protocol_options_set_local_identity`.
    ///
    /// Standard technique: `SecItemAdd` the certificate, `SecItemAdd` the private
    /// key, then `SecItemCopyMatching(kSecClassIdentity)`. This requires keychain
    /// access and — for Secure Enclave keys — cannot round-trip a CryptoKit
    /// enclave key into a `SecKey`, so `.secureEnclave` identities are rejected
    /// here (the SE signing path is used directly by the TLS stack instead).
    ///
    /// May fail without the keychain-sharing entitlement in a bare `swift test`
    /// process; callers/tests should treat a thrown error as an environment
    /// limitation, not a defect (see `IdentitySecurityTests`).
    public static func makeSecIdentity(for identity: PeerIdentity) throws -> SecIdentity {
        guard case .software(let privateKey) = identity.key else {
            throw CertificateError.unsupportedKeyType
        }

        let der = try makeCertificateDER(for: identity)
        guard let secCert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CertificateError.certificateCreationFailed
        }

        // Build a SecKey from the P-256 private key (X9.63 representation).
        var keyError: Unmanaged<CFError>?
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        guard
            let secKey = SecKeyCreateWithData(
                privateKey.x963Representation as CFData, keyAttrs as CFDictionary, &keyError)
        else {
            if let error = keyError?.takeRetainedValue() { throw error }
            throw CertificateError.certificateCreationFailed
        }

        // The key's application label (the public-key hash, assigned by the
        // Security framework) is the canonical link between a cert and its
        // key — and the ONLY safe way to fetch the matching identity below.
        // Fetching kSecClassIdentity without it returns an arbitrary identity
        // from the keychain; with ephemeral per-session keys accumulating
        // across runs that served STALE identities whose certificates failed
        // the peer's key-hash cross-check (identityMismatch on every dial —
        // the device-side "Connecting → Not Connected" bug).
        guard
            let keyAttributes = SecKeyCopyAttributes(secKey) as? [String: Any],
            let applicationLabel = keyAttributes[kSecAttrApplicationLabel as String] as? Data
        else {
            throw CertificateError.certificateCreationFailed
        }

        // Add the private key.
        let addKey: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: secKey,
            kSecAttrApplicationTag as String: Data("dev.securityunion.stormo.tls".utf8),
            kSecUseDataProtectionKeychain as String: true,
        ]
        let keyStatus = SecItemAdd(addKey as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw CertificateError.secItemStatus(keyStatus)
        }

        // Add the certificate.
        let addCert: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: secCert,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let certStatus = SecItemAdd(addCert as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw CertificateError.secItemStatus(certStatus)
        }

        // Fetch the assembled SecIdentity — pinned to THIS key via its
        // application label, never "whichever identity comes first".
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationLabel as String: applicationLabel,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else {
            throw CertificateError.identityNotFound
        }
        // Force-cast through CFTypeRef: the query pins kSecClassIdentity.
        return result as! SecIdentity
    }
}

#endif

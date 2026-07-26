import CryptoKit
import Foundation
import PeerMeshProtocol

#if canImport(Network)
import Network
#endif

#if canImport(Security)
import Security
#endif

#if canImport(Network) && canImport(Security)

/// A `sec_identity_t` usable with `sec_protocol_options_set_local_identity`,
/// plus (on macOS) ownership of the transient file keychain that backs it.
///
/// The identity **references** the keychain that holds its key + certificate, so
/// the keychain must outlive every connection that uses the identity; this type
/// retains it and deletes the backing file only on ``dispose()``.
final class QUICLocalIdentity: @unchecked Sendable {
    let secIdentity: sec_identity_t
    #if os(macOS)
    private let keychain: SecKeychain?
    private let keychainURL: URL?

    init(secIdentity: sec_identity_t, keychain: SecKeychain? = nil, keychainURL: URL? = nil) {
        self.secIdentity = secIdentity
        self.keychain = keychain
        self.keychainURL = keychainURL
    }
    #else
    init(secIdentity: sec_identity_t) {
        self.secIdentity = secIdentity
    }
    #endif

    func dispose() {
        #if os(macOS)
        if let keychain { SecKeychainDelete(keychain) }
        if let keychainURL {
            try? FileManager.default.removeItem(at: keychainURL.deletingLastPathComponent())
        }
        #endif
    }
}

/// Assembles a QUIC/TLS local identity and `NWParameters` from a
/// ``PeerIdentity`` (DD-2). Trust is enforced by ``TrustEvaluator`` in the
/// verify block; the certificate chain is never trusted on its own.
enum QUICTLS {

    static let alpn = "peermesh/1"

    /// Forms the local `sec_identity_t`.
    ///
    /// Resolution order (see the Step 3 report / `docs/spike-results.md`):
    /// 1. `IdentityCertificate.makeSecIdentity` (data-protection keychain) — works
    ///    in an entitled host app.
    /// 2. **(macOS)** a transient *file* keychain: `SecKeychainCreate` +
    ///    `SecItemImport` of the SEC1 private key and the certificate. This needs
    ///    **no keychain entitlement**, so it works in a bare `swift test`
    ///    process — the path CI uses.
    /// 3. Throws ``QUICError/tlsIdentityUnavailable`` (caller decides: inject via
    ///    `tlsProvider`, or skip the QUIC test cleanly).
    static func makeLocalIdentity(for identity: PeerIdentity) throws -> QUICLocalIdentity {
        // Path 1: entitled data-protection keychain.
        let path1Error: String
        do {
            let sec = try IdentityCertificate.makeSecIdentity(for: identity)
            if let secIdentity = sec_identity_create(sec) {
                return QUICLocalIdentity(secIdentity: secIdentity)
            }
            path1Error = "sec_identity_create returned nil"
        } catch {
            path1Error = "keychain path: \(error)"
        }

        #if os(macOS)
        // Path 2: transient file keychain (entitlement-free; SecKeychain API is
        // unavailable on Catalyst and iOS — those platforms must succeed on path 1
        // or inject Configuration.tlsProvider).
        do {
            return try makeFileKeychainIdentity(for: identity)
        } catch {
            throw QUICError.tlsIdentityUnavailable(
                "path1 [\(path1Error)]; path2 [\(error)]")
        }
        #else
        // Path 3: no entitlement-free route on iOS/tvOS/Catalyst from a bare process.
        throw QUICError.tlsIdentityUnavailable(
            "path1 [\(path1Error)]; no fallback on this platform — supply Configuration.tlsProvider")
        #endif
    }

    #if os(macOS)
    private static func createFileKeychain() throws -> (SecKeychain, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peermesh-kc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("id.keychain")
        let pass = UUID().uuidString
        var keychain: SecKeychain?
        let status = SecKeychainCreate(url.path, UInt32(pass.utf8.count), pass, false, nil, &keychain)
        guard status == errSecSuccess, let keychain else {
            throw QUICError.tlsIdentityUnavailable("SecKeychainCreate=\(status)")
        }
        _ = SecKeychainUnlock(keychain, UInt32(pass.utf8.count), pass, true)
        return (keychain, url)
    }

    private static func makeFileKeychainIdentity(for identity: PeerIdentity) throws -> QUICLocalIdentity {
        guard let keyPEM = sec1PrivateKeyPEM(for: identity) else {
            throw QUICError.tlsIdentityUnavailable("identity is not a software P-256 key")
        }
        let certDER = try IdentityCertificate.makeCertificateDER(for: identity)
        let (keychain, url) = try createFileKeychain()

        var keyFormat = SecExternalFormat.formatUnknown
        var keyType = SecExternalItemType.itemTypePrivateKey
        let keyStatus = SecItemImport(
            Data(keyPEM.utf8) as CFData, "key.pem" as CFString,
            &keyFormat, &keyType, [], nil, keychain, nil)
        guard keyStatus == errSecSuccess else {
            SecKeychainDelete(keychain)
            throw QUICError.tlsIdentityUnavailable("SecItemImport(key)=\(keyStatus)")
        }

        var certFormat = SecExternalFormat.formatX509Cert
        var certType = SecExternalItemType.itemTypeCertificate
        let certStatus = SecItemImport(
            certDER as CFData, "cert.der" as CFString,
            &certFormat, &certType, [], nil, keychain, nil)
        guard certStatus == errSecSuccess else {
            SecKeychainDelete(keychain)
            throw QUICError.tlsIdentityUnavailable("SecItemImport(cert)=\(certStatus)")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchSearchList as String: [keychain],
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let fetch = SecItemCopyMatching(query as CFDictionary, &result)
        guard fetch == errSecSuccess, let result else {
            SecKeychainDelete(keychain)
            throw QUICError.tlsIdentityUnavailable("identity fetch=\(fetch)")
        }
        // swiftlint:disable:next force_cast
        let secIdentity = result as! SecIdentity
        guard let identityT = sec_identity_create(secIdentity) else {
            SecKeychainDelete(keychain)
            throw QUICError.tlsIdentityUnavailable("sec_identity_create failed")
        }
        return QUICLocalIdentity(secIdentity: identityT, keychain: keychain, keychainURL: url)
    }

    /// Encodes the identity's P-256 key as SEC1 (traditional OpenSSL) EC private
    /// key PEM — the one format `SecItemImport` accepts into a file keychain
    /// without securityd/entitlements (PKCS#8 is rejected with `errSecUnknownFormat`).
    private static func sec1PrivateKeyPEM(for identity: PeerIdentity) -> String? {
        // Only software-backed keys are exportable to SEC1 (Secure Enclave keys
        // cannot leave the enclave — an entitled host uses path 1 for those).
        guard case .software(let priv) = identity.key else { return nil }
        func tlv(_ tag: UInt8, _ body: Data) -> Data { Data([tag, UInt8(body.count)]) + body }
        let scalar = priv.rawRepresentation                // 32 bytes
        let pub = priv.publicKey.x963Representation         // 65 bytes (0x04‖X‖Y)
        let version = Data([0x02, 0x01, 0x01])
        let privateOctet = tlv(0x04, scalar)
        let curveOID = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        let params = tlv(0xA0, curveOID)
        let bitString = Data([0x03, UInt8(pub.count + 1), 0x00]) + pub
        let publicKey = tlv(0xA1, bitString)
        let der = tlv(0x30, version + privateOctet + params + publicKey)
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN EC PRIVATE KEY-----\n\(b64)\n-----END EC PRIVATE KEY-----\n"
    }
    #endif

    /// Builds `NWParameters` for a QUIC endpoint: ALPN `peermesh/1`, local
    /// identity, mutual authentication (so both ends recover the peer's
    /// authenticated key hash — FR-22), a ``TrustPolicy`` verify block, and
    /// generous stream/flow limits for the stream-per-message data plane (DD-7,
    /// S-6).
    static func parameters(
        localIdentity: QUICLocalIdentity,
        trust: TrustPolicy,
        isListener: Bool
    ) -> NWParameters {
        let quic = NWProtocolQUIC.Options(alpn: [alpn])
        quic.idleTimeout = 30_000
        quic.initialMaxData = 1 << 24
        quic.initialMaxStreamDataBidirectionalLocal = 1 << 20
        quic.initialMaxStreamDataBidirectionalRemote = 1 << 20
        quic.initialMaxStreamDataUnidirectional = 1 << 20
        // Stream-per-message churn (DD-7/S-6): allow many concurrent streams.
        quic.initialMaxStreamsBidirectional = 2_048
        quic.initialMaxStreamsUnidirectional = 2_048

        let sec = quic.securityProtocolOptions
        sec_protocol_options_set_local_identity(sec, localIdentity.secIdentity)
        // Require the peer to present a certificate so its key hash is
        // authenticated on both sides (FR-19/FR-22).
        sec_protocol_options_set_peer_authentication_required(sec, true)
        installVerifyBlock(sec, trust: trust)

        let params = NWParameters(quic: quic)
        params.allowLocalEndpointReuse = true
        return params
    }

    /// Enforces the session ``TrustPolicy`` via ``TrustEvaluator`` (DD-2). The
    /// certificate chain is never trusted by PKI; we extract the leaf DER and
    /// apply the policy. `displayName`/key-hash bookkeeping happens later from the
    /// connection's authenticated metadata.
    private static func installVerifyBlock(_ sec: sec_protocol_options_t, trust: TrustPolicy) {
        let queue = DispatchQueue(label: "dev.securityunion.peermesh.quic.verify")
        sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
            quicDebug("verify block called")
            let trustRef = sec_trust_copy_ref(secTrust).takeRetainedValue()
            guard
                let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate],
                let leaf = chain.first
            else {
                quicDebug("verify: no chain")
                complete(false)
                return
            }
            let der = SecCertificateCopyData(leaf) as Data
            switch TrustEvaluator.evaluatePeer(certificateDER: der, policy: trust) {
            case .accept, .acceptWithIdentityChange:
                quicDebug("verify: accept")
                complete(true)
            case .reject:
                quicDebug("verify: reject")
                complete(false)
            }
        }, queue)
    }
}

#endif

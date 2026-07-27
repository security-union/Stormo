import CryptoKit
import Foundation

#if canImport(Security)
import Security
#endif

/// Persistence backend for the local ``PeerIdentity`` (FR-20).
///
/// Two implementations ship: ``KeychainIdentityStore`` (production; Secure
/// Enclave-backed where available) and ``FileIdentityStore`` (tests/CI; keeps
/// the suite hermetic — it must never touch the real keychain).
public protocol IdentityStore: Sendable {
    /// Loads the persisted identity for `name`, or `nil` if none is stored.
    func load(name: String) throws -> PeerIdentity?
    /// Persists `identity` so it survives relaunch.
    func save(_ identity: PeerIdentity) throws
}

/// On-disk serialized form of an identity. Shared by both stores.
struct StoredIdentity: Codable {
    enum Backing: String, Codable {
        case software
        case secureEnclave
    }
    var name: String
    var backing: Backing
    /// For `.software`: the P-256 private key `rawRepresentation` (32 bytes).
    /// For `.secureEnclave`: the enclave key's opaque `dataRepresentation`.
    var keyData: Data

    init(_ identity: PeerIdentity) {
        self.name = identity.id.displayName
        switch identity.key {
        case .software(let k):
            self.backing = .software
            self.keyData = k.rawRepresentation
        case .secureEnclave(let k):
            self.backing = .secureEnclave
            self.keyData = k.dataRepresentation
        }
    }

    func makeIdentity() throws -> PeerIdentity {
        switch backing {
        case .software:
            let key = try P256.Signing.PrivateKey(rawRepresentation: keyData)
            return PeerIdentity(name: name, key: .software(key))
        case .secureEnclave:
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData)
            return PeerIdentity(name: name, key: .secureEnclave(key))
        }
    }
}

// MARK: - FileIdentityStore

/// Stores identities as JSON files in a caller-provided directory.
///
/// Used by tests and CI so the suite never touches the real keychain. Not for
/// production use on device: the private key material is written to disk in the
/// clear (software keys) — production uses ``KeychainIdentityStore``.
public struct FileIdentityStore: IdentityStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func fileURL(for name: String) -> URL {
        // Derive a filesystem-safe, deterministic filename from the identity name.
        let digest = SHA256.hash(data: Data(name.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("identity-\(hex).json")
    }

    public func load(name: String) throws -> PeerIdentity? {
        let url = fileURL(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let stored = try JSONDecoder().decode(StoredIdentity.self, from: data)
        return try stored.makeIdentity()
    }

    public func save(_ identity: PeerIdentity) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(StoredIdentity(identity))
        try data.write(to: fileURL(for: identity.id.displayName), options: [.atomic])
    }
}

// MARK: - KeychainIdentityStore

#if canImport(Security)

/// Production identity store backed by the data-protection keychain.
///
/// The private key is Secure Enclave-backed (``makeIdentity(name:)``) when
/// `SecureEnclave.isAvailable`; otherwise a software P-256 key is used
/// (simulator/CI/Intel Macs without an enclave). Either way the serialized key
/// material lives as a `kSecClassKey` item tagged
/// `dev.securityunion.peermesh.identity`, in the data-protection keychain.
///
/// Note: Secure Enclave keys can never export a private-key `derRepresentation`
/// (only the public key can) — that is fine; we persist the enclave key's opaque
/// `dataRepresentation` reference blob and the key signs in place.
public struct KeychainIdentityStore: IdentityStore {
    /// Application-tag prefix for identity items (per-name suffix appended).
    public static let applicationTag = "dev.securityunion.peermesh.identity"

    public init() {}

    /// Creates a fresh software-P-256 identity.
    ///
    /// NOT Secure Enclave-backed: the TLS identity path
    /// (`IdentityCertificate.makeSecIdentity`) can only form a `SecIdentity`
    /// from an exportable software key — an enclave-backed identity fails
    /// every advertise/dial with `unsupportedKeyType`. The key material still
    /// rests in the data-protection keychain. TODO(se-identity): enclave
    /// signing support in the certificate/TLS path, then prefer the enclave
    /// here.
    public func makeIdentity(name: String) -> PeerIdentity {
        PeerIdentity(name: name)
    }

    private func tagData(for name: String) -> Data {
        Data("\(Self.applicationTag).\(name)".utf8)
    }

    private func baseQuery(for name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData(for: name),
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load(name: String) throws -> PeerIdentity? {
        var query = baseQuery(for: name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        let stored = try JSONDecoder().decode(StoredIdentity.self, from: data)
        return try stored.makeIdentity()
    }

    public func save(_ identity: PeerIdentity) throws {
        let name = identity.id.displayName
        let blob = try JSONEncoder().encode(StoredIdentity(identity))

        var addQuery = baseQuery(for: name)
        addQuery[kSecValueData as String] = blob

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Replace the existing item's data.
            let updateStatus = SecItemUpdate(
                baseQuery(for: name) as CFDictionary,
                [kSecValueData as String: blob] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
    }
}

#endif

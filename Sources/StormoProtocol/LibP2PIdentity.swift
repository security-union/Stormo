import CryptoKit
import Foundation

/// libp2p-compatible identity encoding (DD-8).
///
/// Stormo derives its ``PeerID`` from the peer's public key exactly the way
/// libp2p does, so a future libp2p bridge stays identity-compatible. This helper
/// is deliberately dependency-free (only CryptoKit's SHA-256, a pure CPU hash —
/// no I/O, consistent with the sans-I/O `StormoProtocol` target, DD-6) and is
/// shared by both `StormoProtocol` and `Stormo` so the two never disagree on
/// the byte layout.
///
/// ## PeerID multihash byte layout (34 bytes)
///
/// ```
/// ┌──────┬──────┬───────────────────────────────┐
/// │ 0x12 │ 0x20 │  SHA-256 digest (32 bytes)     │
/// └──────┴──────┴───────────────────────────────┘
///  sha2-256  len=32   digest over the PublicKey protobuf below
/// ```
///
/// The digest is taken over the libp2p `PublicKey` protobuf message:
///
/// ```
/// message PublicKey {
///   KeyType Type = 1;   // ECDSA = 3
///   bytes   Data = 2;   // DER-encoded SubjectPublicKeyInfo (P-256 SPKI)
/// }
/// ```
///
/// which hand-encodes (no protobuf runtime) to:
///
/// ```
/// 0x08 0x03            field 1, varint, KeyType = ECDSA (3)
/// 0x12 <len> <der…>    field 2, length-delimited, the SPKI DER bytes
/// ```
public enum LibP2PIdentity {

    /// libp2p `KeyType.ECDSA`.
    static let keyTypeECDSA: UInt64 = 3

    /// Computes the 34-byte PeerID multihash for a P-256 public key given its
    /// DER-encoded SubjectPublicKeyInfo (`P256.*.PublicKey.derRepresentation`).
    public static func peerIDMultihash(p256SPKIDER der: Data) -> Data {
        let protobuf = publicKeyProtobuf(spkiDER: der)
        let digest = SHA256.hash(data: protobuf)
        var out = Data(capacity: 34)
        out.append(0x12)  // multihash code: sha2-256
        out.append(0x20)  // digest length: 32
        out.append(contentsOf: digest)
        return out
    }

    /// Hand-encoded libp2p `PublicKey` protobuf for a P-256 SPKI DER blob.
    static func publicKeyProtobuf(spkiDER der: Data) -> Data {
        var out = Data()
        // field 1 (Type), wire type 0 (varint): tag = (1 << 3) | 0 = 0x08
        out.append(0x08)
        out.append(contentsOf: varint(keyTypeECDSA))
        // field 2 (Data), wire type 2 (length-delimited): tag = (2 << 3) | 2 = 0x12
        out.append(0x12)
        out.append(contentsOf: varint(UInt64(der.count)))
        out.append(der)
        return out
    }

    /// Base-128 varint (protobuf / unsigned LEB128).
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while v != 0
        return bytes
    }

    // MARK: - base58btc

    private static let base58Alphabet = Array(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    /// Encodes raw bytes as base58btc (Bitcoin alphabet) — the textual PeerID
    /// form (`Qm…` for sha2-256 multihashes).
    public static func base58btc(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        // Leading zero bytes map to leading '1's.
        var leadingZeros = 0
        for byte in data {
            if byte == 0 { leadingZeros += 1 } else { break }
        }

        // Big-integer base-256 → base-58 by repeated division.
        var digits: [UInt8] = []
        for byte in data {
            var carry = Int(byte)
            for i in 0..<digits.count {
                carry += Int(digits[i]) << 8
                digits[i] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }

        var scalars: [UInt8] = []
        scalars.reserveCapacity(leadingZeros + digits.count)
        for _ in 0..<leadingZeros { scalars.append(base58Alphabet[0]) }
        for digit in digits.reversed() { scalars.append(base58Alphabet[Int(digit)]) }
        return String(decoding: scalars, as: UTF8.self)
    }

    /// Decodes base58btc back to raw bytes; `nil` on any invalid character.
    /// Inverse of ``base58btc(_:)`` — used to recover a full PeerID multihash
    /// from a Bonjour service instance name (AWDL name-only discovery).
    public static func base58btcDecode(_ string: String) -> Data? {
        guard !string.isEmpty else { return Data() }

        var leadingOnes = 0
        for scalar in string.utf8 {
            if scalar == base58Alphabet[0] { leadingOnes += 1 } else { break }
        }

        // Big-integer base-58 → base-256 by repeated multiplication.
        var bytes: [UInt8] = []
        for scalar in string.utf8 {
            guard let value = base58Reverse[scalar] else { return nil }
            var carry = Int(value)
            for i in 0..<bytes.count {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
        }

        var out = Data(repeating: 0, count: leadingOnes)
        out.append(contentsOf: bytes.reversed())
        return out
    }

    private static let base58Reverse: [UInt8: UInt8] = {
        var map: [UInt8: UInt8] = [:]
        for (index, scalar) in base58Alphabet.enumerated() {
            map[scalar] = UInt8(index)
        }
        return map
    }()
}

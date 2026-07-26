import FlatBuffers
import Foundation

/// The codec boundary for control-plane messages (DD-5).
///
/// Zero-copy contract (DD-5/DD-6): `decode` verifies the buffer **once** and
/// returns a ``Signal`` that reads it in place forever after — nothing is
/// unpacked. `encode` is the identity on the signal's canonical bytes (the
/// builder already produced wire form).
public enum SignalCodec {
    /// Maximum size of a single control message (DD-5 rule 3). Invitation
    /// contexts larger than this are chunked.
    public static let maxControlMessageSize = 64 * 1024

    /// Protocol version stamped into every `Signal` envelope (QA-11).
    public static let protocolVersion: UInt16 = 1

    /// Wire bytes for a signal. Size-prefix framing is applied by the driver.
    public static func encode(_ signal: Signal) -> Data {
        signal.encoded
    }

    /// Verify untrusted bytes (DD-5 rule 3: verifier with hard caps — this is
    /// input from a peer that may not be authenticated yet) and wrap them for
    /// in-place reading.
    ///
    /// - TODO(Phase 1): distinguish "unknown union variant from a newer peer"
    ///   (must be tolerated per QA-11 — pre-read `bodyType` before full
    ///   verification) from structural malformation (connection-fatal).
    public static func decode(_ data: Data) throws -> Signal {
        guard data.count <= maxControlMessageSize, !data.isEmpty else {
            throw PeerMeshError.malformedSignal
        }
        var buffer = ByteBuffer(data: data)
        do {
            let root: WireSignal = try getCheckedRoot(
                byteBuffer: &buffer,
                options: VerifierOptions(
                    maxDepth: 16,
                    maxTableCount: 1024,
                    maxApparentSize: UInt32(maxControlMessageSize)))
            return Signal(verified: data, root: root)
        } catch {
            throw PeerMeshError.malformedSignal
        }
    }
}

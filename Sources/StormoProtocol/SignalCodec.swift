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

    /// Wire bytes for a signal. Size-prefix framing is applied by the driver.
    public static func encode(_ signal: Signal) -> Data {
        signal.encoded
    }

    /// Verify untrusted bytes (DD-5 rule 3: verifier with hard caps — this is
    /// input from a peer that may not be authenticated yet) and wrap them for
    /// in-place reading.
    ///
    /// Forward compatibility (QA-11): a newer peer's unknown union variant still
    /// passes the verifier — it is structurally valid — and surfaces as
    /// ``Signal/Body/unrecognized`` (ignored-and-logged, DD-5 rule 1). Only
    /// genuine structural malformation throws, and that is connection-fatal.
    public static func decode(_ data: Data) throws -> Signal {
        guard data.count <= maxControlMessageSize, !data.isEmpty else {
            throw StormoError.malformedSignal
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
            throw StormoError.malformedSignal
        }
    }
}

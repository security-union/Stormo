import Foundation
import PeerMesh

/// Near-drop-in replacement for `MCSession` (FR-24).
///
/// Migration from MultipeerConnectivity is a mechanical rename:
///
/// | MultipeerConnectivity        | MPCCompat                     |
/// |------------------------------|-------------------------------|
/// | `MCSession`                  | `MultipeerSession`            |
/// | `MCPeerID`                   | `PeerMesh.PeerID`             |
/// | `MCSessionDelegate`          | `MultipeerSessionDelegate`    |
/// | `MCSessionSendDataMode`      | `MultipeerSession.SendDataMode` |
/// | `MCSessionState`             | `MultipeerSession.PeerState`  |
///
/// Behavioral notes vs. MCSession:
/// - Encryption is always on (`.required` semantics); there is no plaintext mode.
/// - The 8-peer ceiling is lifted; set ``legacyPeerLimit`` to `true` to emulate
///   it for behavioral-parity testing during migration.
/// - Delegate callbacks arrive on an internal serial queue, matching MCSession's
///   documented behavior.
public final class MultipeerSession: @unchecked Sendable {

    public enum SendDataMode: Sendable {
        case reliable
        case unreliable
    }

    /// Raw values match `MCSessionState` so migrated logging/persistence code
    /// (`state.rawValue`) behaves identically.
    public enum PeerState: Int, Sendable {
        case notConnected = 0
        case connecting = 1
        case connected = 2
    }

    /// Source-compatibility analog of `MCEncryptionPreference`. PeerMesh is
    /// ALWAYS encrypted (FR-19): `.optional` and `.none` are accepted for
    /// mechanical migration but behave as `.required`.
    public enum EncryptionPreference: Sendable {
        case optional
        case required
        case none
    }

    public weak var delegate: (any MultipeerSessionDelegate)?

    public private(set) var myPeerID: PeerID
    public private(set) var connectedPeers: [PeerID] = []

    /// Emulate MCSession's 8-peer ceiling (off by default; FR-24).
    public var legacyPeerLimit = false

    private let session: PeerSession
    private let delegateQueue = DispatchQueue(label: "mpccompat.session.delegate")

    public init(peer name: String, service: String) {
        let identity = PeerIdentity.loadOrCreate(name: name)
        self.myPeerID = identity.id
        self.session = PeerSession(
            identity: identity,
            service: ServiceDescriptor(type: service)
        )
        // TODO(Phase 2): pump session.membership / session.messages /
        // resource + stream events into delegate callbacks on delegateQueue.
    }

    /// `MCSession(peer:securityIdentity:encryptionPreference:)` analog.
    ///
    /// - `securityIdentity` is accepted for source compatibility and ignored:
    ///   PeerMesh identities are key-derived (FR-20) and managed automatically.
    /// - `encryptionPreference` is accepted for source compatibility; traffic
    ///   is always encrypted regardless (FR-19).
    /// - MCSession carries no service type (its advertiser/browser do); the
    ///   `service` default is a placeholder until Phase 2 unifies session and
    ///   discovery wiring.
    public convenience init(
        peer peerID: PeerID,
        securityIdentity: [Any]? = nil,
        encryptionPreference: EncryptionPreference = .required,
        service: String = "_peermesh._udp"
    ) {
        self.init(peer: peerID.displayName, service: service)
        // TODO(Phase 2): honor the caller-supplied PeerID as the session
        // identity end-to-end (requires identity lookup by display name).
        self.myPeerID = peerID
    }

    // MARK: MCSession-shaped API

    public func send(_ data: Data, toPeers peerIDs: [PeerID], with mode: SendDataMode) throws {
        // TODO(Phase 2): bridge to session.send(_:to:delivery:). Mapping (DD-7):
        // MCSession .reliable guaranteed FIFO per pair → Delivery.reliableOrdered;
        // .unreliable → Delivery.datagram. (PeerMesh-native `.reliable` is
        // unordered-across-messages and has no MCSession equivalent.)
        throw PeerMeshError.unimplemented("MultipeerSession.send")
    }

    public func sendResource(
        at resourceURL: URL,
        withName resourceName: String,
        toPeer peerID: PeerID,
        withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)? = nil
    ) -> Progress? {
        // TODO(Phase 2): bridge to session.sendResource(at:to:).
        completionHandler?(PeerMeshError.unimplemented("MultipeerSession.sendResource"))
        return nil
    }

    public func startStream(withName streamName: String, toPeer peerID: PeerID) throws -> OutputStream {
        // TODO(Phase 2): NSStream bridge over PeerByteStream (design doc FR-24;
        // modern callers should use PeerSession.openStream instead).
        throw PeerMeshError.unimplemented("MultipeerSession.startStream")
    }

    public func disconnect() {
        // TODO(Phase 2): bridge to session.disconnect().
    }
}

extension PeerID {
    /// `MCPeerID(displayName:)` analog: creates a fresh key-derived identity
    /// carrying this display name. Like `MCPeerID`, each call produces a
    /// distinct peer identity; persist via `Codable` (JSON) rather than
    /// `NSKeyedArchiver` to keep it stable across launches.
    public init(displayName: String) {
        self = PeerIdentity(name: displayName).id
    }
}

/// Near-drop-in replacement for `MCSessionDelegate` (FR-24).
public protocol MultipeerSessionDelegate: AnyObject, Sendable {
    func session(_ session: MultipeerSession, peer peerID: PeerID, didChange state: MultipeerSession.PeerState)
    func session(_ session: MultipeerSession, didReceive data: Data, fromPeer peerID: PeerID)
    func session(_ session: MultipeerSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: PeerID)
    func session(_ session: MultipeerSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: PeerID, with progress: Progress)
    func session(_ session: MultipeerSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: PeerID, at localURL: URL?, withError error: Error?)
}

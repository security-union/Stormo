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
/// - The 8-peer ceiling is lifted (FR-24), with no cap emulation.
/// - Delegate callbacks arrive on an internal serial queue, matching MCSession's
///   documented behavior.
///
/// ### Shared runtime (the MC three-object model)
/// `MCSession` carries no service type — its advertiser and browser do. A
/// `MultipeerSession` therefore *parks* on construction: it has no underlying
/// ``PeerSession`` until a ``NearbyServiceAdvertiser`` or ``NearbyServiceBrowser``
/// (constructed with the same `PeerID`) attaches it to their shared
/// ``CompatCore``. Attachment happens exactly where MC associates a session with
/// a connection: `NearbyServiceBrowser.invitePeer(_:to:...)` and the
/// advertiser's `invitationHandler(true, session)`. The advertiser/browser's
/// `serviceType` wins over the placeholder passed to this initializer.
///
/// ### Peer identity
/// The bridge holds the app's `PeerID` (public-key hash + display name) but not
/// its private key, so the underlying `PeerSession` uses a freshly derived
/// key-identity. Remote peer IDs surfaced to the delegate (`didChange`,
/// `didReceive`) carry *that* session's key hash — stable within a session and
/// across the device's advertiser/browser, with the display name preserved, but
/// not a value the app can precompute from a locally constructed `PeerID`.
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

    public let myPeerID: PeerID

    /// Bonjour service type placeholder; superseded by the attaching
    /// advertiser/browser's `serviceType` (MC carries no service on the session).
    private let placeholderService: String
    private let injectedTransport: (any PeerTransport)?

    private let stateLock = NSLock()
    private var _connectedPeers: [PeerID] = []
    private var _core: CompatCore?

    /// Members currently connected to this session (mutated by the core on the
    /// delegate queue; read-safe from any thread).
    public var connectedPeers: [PeerID] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _connectedPeers
    }

    /// Designated initializer (internal): all public inits funnel here.
    init(myPeerID: PeerID, service: String, transport: (any PeerTransport)?) {
        self.myPeerID = myPeerID
        self.placeholderService = service
        self.injectedTransport = transport
    }

    /// `MCSession(peer:)` analog taking a display name.
    public convenience init(peer name: String, service: String) {
        self.init(myPeerID: PeerIdentity.loadOrCreate(name: name).id, service: service, transport: nil)
    }

    /// `MCSession(peer:securityIdentity:encryptionPreference:)` analog.
    ///
    /// - `securityIdentity` is accepted for source compatibility and ignored:
    ///   PeerMesh identities are key-derived (FR-20) and managed automatically.
    /// - `encryptionPreference` is accepted for source compatibility; traffic
    ///   is always encrypted regardless (FR-19).
    /// - MCSession carries no service type (its advertiser/browser do); the
    ///   `service` value is a placeholder until an advertiser/browser attaches.
    public convenience init(
        peer peerID: PeerID,
        securityIdentity: [Any]? = nil,
        encryptionPreference: EncryptionPreference = .required,
        service: String = "_peermesh._udp"
    ) {
        self.init(myPeerID: peerID, service: service, transport: nil)
    }

    /// Test entry point: inject a transport (e.g. `InMemoryTransport`) threaded
    /// through the shared ``CompatCore`` to the underlying `PeerSession`.
    convenience init(
        peer peerID: PeerID,
        service: String = "_peermesh._udp",
        transport: any PeerTransport
    ) {
        self.init(myPeerID: peerID, service: service, transport: transport)
    }

    // MARK: Core binding

    /// The shared core, once an advertiser/browser has attached this session.
    var core: CompatCore? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _core
    }

    /// Adopt this session as `core`'s delegate target. Called from
    /// `browser.invitePeer(_:to:)` and the advertiser's `invitationHandler`.
    func bind(to core: CompatCore) {
        // The advertiser/browser's serviceType always wins — MCSession never
        // carried a service type, so a standalone-constructed MultipeerSession
        // parks with a placeholder until an advertiser/browser binds it. This
        // is the designed flow, not an anomaly; log only in debug builds.
        #if DEBUG
        if placeholderService != core.serviceType {
            print("MPCCompat: session bound to serviceType '\(core.serviceType)' "
                + "(placeholder '\(placeholderService)' discarded — expected flow).")
        }
        #endif
        stateLock.lock()
        _core = core
        stateLock.unlock()
        core.attachSession(self)
    }

    /// Update `connectedPeers` (called by the core on its serial delegate queue).
    func setConnected(peer: PeerID, connected: Bool) {
        stateLock.lock()
        _connectedPeers.removeAll { $0 == peer }
        if connected { _connectedPeers.append(peer) }
        stateLock.unlock()
    }

    // MARK: MCSession-shaped API

    /// Enqueue `data` for delivery (MCSession's `send` is synchronous).
    ///
    /// Mode mapping (DD-7): MCSession `.reliable` is guaranteed FIFO per pair →
    /// `Delivery.reliableOrdered`; `.unreliable` → `Delivery.datagram`. Throws
    /// only when this session is not attached to a running advertiser/browser
    /// (no route exists); transient delivery failures surface on the delegate
    /// path, as they do in MCSession.
    public func send(_ data: Data, toPeers peerIDs: [PeerID], with mode: SendDataMode) throws {
        guard let core else { throw PeerMeshError.peerUnreachable(myPeerID) }
        // MPC's .unreliable allowed large payloads (raw UDP + IP
        // fragmentation); PeerMesh datagrams are honest about the MTU and
        // refuse them. Oversized unreliable sends degrade to .reliable —
        // unordered, guaranteed: a superset of MPC's "may be dropped"
        // promise, and the closest semantics that still deliver.
        let delivery: Delivery
        if mode == .reliable {
            delivery = .reliableOrdered
        } else if data.count > Delivery.maxDatagramPayload {
            delivery = .reliable
        } else {
            delivery = .datagram
        }
        core.send(data, to: peerIDs, delivery: delivery)
    }

    /// `MCSession.sendResource` analog. Returns a live `Progress` immediately.
    ///
    /// Semantic delta vs MCSession: the completion handler fires when the
    /// sender finishes streaming the file (or on error/cancel), not on
    /// confirmed recipient receipt.
    public func sendResource(
        at resourceURL: URL,
        withName resourceName: String,
        toPeer peerID: PeerID,
        withCompletionHandler completionHandler: ((Error?) -> Void)? = nil
    ) -> Progress? {
        guard let core else {
            completionHandler?(PeerMeshError.peerUnreachable(peerID))
            return nil
        }
        return core.sendResource(
            at: resourceURL, name: resourceName, to: peerID,
            completion: completionHandler)
    }

    /// `MCSession.startStream` analog. Not yet bridged: the `NSStream` adapter
    /// over `PeerByteStream` (FR-18) is future work — TODO(compat-nsstream-bridge).
    /// Modern callers should use `PeerSession.openStream` (byte streams
    /// themselves are implemented; only the `NSStream` shim is not).
    public func startStream(withName streamName: String, toPeer peerID: PeerID) throws -> OutputStream {
        throw PeerMeshError.unimplemented("MultipeerSession.startStream")
    }

    public func disconnect() {
        // MCSession semantics: drop session connections/membership ONLY.
        // Advertiser/browser (independent objects in MPC) keep running, and
        // the underlying PeerSession + transport survive so a re-invite still
        // knows the peer's endpoint. Full teardown belongs to the app-level
        // stop path (advertiser/browser stop + this), which the core folds
        // into leaveSession + stopped discovery.
        core?.leaveSession()
        stateLock.lock()
        _connectedPeers.removeAll()
        stateLock.unlock()
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
///
/// Deliberately NOT `Sendable` — the
/// real MCSessionDelegate predates concurrency annotations, and requiring it
/// would force the requirement onto every migrated conformer. Callbacks
/// arrive on the compat serial delegate queue; thread-safety is the
/// bridge's job, not the conformer's.
public protocol MultipeerSessionDelegate: AnyObject {
    func session(_ session: MultipeerSession, peer peerID: PeerID, didChange state: MultipeerSession.PeerState)
    func session(_ session: MultipeerSession, didReceive data: Data, fromPeer peerID: PeerID)
    func session(_ session: MultipeerSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: PeerID)
    func session(_ session: MultipeerSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: PeerID, with progress: Progress)
    func session(_ session: MultipeerSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: PeerID, at localURL: URL?, withError error: Error?)
}

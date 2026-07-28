import Foundation
import Stromo

/// Near-drop-in replacement for `MCNearbyServiceAdvertiser` (FR-24).
///
/// Attaches (with any ``MultipeerSession`` / ``NearbyServiceBrowser`` built from
/// the same `PeerID`) to a shared ``CompatCore`` keyed on `(peerID, serviceType)`,
/// so all three drive one underlying `PeerSession`.
public final class NearbyServiceAdvertiser: @unchecked Sendable {
    public weak var delegate: (any NearbyServiceAdvertiserDelegate)?

    public let myPeerID: PeerID
    public let discoveryInfo: [String: String]?
    public let serviceType: String

    private let transport: (any PeerTransport)?
    private let lock = NSLock()
    private var coreRef: CompatCore?

    /// Designated initializer (internal): supports transport injection for tests.
    init(
        peer myPeerID: PeerID,
        discoveryInfo: [String: String]?,
        serviceType: String,
        transport: (any PeerTransport)?
    ) {
        self.myPeerID = myPeerID
        self.discoveryInfo = discoveryInfo
        self.serviceType = serviceType
        self.transport = transport
    }

    public convenience init(peer myPeerID: PeerID, discoveryInfo: [String: String]?, serviceType: String) {
        self.init(peer: myPeerID, discoveryInfo: discoveryInfo, serviceType: serviceType, transport: nil)
    }

    /// The shared core, resolved (and registered as its advertiser) on first use.
    var core: CompatCore {
        lock.lock()
        defer { lock.unlock() }
        if let core = coreRef { return core }
        let core = CompatRegistry.shared.core(
            peer: myPeerID, serviceType: serviceType, transport: transport)
        core.attachAdvertiser(self)
        coreRef = core
        return core
    }

    public func startAdvertisingPeer() {
        let core = self.core
        core.attachAdvertiser(self)
        core.startAdvertising(metadata: discoveryInfo ?? [:])
    }

    public func stopAdvertisingPeer() {
        coreRef?.stopAdvertising()
    }
}

public protocol NearbyServiceAdvertiserDelegate: AnyObject {
    func advertiser(
        _ advertiser: NearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: PeerID,
        withContext context: Data?,
        invitationHandler: @escaping @Sendable (Bool, MultipeerSession?) -> Void
    )
    func advertiser(_ advertiser: NearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error)
}

/// Near-drop-in replacement for `MCNearbyServiceBrowser` (FR-24).
public final class NearbyServiceBrowser: @unchecked Sendable {
    public weak var delegate: (any NearbyServiceBrowserDelegate)?

    public let myPeerID: PeerID
    public let serviceType: String

    private let transport: (any PeerTransport)?
    private let lock = NSLock()
    private var coreRef: CompatCore?

    /// Designated initializer (internal): supports transport injection for tests.
    init(peer myPeerID: PeerID, serviceType: String, transport: (any PeerTransport)?) {
        self.myPeerID = myPeerID
        self.serviceType = serviceType
        self.transport = transport
    }

    public convenience init(peer myPeerID: PeerID, serviceType: String) {
        self.init(peer: myPeerID, serviceType: serviceType, transport: nil)
    }

    /// The shared core, resolved (and registered as its browser) on first use.
    var core: CompatCore {
        lock.lock()
        defer { lock.unlock() }
        if let core = coreRef { return core }
        let core = CompatRegistry.shared.core(
            peer: myPeerID, serviceType: serviceType, transport: transport)
        core.attachBrowser(self)
        coreRef = core
        return core
    }

    public func startBrowsingForPeers() {
        let core = self.core
        core.attachBrowser(self)
        core.startBrowsing()
    }

    public func stopBrowsingForPeers() {
        coreRef?.stopBrowsing()
    }

    public func invitePeer(
        _ peerID: PeerID,
        to session: MultipeerSession,
        withContext context: Data?,
        timeout: TimeInterval
    ) {
        let core = self.core
        // Adopt the caller's session as the core's delegate target, exactly as
        // MC associates the invited-with session with the resulting connection.
        session.bind(to: core)
        core.invite(peerID: peerID, context: context, timeout: timeout)
    }
}

public protocol NearbyServiceBrowserDelegate: AnyObject {
    func browser(
        _ browser: NearbyServiceBrowser,
        foundPeer peerID: PeerID,
        withDiscoveryInfo info: [String: String]?
    )
    func browser(_ browser: NearbyServiceBrowser, lostPeer peerID: PeerID)
    func browser(_ browser: NearbyServiceBrowser, didNotStartBrowsingForPeers error: Error)
}

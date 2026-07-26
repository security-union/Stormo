import Foundation
import PeerMesh

/// Near-drop-in replacement for `MCNearbyServiceAdvertiser` (FR-24).
public final class NearbyServiceAdvertiser: @unchecked Sendable {
    public weak var delegate: (any NearbyServiceAdvertiserDelegate)?

    public let myPeerID: PeerID
    public let discoveryInfo: [String: String]?
    public let serviceType: String

    public init(peer myPeerID: PeerID, discoveryInfo: [String: String]?, serviceType: String) {
        self.myPeerID = myPeerID
        self.discoveryInfo = discoveryInfo
        self.serviceType = serviceType
    }

    public func startAdvertisingPeer() {
        // TODO(Phase 2): bridge to PeerSession.startAdvertising(metadata:) and
        // pump PeerSession.invitations into didReceiveInvitationFromPeer.
    }

    public func stopAdvertisingPeer() {
        // TODO(Phase 2): bridge to PeerSession.stopAdvertising().
    }
}

public protocol NearbyServiceAdvertiserDelegate: AnyObject, Sendable {
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

    public init(peer myPeerID: PeerID, serviceType: String) {
        self.myPeerID = myPeerID
        self.serviceType = serviceType
    }

    public func startBrowsingForPeers() {
        // TODO(Phase 2): bridge to PeerSession.startBrowsing(), pump
        // discoveries into foundPeer/lostPeer.
    }

    public func stopBrowsingForPeers() {
        // TODO(Phase 2): bridge to PeerSession.stopBrowsing().
    }

    public func invitePeer(
        _ peerID: PeerID,
        to session: MultipeerSession,
        withContext context: Data?,
        timeout: TimeInterval
    ) {
        // TODO(Phase 2): bridge to PeerSession.invite(_:context:timeout:).
    }
}

public protocol NearbyServiceBrowserDelegate: AnyObject, Sendable {
    func browser(
        _ browser: NearbyServiceBrowser,
        foundPeer peerID: PeerID,
        withDiscoveryInfo info: [String: String]?
    )
    func browser(_ browser: NearbyServiceBrowser, lostPeer peerID: PeerID)
    func browser(_ browser: NearbyServiceBrowser, didNotStartBrowsingForPeers error: Error)
}

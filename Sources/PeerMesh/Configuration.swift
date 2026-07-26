import Foundation

/// The Bonjour service a session advertises and browses (FR-1, FR-2).
public struct ServiceDescriptor: Hashable, Sendable {
    /// Bonjour service type, e.g. `"_myapp._udp"`. Must also be declared under
    /// `NSBonjourServices` in the app's Info.plist (C-4).
    public let type: String

    public init(type: String) {
        self.type = type
    }
}

extension ServiceDescriptor: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(type: value)
    }
}

/// Peer authentication policy (FR-21, DD-2). Encryption is always on (FR-19);
/// this only selects how peers are *authenticated*.
public enum TrustPolicy: Sendable {
    /// Zero-configuration default with MultipeerConnectivity-equivalent
    /// ergonomics: any peer certificate is accepted and its key hash recorded;
    /// authorization is the user accepting the invitation. TOFU continuity
    /// warnings fire if a known peer's key changes.
    case automatic

    /// Short-code confirmation bound to the TLS transcript (active-MITM
    /// resistant, no PKI). Opt-in.
    case pairingCode

    /// App-provisioned trust for managed fleets: only peers whose certificate
    /// (or issuing app CA) matches a pinned entry are admitted. Opt-in.
    case pinned(certificates: [Data])
}

/// Session topology strategy (FR-10, FR-11, DD-3).
public enum SessionTopology: Sendable {
    /// Every peer connects to every other peer. Default; supports ≥ 32 peers.
    case fullMesh(maxPeers: Int)

    /// A host relays traffic between peers; scales to ≥ 128 peers.
    case hostRelay(host: HostSelection)

    public enum HostSelection: Sendable {
        case elected
        case fixed(PeerID)
    }

    /// The default topology: full mesh, 32-peer ceiling (QA-2).
    public static let `default`: SessionTopology = .fullMesh(maxPeers: 32)
}

// Delivery, Recipients, PeerMeshError, Signal, and ProtocolEngine live in the
// sans-I/O PeerMeshProtocol target (DD-6) and are re-exported by this module.

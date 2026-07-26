import Foundation
#if canImport(Network)
import Network
#endif

/// Primary transport (DD-1): one QUIC connection per peer pair over
/// `NWConnection` + `NWProtocolQUIC`, Bonjour discovery via `NWBrowser` /
/// `NWListener`, peer-to-peer Wi-Fi via `includePeerToPeer` (FR-3).
///
/// Status: Step 3 of the transport plan — implemented after the runtime shell
/// is proven over `InMemoryTransport` (tier 1.5) and validated first over
/// loopback (tier 2, Spikes S-3/S-6), then AWDL on hardware (tier 3, S-1).
/// If S-1 fails, `TCPTLSTransport` is promoted to primary (design doc §8).
public struct QUICTransport: PeerTransport {
    public let inboundConnections: AsyncStream<any PeerConnection>

    public init() {
        // TODO(Step 3): yield connections accepted by the NWListener.
        self.inboundConnections = AsyncStream { _ in }
    }

    public func startAdvertising(
        service: ServiceDescriptor,
        metadata: [String: String],
        identity: PeerIdentity
    ) async throws {
        // TODO(Step 3): NWListener with QUIC parameters + .service(type:),
        // NWTXTRecord from metadata, includePeerToPeer = true, local identity
        // from self-signed cert (Step 2), Local Network permission surfacing
        // (FR-4).
        throw PeerMeshError.unimplemented("QUICTransport.startAdvertising")
    }

    public func stopAdvertising() async {}

    public func discoveries(service: ServiceDescriptor) async throws -> AsyncStream<DiscoveryEvent> {
        // TODO(Step 3): NWBrowser(.bonjourWithTXTRecord), dedup across
        // interfaces, map TXT records to DiscoveredPeer metadata.
        throw PeerMeshError.unimplemented("QUICTransport.discoveries")
    }

    public func stopBrowsing() async {}

    public func connect(
        to peer: DiscoveredPeer,
        identity: PeerIdentity,
        trust: TrustPolicy
    ) async throws -> any PeerConnection {
        // TODO(Step 3): NWMultiplexGroup with NWProtocolQUIC.Options (alpn
        // "peermesh"), sec_protocol_options_set_local_identity (DD-2), verify
        // block per TrustPolicy, control stream + per-message streams (DD-7),
        // datagram flow for `.datagram` delivery.
        throw PeerMeshError.unimplemented("QUICTransport.connect")
    }
}

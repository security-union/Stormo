import Foundation
import Testing

import StormoTestKit

@testable import Stormo

// =============================================================================
// Disconnection detection (FR-14 bound) — the three departure shapes
// =============================================================================
//
// 1. Graceful leave  — the peer sends Leave signals: survivors observe `.left`
//    IMMEDIATELY, no timeout involved. Tested here at mesh scale (in-memory).
// 2. Abrupt close    — the peer vanishes without a Leave but the transport
//    still closes (crashed app whose OS tore the connection down): survivors
//    observe `.left` as soon as the close propagates. Tested here over real
//    QUIC via `KillSwitchTransport`.
// 3. True silence    — the peer stops responding entirely (radio walk-away,
//    SIGKILL): detection falls to the connection-level heartbeats, which are
//    ALWAYS ON (failure mode 9: QUIC PINGs every 1 s via
//    `quicEnableKeepalive`, 5 s idle timeout ⇒ a dead peer surfaces as a
//    connection failure after ~5 missed PINGs). Loopback cannot fake silence
//    inside one process, so this shape is asserted cross-process in
//    `Scripts/e2e-cli.sh` (kill -9 the lingering joiner; host must observe
//    `.left` within 10 s).
//
// Engine-level liveness beyond the transport bound stays TODO(liveness).
// =============================================================================

@Suite("Mesh disconnection — graceful leave (InMemoryTransport)")
struct MeshDisconnectionTests {

    @Test("One peer leaves an 8-mesh: every survivor observes .left; mesh stays reliable")
    func gracefulMeshDeparture() async throws {
        let n = 8
        let hub = InMemoryTransport.Hub()
        let sessions = (0 ..< n).map { i in
            PeerSession(
                identity: PeerIdentity(name: "peer-\(i)"),
                service: "_mesh._udp",
                transport: InMemoryTransport(hub: hub))
        }
        _ = try await formMesh(sessions)
        let departed = await sessions[0].identity.id

        // Watchers first, so the .left events cannot be missed.
        let watchers = sessions.dropFirst().map { session in
            Task<Bool, Never> {
                for await event in session.membership {
                    if case .left(let id) = event, id == departed { return true }
                }
                return false
            }
        }

        let leftAt = Date()
        await sessions[0].leave()

        // Deterministic: driven by Leave signals, never by a timeout. The
        // deadline below only bounds the FAILURE case.
        let deadline = Date().addingTimeInterval(10)
        for session in sessions.dropFirst() {
            while await session.members.contains(departed) {
                guard Date() < deadline else {
                    Issue.record("a survivor still lists the departed peer after 10 s")
                    return
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        let detection = Date().timeIntervalSince(leftAt)
        for watcher in watchers { #expect(await watcher.value, "survivor missed the .left event") }
        #expect(detection < 5, "graceful departure took \(detection)s — should be immediate")
        #expect(await sessions[0].members.isEmpty)
        for session in sessions.dropFirst() {
            #expect(await session.members.count == n - 2)
        }

        // The surviving mesh must still honor the full reliability contract.
        let survivors = Array(sessions.dropFirst())
        let survivorIDs = Array(1 ..< n)
        let (inboxes, corrupt, _) = try await pump(
            survivors, delivery: .reliableOrdered, messagesPerSender: 12,
            size: { _ in 256 }, indices: survivorIDs)
        assertMeshDelivery(
            inboxes: inboxes, corrupt: corrupt, delivery: .reliableOrdered,
            messagesPerSender: 12, ordered: true, indices: survivorIDs)

        for session in sessions { await session.disconnect() }
    }
}

#if canImport(Network) && canImport(Security)

/// Test-side transport decorator that records every live connection (dialed
/// and accepted) and can sever them all at the TRANSPORT level — no Leave
/// signal, no session teardown. The wire shape of a crashed process whose OS
/// closed the connection out from under it.
final class KillSwitchTransport: PeerTransport, @unchecked Sendable {
    private let base: any PeerTransport
    private let captured = Locked<[any PeerConnection]>([])
    let inboundConnections: AsyncStream<any PeerConnection>

    init(base: any PeerTransport) {
        self.base = base
        let (stream, continuation) = AsyncStream<any PeerConnection>.makeStream()
        self.inboundConnections = stream
        let captured = self.captured
        let baseInbound = base.inboundConnections
        Task {
            for await connection in baseInbound {
                captured.withLock { $0.append(connection) }
                continuation.yield(connection)
            }
            continuation.finish()
        }
    }

    func startAdvertising(
        service: ServiceDescriptor, metadata: [String: String], identity: PeerIdentity
    ) async throws {
        try await base.startAdvertising(service: service, metadata: metadata, identity: identity)
    }

    func stopAdvertising() async { await base.stopAdvertising() }

    func discoveries(service: ServiceDescriptor) async throws -> AsyncStream<DiscoveryEvent> {
        try await base.discoveries(service: service)
    }

    func stopBrowsing() async { await base.stopBrowsing() }

    func connect(
        to peer: DiscoveredPeer, identity: PeerIdentity, trust: TrustPolicy
    ) async throws -> any PeerConnection {
        let connection = try await base.connect(to: peer, identity: identity, trust: trust)
        captured.withLock { $0.append(connection) }
        return connection
    }

    /// Severs every captured connection without any protocol goodbye.
    func kill() async {
        for connection in captured.value { await connection.close() }
    }
}

@Suite("Mesh disconnection — abrupt loss (loopback QUIC)", .serialized)
struct QUICDisconnectionTests {

    @Test("Connection dies without a Leave signal: survivor observes .left promptly")
    func abruptConnectionLoss() async throws {
        guard QUICTransport.isTLSIdentityAvailable(for: PeerIdentity(name: "probe")) else {
            print("[skip] QUIC: no TLS identity in this environment")
            return
        }
        let rendezvous = Rendezvous()
        let survivor = PeerSession(
            identity: PeerIdentity(name: "peer-0"), service: "_mesh._udp",
            transport: QUICTransport(configuration: .init(discovery: .rendezvous(rendezvous))))
        let killSwitch = KillSwitchTransport(
            base: QUICTransport(configuration: .init(discovery: .rendezvous(rendezvous))))
        let victim = PeerSession(
            identity: PeerIdentity(name: "peer-1"), service: "_mesh._udp",
            transport: killSwitch)

        _ = try await formMesh([survivor, victim])
        let victimID = await victim.identity.id

        let watcher = Task<Bool, Never> {
            for await event in survivor.membership {
                if case .left(let id) = event, id == victimID { return true }
            }
            return false
        }

        let killedAt = Date()
        await killSwitch.kill()

        // Close propagation, not heartbeat expiry: well under the 5 s idle
        // timeout. (The true-silence path — no close at all — is the
        // cross-process kill -9 scenario in Scripts/e2e-cli.sh.)
        let deadline = Date().addingTimeInterval(10)
        while await survivor.members.contains(victimID), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let detection = Date().timeIntervalSince(killedAt)
        #expect(
            await !survivor.members.contains(victimID),
            "survivor still lists the dead peer after \(detection)s")
        #expect(await watcher.value, "survivor missed the .left event")
        #expect(detection < 10, "abrupt-close detection took \(detection)s")

        await survivor.disconnect()
        await victim.disconnect()
    }
}

#endif

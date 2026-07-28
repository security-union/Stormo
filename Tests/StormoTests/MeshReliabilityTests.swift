import Foundation
import Testing

import StormoTestKit

@testable import Stormo

// =============================================================================
// N-peer mesh reliability (QA-2 / QA-8) — what these suites prove and how
// =============================================================================
//
// Both suites assert ONE contract through the harness in MeshHarness.swift:
// N sessions form a full mesh (peer i invites peer j iff i < j — glare-free;
// FR-12's simultaneous-dial tie-break is tested elsewhere), every peer
// broadcasts self-verifying payloads to `.all` concurrently, and every inbox
// is audited for:
//
//   1. exactly-once   — per (receiver, sender) link the seq set is exactly
//                       0..<M: loss and duplication in a single check;
//   2. integrity      — payload bodies are regenerated from (sender, seq) and
//                       byte-compared, so truncation/corruption/frame-bleed
//                       fail even when the count is right;
//   3. attribution    — the envelope's claimed sender == the wire sender;
//   4. ordering       — `.reliableOrdered` arrivals strictly increase per
//                       sender; plain `.reliable` promises no order and is
//                       deliberately NOT order-checked;
//   5. clean teardown — membership drains to zero on every peer, and (QUIC)
//                       the dedicated-stream open/retire ledger balances.
//
// Measured 2026-07-27, Apple-silicon dev machine, serialized run
// (`swift test --no-parallel`). The default parallel run contends for cores
// and inflates per-case times ~40x — use it for correctness, never for
// benchmark numbers (S-6 nightly is the formal benchmark home).
//
// In-memory sweep (N = 3...32, all passing; throughput = aggregate reliable):
//
//   | peers | links | formation | throughput |
//   |------:|------:|----------:|-----------:|
//   |     3 |     3 |   <0.01 s |  2.5k msg/s|
//   |     8 |    28 |   <0.01 s |   21k msg/s|
//   |    16 |   120 |    0.01 s |   21k msg/s|
//   |    24 |   276 |    0.07 s |   22k msg/s|
//   |    32 |   496 |    0.19 s |   23k msg/s|
//
// Findings: formation follows the N² link count with no cliff through QA-2's
// 32-peer target (QA-8's 60 s budget is met ~40x over). Throughput plateaus
// at ~22k msg/s from ~9 peers — CPU saturation (FlatBuffers encode + body
// verification per message), not a protocol limit: zero loss, duplication,
// misordering, or misattribution at any N.
//
// QUIC triangle (3 peers, loopback, ladder cycling 64 B → 1.2 KB → 4.5 KB →
// channelMaxPayload → +1 → 2 MiB so consecutive seqs cross the channel ↔
// dedicated-stream boundary, failure mode 13):
//
//   |                        | .reliable | .reliableOrdered |
//   |------------------------|----------:|-----------------:|
//   | delivered              |   72 / 72 |          72 / 72 |
//   | volume                 |  48.1 MiB |         48.1 MiB |
//   | throughput             | 23.2 MiB/s|        36.4 MiB/s|
//   | order across paths     |       n/a |             held |
//   | zombie streams at exit |         0 |                0 |
//
// Findings: both boundary probes (channelMaxPayload exactly vs one byte
// over — two different code paths) deliver intact; ordered delivery survives
// small channel messages physically overtaking 2 MiB dedicated-stream
// messages (the DD-7 reorder buffer holds and releases); the open/retire
// counters balance after teardown, guarding the stream-leak bug class.
// =============================================================================

/// Tier 1.5: the QA-8 mesh simulation — N complete runtimes (engine, codec,
/// timers, effect executor) over `InMemoryTransport`, zero radios. Asserts
/// the full reliability contract (exactly-once, integrity, attribution,
/// per-sender order) at QA-2's 32-peer full-mesh size, with the
/// `ReorderingTransport` axis stressing the DD-7 reorder buffer.
///
/// `.serialized`: 31 concurrent mesh cases oversubscribe CI's ~3-core runner
/// — invites blow their 15 s timeout at N≈14+, and the starvation even breaks
/// the timing-sensitive DD-7 reordering test in the neighboring suite.
@Suite("Mesh reliability over InMemoryTransport", .serialized)
struct InMemoryMeshReliabilityTests {

    /// Channel-path rungs only: framing stress, the sub-MTU datagram boundary
    /// (TODO(datagrams)), and the remote-shutter preview still. The ≥ 1 MiB
    /// rungs are meaningless here — InMemoryTransport does not route by size;
    /// the real boundary is the QUIC triangle's job.
    static let channelLadder = [64, 1_200, 4_500]

    /// Monotonic sweep to QA-2's full-mesh size: every N in 3...32, so a
    /// scaling cliff (formation or delivery) names the exact N where it
    /// starts, plus the reorder-buffer stress case (DD-7) at N=3.
    static let matrix =
        (3 ... 32).map { (peers: $0, reordering: false) } + [(peers: 3, reordering: true)]

    @Test("N-peer full mesh: exactly-once, attribution, ordering", arguments: matrix)
    func fullMeshReliability(peers: Int, reordering: Bool) async throws {
        let testStart = Date()
        let hub = InMemoryTransport.Hub()
        let sessions = (0 ..< peers).map { i -> PeerSession in
            let base = InMemoryTransport(hub: hub)
            return PeerSession(
                identity: PeerIdentity(name: "peer-\(i)"),
                service: "_mesh._udp",
                transport: reordering ? ReorderingTransport(base: base) : base)
        }

        let formation = try await formMesh(sessions)
        print("MESH n=\(peers) reordering=\(reordering) formed in \(String(format: "%.2f", formation))s")

        // Fixed across the sweep so per-N metrics are comparable.
        let messagesPerSender = 12
        for delivery in [Delivery.reliable, .reliableOrdered] {
            let (inboxes, corrupt, metrics) = try await pump(
                sessions, delivery: delivery, messagesPerSender: messagesPerSender,
                size: { seq in Self.channelLadder[seq % Self.channelLadder.count] })
            assertMeshDelivery(
                inboxes: inboxes, corrupt: corrupt, delivery: delivery,
                messagesPerSender: messagesPerSender, ordered: delivery == .reliableOrdered)
            print("MESH n=\(peers) reordering=\(reordering) \(delivery): \(metrics.summary)")
        }

        for session in sessions { await session.disconnect() }
        #expect(await meshDrained(sessions), "membership did not drain after disconnect")

        if peers == 32 {
            let elapsed = Date().timeIntervalSince(testStart)
            #expect(elapsed < 60, "QA-8: 32-peer mesh simulation took \(elapsed)s (budget 60s)")
        }
    }
}

#if canImport(Network) && canImport(Security)

/// Tier 2: the same contract over REAL loopback QUIC (Rendezvous discovery —
/// no mDNS). What the in-memory tier is blind to lives here: the per-direction
/// message channel vs dedicated-stream routing at `channelMaxPayload`
/// (failure mode 13), the FIN two-step, and stream retirement. Serialized:
/// binds real sockets and reads the global dedicated-stream counters.
@Suite("Mesh reliability over loopback QUIC", .serialized)
struct QUICMeshReliabilityTests {

    @Test("3-peer triangle: full size ladder across both stream paths")
    func quicTriangle() async throws {
        guard QUICTransport.isTLSIdentityAvailable(for: PeerIdentity(name: "probe")) else {
            print("[skip] QUIC: no TLS identity in this environment")
            return
        }
        let rendezvous = Rendezvous()
        let sessions = (0 ..< 3).map { i in
            PeerSession(
                identity: PeerIdentity(name: "peer-\(i)"),
                service: "_mesh._udp",
                transport: QUICTransport(configuration: .init(discovery: .rendezvous(rendezvous))))
        }

        let formation = try await formMesh(sessions)
        print("MESH quic n=3 formed in \(String(format: "%.2f", formation))s")

        // The ladder pinned to the transport's seams: channel rungs, the exact
        // routing boundary (last-on-channel / first-dedicated), and a payload
        // comfortably inside the dedicated-stream path. Cycling it makes
        // consecutive seqs of ONE sender cross the boundary, so for
        // `.reliableOrdered` a small channel message physically beats the big
        // dedicated-stream message preceding it in sequence — the reorder
        // buffer must hold and release (DD-7). Nothing else forces that.
        let ladder = [
            64, 1_200, 4_500,
            QUICConnection.channelMaxPayload,
            QUICConnection.channelMaxPayload + 1,
            2 << 20,
        ]
        let messagesPerSender = 12  // two full ladder cycles per sender

        for delivery in [Delivery.reliable, .reliableOrdered] {
            let (inboxes, corrupt, metrics) = try await pump(
                sessions, delivery: delivery, messagesPerSender: messagesPerSender,
                size: { seq in ladder[seq % ladder.count] }, timeout: 120)
            assertMeshDelivery(
                inboxes: inboxes, corrupt: corrupt, delivery: delivery,
                messagesPerSender: messagesPerSender, ordered: delivery == .reliableOrdered)
            print("MESH quic n=3 \(delivery): \(metrics.summary)")
        }

        for session in sessions { await session.disconnect() }
        #expect(await meshDrained(sessions), "membership did not drain after disconnect")

        // No zombie dedicated streams (failure mode 13). Retirement is
        // asynchronous and the churn suite moves the same global counters, so
        // assert eventual convergence, never deltas.
        let deadline = Date().addingTimeInterval(30)
        while QUICConnection.dedicatedOpened.value != QUICConnection.dedicatedRetired.value,
            Date() < deadline
        {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let opened = QUICConnection.dedicatedOpened.value
        let retired = QUICConnection.dedicatedRetired.value
        #expect(retired == opened, "zombie streams: \(opened - retired) opened, never retired")
    }
}

#endif

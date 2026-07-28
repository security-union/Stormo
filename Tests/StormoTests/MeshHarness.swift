import Foundation
import Testing

import Stormo

/// N-peer mesh test harness (QA-2 / QA-8): full-mesh formation over any
/// `PeerTransport`, a traffic pump with self-verifying payloads, and the
/// reliability assertions (exactly-once, integrity, attribution, per-sender
/// order). Shared by the InMemoryTransport mesh simulation and the real-QUIC
/// triangle so both tiers assert the identical contract.

// MARK: - Self-verifying payload envelope

/// `sender UInt16 | seq UInt32 | length UInt32 | body` (big-endian), where
/// body is deterministic bytes seeded from (sender, seq). The receiver
/// regenerates and byte-compares — count-based assertions cannot see
/// truncation, corruption, or frame-boundary bleed between the
/// `[len][header][len][payload]` units on the shared message channel.
enum MeshPayload {
    static let headerSize = 10

    static func make(sender: Int, seq: Int, size: Int) -> Data {
        precondition(size >= headerSize, "payload floor is the \(headerSize)-byte header")
        var data = Data(capacity: size)
        data.append(contentsOf: [UInt8(sender >> 8 & 0xFF), UInt8(sender & 0xFF)])
        appendUInt32(&data, UInt32(seq))
        appendUInt32(&data, UInt32(size))
        data.append(body(sender: sender, seq: seq, count: size - headerSize))
        return data
    }

    /// nil = corrupt: short, length mismatch (truncation), or body mismatch.
    static func decode(_ data: Data) -> (sender: Int, seq: Int)? {
        guard data.count >= headerSize else { return nil }
        let h = [UInt8](data.prefix(headerSize))
        let sender = Int(h[0]) << 8 | Int(h[1])
        let seq = Int(h[2]) << 24 | Int(h[3]) << 16 | Int(h[4]) << 8 | Int(h[5])
        let length = Int(h[6]) << 24 | Int(h[7]) << 16 | Int(h[8]) << 8 | Int(h[9])
        guard length == data.count else { return nil }
        guard data.dropFirst(headerSize) == body(sender: sender, seq: seq, count: length - headerSize)
        else { return nil }
        return (sender, seq)
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(contentsOf: [
            UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
            UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF),
        ])
    }

    /// SplitMix64 keyed by (sender, seq): cheap, deterministic, and distinct
    /// per message so cross-wired payloads can never verify.
    private static func body(sender: Int, seq: Int, count: Int) -> Data {
        var state = UInt64(sender) << 32 ^ UInt64(seq)
        var out = Data(capacity: count)
        while out.count < count {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            withUnsafeBytes(of: z) { out.append(contentsOf: $0.prefix(min(8, count - out.count))) }
        }
        return out
    }
}

// MARK: - Mesh formation

enum MeshHarnessError: Error, CustomStringConvertible {
    case inviteFailed(from: Int, to: Int, underlying: any Error)
    case formationTimeout(session: Int, members: Int, expected: Int)

    var description: String {
        switch self {
        case .inviteFailed(let from, let to, let underlying):
            return "peer-\(from) → peer-\(to) invite failed: \(underlying)"
        case .formationTimeout(let session, let members, let expected):
            return "peer-\(session) converged to \(members)/\(expected) members before the deadline"
        }
    }
}

/// Index baked into the test identities ("peer-3" → 3). Test plumbing only —
/// production code must never route on `displayName` (it is cosmetic), but
/// these tiers (Hub, Rendezvous) carry the advertised name faithfully.
func meshIndex(of displayName: String) -> Int? {
    guard displayName.hasPrefix("peer-") else { return nil }
    return Int(displayName.dropFirst(5))
}

/// Forms the full mesh: every session advertises AND browses; peer i invites
/// peer j exactly when i < j, so formation is deterministic and glare-free
/// (the FR-12 simultaneous-dial tie-break gets its own targeted test, not
/// noise here). Returns once EVERY session reports n-1 members (QA-2
/// membership convergence), or throws with the laggard named.
func formMesh(_ sessions: [PeerSession], timeout: TimeInterval = 30) async throws -> TimeInterval {
    let n = sessions.count
    let start = Date()

    let acceptors = sessions.map { session in
        Task { for await invitation in session.invitations { await invitation.accept() } }
    }
    defer { for acceptor in acceptors { acceptor.cancel() } }

    for session in sessions { try await session.startAdvertising(metadata: [:]) }
    for session in sessions { try await session.startBrowsing() }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for (i, session) in sessions.enumerated() where i < n - 1 {
            group.addTask {
                var invited = Set<PeerID>()
                try await withThrowingTaskGroup(of: Void.self) { invites in
                    for await event in session.discoveries {
                        // .found and .updated are one signal (failure mode 8).
                        let discovered: DiscoveredPeer?
                        switch event {
                        case .found(let peer), .updated(let peer): discovered = peer
                        case .lost: discovered = nil
                        }
                        guard let discovered,
                            let j = meshIndex(of: discovered.id.displayName), j > i,
                            invited.insert(discovered.id).inserted
                        else { continue }
                        invites.addTask {
                            do { _ = try await session.invite(discovered, timeout: 15) } catch {
                                throw MeshHarnessError.inviteFailed(from: i, to: j, underlying: error)
                            }
                        }
                        if invited.count == n - 1 - i { break }
                    }
                    try await invites.waitForAll()
                }
            }
        }
        try await group.waitForAll()
    }

    let deadline = start.addingTimeInterval(timeout)
    for (i, session) in sessions.enumerated() {
        while await session.members.count != n - 1 {
            guard Date() < deadline else {
                throw MeshHarnessError.formationTimeout(
                    session: i, members: await session.members.count, expected: n - 1)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    return Date().timeIntervalSince(start)
}

// MARK: - Traffic pump

struct MeshDelivery: Sendable {
    let claimedSender: Int  // from the envelope
    let wireSender: Int?  // from InboundMessage.sender
    let seq: Int
    let delivery: Delivery
    let bytes: Int
}

struct PumpMetrics: Sendable {
    let elapsed: TimeInterval
    let messages: Int
    let bytes: Int

    var summary: String {
        String(
            format: "%d msgs / %.1f MiB in %.2fs (%.0f msg/s, %.1f MiB/s)",
            messages, Double(bytes) / 1_048_576, elapsed,
            Double(messages) / max(elapsed, 0.001),
            Double(bytes) / 1_048_576 / max(elapsed, 0.001))
    }
}

/// Every peer broadcasts `messagesPerSender` payloads to `.all`, sizes chosen
/// per-seq by `size`. Sends are sequential WITHIN a sender (so the runtime's
/// sequence stamping matches our seq numbers) and concurrent ACROSS senders —
/// interleaving across the N×(N-1) directed links is where reliability bugs
/// live. Receipt collection is deadline-bounded: on loss the pump returns the
/// partial inboxes for the assertions to name precisely, it never hangs.
/// `indices` maps array position → the peer-name index each session stamps in
/// its envelopes (default positional). Pass it when pumping a SUBSET of a
/// mesh — e.g. survivors [1...] after peer-0 departed — so envelope sender
/// ids still match the sessions' "peer-N" identities.
func pump(
    _ sessions: [PeerSession],
    delivery: Delivery,
    messagesPerSender: Int,
    size: @escaping @Sendable (Int) -> Int,
    indices: [Int]? = nil,
    timeout: TimeInterval = 60
) async throws -> (inboxes: [[MeshDelivery]], corrupt: Int, metrics: PumpMetrics) {
    let n = sessions.count
    let ids = indices ?? Array(0 ..< n)
    let expectedPerReceiver = (n - 1) * messagesPerSender
    let boxes = sessions.map { _ in Locked<[MeshDelivery]>([]) }
    let corrupt = Locked(0)
    let start = Date()

    let collectors = sessions.enumerated().map { receiver, session in
        Task {
            for await message in session.messages {
                guard let (sender, seq) = MeshPayload.decode(message.payload) else {
                    corrupt.withLock { $0 += 1 }
                    continue
                }
                let record = MeshDelivery(
                    claimedSender: sender,
                    wireSender: meshIndex(of: message.sender.displayName),
                    seq: seq, delivery: message.delivery, bytes: message.payload.count)
                let full = boxes[receiver].withLock { box -> Bool in
                    box.append(record)
                    return box.count >= expectedPerReceiver
                }
                if full { break }
            }
        }
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for (position, session) in sessions.enumerated() {
            let sender = ids[position]
            group.addTask {
                for seq in 0 ..< messagesPerSender {
                    try await session.send(
                        MeshPayload.make(sender: sender, seq: seq, size: size(seq)),
                        to: .all, delivery: delivery)
                }
            }
        }
        try await group.waitForAll()
    }

    // send() returns before transport handoff (TODO(send-ack)), so receipts
    // trail the send loop — drain until full or deadline.
    let deadline = start.addingTimeInterval(timeout)
    while boxes.contains(where: { $0.value.count < expectedPerReceiver }), Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    for collector in collectors { collector.cancel() }

    let inboxes = boxes.map(\.value)
    let metrics = PumpMetrics(
        elapsed: Date().timeIntervalSince(start),
        messages: inboxes.reduce(0) { $0 + $1.count },
        bytes: inboxes.reduce(0) { $0 + $1.reduce(0) { $0 + $1.bytes } })
    return (inboxes, corrupt.value, metrics)
}

// MARK: - Assertions

/// The reliability contract, per (receiver, sender) link:
/// - exactly-once: the seq multiset is exactly 0..<M (loss and duplication in
///   one check), with payload integrity already enforced by decode,
/// - attribution: the envelope's sender matches the wire sender,
/// - `ordered`: arrival order per sender is strictly increasing — asserted
///   only for `.reliableOrdered`; plain `.reliable` promises no order.
/// Violations aggregate per link so a failure names receiver/sender/seqs
/// instead of spamming one expectation per message.
func assertMeshDelivery(
    inboxes: [[MeshDelivery]],
    corrupt: Int,
    delivery: Delivery,
    messagesPerSender: Int,
    ordered: Bool,
    indices: [Int]? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let ids = indices ?? Array(0 ..< inboxes.count)
    #expect(corrupt == 0, "\(corrupt) corrupt/truncated payloads", sourceLocation: sourceLocation)

    for (position, inbox) in inboxes.enumerated() {
        let receiver = ids[position]
        var wrongDelivery = 0
        var misattributed = 0
        var arrivals: [Int: [Int]] = [:]  // sender → seqs in arrival order
        for record in inbox {
            if record.delivery != delivery { wrongDelivery += 1 }
            if record.wireSender != record.claimedSender { misattributed += 1 }
            arrivals[record.claimedSender, default: []].append(record.seq)
        }
        #expect(
            wrongDelivery == 0,
            "receiver \(receiver): \(wrongDelivery) records with delivery ≠ \(delivery)",
            sourceLocation: sourceLocation)
        #expect(
            misattributed == 0,
            "receiver \(receiver): \(misattributed) records whose envelope sender ≠ wire sender",
            sourceLocation: sourceLocation)

        for sender in ids where sender != receiver {
            let seqs = arrivals[sender] ?? []
            let unique = Set(seqs)
            let missing = Set(0 ..< messagesPerSender).subtracting(unique)
            let duplicates = seqs.count - unique.count
            let linkSummary =
                "receiver \(receiver) ← sender \(sender): \(seqs.count)/\(messagesPerSender) delivered, missing \(missing.sorted().prefix(10)), \(duplicates) duplicates"
            #expect(
                missing.isEmpty && duplicates == 0 && seqs.count == messagesPerSender,
                Comment(rawValue: linkSummary),
                sourceLocation: sourceLocation)
            if ordered {
                let orderSummary =
                    "receiver \(receiver) ← sender \(sender): out-of-order arrivals \(seqs.prefix(30))"
                #expect(
                    zip(seqs, seqs.dropFirst()).allSatisfy { $0 < $1 },
                    Comment(rawValue: orderSummary),
                    sourceLocation: sourceLocation)
            }
        }
    }
}

/// Post-disconnect drain: true once every session's membership is empty.
func meshDrained(_ sessions: [PeerSession], timeout: TimeInterval = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    for session in sessions {
        while await !session.members.isEmpty {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    return true
}

// MARK: - Dedicated-stream counter serialization

/// Umbrella for every suite that asserts on the process-global dedicated-
/// stream counters (`QUICConnection.dedicatedOpened`/`.dedicatedRetired`).
/// The churn suite's exact-delta expectations are only sound while no other
/// suite opens oversized-payload streams, and `.serialized` applies
/// recursively, so member suites never overlap. Any new suite that sends
/// payloads above `channelMaxPayload` over real QUIC must live here.
@Suite(.serialized)
enum DedicatedStreamCounterSuites {}

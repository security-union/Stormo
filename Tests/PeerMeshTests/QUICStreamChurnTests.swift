import Foundation
import Testing

@testable import Stromo

#if canImport(Network) && canImport(Security)

/// Message-churn soak (failure mode 13). Messages ride the persistent
/// channel, so churn no longer consumes the connection's lifetime stream
/// budget; oversized payloads take a dedicated stream, which must be retired
/// (no zombie handles). Related: TODO(churn-benchmark) measures the ceiling;
/// this asserts correctness at volume.
@Suite("QUIC stream churn", .serialized)
struct QUICStreamChurnTests {

    // No .timeLimit trait: it is iOS 16+ API and the floor is iOS 15 (the CI
    // job timeout bounds a hang instead).
    @Test("A session survives message churn far past the old per-stream budget")
    func churnPastInitialCredit() async throws {
        guard QUICTransport.isTLSIdentityAvailable(for: PeerIdentity(name: "probe")) else {
            print("[skip] QUIC: no TLS identity in this environment"); return
        }
        let smallCount = 2_200  // would exceed the old 2048 stream budget
        let bigPayload = Data(repeating: 0xB1, count: QUICConnection.channelMaxPayload + 1)

        let rv = Rendezvous()
        func t() -> QUICTransport { QUICTransport(configuration: .init(discovery: .rendezvous(rv))) }
        let camera = PeerSession(identity: PeerIdentity(name: "Camera"), service: "_churn._udp", transport: t())
        let monitor = PeerSession(identity: PeerIdentity(name: "Monitor"), service: "_churn._udp", transport: t())

        try await camera.startAdvertising(metadata: [:])
        let accept = Task { for await inv in camera.invitations { await inv.accept(); break } }
        try await monitor.startBrowsing()
        var discovered: DiscoveredPeer?
        for await event in monitor.discoveries {
            if case .found(let peer) = event { discovered = peer; break }
        }
        _ = try await monitor.invite(try #require(discovered), context: Data())
        await accept.value

        let received = Task<(small: Int, big: Int), Never> {
            var small = 0
            var big = 0
            for await message in camera.messages {
                if message.payload.count > QUICConnection.channelMaxPayload { big += 1 } else { small += 1 }
                if small == smallCount && big == 1 { break }
            }
            return (small, big)
        }

        // Bounded concurrency: the shape of a real frame-streaming sender.
        let width = 32
        var sendFailure: (index: Int, error: any Error)?
        await withTaskGroup(of: (Int, (any Error)?).self) { group in
            var next = 1
            var inFlight = 0
            while next <= smallCount || inFlight > 0 {
                while next <= smallCount && inFlight < width {
                    let n = next
                    next += 1
                    inFlight += 1
                    group.addTask {
                        do {
                            try await monitor.send(Data([UInt8(n % 256)]), delivery: .reliable)
                            return (n, nil)
                        } catch {
                            return (n, error)
                        }
                    }
                }
                if let (n, error) = await group.next() {
                    inFlight -= 1
                    if let error, sendFailure == nil { sendFailure = (n, error) }
                }
            }
        }
        // Oversized message: dedicated-stream fallback (FR-15 16 MB support).
        try await monitor.send(bigPayload, delivery: .reliable)

        if let sendFailure {
            Issue.record("send #\(sendFailure.index) failed: \(sendFailure.error)")
            received.cancel()
        }

        let counts = await received.value
        #expect(counts.small == smallCount)
        #expect(counts.big == 1)
        await monitor.disconnect()
        await camera.disconnect()

        // No zombie dedicated streams (failure mode 13): the oversized message
        // opened one handle per side; every opened handle must retire.
        // Retirement is asynchronous, so poll briefly before judging.
        let deadline = Date().addingTimeInterval(10)
        while QUICConnection.dedicatedOpened.value != QUICConnection.dedicatedRetired.value,
            Date() < deadline
        {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let opened = QUICConnection.dedicatedOpened.value
        let retired = QUICConnection.dedicatedRetired.value
        #expect(opened >= 2)  // big message: sender + receiver handles
        #expect(retired == opened, "zombie streams: \(opened - retired) opened, never retired")
    }

    // Lives in this serialized suite: it reads the global dedicated-stream
    // counters, which the churn test also moves — parallel suites would race.
    @Test("Sub-cap messages of every mode ride the channel; only oversized opens dedicated streams")
    func primitiveSelection() async throws {
        guard QUICTransport.isTLSIdentityAvailable(for: PeerIdentity(name: "probe")) else {
            print("[skip] QUIC: no TLS identity in this environment"); return
        }
        let rv = Rendezvous()
        func t() -> QUICTransport { QUICTransport(configuration: .init(discovery: .rendezvous(rv))) }
        let camera = PeerSession(identity: PeerIdentity(name: "Camera"), service: "_wire._udp", transport: t())
        let monitor = PeerSession(identity: PeerIdentity(name: "Monitor"), service: "_wire._udp", transport: t())

        try await camera.startAdvertising(metadata: [:])
        let accept = Task { for await inv in camera.invitations { await inv.accept(); break } }
        try await monitor.startBrowsing()
        var discovered: DiscoveredPeer?
        for await event in monitor.discoveries {
            if case .found(let peer) = event { discovered = peer; break }
        }
        _ = try await monitor.invite(try #require(discovered), context: Data())
        await accept.value

        let perMode = 20
        let receiver = Task<[Delivery: Int], Never> {
            var counts: [Delivery: Int] = [:]
            var oversized = 0
            for await message in camera.messages {
                if message.payload.count > QUICConnection.channelMaxPayload {
                    oversized += 1
                } else {
                    counts[message.delivery, default: 0] += 1
                }
                if oversized == 1, counts[.reliable] == perMode,
                    counts[.reliableOrdered] == perMode, counts[.datagram] == perMode
                { break }
            }
            return counts
        }

        let openedBefore = QUICConnection.dedicatedOpened.value

        for n in 0 ..< perMode {
            try await monitor.send(Data([UInt8(n)]), delivery: .reliable)
            try await monitor.send(Data([UInt8(n)]), delivery: .reliableOrdered)
            try await monitor.send(Data(repeating: UInt8(n), count: 600), delivery: .datagram)
        }
        // All three modes above must not have opened a single dedicated stream.
        #expect(QUICConnection.dedicatedOpened.value == openedBefore)

        // Oversized .reliable is the ONLY route to a dedicated message stream.
        try await monitor.send(
            Data(repeating: 0xE0, count: QUICConnection.channelMaxPayload + 1), delivery: .reliable)

        let counts = await receiver.value
        #expect(counts[.reliable] == perMode)
        #expect(counts[.reliableOrdered] == perMode)
        #expect(counts[.datagram] == perMode)
        #expect(QUICConnection.dedicatedOpened.value == openedBefore + 2)  // sender + receiver handles

        await monitor.disconnect()
        await camera.disconnect()
    }
}

#endif

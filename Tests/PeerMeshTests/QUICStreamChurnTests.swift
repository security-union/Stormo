import Foundation
import Testing

@testable import PeerMesh

#if canImport(Network) && canImport(Security)

/// Functional stream-churn soak (related: TODO(churn-benchmark) measures the
/// ceiling; this asserts correctness past the credit boundary).
///
/// Every message rides its own QUIC stream (DD-7) inside one connection whose
/// peers grant `initialMaxStreams* = 2048`. Credit comes back only when a
/// stream FULLY closes (both directions). A session that leaks stream closes
/// stalls at the initial limit — at remote-shutter's ~66 streams/sec that is
/// ~60 s into a healthy session, surfacing as sends timing out and then the
/// idle timeout collapsing the connection.
@Suite("QUIC stream churn", .serialized)
struct QUICStreamChurnTests {

    @Test("A session survives message churn past the initial stream credit (2048)", .timeLimit(.minutes(4)))
    func churnPastInitialCredit() async throws {
        guard QUICTransport.isTLSIdentityAvailable(for: PeerIdentity(name: "probe")) else {
            print("[skip] QUIC: no TLS identity in this environment"); return
        }
        let messageCount = 2_200  // past the 2048 initial stream limit

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

        let received = Task<Int, Never> {
            var count = 0
            for await _ in camera.messages {
                count += 1
                if count == messageCount { break }
            }
            return count
        }

        // Bounded concurrency: fast enough to cross the credit boundary in CI,
        // and the shape of a real frame-streaming sender.
        let width = 32
        var sendFailure: (index: Int, error: any Error)?
        await withTaskGroup(of: (Int, (any Error)?).self) { group in
            var next = 1
            var inFlight = 0
            while next <= messageCount || inFlight > 0 {
                while next <= messageCount && inFlight < width {
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
        if let sendFailure {
            Issue.record(
                "send #\(sendFailure.index) failed: \(sendFailure.error) — stream credit exhausted?")
            received.cancel()
        }

        #expect(await received.value == messageCount)
        await monitor.disconnect()
        await camera.disconnect()

        // No zombie streams (failure mode 13): every opened message-stream
        // handle must retire. Retirement is asynchronous (the sender's retire
        // follows the receiver's), so poll briefly before judging.
        let deadline = Date().addingTimeInterval(10)
        while QUICConnection.dedicatedOpened.value != QUICConnection.dedicatedRetired.value,
            Date() < deadline
        {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let opened = QUICConnection.dedicatedOpened.value
        let retired = QUICConnection.dedicatedRetired.value
        #expect(opened >= messageCount * 2)  // sender + receiver handles
        #expect(retired == opened, "zombie streams: \(opened - retired) opened, never retired")
    }
}

#endif

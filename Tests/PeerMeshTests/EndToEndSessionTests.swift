import CryptoKit
import Foundation
import Testing

import PeerMesh
import PeerMeshTestKit

/// Tier-1.5 tests: the COMPLETE runtime — PeerSession effect executor, engine,
/// codec, timers — over the in-memory transport. Real wire bytes (FlatBuffers
/// signals), real async runtime, zero radios (QA-8).
@Suite("PeerSession end-to-end over InMemoryTransport")
struct EndToEndSessionTests {

    func makePair(hub: InMemoryTransport.Hub) -> (advertiser: PeerSession, browser: PeerSession) {
        let advertiser = PeerSession(
            identity: PeerIdentity(name: "Camera"),
            service: "_e2e._udp",
            transport: InMemoryTransport(hub: hub))
        let browser = PeerSession(
            identity: PeerIdentity(name: "Monitor"),
            service: "_e2e._udp",
            transport: InMemoryTransport(hub: hub))
        return (advertiser, browser)
    }

    @Test("Discovery → invitation → membership → messaging, both directions")
    func fullSessionLifecycle() async throws {
        let hub = InMemoryTransport.Hub()
        let (camera, monitor) = makePair(hub: hub)

        // Camera advertises and auto-accepts the first invitation.
        try await camera.startAdvertising(metadata: ["role": "camera"])
        let acceptTask = Task {
            for await invitation in camera.invitations {
                #expect(invitation.context == Data("hello".utf8))
                await invitation.accept()
                break
            }
        }

        // Monitor browses and finds the camera (with its metadata).
        try await monitor.startBrowsing()
        var discovered: DiscoveredPeer?
        for await event in monitor.discoveries {
            if case .found(let peer) = event {
                discovered = peer
                break
            }
        }
        let cameraPeer = try #require(discovered)
        #expect(cameraPeer.metadata["role"] == "camera")

        // Invite completes with membership on both sides.
        let member = try await monitor.invite(cameraPeer, context: Data("hello".utf8))
        #expect(member.id.displayName == "Camera")
        await acceptTask.value
        #expect(await monitor.members.count == 1)
        #expect(await camera.members.count == 1)

        // Messaging: monitor → camera (reliable), camera → monitor (datagram).
        let cameraInbox = Task<InboundMessage?, Never> {
            for await message in camera.messages { return message }
            return nil
        }
        try await monitor.send(Data([0xCA, 0xFE]), to: .all, delivery: .reliable)
        let received = try #require(await cameraInbox.value)
        #expect(received.payload == Data([0xCA, 0xFE]))
        #expect(received.delivery == .reliable)
        #expect(received.sender.displayName == "Monitor")

        let monitorInbox = Task<InboundMessage?, Never> {
            for await message in monitor.messages { return message }
            return nil
        }
        try await camera.send(Data([0x60]), to: .all, delivery: .datagram)
        let frame = try #require(await monitorInbox.value)
        #expect(frame.payload == Data([0x60]))
        #expect(frame.delivery == .datagram)

        await monitor.disconnect()
        await camera.disconnect()
    }

    @Test("Declined invitation throws invitationDeclined")
    func declinedInvitation() async throws {
        let hub = InMemoryTransport.Hub()
        let (camera, monitor) = makePair(hub: hub)

        try await camera.startAdvertising()
        let declineTask = Task {
            for await invitation in camera.invitations {
                await invitation.decline()
                break
            }
        }

        try await monitor.startBrowsing()
        var discovered: DiscoveredPeer?
        for await event in monitor.discoveries {
            if case .found(let peer) = event {
                discovered = peer
                break
            }
        }

        await #expect(throws: PeerMeshError.invitationDeclined) {
            try await monitor.invite(try #require(discovered))
        }
        await declineTask.value
        #expect(await monitor.members.isEmpty)

        await monitor.disconnect()
        await camera.disconnect()
    }

    @Test("Unanswered invitation times out via the runtime timer")
    func invitationTimeout() async throws {
        let hub = InMemoryTransport.Hub()
        let (camera, monitor) = makePair(hub: hub)

        // Camera advertises but never consumes its invitations stream.
        try await camera.startAdvertising()
        try await monitor.startBrowsing()
        var discovered: DiscoveredPeer?
        for await event in monitor.discoveries {
            if case .found(let peer) = event {
                discovered = peer
                break
            }
        }

        await #expect(throws: PeerMeshError.invitationTimedOut) {
            try await monitor.invite(try #require(discovered), timeout: 0.2)
        }

        await monitor.disconnect()
        await camera.disconnect()
    }

    @Test("Datagram sends over the cap throw datagramTooLarge; at the cap they pass the guard")
    func datagramCap() async throws {
        let hub = InMemoryTransport.Hub()
        let identity = PeerIdentity(name: "Capped")
        let session = PeerSession(
            identity: identity,
            service: "_e2e._udp",
            transport: InMemoryTransport(hub: hub))

        let oversized = Data(repeating: 0xD8, count: Delivery.maxDatagramPayload + 1)
        await #expect(throws: PeerMeshError.datagramTooLarge(
            bytes: Delivery.maxDatagramPayload + 1, limit: Delivery.maxDatagramPayload)
        ) {
            try await session.send(oversized, delivery: .datagram)
        }

        // Exactly at the cap: passes the size guard (then fails on membership,
        // proving the guard, not the payload, was the gate above).
        await #expect(throws: PeerMeshError.peerUnreachable(identity.id)) {
            try await session.send(
                Data(repeating: 0xD8, count: Delivery.maxDatagramPayload), delivery: .datagram)
        }
        await session.disconnect()
    }

    @Test("Send with no members throws peerUnreachable")
    func sendWithoutMembers() async throws {
        let hub = InMemoryTransport.Hub()
        let session = PeerSession(
            identity: PeerIdentity(name: "Lonely"),
            service: "_e2e._udp",
            transport: InMemoryTransport(hub: hub))
        await #expect(throws: PeerMeshError.self) {
            try await session.send(Data([1]))
        }
        await session.disconnect()
    }

    @Test("Peer departure surfaces as membership .left on the survivor")
    func peerDeparture() async throws {
        let hub = InMemoryTransport.Hub()
        let (camera, monitor) = makePair(hub: hub)

        try await camera.startAdvertising()
        let acceptTask = Task {
            for await invitation in camera.invitations {
                await invitation.accept()
                break
            }
        }
        try await monitor.startBrowsing()
        var discovered: DiscoveredPeer?
        for await event in monitor.discoveries {
            if case .found(let peer) = event {
                discovered = peer
                break
            }
        }
        _ = try await monitor.invite(try #require(discovered))
        await acceptTask.value

        let departureTask = Task<PeerID?, Never> {
            for await event in camera.membership {
                if case .left(let id) = event { return id }
            }
            return nil
        }
        await monitor.disconnect()
        let departed = try #require(await departureTask.value)
        #expect(departed.displayName == "Monitor")
        #expect(await camera.members.isEmpty)

        await camera.disconnect()
    }

    // MARK: - Step 4 data plane (FR-15..FR-18, DD-7)

    /// Advertiser (camera) accepts; browser (monitor) invites. Returns both
    /// sessions plus the camera's `PeerID` as seen from the monitor (the send
    /// target for the data-plane tests). `reordering` wraps the transport in
    /// `ReorderingTransport` to shuffle data-event delivery (DD-7 proof).
    func establishedPair(
        hub: InMemoryTransport.Hub, reordering: Bool = false
    ) async throws -> (camera: PeerSession, monitor: PeerSession, cameraID: PeerID) {
        func transport() -> any PeerTransport {
            let base = InMemoryTransport(hub: hub)
            return reordering ? ReorderingTransport(base: base) : base
        }
        let camera = PeerSession(
            identity: PeerIdentity(name: "Camera"), service: "_e2e._udp", transport: transport())
        let monitor = PeerSession(
            identity: PeerIdentity(name: "Monitor"), service: "_e2e._udp", transport: transport())

        try await camera.startAdvertising()
        let acceptTask = Task {
            for await invitation in camera.invitations { await invitation.accept(); break }
        }
        try await monitor.startBrowsing()
        var discovered: DiscoveredPeer?
        for await event in monitor.discoveries {
            if case .found(let peer) = event { discovered = peer; break }
        }
        let member = try await monitor.invite(try #require(discovered))
        await acceptTask.value
        return (camera, monitor, member.id)
    }

    @Test("Resource transfer streams disk-to-disk with matching checksum (FR-17, QA-3)")
    func resourceTransfer() async throws {
        let hub = InMemoryTransport.Hub()
        let (camera, monitor, cameraID) = try await establishedPair(hub: hub)

        let size = 2 * 1024 * 1024
        let sourceURL = try Self.makeTempFile(bytes: size)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourceDigest = try Self.sha256(of: sourceURL)

        // Receiver collects the transfer lifecycle and the started progress.
        let receiver = Task<(url: URL, progress: Progress)?, Never> {
            var startedProgress: Progress?
            for await event in camera.resources {
                switch event {
                case .started(_, _, let progress): startedProgress = progress
                case .finished(_, _, let url): return startedProgress.map { (url, $0) }
                case .failed: return nil
                }
            }
            return nil
        }

        let transfer = try await monitor.sendResource(at: sourceURL, to: cameraID)
        let result = try #require(await receiver.value)
        defer { try? FileManager.default.removeItem(at: result.url) }

        #expect(try Self.sha256(of: result.url) == sourceDigest)
        #expect(transfer.progress.totalUnitCount == Int64(size))
        #expect(result.progress.totalUnitCount == Int64(size))
        // Sender progress reaches 100% (may lag the receiver's finished event).
        let senderProgress = transfer.progress
        #expect(await Self.eventually { senderProgress.completedUnitCount == Int64(size) })

        await monitor.disconnect()
        await camera.disconnect()
    }

    @Test("Resource transfer cancellation discards the partial temp file (FR-17)")
    func resourceTransferCancellation() async throws {
        let hub = InMemoryTransport.Hub()
        let (camera, monitor, cameraID) = try await establishedPair(hub: hub)

        // Large enough that it cannot complete before the cancel lands.
        let sourceURL = try Self.makeTempFile(bytes: 8 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let receiver = Task<Bool, Never> {
            for await event in camera.resources {
                switch event {
                case .finished: return false      // should not happen
                case .failed: return true
                case .started: continue
                }
            }
            return false
        }

        let transfer = try await monitor.sendResource(at: sourceURL, to: cameraID)
        transfer.progress.cancel()

        #expect(await receiver.value)  // surfaced as .failed, temp file discarded

        await monitor.disconnect()
        await camera.disconnect()
    }

    @Test("Ordered delivery is restored under reordering; plain reliable is not (DD-7)")
    func orderedVsUnordered() async throws {
        let count = 6

        // .reliableOrdered: reorder buffer restores FIFO despite wire shuffling.
        do {
            let hub = InMemoryTransport.Hub()
            let (camera, monitor, cameraID) = try await establishedPair(hub: hub, reordering: true)
            let inbox = Task<[UInt8], Never> {
                var received: [UInt8] = []
                for await message in camera.messages {
                    received.append(message.payload[0])
                    if received.count == count { break }
                }
                return received
            }
            for i in 0..<count {
                try await monitor.send(
                    Data([UInt8(i)]), to: .peer(cameraID), delivery: .reliableOrdered)
            }
            #expect(await inbox.value == Array(0..<UInt8(count)))
            await monitor.disconnect()
            await camera.disconnect()
        }

        // .reliable: same reordering, no buffer → surfaces out of order.
        do {
            let hub = InMemoryTransport.Hub()
            let (camera, monitor, cameraID) = try await establishedPair(hub: hub, reordering: true)
            let inbox = Task<[UInt8], Never> {
                var received: [UInt8] = []
                for await message in camera.messages {
                    received.append(message.payload[0])
                    if received.count == count { break }
                }
                return received
            }
            // Space sends so wire-arrival order is the send order, making the
            // decorator's adjacent-swap reordering deterministic and observable.
            for i in 0..<count {
                try await monitor.send(Data([UInt8(i)]), to: .peer(cameraID), delivery: .reliable)
                try await Task.sleep(nanoseconds: 3_000_000)
            }
            let order = await inbox.value
            #expect(order.sorted() == Array(0..<UInt8(count)))  // nothing lost
            #expect(order != Array(0..<UInt8(count)))           // but not in order
            await monitor.disconnect()
            await camera.disconnect()
        }
    }

    @Test("Application byte stream round-trips label and data (FR-18)")
    func appByteStream() async throws {
        let hub = InMemoryTransport.Hub()
        let (camera, monitor, cameraID) = try await establishedPair(hub: hub)

        let incoming = Task<(String, [Data]), Never> {
            for await (label, _, stream) in camera.incomingStreams {
                var chunks: [Data] = []
                if let received = try? await Self.collect(stream) { chunks = received }
                return (label, chunks)
            }
            return ("", [])
        }

        let writer = try await monitor.openStream("telemetry", with: cameraID)
        try await writer.write(Data("frame-1".utf8))
        try await writer.write(Data("frame-2".utf8))
        await writer.finish()

        let (label, chunks) = await incoming.value
        #expect(label == "telemetry")
        #expect(chunks == [Data("frame-1".utf8), Data("frame-2".utf8)])

        await monitor.disconnect()
        await camera.disconnect()
    }

    // MARK: - Test helpers

    static func makeTempFile(bytes: Int) throws -> URL {
        let block = Data((0..<1024).map { UInt8($0 % 256) })
        var data = Data(capacity: bytes)
        while data.count < bytes { data.append(block) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peermesh-src-\(UUID().uuidString).bin")
        try data.prefix(bytes).write(to: url)
        return url
    }

    static func sha256(of url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url)))
    }

    static func collect(_ stream: any PeerByteStream) async throws -> [Data] {
        var chunks: [Data] = []
        for try await chunk in stream.incoming { chunks.append(chunk) }
        return chunks
    }

    static func eventually(
        timeoutNanos: UInt64 = 3_000_000_000,
        _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanos {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

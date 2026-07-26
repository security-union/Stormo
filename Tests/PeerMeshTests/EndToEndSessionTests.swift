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
}

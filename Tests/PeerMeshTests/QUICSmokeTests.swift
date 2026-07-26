import Foundation
import Testing

import PeerMesh

@Suite("QUIC smoke", .serialized)
struct QUICSmokeTests {
    #if canImport(Network) && canImport(Security)

    static let logURL = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-darioalessandro-Documents-multipeer-connectivity/2401fce3-1214-4515-9cbb-686ff2125601/scratchpad/phases.log")

    static func log(_ s: String) {
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    func phase(_ name: String, _ body: () async throws -> Void) async throws {
        Self.log("START \(name)")
        try await body()
        Self.log("OK \(name)")
    }

    @Test("QUIC loopback: discovery → invite → messaging both directions")
    func lifecycle() async throws {
        guard QUICTransport.isTLSIdentityAvailable(for: PeerIdentity(name: "probe")) else {
            print("[skip] QUIC: no TLS identity in this environment"); return
        }
        let rv = Rendezvous()
        func t() -> QUICTransport { QUICTransport(configuration: .init(discovery: .rendezvous(rv))) }
        let camera = PeerSession(identity: PeerIdentity(name: "Camera"), service: "_smoke._udp", transport: t())
        let monitor = PeerSession(identity: PeerIdentity(name: "Monitor"), service: "_smoke._udp", transport: t())

        try await phase("advertise") { try await camera.startAdvertising(metadata: ["role": "camera"]) }
        let accept = Task { for await inv in camera.invitations { print("PHASE got invitation"); await inv.accept(); break } }

        try await phase("browse") { try await monitor.startBrowsing() }
        var discovered: DiscoveredPeer?
        try await phase("discover") {
            for await event in monitor.discoveries {
                if case .found(let peer) = event { discovered = peer; break }
            }
        }
        let cameraPeer = try #require(discovered)
        print("PHASE discovered \(cameraPeer.id)")

        try await phase("invite") {
            let member = try await monitor.invite(cameraPeer, context: Data("hi".utf8))
            print("PHASE invited member=\(member.id)")
        }
        await accept.value

        try await phase("send reliable m->c") {
            let inbox = Task<InboundMessage?, Never> { for await m in camera.messages { return m }; return nil }
            try await monitor.send(Data([0xCA, 0xFE]), delivery: .reliable)
            let got = try #require(await inbox.value)
            #expect(got.payload == Data([0xCA, 0xFE]))
            #expect(got.delivery == .reliable)
        }

        try await phase("send datagram c->m") {
            let inbox = Task<InboundMessage?, Never> { for await m in monitor.messages { return m }; return nil }
            try await camera.send(Data([0x60]), delivery: .datagram)
            let frame = try #require(await inbox.value)
            #expect(frame.payload == Data([0x60]))
            #expect(frame.delivery == .datagram)
        }

        await monitor.disconnect()
        await camera.disconnect()
        print("PHASE DONE")
    }
    #endif
}

extension QUICSmokeTests {
    #if canImport(Network) && canImport(Security)
    /// Same lifecycle as the rendezvous test but over REAL Bonjour discovery,
    /// both sessions in one process — the exact combination the entitled-app
    /// loopback test runs (where it stalls at hello-send on Catalyst).
    /// Isolates: in-process + Bonjour on plain macOS.
    @Test("QUIC in-process lifecycle over real Bonjour discovery")
    func bonjourLifecycle() async throws {
        guard QUICTransport.isTLSIdentityAvailable(for: PeerIdentity(name: "probe")) else {
            print("[skip] QUIC: no TLS identity in this environment"); return
        }
        setenv("PEERMESH_NO_P2P", "1", 1)
        let service = ServiceDescriptor(type: "_pmbj\(UInt16.random(in: 1000...9999))._udp")
        func transport() -> QUICTransport { QUICTransport(configuration: .init(discovery: .bonjour)) }
        let camera = PeerSession(
            identity: PeerIdentity(name: "BjCamera"), service: service, transport: transport())
        let monitor = PeerSession(
            identity: PeerIdentity(name: "BjMonitor"), service: service, transport: transport())

        try await camera.startAdvertising(metadata: ["role": "camera"])
        let accept = Task { for await inv in camera.invitations { await inv.accept(); break } }

        try await monitor.startBrowsing()
        var found: DiscoveredPeer?
        for await event in monitor.discoveries {
            // Name-only (AWDL-style) finds carry a placeholder; the real name
            // arrives via .updated — match both (dual-browse contract).
            switch event {
            case .found(let peer), .updated(let peer):
                if peer.id.displayName == "BjCamera" { found = peer }
            case .lost: break
            }
            if found != nil { break }
        }
        let member = try await monitor.invite(try #require(found), timeout: 15)
        #expect(member.id.displayName == "BjCamera")
        await accept.value

        let inbox = Task<InboundMessage?, Never> {
            for await m in camera.messages { return m }
            return nil
        }
        try await monitor.send(Data([0xB0]), delivery: .reliable)
        let got = try #require(await inbox.value)
        #expect(got.payload == Data([0xB0]))

        await monitor.disconnect()
        await camera.disconnect()
    }
    #endif
}

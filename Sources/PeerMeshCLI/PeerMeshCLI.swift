import Foundation
import PeerMesh

/// Diagnostic CLI: exercises the production discovery + transport path
/// (Bonjour + QUIC) between real processes. The debugging ladder for
/// "devices can't see each other": two processes on one Mac → two Macs on a
/// LAN → two iPhones (implementation plan Step 5).
///
///     peermesh advertise [--service _pmdemo._udp] [--name A] [--meta k=v]...
///     peermesh browse    [--service _pmdemo._udp] [--timeout 30]
///     peermesh host      [--service ...] [--name A] [--once]
///     peermesh join      [--service ...] [--name B] [--peer A] [--send ping]
///
/// `host` advertises, auto-accepts invitations, echoes every message back
/// ("pong: <text>"). `join` browses, invites the first (or --peer named) peer,
/// sends --send, waits for the echo, prints SUCCESS, exits 0. Both exit 2 on
/// --timeout (default 30 s). Set QUIC_DEBUG=1 for driver logs.
@main
struct PeerMeshCLI {

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first, ["advertise", "browse", "host", "join"].contains(command) else {
            print("usage: peermesh advertise|browse|host|join [--service TYPE] [--name NAME] [--peer NAME] [--send TEXT] [--meta k=v] [--timeout SECS] [--once]")
            exit(64)
        }
        arguments.removeFirst()

        var options: [String: String] = [:]
        var metadata: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { index += 1; continue }
            let key = String(argument.dropFirst(2))
            let value = (index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--"))
                ? arguments[index + 1] : nil
            if key == "meta", let value, let equals = value.firstIndex(of: "=") {
                metadata[String(value[..<equals])] = String(value[value.index(after: equals)...])
                index += 2
            } else if let value {
                options[key] = value
                index += 2
            } else {
                options[key] = "true"
                index += 1
            }
        }

        let service = options["service"] ?? "_pmdemo._udp"
        let name = options["name"] ?? "\(ProcessInfo.processInfo.hostName)-\(getpid())"
        let timeout = TimeInterval(options["timeout"] ?? "30") ?? 30

        log("peermesh \(command) — name=\(name) service=\(service) pid=\(getpid())")

        // Global watchdog: a diagnostic tool must never hang silently.
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            log("TIMEOUT after \(Int(timeout))s")
            exit(2)
        }

        let session = PeerSession(name: name, service: ServiceDescriptor(type: service))
        log("local peer id: \(await session.identity.id)")

        do {
            switch command {
            case "advertise":
                try await session.startAdvertising(metadata: metadata)
                log("advertising (ctrl-c to stop)")
                for await event in session.membership { log("membership: \(event)") }

            case "browse":
                try await session.startBrowsing()
                log("browsing…")
                for await event in session.discoveries {
                    switch event {
                    case .found(let peer): log("FOUND \(peer.id) metadata=\(peer.metadata)")
                    case .updated(let peer): log("UPDATED \(peer.id) metadata=\(peer.metadata)")
                    case .lost(let id): log("LOST \(id)")
                    }
                }

            case "host":
                try await session.startAdvertising(metadata: metadata)
                log("hosting: advertising + auto-accepting invitations")
                Task {
                    for await invitation in session.invitations {
                        log("invitation from \(invitation.from.displayName) context=\(invitation.context.flatMap { String(data: $0, encoding: .utf8) } ?? "nil") — accepting")
                        await invitation.accept()
                    }
                }
                let peerDeparted = AsyncStream<Void>.makeStream()
                Task {
                    for await event in session.membership {
                        log("membership: \(event)")
                        if case .left = event { peerDeparted.continuation.yield(()) }
                    }
                }
                Task {
                    for await message in session.messages {
                        let text = String(data: message.payload, encoding: .utf8) ?? "\(message.payload.count)B"
                        log("recv \"\(text)\" from \(message.sender.displayName)")
                        try? await session.send(
                            Data("pong: \(text)".utf8), to: .peer(message.sender), delivery: .reliable)
                        log("echoed")
                    }
                }
                if options["once"] != nil {
                    // Exit only when the joiner departs — proof the echo was
                    // delivered (the joiner exits after receiving it). Exiting
                    // right after send() would kill the process before the
                    // fire-and-forget effects actually transmit.
                    for await _ in peerDeparted.stream { break }
                    log("SUCCESS (host, --once): peer departed after exchange")
                    exit(0)
                }
                for await _ in peerDeparted.stream {}

            case "join":
                try await session.startBrowsing()
                log("browsing for a host…")
                var target: DiscoveredPeer?
                for await event in session.discoveries {
                    // AWDL name-only finds carry a hash-prefix placeholder name;
                    // the display name arrives via .updated (TXT enrichment) —
                    // match on both.
                    let peer: DiscoveredPeer?
                    switch event {
                    case .found(let p):
                        log("found \(p.id) metadata=\(p.metadata)")
                        peer = p
                    case .updated(let p):
                        log("updated \(p.id) metadata=\(p.metadata)")
                        peer = p
                    case .lost(let id):
                        log("lost \(id)")
                        peer = nil
                    }
                    guard let peer else { continue }
                    if let wanted = options["peer"], peer.id.displayName != wanted { continue }
                    target = peer
                    break
                }
                guard let target else { log("no peer found"); exit(1) }

                log("inviting \(target.id.displayName)…")
                let member = try await session.invite(
                    target, context: Data("peermesh-cli".utf8), timeout: min(timeout, 15))
                log("JOINED session with \(member.id.displayName)")

                let text = options["send"] ?? "ping"
                try await session.send(Data(text.utf8), delivery: .reliable)
                log("sent \"\(text)\" — awaiting echo…")
                for await message in session.messages {
                    let reply = String(data: message.payload, encoding: .utf8) ?? "\(message.payload.count)B"
                    log("recv \"\(reply)\" from \(message.sender.displayName)")
                    break
                }
                await session.disconnect()  // clean close → host observes .left
                log("SUCCESS")
                exit(0)

            default:
                exit(64)
            }
        } catch {
            log("ERROR: \(error)")
            exit(1)
        }
    }

    static func log(_ message: String) {
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        print("[\(stamp)] \(message)")
        fflush(stdout)
    }
}

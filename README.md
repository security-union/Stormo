# PeerMesh

**The open-source replacement for Apple's deprecated MultipeerConnectivity
framework** — peer-to-peer sessions built on Network.framework and QUIC.

> **Status: pre-alpha scaffolding.** API surface and design are baselined; the
> engine is under construction. Not yet usable in apps.

MultipeerConnectivity was formally deprecated in the OS 27 SDKs. PeerMesh
restores its high-level programming model — discovery, invitations, sessions,
reliable and unreliable messaging, byte streams, and file transfer between
nearby Apple devices, including over peer-to-peer Wi-Fi with **no network
infrastructure at all** — and lifts its limits: more than 8 peers, real flow
control, always-on TLS 1.3.

Migrating from `MCSession`, `MCPeerID`, `MCNearbyServiceAdvertiser`, or
`MCBrowserViewController`? The [`MPCCompat` module](#modules) is a
near-drop-in migration surface: mechanical renames, same delegate semantics.

```swift
import PeerMesh

let session = PeerSession(name: "Dario's iPhone", service: "_myapp._udp")
try await session.startAdvertising()

for await invitation in session.invitations {
    await invitation.accept()
}

try await session.send(data, to: .all)                    // reliable QUIC stream
try await session.send(input, to: .all, delivery: .datagram)  // low-latency datagram
```

## Why

Beyond the formal deprecation (WWDC 2026), MultipeerConnectivity's
infrastructure-less connection path is already broken on iOS 26 — Apple DTS has
said a fix is unlikely. Apple's recommended migration target, Network.framework,
is a set of low-level primitives: session management, invitations, resource
transfer, and flow control all become your problem. PeerMesh restores the
high-level programming model on Apple's supported stack.

**Honest limitations:** no Bluetooth transport — no current Apple API offers
one to third-party apps (MPC itself lost Bluetooth ~10 years ago). Peer-to-peer
Wi-Fi requires `NSLocalNetworkUsageDescription` and `NSBonjourServices` in your
Info.plist.

## Modules

| Product | Purpose |
|---|---|
| `PeerMesh` | Modern core: `async`/`await`, `AsyncSequence` events, QUIC transport |
| `MPCCompat` | Near-drop-in migration surface for MultipeerConnectivity codebases (`MultipeerSession` ≈ `MCSession`, delegate semantics preserved) |
| `PeerMeshUI` | SwiftUI peer browser and invitation consent components |
| `PeerMeshTestKit` | In-memory transport — run full mesh scenarios in CI, no radios |

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/securityunion/peermesh.git", from: "0.1.0")
]
```

Platforms: iOS 15+ · iPadOS 15+ · macOS 12+ · tvOS 15+ · visionOS 1+ (QUIC floor).

## Design

- [Feasibility study](docs/feasibility-study-mpc-replacement.md) — why MPC was
  deprecated, the ecosystem gap, and the product analysis.
- [Design document](docs/design-mpc-successor.md) — requirements (functional + SEI
  quality-attribute scenarios), QUIC transport decision, security model,
  disciplined-FlatBuffers signaling, architecture.
- [Implementation plan](docs/IMPLEMENTATION-PLAN.md) — the step-by-step
  transport/runtime execution plan with statuses and exit criteria.

Signaling schemas live in [`Schemas/`](Schemas/signal.fbs); codegen uses the
`flatc` pinned by `flake.nix` (`nix develop`).

## License

MIT (placeholder — final license selection before first public release).

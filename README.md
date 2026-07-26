# PeerMesh

**The open-source replacement for Apple's deprecated MultipeerConnectivity
framework** — peer-to-peer sessions over Network.framework + QUIC.

Discovery, invitations, reliable/unreliable messaging, and file transfer
between nearby Apple devices — including over **peer-to-peer Wi-Fi with no
network at all** (the scenario broken in MPC on iOS 26). Proven in a shipping
camera app streaming live preview at 33 fps device-to-device with no
infrastructure.

```swift
import PeerMesh

let session = PeerSession(name: "Dario's iPhone", service: "_myapp._udp")
try await session.startAdvertising()
for await invitation in session.invitations { await invitation.accept() }
try await session.send(data, to: .all)
```

Migrating from `MCSession`? The **`MPCCompat`** module is a near-drop-in
surface: mechanical renames (`MCSession`→`MultipeerSession`,
`MCPeerID`→`PeerID`), same delegate semantics.

## Highlights

- **QUIC transport**: TLS 1.3 always on, stream-per-message (no head-of-line
  blocking), validated over AWDL on real devices
- **More than 8 peers**, real flow control, key-derived unforgeable peer IDs
  (libp2p-compatible)
- **Sans-I/O protocol engine**: fully deterministic and testable without radios
- Zero-config trust by default (MPC ergonomics); pairing-code and pinned modes
  for MITM resistance

## Install

```swift
.package(url: "https://github.com/security-union/Multipeer-Connectivity.git", from: "0.1.0")
```

Platforms: iOS 15+ · macOS 12+ · tvOS 15+ · visionOS 1+. Apps need
`NSLocalNetworkUsageDescription` + `NSBonjourServices` (like MPC);
macOS/Catalyst also need the Keychain Sharing entitlement. No Bluetooth
transport — no current Apple API offers one (MPC's has been gone ~10 years).

## Docs

[Design document](docs/design-mpc-successor.md) ·
[Implementation plan](docs/IMPLEMENTATION-PLAN.md) ·
[Platform findings](docs/spike-results.md) ·
[Feasibility study](docs/feasibility-study-mpc-replacement.md)

## Status

Pre-release. Core protocol, QUIC transport, and MPCCompat are functional and
hardware-validated; API may still change before 1.0. License: MIT (final
selection before first tagged release).

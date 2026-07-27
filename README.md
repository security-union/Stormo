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

Migrating from `MCSession`? The **`MPCCompat`** module plus one app-local
typealias file makes it a near-drop-in swap — see
[Replacing MultipeerConnectivity](#replacing-multipeerconnectivity) below.

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
.package(url: "https://github.com/security-union/PeerMesh.git", from: "1.0.0")
```

Platforms: iOS 15+ · macOS 12+ · tvOS 15+ · visionOS 1+. Apps need
`NSLocalNetworkUsageDescription` + `NSBonjourServices` (like MPC);
macOS/Catalyst also need the Keychain Sharing entitlement. No Bluetooth
transport — no current Apple API offers one (MPC's has been gone ~10 years).

## Replacing MultipeerConnectivity

The recipe below is exactly how [Remote Shutter](https://github.com/security-union/remote-shutter)
(a shipping App Store camera app) migrated off MPC — the app diff was a few
imports, one new file, and its peer-ID cache.

**1. Add the package** to your app target, linking the `PeerMesh` and
`MPCCompat` products:

```swift
.package(url: "https://github.com/security-union/PeerMesh.git", from: "1.0.0")
```

**2. Check your `Info.plist`.** Same requirements as MPC:
`NSLocalNetworkUsageDescription`, and your service type under
`NSBonjourServices` — PeerMesh uses the `_yourservice._udp` variant (Apple's
guidance for MPC apps was to declare both `._tcp` and `._udp`, so most apps
already have it).

**3. Add one app-local typealias file** — this is the key to a thin diff. Your
app keeps MPC's type names; the implementations come from MPCCompat. PeerMesh
deliberately does not publish `MC`-prefixed names, so the mapping lives in
*your* app:

```swift
//  MultipeerCompatAliases.swift — the entire MPC → PeerMesh mapping.

import MPCCompat
import PeerMesh

public typealias MCPeerID = PeerID
public typealias MCSession = MultipeerSession
public typealias MCSessionDelegate = MultipeerSessionDelegate
public typealias MCSessionState = MultipeerSession.PeerState
public typealias MCSessionSendDataMode = MultipeerSession.SendDataMode
public typealias MCEncryptionPreference = MultipeerSession.EncryptionPreference
public typealias MCNearbyServiceAdvertiser = NearbyServiceAdvertiser
public typealias MCNearbyServiceAdvertiserDelegate = NearbyServiceAdvertiserDelegate
public typealias MCNearbyServiceBrowser = NearbyServiceBrowser
public typealias MCNearbyServiceBrowserDelegate = NearbyServiceBrowserDelegate
```

**4. Replace the import.** Everywhere you have `import MultipeerConnectivity`,
write `import MPCCompat` (or nothing, if the aliases file is in the same
module). Sessions, advertisers, browsers, delegates, `send`, `sendResource`,
invitations — unchanged call sites.

**5. The deltas you should know about** (each documented on `MultipeerSession`):

- **Peer-ID persistence**: `PeerID` is `Codable`, not `NSCoding` — if you
  archived `MCPeerID`s, re-do that cache (usually a few lines).
- **Always encrypted**: TLS 1.3, no `.none`/`.optional`. `MCEncryptionPreference`
  exists for source compatibility and is ignored.
- **Identity is the key**: peer IDs are derived from a persisted per-device
  key (unforgeable, stable across launches) — display names are cosmetic.
- **`.unreliable` over 1200 bytes** is delivered reliably instead (real
  datagrams never fragment; MPC only accepted large unreliable sends via
  fragile IP fragmentation).
- **`sendResource` completion** fires when the sender finishes streaming, not
  on recipient receipt. Both sides get live byte-counting `Progress`.
- **`startStream` (NSStream)** is not bridged yet; modern callers use
  `PeerSession.openStream`.
- No 8-peer cap; sessions support 32+ peers full-mesh.

## Docs

[Design document](docs/design-mpc-successor.md) ·
[Implementation plan](docs/IMPLEMENTATION-PLAN.md) ·
[Platform findings](docs/spike-results.md) ·
[Feasibility study](docs/feasibility-study-mpc-replacement.md)

## Status

Pre-release. Core protocol, QUIC transport, and MPCCompat are functional and
hardware-validated; API may still change before 1.0. License: MIT (see
[LICENSE](LICENSE)).

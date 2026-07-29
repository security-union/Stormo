# Stormo

**The open-source replacement for Apple's deprecated MultipeerConnectivity
framework** — peer-to-peer sessions over Network.framework + QUIC.

Discovery, invitations, reliable/unreliable messaging, and file transfer
between nearby Apple devices — including over **peer-to-peer Wi-Fi with no
network at all** (the scenario broken in MPC on iOS 26). Proven in a shipping
camera app streaming live preview at 33 fps device-to-device with no
infrastructure.

```swift
import Stormo

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
.package(url: "https://github.com/security-union/Stormo.git", from: "1.0.0")
```

Platforms: iOS 15+ · macOS 12+ · tvOS 15+ · visionOS 1+. Apps need
`NSLocalNetworkUsageDescription` + `NSBonjourServices` (like MPC);
macOS/Catalyst also need the Keychain Sharing entitlement. No Bluetooth
transport — no current Apple API offers one (MPC's has been gone ~10 years).

## Replacing MultipeerConnectivity

The recipe below is exactly how [Remote Shutter](https://github.com/security-union/remote-shutter)
(a shipping App Store camera app) migrated off MPC — the app diff was a few
imports, one new file, and its peer-ID cache.

**1. Add the package** to your app target, linking the `Stormo` and
`MPCCompat` products:

```swift
.package(url: "https://github.com/security-union/Stormo.git", from: "1.0.0")
```

**2. Check your `Info.plist`.** Same requirements as MPC:
`NSLocalNetworkUsageDescription`, and your service type under
`NSBonjourServices` — Stormo uses the `_yourservice._udp` variant (Apple's
guidance for MPC apps was to declare both `._tcp` and `._udp`, so most apps
already have it).

**3. Add one app-local typealias file** — this is the key to a thin diff. Your
app keeps MPC's type names; the implementations come from MPCCompat. Stormo
deliberately does not publish `MC`-prefixed names, so the mapping lives in
*your* app:

```swift
//  MultipeerCompatAliases.swift — the entire MPC → Stormo mapping.

import MPCCompat
import Stormo

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

**6. Two MPC habits you must drop** — both are patterns that were correct
against MPC and actively break here. If your app connects once and then never
again, look here first:

- **Do NOT rebuild the session per connection attempt.** MPC apps commonly
  create a virgin `MCSession` before each invite/accept, because Apple never
  documented a torn-down `MCSession` as reusable and a reused one was the
  classic cause of invites wedged in `.connecting`. Here `MultipeerSession` is
  a *facade over one long-lived peer session*: rebuilding resets no transport,
  and `disconnect()` closes every open connection — including the one that
  just completed its handshake and delivered the invitation you are about to
  accept. The symptom is distinctive: the first connection works, every later
  one dies milliseconds after a successful handshake. Keep one session and
  invite/accept on it.
- **Do NOT restart a connection attempt that is still in flight.** A QUIC dial
  (handshake + TLS + `PeerHello`) takes seconds, where MPC's invite felt
  instantaneous. A fixed-rate reconnect loop that re-invites every second will
  keep cancelling its own handshake and never connect. Retry on an attempt's
  *failure*, not on a timer that ignores it.

**7. Backgrounding is yours to handle now.** MPC's link was owned by system
daemons and survived app suspension; a userspace QUIC connection cannot — the
peer sees the connection die within ~5 s of the freeze. Call
`announceSuspension(gracePeriod:)` from `didEnterBackground` and
`resumeFromSuspension()` from `didBecomeActive`: peers then hold membership
across the freeze instead of reporting a departure, and reconnect silently.
The beyond-MC `peerDidSuspend`/`peerDidResume` delegate callbacks let you show
a "reconnecting" state; a peer under its grace window stays `.connected`, and
grace expiry arrives as the ordinary `.notConnected`. See
[DD-9](docs/design-mpc-successor.md) for the protocol.

**8. `foundPeer` can fire more than once for the same peer.** Over
peer-to-peer Wi-Fi a peer is first surfaced from a name-only Bonjour find whose
`displayName` is a key-hash placeholder; when TXT resolution catches up the
peer is re-delivered with its real name. `PeerID` equality is key-hash-only, so
both deliveries compare equal — a peer list must **update the stored value in
place**, never dedup-and-drop it, or the placeholder name is frozen in your UI
forever. (`lostPeer` gives you back the same enriched `PeerID` you were shown.)

## Docs

[Design document](docs/design-mpc-successor.md) ·
[Implementation plan](docs/IMPLEMENTATION-PLAN.md) ·
[Platform findings](docs/spike-results.md) ·
[Feasibility study](docs/feasibility-study-mpc-replacement.md)

## Status

Pre-release. Core protocol, QUIC transport, and MPCCompat are functional and
hardware-validated; API may still change before 1.0. License: MIT (see
[LICENSE](LICENSE)).

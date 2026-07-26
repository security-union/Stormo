# Spike Results

Running log of validation-spike outcomes (design doc §8). Update as spikes land.

## S-3 — QUIC stream multiplexing on Network.framework (RESOLVED, loopback)

**Verdict: `NWConnectionGroup(with: NWMultiplexGroup(to:))` works** for the DD-1
model — control stream + per-message dedicated streams over one QUIC
connection — with three hard-won platform findings:

1. **Inbound streams never fire `.ready`.** Streams surfaced by
   `newConnectionHandler` are receivable immediately after `start(queue:)`
   while their state stays `.preparing`. Never gate inbound receives on
   `.ready` (`quicStartReceiving`). Dialer-extracted outbound streams DO
   reach `.ready` normally.
2. **Inbound `QUICConnection` lifetime.** Between `NWListener`'s group arrival
   and handshake completion, nothing app-side holds the wrapper strongly if
   handlers capture it weakly — it deallocates and every stream is silently
   dropped (`guard let self` swallows them). Fixed with an explicit
   pending-inbound retention table released on adoption/termination.
3. **FIN semantics.** `send(content:isComplete:true)` with the default content
   context never surfaces stream completion to the peer (`isComplete` stays
   false on receive). Sending payload *with* `.finalMessage` delivers nothing
   at all. The reliable pattern is two-step: payload on the default context,
   then an empty `.finalMessage` send (`quicSend`/`quicFinish`).

Stream classification is done with a 1-byte tag prologue (control=0x00,
dedicated=0x01) + length-prefixed FlatBuffers `StreamHeader` on dedicated
streams (DD-7), so classification never depends on stream open order.

Datagrams (RFC 9221): NOT yet exercised — `.datagram` delivery currently maps
onto a dedicated stream with a marker label (documented limitation; real
datagram flow is follow-up work, tracked for S-1 hardware validation where
latency actually matters).

## S-6 — Stream-per-message churn (PENDING formal benchmark)

The smoke lifecycle (2 messages + handshake + discovery) completes in ~0.16 s
on loopback including process warm-up; per-message stream open/classify/FIN
round-trips are sub-millisecond in the debug logs. The formal 10²–10⁴ msg/s
benchmark with memory tracking remains to be scripted (nightly CI job stub in
ci.yml).

## S-1 / S-2 / S-5 — AWDL, mesh ceiling, backgrounding (BLOCKED on hardware)

Loopback proves the driver, not the radio. `includePeerToPeer` paths, AWDL
behavior, real-device mesh scaling, and lifecycle transitions require the
physical device lab (implementation plan Step 5).

## TLS identity in test environments

`SecIdentity` formation needs keychain access unavailable to bare `swift test`
(errSecMissingEntitlement). The driver takes a `Configuration.tlsProvider`
hook; tests use `QUICTransport.isTLSIdentityAvailable` to skip cleanly where
no identity can be formed. On this development machine the data-protection
keychain path works and the QUIC suite runs for real.

## In-process pairing matrix (Jul 26, gap-closure pass)

| Combination | Result |
|---|---|
| Same process, rendezvous discovery, macOS `swift test` | ✅ 0.16 s |
| Two processes, Bonjour, macOS (CLI / `Scripts/e2e-cli.sh`) | ✅ ~0.3 s warm, ~4 s first contact |
| Same process, Bonjour, macOS `swift test` | ✅ but slow (~11 s incl. registration+browse) |
| Same process, Bonjour, **Catalyst** entitled app host | ❌ stalls at hello-send: TLS completes both ways, dialer control stream `ready`, but the first `send`'s completion never fires. Catalyst-sandbox-specific; the app-loopback test skips with reason. Not the cross-device path. |

Operational finding: FIRST-contact Bonjour+QUIC establishment can take
seconds (mDNS registration + resolve + handshake). App-level invite/state
timeouts near 10 s are marginal on first contact — remote-shutter's
coordinator arms 10 s transient-state timeouts, a candidate explanation for
device-side "Connecting → Not Connected" alongside AP client isolation.
The QUIC_DEBUG transcript discriminates: dial stuck in `waiting` = network
path blocked; steady progress cut short = timeout too tight.

## Device-blocking findings (Jul 26 evening — from real iPhone/iPad + Catalyst logs)

1. **Stale keychain identity (THE cross-device connect failure).**
   `makeSecIdentity`'s final `kSecClassIdentity` fetch had no discriminator —
   it returned an arbitrary (often stale) identity from the app's persistent
   data-protection keychain, so the presented TLS cert failed the dialer's
   key-hash cross-check → `identityMismatch` on every dial ("Connecting →
   Not Connected"). Only reproducible on entitled persistent keychains
   (iOS/iPadOS/Catalyst) — macOS test paths use a per-run file keychain,
   which is why every macOS rung was green. Fix: pin the fetch to the key's
   `kSecAttrApplicationLabel` (public-key hash). Regression coverage: the
   remote-shutter Catalyst in-process loopback test now runs the FULL app
   stack over real QUIC and passes (1.2 s).
2. **`group.extract()` vs `NWConnection(from:)`.** On the iOS-family stack,
   extract()-created streams warn `nw_connection_copy_protocol_metadata on
   unconnected` and behave inconsistently; `NWConnection(from: group)`
   (iOS 16+/macOS 13+) is the supported stream-creation API and is now used
   everywhere, with extract() only as the macOS 12 fallback.
3. **MCSession.disconnect semantics** (fixed earlier same day): disconnect
   must never tear down discovery — see the re-invite regression test.

## S-1 preparation: discovery audit vs Apple's P2P pattern (Jul 26 night)

User report: same-Wi-Fi works device-to-device; peer-to-peer Wi-Fi (AWDL,
no shared network) peers don't see each other. Audit vs TN3213/TicTacToe
found three divergences, all fixed:

1. **Browse kind:** we browsed `.bonjourWithTXTRecord` only; TXT resolution
   is not dependable over AWDL. Now DUAL-browse: plain `.bonjour` (AWDL-
   capable; PeerID reconstructed from the instance name) + TXT browse as an
   enrichment source (`.updated` upgrades name-only finds with display
   name/metadata). Consumers must treat `.found` and `.updated` uniformly —
   name-only finds carry a hash-prefix placeholder name.
2. **Instance name now carries the FULL base58 PeerID multihash** (~47
   chars ≤ 63-byte limit) so plain-browse results yield complete identities
   (base58 decode added to LibP2PIdentity).
3. **Dial-side `includePeerToPeer` was never set** — Apple sets it on
   listener, browser, AND outgoing connection. Now threaded through
   QUICConnection.dial (bonjour mode + not opted out).

Prerequisite: PeerID equality/hash is now key-hash-only (identity IS the
key); display names are cosmetic and source-dependent. Dial adopts the
peer's real display name from its PeerHello.

Verified after changes: 54 package tests, cross-process CLI E2E, simulator
app-loopback (1.1 s). Catalyst app-loopback currently blocked by an
unrelated Xcode 26.6 codesign failure on freshly-copied XCUIAutomation/
Testing frameworks (CLI xcodebuild only; appeared after a DerivedData wipe).
AWDL itself remains hardware-only (S-1 device protocol below).

**S-1 device protocol:** both phones Wi-Fi ON but forget/disconnect all
networks (Settings→Wi-Fi, stay on the Wi-Fi screen or just unassociated);
Bluetooth ON helps AWDL rendezvous; both apps FOREGROUND, screens on;
launch via Xcode for QUIC_DEBUG transcripts. Expect discovery via the
plain-Bonjour path (placeholder names possible until connect). If discovery
works but dial fails in `waiting`, capture both transcripts — next suspects
are QUIC-over-awdl0 binding (the core S-1 question) and iOS 26 AWDL
teardown timing (the bug that killed MPC).

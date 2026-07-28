# Stormo Implementation Plan

**Working plan — SU-2026-WP-001** · Last updated: July 26, 2026

Companion documents: [Design document](design-mpc-successor.md) (requirements FR-x/QA-x, decisions DD-1..DD-8, spikes S-1..S-6) · [Feasibility study](feasibility-study-mpc-replacement.md) (product Phases 1–3).

This is the engineering execution plan for the transport and runtime. Update the status column as steps land; add dated notes under each step.

## Status overview

| Step | Scope | Status | Gated on |
|---|---|---|---|
| 0 | Scaffolding: SPM package, sans-I/O engine, zero-copy FlatBuffers signaling, CI matrix | ✅ Done (Jul 25–26) | — |
| 1 | Runtime shell + InMemoryTransport end-to-end | ✅ Done (Jul 26) | — |
| 2 | Identity & TLS (Keychain, self-signed certs, verify policies, libp2p PeerID) | ✅ Done (Jul 26) | — |
| 3 | QUICTransport over loopback (tier 2; S-3 resolved — see [spike-results](spike-results.md)) | ✅ Done (Jul 26); S-6 formal bench + real RFC 9221 datagrams pending | — |
| 4 | Data plane completion + MPCCompat bridge | ✅ Done (Jul 26); remote-shutter validated: all platforms build, 553 tests 0 failures, zero app-source changes | — |
| 5 | Hardware spikes (AWDL) | 🟢 S-1 PASSED (Jul 26): QUIC-over-AWDL confirmed on devices — no-infrastructure camera streaming at ~33 fps. S-2 (mesh >2) and S-5 (backgrounding) remain | more devices / lifecycle runs |
| 6 | Release engineering: 0.1.0, docs, discoverability | ⬜ | license decision, Step 5 outcomes |

**Jul 26 status:** 48 tests green on `main` across 8 suites — engine, codec,
runtime, identity/trust (libp2p multihash PeerIDs), ordered delivery, resource
transfer, byte streams, MPCCompat bridge (incl. the remote-shutter video path),
and the full QUIC loopback lifecycle. Three Network.framework platform findings
recorded in [spike-results.md](spike-results.md) (inbound-stream readiness,
inbound-connection retention, two-step FIN).

Integration proof: `remote-shutter` branch `feat/Stormo-mpccompat` (compiles + full unit suite green against MPCCompat; functional once Step 4 lands).

---

## Step 0 — Scaffolding ✅

Landed: SPM package (`StormoProtocol` / `Stormo` / `MPCCompat` / `StormoUI` / `StormoTestKit`); sans-I/O `ProtocolEngine` (DD-6) with invitation/roster/messaging transitions; disciplined zero-copy FlatBuffers signaling (`signal.fbs`, `stream_header.fbs`, `SignalCodec` with verifier caps, DD-5); flake.nix pinning `flatc` = SPM runtime (exact 25.2.10); CI workflow (macOS native + iOS Simulator + Mac Catalyst + codegen-drift job); MPCCompat compile surface validated against a real app (remote-shutter).

## Step 1 — Runtime shell + InMemoryTransport ✅

Landed (Jul 26): `PeerSession` as effect executor (engine inputs from connections/timers/app; effects → dial/send/timers/close/emit; invite continuations; Invitation accept/decline closures); transport contracts split control vs data channels + `inboundConnections`; per-invite timeout in `Command.invite`; full `InMemoryTransport.Hub` (advertisement replay, discovery fan-out, brokered connection pairs); 5 end-to-end tests (lifecycle, decline, timeout, no-members, churn). 23 tests green.

**Exit criterion met:** two `PeerSession`s complete advertise → browse → invite → accept → bidirectional messaging with real FlatBuffers wire bytes, zero radios.

## Step 2 — Identity & TLS ⬜ (next; pure desk work)

Everything QUIC needs before a TLS handshake can happen.

1. **Persistent identity:** Keychain-stored P-256 signing key (Secure Enclave where available; simulator/CI fallback to keychain-software). Replaces `PeerIdentity.loadOrCreate`'s ephemeral TODO. Identity continuity is what makes `.automatic` TOFU warnings real (FR-21).
2. **libp2p PeerID encoding (DD-8):** switch `PeerID.keyHash` derivation to multihash-of-encoded-public-key, CIDv1 text form for display/debugging. Must land **before wire freeze** — it changes roster bytes.
3. **Self-signed certificate:** generate X.509 via `apple/swift-certificates` (new dependency, pure Swift), bind to the P-256 key, import to Keychain → `SecIdentity` for `sec_protocol_options_set_local_identity`.
4. **Verify policies:** `sec_protocol_options_set_verify_block` implementations per `TrustPolicy` — `.automatic` (accept + record key hash, FR-22 callback), `.pinned` (match pinned certs/CA). `.pairingCode` transcript binding deferred to its own sub-step behind **Spike S-4** (TLS exporter accessibility).
5. **Tests:** identity persistence round-trip; cert generation; key-hash extraction from `SecCertificate`; TOFU continuity warning (`MembershipEvent.identityChanged`).

**Exit criteria:** identity survives relaunch; `SecIdentity` usable in a `NWParameters` TLS options block (compile + unit-verified on macOS); PeerID format is libp2p-compatible; DD-2 verify policies unit-tested with fixture certs.

## Step 3 — QUICTransport over loopback ⬜ (tier 2; desk work)

The real driver, validated entirely on `127.0.0.1` in CI — no radios.

1. **Listener/advertiser:** `NWListener` with QUIC parameters (ALPN `"Stormo"`, local identity from Step 2) + Bonjour `.service(type:)` with `NWTXTRecord` metadata; `includePeerToPeer = true`; Local Network permission surfacing (FR-4).
2. **Browser:** `NWBrowser(.bonjourWithTXTRecord)`, cross-interface dedup by peer id (FR-2).
3. **Connection = QUIC multiplex:** resolve **Spike S-3** (`NWMultiplexGroup` vs per-stream `NWConnection`s) empirically on loopback; control stream (signals, size-prefixed) + stream-per-message with `StreamHeader` (DD-7) + datagram flow for `.datagram` (RFC 9221).
4. **Benchmark = Spike S-6:** stream-churn rate (target ≥1,000 msg/s loopback, flat memory) wired as the nightly CI job stub in `ci.yml`.
5. **Tests:** the *same* E2E suite as Step 1, parameterized over transports (InMemory + QUIC-loopback) — one suite, two drivers, per DD-6.

**Exit criteria:** E2E suite green over real QUIC on loopback on macOS CI + iOS Simulator; S-3 decision recorded in design doc; S-6 numbers recorded (or coalescing fallback designed).

## Step 4 — Data plane completion + MPCCompat bridge ⬜

1. **`.reliableOrdered`:** sequence numbers + receiver reorder buffer (DD-7).
2. **Resource transfer (FR-17):** `TransferOffer` signal + `transferChunk` stream; disk-to-disk, `Progress`, cancellation via stream reset; memory cap per QA-3.
3. **App byte streams (FR-18):** `StreamOpen` + `PeerByteStream` over dedicated streams.
4. **MPCCompat bridge:** pump `PeerSession` membership/messages/resources into `MultipeerSessionDelegate` callbacks (serial delegate queue, MCSession semantics); `NearbyServiceAdvertiser/Browser` bridging; `MultipeerSession.send/sendResource` wired (`.reliable`→`.reliableOrdered`, `.unreliable`→`.datagram`).
5. **Validation:** remote-shutter `feat/Stormo-mpccompat` runs camera↔monitor over LAN (simulator loopback first, then two Macs/devices on one network); its loopback session tests pass against the bridge over InMemoryTransport.

**Exit criteria:** remote-shutter takes a photo through Stormo on LAN; MPCCompat E2E tests in Stormo repo green over both transports.

## Step 5 — Hardware spikes ⬜ (requires operator + ≥2 physical devices)

- **S-1 (go/no-go for DD-1):** QUIC incl. datagrams over `includePeerToPeer`/AWDL, both devices unassociated to any AP (FR-3/QA-1 scenario). Throughput/latency vs TCP+TLS on the same path, across iOS 15/17/26-class devices. Fail → promote `TCPTLSTransport` to primary (its skeleton exists as the contingency in FR-25).
- **S-2:** AWDL full-mesh ceiling (8→16→32 devices as available) → documented per-topology limits (QA-2).
- **S-5:** backgrounding/foreground QUIC behavior → documented resume semantics (C-5).
- Also here: Local Network prompt UX validation, iOS 26 regression-adjacent behaviors.

**Exit criteria:** QA-1 measure evaluated on real hardware; DD-1 confirmed or contingency invoked; results folded into design doc §8.

## Step 6 — Release engineering ⬜

Initial public commit + tag `0.1.0`; license decision (MIT vs Apache-2.0 — study §8 leans Apache for the patent grant); repo description/topics + Swift Package Index submission; hosted DocC + `llms.txt`; "Migrating from MultipeerConnectivity to Stormo" guide (the TN3213-echo landing page); name availability final check (`Stormo` verified clear Jul 26); threat-model document (security-consultancy differentiator, study §8.3).

---

## Standing constraints (from design doc)

- Engine stays sans-I/O: no sockets/clocks/async in `StormoProtocol` (DD-6).
- FlatBuffers discipline: schema evolution rules + verifier caps + pinned-together flatc/runtime (DD-5).
- One suite, N transports/platforms: new features land with engine tests first, driver parity second (QA-8).
- No Bluetooth claims, ever (C-2); no private API (C-6).

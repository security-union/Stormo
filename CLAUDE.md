# CLAUDE.md — PeerMesh contributor guide (AI & human)

PeerMesh is an open-source replacement for Apple's deprecated
MultipeerConnectivity, built on Network.framework + QUIC. The codebase is
split by the sans-I/O discipline (DD-6): a pure, deterministic protocol engine
that decides, and thin async drivers that move bytes. Read
`docs/design-mpc-successor.md` (the DD-1..DD-8 decisions and FR/QA
requirements) before making architectural changes; `docs/spike-results.md` is
the hard-won platform-findings log and the source of the failure modes below.

## Module map

| Module | Kind | What lives here |
|---|---|---|
| **PeerMeshProtocol** | library (sans-I/O) | `ProtocolEngine` state machine, `Signal` model + `SignalCodec` (FlatBuffers verifier), `PeerID`/`LibP2PIdentity`, `Delivery`/`Recipients`/`PeerMeshError`, `Locked`. Only dependency: FlatBuffers. |
| **PeerMesh** | library (runtime) | `PeerSession` actor (effect executor), `QUICTransport` + QUIC driver, Security (identity, certificate, keychain stores, `TrustEvaluator`), public event/config types. Re-exports PeerMeshProtocol so apps write only `import PeerMesh`. |
| **MPCCompat** | library | Near-drop-in `MCSession`/`MCPeerID`/advertiser/browser analogs over `PeerSession` (FR-24). |
| **PeerMeshUI** | library | SwiftUI peer picker + invitation consent (FR-23). **Experimental preview, API unstable.** |
| **PeerMeshTestKit** | library | `InMemoryTransport` (+ mesh sim) and `ReorderingTransport` — CI without radios (QA-8). |
| **PeerMeshCLI** (`peermesh-cli`) | executable | Diagnostic advertise/browse/host/join over real Bonjour+QUIC between processes. |

## Build & test

- `swift test` — tiers 1 & 2 (engine + loopback QUIC), fast macOS loop. 54 tests today.
- `./Scripts/e2e-cli.sh` — cross-process Bonjour+QUIC exchange (host + joiner as separate processes). Caught the FIN and inbound-retention bugs.
- `xcodebuild test -scheme PeerMesh-Package -destination '<dest>'` for other Apple targets (same suite, N destinations):
  - iOS simulator: `-destination 'platform=iOS Simulator,id=<UDID>'` (resolve a UDID via `xcrun simctl list devices available`).
  - Mac Catalyst: `-destination 'platform=macOS,variant=Mac Catalyst'`.

### Environment flags
- `QUIC_DEBUG=1` — enable the QUIC driver's diagnostic log to stdout.
- `QUIC_DEBUG_LOG=<path>` — also append that log to a file (survives sandboxing).
- `PEERMESH_NO_P2P=1` — disable `includePeerToPeer`. Required for **in-process** entitled E2E tests: `includePeerToPeer` breaks same-machine self-dials (failure mode 10). Never set it for real cross-device runs.

### FlatBuffers regeneration (DD-5 rule 4)
```
flatc --swift -o Sources/PeerMeshProtocol/Generated Schemas/*.fbs
```
Generated sources are committed and CI fails on drift. **Exact-version pin
rule:** the `flatc` in `flake.nix` MUST equal the `google/flatbuffers` runtime
pinned `exact:` in `Package.swift` (currently `25.2.10`) — generated code and
the runtime that reads it are one unit. Bump both together.

## Hard architectural rules

- **PeerMeshProtocol stays sans-I/O.** No sockets, no clocks, no async, no
  Foundation I/O. Its only dependency is FlatBuffers. Time enters the engine as
  an `Input`, never from a clock. (`Locked`/`NSLock` is a synchronization
  primitive, not I/O, and is allowed.)
- **Engine changes land with tier-1 tests first** (`Tests/PeerMeshProtocolTests`).
  The engine is `handle(Input) -> [Effect]`, pure and deterministic — assert on
  the effect list.
- **FlatBuffers schema evolution:** field ids are append-only; never renumber,
  retype, or remove (only `(deprecated)`); no new `(required)` after 1.0;
  enum/union values append-only with `UNKNOWN = 0`. Every inbound buffer goes
  through the verifier (`getCheckedRoot`, hard caps). Generated code is
  committed. Do NOT hand-edit `Schemas/` or `Sources/PeerMeshProtocol/Generated/`.
- **Platform floor: iOS 15 / macOS 12** (QUIC floor). No `Duration` (use
  `TimeInterval`). RFC 9221 datagrams are iOS 16/macOS 13, below the floor — see
  failure mode 1 and the datagram-marker mapping.
- **PeerID equality is key-hash-only.** Identity IS the key. `displayName` is
  cosmetic and source-dependent (AWDL name-only finds carry placeholders). Never
  add `displayName` to identity/equality/hashing semantics.

## Failure modes (from `docs/spike-results.md` — the crown jewels)

These are the platform traps that cost real device time. Do not "simplify" the
code that guards them without understanding why it exists.

1. **QUIC FIN is two-step.** `send(content:isComplete:true)` never surfaces
   completion; payload sent *with* `.finalMessage` delivers NOTHING. Reliable
   pattern: payload on the default context, then a separate empty
   `.finalMessage` send (`quicSend`/`quicFinish`).
2. **Inbound QUIC streams never fire `.ready`.** Streams from
   `newConnectionHandler` are receivable immediately while state stays
   `.preparing`. Start and receive; never gate inbound receives on readiness.
3. **Inbound connection wrappers deallocate silently.** Between group arrival
   and handshake completion nothing holds the wrapper if handlers capture it
   weakly — it deallocates and every stream is dropped. `QUICConnection.accept`
   keeps a `pendingInbound` strong-retention table until adoption/termination.
4. **`group.extract()` streams don't transmit on the iOS-family stack** — they
   report `.ready` but never send. Use `NWConnection(from:)` (iOS 16+/macOS 13+);
   `extract()` is only the macOS 12 fallback.
5. **Keychain identity fetch MUST pin `kSecAttrApplicationLabel`** (the public-key
   hash). An unpinned `kSecClassIdentity` query returns an arbitrary/stale
   identity → `identityMismatch` on every dial. This was THE cross-device connect
   bug; only reproduces on entitled persistent keychains (iOS/iPadOS/Catalyst).
6. **macOS/Catalyst need the Keychain Sharing entitlement** for the
   data-protection keychain (`-34018` without it); iOS grants it implicitly. The
   `SecKeychain` file-fallback (used by bare `swift test` on macOS) is macOS-only
   — unavailable on Catalyst/iOS, which must succeed on path 1 or inject
   `Configuration.tlsProvider`. (The `SecKeychain` API is deprecated by Apple
   with no replacement; the resulting build warnings are unavoidable.)
7. **Invalid Bonjour types register NOTHING, silently.** `validateBonjourType`
   throws instead. MPC-style bare types (`"remotecam"`) are translated only in
   MPCCompat; native callers must pass `_name._udp`.
8. **TXT-record browsing is unreliable over AWDL.** Hence dual-browse: plain
   `.bonjour` (AWDL-capable; PeerID from the instance name) + TXT browse as
   enrichment. Consumers must treat `.found` and `.updated` uniformly.
9. **AWDL requires foreground + screen on.** Idle-looking links get torn down by
   iOS 26 (the bug that killed MPC). Keepalives exist to assert interface use and
   hold the QUIC idle timeout.
10. **`includePeerToPeer` breaks same-machine self-dials.** Use
    `PEERMESH_NO_P2P=1` for in-process tests.
11. **Swift NSError bridging renumbers payload enum cases.** All public errors
    must conform to `LocalizedError` so the diagnostic string survives bridging.

## TODO ledger (single authoritative list)

In-code TODOs reference these by name: `// TODO(ledger-name): one line`.

- **datagrams** — real RFC 9221 QUIC datagrams (currently mapped onto a marked
  reliable stream, floor-compatibility; see `QUICStreamHeaderCodec.datagramMarker`).
- **churn-benchmark** — S-6 formal stream-churn benchmark (nightly CI stub in `ci.yml`).
- **pairing-code** — `.pairingCode` transcript binding (S-4, DD-2).
- **compat-nsstream-bridge** — `MPCCompat.startStream` `NSStream` bridge over `PeerByteStream`.
- **ui-completion** — PeerMeshUI beyond the current skeleton.
- **mesh-join** — join via endpoint exchange for gossiped roster members (roster names peers we haven't discovered).
- **send-ack** — send-acknowledgement API (`PeerSession.send` returns before transport handoff).
- **compat-identity-persistence** — MPCCompat per-name identity persistence (sessions currently use an ephemeral key per `CompatCore`).
- **mesh-hardware** — S-2 mesh-ceiling and S-5 backgrounding hardware spikes.
- **liveness** — FR-14 liveness detection beyond the transport idle timeout.

## More docs

`docs/design-mpc-successor.md` (design), `docs/IMPLEMENTATION-PLAN.md` (plan),
`docs/spike-results.md` (platform findings),
`docs/feasibility-study-mpc-replacement.md` (why this exists).

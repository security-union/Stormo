# Feasibility Study: A Third-Party Replacement for Apple's MultipeerConnectivity Framework

**Technical Report — SU-2026-TR-001**

| | |
|---|---|
| **Prepared by** | Security Union (dario@securityunion.dev) |
| **Date** | July 25, 2026 |
| **Status** | Final |
| **Distribution** | Unlimited |

*This report follows the structure and conventions of a Carnegie Mellon University Software Engineering Institute (SEI) Technical Report. It is an independent work product of Security Union and is not affiliated with, endorsed by, or produced by CMU, the SEI, or Apple Inc.*

---

## Abstract

Apple's MultipeerConnectivity framework (MPC), the high-level API for proximity-based peer-to-peer networking on iOS, macOS, tvOS, and visionOS since 2013, was formally deprecated in the OS 27 SDKs announced at WWDC 2026, after roughly a decade of informal discouragement by Apple Developer Technical Support. Apple's prescribed migration target, Network.framework, is a set of low-level primitives that omits the high-level capabilities developers actually used MPC for: automatic session and mesh management, an invitation handshake, resource transfer with progress reporting, byte streams, turnkey encryption, and system-provided discovery UI. This study (1) analyzes why and how MPC was deprecated, (2) surveys the existing open-source and commercial landscape to determine whether a replacement already exists, (3) assesses the technical feasibility of building an open-source Swift Package Manager (SPM) package that restores MPC's programming model on top of Network.framework, and (4) evaluates candidate product strategies. The study finds that the niche for a maintained, permissively licensed, MPC-equivalent package is genuinely unfilled as of July 2026; that full functional parity with MPC *as it actually behaves today* is technically achievable — under an AI-driven development model (code written by a coding agent, human engineer directing and testing on hardware), an MVP in roughly 1–2 calendar weeks and full parity in roughly 6–10 calendar weeks, with physical multi-device testing rather than code production as the binding constraint (human-equivalent scope: ~7–11 person-months); and that the highest expected-value strategy for a small security-focused consultancy is a pure open-source package with a modern Swift-concurrency core and an MPC-compatibility shim, operated as a credibility and lead-generation engine for migration and security-audit consulting rather than as a directly monetized product.

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Background: MultipeerConnectivity and Its Deprecation](#2-background-multipeerconnectivity-and-its-deprecation)
3. [Current Solution Landscape](#3-current-solution-landscape)
4. [Technical Feasibility Analysis](#4-technical-feasibility-analysis)
5. [Market and Product Feasibility Analysis](#5-market-and-product-feasibility-analysis)
6. [Analysis of Alternatives](#6-analysis-of-alternatives)
7. [Risk Analysis](#7-risk-analysis)
8. [Recommendations](#8-recommendations)
9. [Conclusion](#9-conclusion)
- [Appendix A: MPC → Network.framework API Mapping](#appendix-a-mpc--networkframework-api-mapping)
- [References](#references)

---

## 1. Introduction

### 1.1 Purpose

This report evaluates the feasibility of offering a new product that replaces Apple's deprecated MultipeerConnectivity framework, with particular attention to a 1:1 (or near-1:1) replacement distributed worldwide as an open-source Swift package.

### 1.2 Scope

The study covers: the deprecation's causes, mechanics, and timeline; Apple's recommended migration path and its gaps; a survey of existing open-source packages and commercial SDKs; a technical feasibility assessment including an API-level mapping, effort estimates, and API design alternatives; a market assessment; candidate product strategies; and a risk analysis with mitigations. Out of scope: implementation, detailed protocol design, and Android interoperability engineering (noted only as a strategic option).

### 1.3 Method

Four parallel research tracks were executed against primary sources: (a) Apple's Technote TN3213 and Developer Forums threads including direct statements by Apple Developer Technical Support (DTS) engineers Quinn "The Eskimo!" and Kevin Elliott [1][2][3]; (b) a survey of GitHub, the Swift Package Index, and community channels for existing replacements; (c) an engineering analysis mapping the complete MPC API surface onto Network.framework primitives, sourced from Apple documentation and WWDC sessions [4][5][6]; and (d) a market analysis of commercial alternatives, demand signals, and open-source sustainability precedents. Claims are cited throughout; where evidence is inferential rather than documented, the text says so.

### 1.4 Audience

The primary audience is Security Union's leadership deciding whether to invest in this product. Secondary audiences are engineers who would build it and prospective users evaluating the resulting package.

---

## 2. Background: MultipeerConnectivity and Its Deprecation

### 2.1 What MultipeerConnectivity Is

Introduced with iOS 7 (2013), MPC provides discovery of nearby devices and exchange of message data, byte streams, and resources (files) without the app managing transports or topology [7]. Its API surface comprises:

- **`MCPeerID`** — participant identity.
- **`MCSession`** — a symmetric-peer session of up to 8 devices with automatic mesh membership, internal serial queue, and turnkey encryption (`MCEncryptionPreference`: `.none` / `.optional` / `.required`, plus an optional PKI `securityIdentity`).
- **`MCNearbyServiceAdvertiser` / `MCNearbyServiceBrowser`** — service advertising and browsing with a `discoveryInfo` dictionary and an invitation handshake carrying opaque context data.
- **`MCAdvertiserAssistant` / `MCBrowserViewController`** — system-provided invitation and peer-picker UI.
- **Data paths** — `send(_:toPeers:with:)` in `.reliable` and `.unreliable` modes; `startStream(withName:toPeer:)` for `NSStream`-based byte streams; `sendResource(at:...)` for file transfer with `Progress` reporting and delegate callbacks.

Every participant is a symmetric peer; the framework owns discovery, invitation, session membership, transport selection, and encryption.

### 2.2 Deprecation History and Current Status

MPC's deprecation was unusually protracted:

- **~2015:** Bluetooth support was silently disabled and later removed entirely. Per Quinn (DTS): "Multipeer Connectivity hasn't worked over Bluetooth for 10-ish years. On modern systems its peer-to-peer support is based entirely on peer-to-peer Wi-Fi" [8]. Apple's own framework documentation still (stale) claims Bluetooth PAN as a transport [7].
- **2019–2025:** DTS informally and consistently steered developers to Network.framework. Quinn: "The fact that Multipeer Connectivity is not officially deprecated is an ongoing source of confusion, one that I've been trying to rectify for years (r. 83185901)" [3].
- **2025 (TN3213):** Apple published Technote TN3213, "Moving from Multipeer Connectivity to Network framework," the canonical migration document [1], cross-posted in full to the Developer Forums by Quinn [2].
- **Late 2025–2026 (iOS 26):** MPC's connection establishment regressed severely. The failure mechanism, diagnosed by Kevin Elliott (DTS) from sysdiagnose logs [3]: when the peers are not associated to the same Wi-Fi network, MPC bootstraps discovery/negotiation over **Bluetooth** and then brings up **peer-to-peer Wi-Fi (AWDL)** as the data transport; on iOS 26 a timing race causes the system to tear down the AWDL interface before MPC finishes establishing the connection over it (log signature: `wifip2pd` terminating `AWDLBrowse _rps-service._tcp.local` "with reason User Requested" mid-handshake). Elliott: "it looks to me like there's a timing bug of some kind which is causing the system to teardown the AWDL interface before MPC is able to fully establish the connection." Symptom: the invitation is delivered, both peers transition to `.connecting`, then fall back to `.notConnected`; because it is a race, retries sometimes succeed — developers report up to ~20 attempts per connection (FB22691771). When both devices share an infrastructure Wi-Fi network the Bluetooth→AWDL bootstrap is unnecessary and MPC still works, so the bug narrows MPC's reliable envelope to same-LAN operation — eliminating exactly the ad-hoc, infrastructure-less scenario that was MPC's differentiator. DTS stated the framework team is unlikely to fix it given the deprecation trajectory [3].
- **June 2026 (WWDC 2026):** Formal deprecation landed in the OS 27 SDKs. Two independent pieces of evidence: (a) Apple's documentation metadata now bounds `MCSession` availability at "iOS 7.0.0 – 27.0.0" (identically for iPadOS, macOS 10.10–27.0, Mac Catalyst, tvOS, and visionOS) — a terminal version in the availability range is how Apple's documentation records deprecation, in contrast to the open-ended "7.0+" of supported APIs [9]; (b) developer confirmation in the forums immediately after WWDC 2026: "Well, I guess we have our answer now. It's officially deprecated!" [3].

**Status as of July 2026:** formally deprecated in the OS 27 SDKs (in beta); still shipping and functional (no removal date announced); unmaintained and actively regressing, with its differentiating no-infrastructure connection path already broken on iOS 26 and no fix expected.

### 2.3 Apple's Stated Rationale

TN3213 lists eight drawbacks verbatim [1][2]:

1. An opinionated symmetric-peer model, where "many apps work better with the traditional client/server model."
2. "Good latency but poor throughput."
3. No flow control ("back pressure"), "which severely constrains its utility for general-purpose networking."
4. UI components that are "effectively obsolete."
5. No evolution in years; reliance on `NSStream`, "which has been scheduled for deprecation as far as networking is concerned."
6. Always-on peer-to-peer Wi-Fi, "something that's not required for many apps and can impact the performance of the network."
7. A security model requiring PKI, "tricky to deploy in a peer-to-peer environment."
8. "It has some gnarly bugs."

Kevin Elliott (DTS) supplied the deeper summary: "Critically, this isn't simply about any specific bug or minor failure. The reality is that our experience across a very long period of time is that, in practice, MultipeerConnectivity simply does not work very well for most developers" [3].

### 2.4 Apple's Recommended Migration Path and Its Gaps

TN3213 directs developers to Network.framework: `NWListener` (Bonjour service registration) replaces the advertiser, `NWBrowser` replaces the browser, `NWConnection` carries data over WebSocket/TCP/QUIC (reliable) or UDP (unreliable), TLS-PKI or TLS-PSK replaces `MCEncryptionPreference`, and peer-to-peer Wi-Fi is opt-in via `NWParameters.includePeerToPeer` [1][2]. TN3213 explicitly dispels a widespread myth: "Many folks use Multipeer Connectivity because they think it's the only way to use peer-to-peer Wi-Fi. That's not the case" [2]. Apple's sample "Building a custom peer-to-peer protocol" demonstrates the pattern [6].

However, Apple's own migration document acknowledges that the following MPC capabilities have **no equivalent** and become the application's responsibility:

| Lost capability | TN3213 position |
|---|---|
| Session/mesh membership tracking | "That responsibility falls on you" — keep your own connection list, deduplicate bidirectional connections, gossip membership |
| Invitation handshake with context data | Build your own application-level protocol |
| `MCBrowserViewController` / `MCAdvertiserAssistant` UI | "No direct equivalent" — build your own UI |
| `sendResource` file transfer with progress | "No equivalent support" — reimplement chunked transfer, including flow control; Quinn warns that failing to implement flow control risks unbounded memory growth and jetsam termination on iOS |
| Turnkey encryption enum | Explicit TLS configuration (PKI or PSK) on `NWParameters`; nothing is encrypted by default |
| Internal queue management | "You get to control the queue" — the app owns concurrency discipline |

In short: Apple deprecated a high-level framework and offered a low-level toolkit. The delta between the two is precisely the product opportunity examined in this report.

---

## 3. Current Solution Landscape

### 3.1 Open-Source Packages: Wrappers vs. True Replacements

The survey's central finding is a critical distinction: **nearly every popular "multipeer" Swift package is a wrapper *around* MPC and therefore dies with it.**

**Wrappers around MPC (not replacements):**

| Package | Stars | Status | Note |
|---|---|---|---|
| insidegui/MultipeerKit [10] | ~1,130 | Maintained (June 2026) | Most popular; Codable-over-MPC ergonomics; inherits MPC's fate |
| jpsim/PeerKit | 868 | Stale (2018) | Event-driven MPC wrapper |
| dingwilson/MultiPeer | 245 | Stale (2021) | MPC wrapper |
| maxxfrazer/MultipeerHelper | 106 | Stale (2023) | RealityKit-focused MPC wrapper |
| rchatham/PeerConnectivity | 56 | Active (July 2026) | Functional-style MPC wrapper |
| p-sun P2PKit, maturada/MultipeerKit, CocoaMultipeer | <20 each | Stale/legacy | MPC or deprecated-CFNetwork based |

**True replacements built on Network.framework or other transports:**

- **1amageek/swift-peer-connectivity** [11] — the only project positioned as a multi-transport, MPC-shaped replacement (facade over libp2p, Network.framework, Bonjour, and MPC itself). However: created April 2026, 4 stars, ~22 commits, solo experimental, **no license file** (legally unusable), and requires Swift 6.2 / OS 26 minimums. Not production-viable.
- **utmapp/SwiftConnect** — Network.framework-based but strictly client-server (not a symmetric mesh) and LGPL-3.0 (problematic for App Store distribution patterns).
- **dobster/P2PShareKit** — Network.framework demo-grade sample, stale since 2020.
- **swift-libp2p** — active and serious, but a heavyweight internet-scale P2P stack with a different mental model; not an MPC-shaped local-proximity API.

**Conclusion: the niche of a mature, maintained, permissively licensed, SPM-distributed, MPC-equivalent package built on Network.framework is unfilled as of July 2026** [10][11].

### 3.2 Apple's First-Party Direction: Wi-Fi Aware

Apple's forward-looking answer is the **Wi-Fi Aware framework** (WWDC 2025, iOS/iPadOS 26+), an implementation of the Wi-Fi Alliance NAN standard — the industry-standard equivalent of the AWDL technology underlying AirDrop, driven partly by the EU Digital Markets Act [12][13]. It is not an MPC substitute:

- **Pairing-gated:** devices must first pair through `DeviceDiscoveryUI` or `AccessorySetupKit` system UI with user confirmation. MPC's anonymous, zero-config, app-drawn discovery model is not reproducible on it [14].
- **Hardware-gated:** iPhone 12+, iPad (10th gen)+, and similar floors; a capability check is required at runtime.
- **Platform-gated:** absent from macOS 26 Tahoe at launch, while MPC spans iOS/macOS/tvOS/visionOS [15].
- **Low-level:** actual data transport still runs through Network.framework connections; there is no session, membership, resource, or stream layer.

Wi-Fi Aware does offer capabilities MPC never had — background connectivity to paired devices, robust multi-peer topology, high throughput — making it attractive as an *optional backend* for paired-device scenarios, not as the foundation of an MPC replacement.

### 3.3 Commercial SDKs

| Vendor | Positioning | Relevance |
|---|---|---|
| **Ditto** [16] | Edge-native CRDT sync database with P2P mesh (BLE/P2P-WiFi/LAN); $82M Series B (Mar 2025); sales-led, enterprise pricing | A data-sync platform, not a session API; leaves the lightweight, code-first niche open |
| **Bridgefy** | BLE mesh offline messaging SDK; active 2026 | Messaging/disaster-comms vertical; historical cryptography criticisms (later moved to Signal protocol) — a cautionary tale supporting a security-audited positioning |
| **Google Nearby Connections** | Android-first; iOS support constrained; Wi-Fi Aware interop blocked by device incompatibility [17] | Not a credible iOS-primary option |
| **Photon / internet-relay game SDKs** | Cloud relay multiplayer (free 100 CCU tier) | Substitutes for *some* local-multiplayer demand; caps willingness-to-pay for local-only networking |

No commercial entrant is positioned specifically as "the MPC replacement." No dominant OSS successor has emerged.

---

## 4. Technical Feasibility Analysis

### 4.1 The Transport Question Resolved

The perceived hardest gap — Bluetooth — is not a real gap. MPC's Bluetooth transport was removed roughly a decade ago; modern MPC is peer-to-peer Wi-Fi (AWDL) plus infrastructure Wi-Fi only [8]. Network.framework's `includePeerToPeer` provides exactly the same peer-to-peer Wi-Fi access [18]. Therefore **a Network.framework-based replacement can achieve full parity with what MPC actually does today.** The "works with Wi-Fi off, over Bluetooth" scenario is not achievable by any current third-party Apple API, including MPC itself. Quinn's guidance: "Forget about peer-to-peer Bluetooth, and rely on either peer-to-peer Wi-Fi or Wi-Fi Aware" [8].

Two constraints carry over: AWDL is a private implementation detail reachable only through `includePeerToPeer`, and Network.framework's Happy Eyeballs path selection cannot be forced to prefer the peer-to-peer path [18]. MPC operated under the same ceiling.

### 4.2 API Mapping Summary

Appendix A gives the complete element-by-element mapping. Summary of parity confidence:

- **High confidence (mechanical):** peer identity (UUID + display name in Bonjour TXT records), advertising (`NWListener` + `NWTXTRecord`), browsing (`NWBrowser`), reliable messaging (TCP/WebSocket + custom `NWProtocolFramer` TLV codec, per the WWDC19 template [4]), encryption (TLS-PSK via `sec_protocol_options_add_pre_shared_key` or certificate identity), delegate-equivalent state surfacing.
- **Medium confidence (real engineering):** the invitation handshake (application-level protocol over a fresh TLS connection carrying peer ID + context bytes, with accept/reject semantics); dual reliable+unreliable transport pairing per peer (TCP + negotiated UDP, TN3213's own prescribed pattern [2]); resource transfer (chunked framer messages with `Progress`, cancellation, and back-pressure via send-completion pacing); replacement discovery/invitation UI in SwiftUI.
- **The core net-new work — session/mesh membership:** Network.framework is strictly point-to-point. The library must implement: simultaneous advertise+browse per peer; deterministic connection deduplication (lower peer ID initiates — the pattern Quinn himself recommends [19]); roster gossip so joining peers learn existing members; and state aggregation synthesizing MPC's per-peer session callbacks. At MPC's 8-peer cap this is at most 28 connections in a full mesh — architecturally tractable. `NWConnectionGroup` is not the answer (UDP multicast only, entitlement-gated, unsuited to the data mesh [20]).
- **Deliberately non-1:1:** `startStream`'s `NSStream` objects. `NSStream` is itself scheduled for deprecation for networking [1]; the modern replacement is an `AsyncSequence`-based stream API, with an `NSStream` shim only in a compatibility layer if demanded.

One notable finding: MPC's legacy handshake authorized peers based on a cleartext hostname — a documented weakness [21]. A fresh implementation doing proper TLS-PSK/certificate authentication would *exceed* MPC's security, a natural angle for a security-focused vendor.

### 4.3 API Design Alternatives

- **Design A — exact drop-in (mirror `MCSession` et al. in a new module).** Migration cost approaches zero (change an import). But it perpetuates dated delegate/NSStream ergonomics, and mirroring Apple's `MC`-prefixed class and selector names carries trademark/API-copyright exposure; post-*Google v. Oracle* reimplementation-for-interoperability leans toward fair use in the US, but the question is unsettled and Apple could object.
- **Design B — modern Swift-concurrency core + clearly-unofficial MPC-compatibility shim (recommended).** Native surface built on `async`/`await` and `AsyncSequence` (aligned with WWDC25's structured-concurrency direction for Network.framework [5]), with a separate `MPCCompat` module offering near-drop-in typealiases and shims that consumers opt into. Captures both audiences (greenfield and migrating), minimizes legal exposure on the core, and is future-proof.

### 4.4 Effort Estimate

**Development model assumption:** the code is written by an AI coding agent (Claude Code) with a human engineer directing, reviewing, and operating physical devices. Under this model, code production ceases to be the schedule driver; the human-gated activities — multi-device hardware testing, App Store/entitlement setup, design decisions, and review — dominate the calendar. Classical person-month figures are retained below only as a scope proxy for comparison with conventional staffing.

Module decomposition (scope sizes are transport-agnostic; they measure the amount of behavior to build and verify, not who types it):

| Module | Scope | Size |
|---|---|---|
| Discovery | NWListener/NWBrowser, TXT records, Local Network permission surfacing | Small |
| Transport | Connection lifecycle, TLS-PSK/identity, TLV framer | Small–medium |
| Session/Mesh | Membership, dedup, roster gossip, state aggregation, reliable+unreliable pairing | **Largest module** |
| Resources | Chunked transfer, Progress, cancellation, back-pressure | Medium |
| Streams | AsyncSequence API (+ optional NSStream shim) | Small–medium |
| UI | SwiftUI browser/invite components replacing MCBrowserViewController/MCAdvertiserAssistant | Medium |
| Compat shim | MPC-shaped facade over the above | Small |

Estimates under AI-driven development (human-equivalent scope in parentheses):

- **MVP** (discovery + invitation + reliable/unreliable messaging, 2-peer sessions; order 2–4k LOC): code production in **days of agent sessions**; **~1–2 calendar weeks** end-to-end including on-device validation cycles. (Human-equivalent scope: ~1.5–2.5 person-months.)
- **Full parity** (8-peer auto-mesh, resources, streams, UI, PSK+certificate auth, compat shim; order 8–15k LOC total): **~4–8 calendar weeks incremental**, of which the majority is hardware-in-the-loop iteration rather than code writing. (Human-equivalent scope: ~5–8 person-months incremental.)
- **Physical testing is the binding constraint, not code.** Peer-to-peer Wi-Fi cannot be exercised reliably on the Simulator, and the agent cannot hold two iPhones: every mesh, radio, backgrounding, and Local-Network-permission behavior needs a human running a physical multi-device matrix (several iPhones/iPads across ≥2 OS versions). Loopback-`NWConnection` unit tests of the framer and mesh logic are agent-automatable and should be maximized precisely to shrink the on-device debugging surface. Expect the human time budget to be dominated (>60%) by device-in-hand test/debug cycles and design/API review, with a long tail of per-OS-beta regression checks.
- **Cost implication:** the effective investment shifts from salary-months to (a) a small physical device lab, (b) a few weeks of a senior engineer's direction/review/testing time, and (c) agent compute — materially lowering the barrier to entry, which cuts both ways: it also lowers it for competitors, strengthening the first-mover argument in §8.

Deployment prerequisites are no worse than MPC's: `NSLocalNetworkUsageDescription` and `NSBonjourServices` in Info.plist; standard Bonjour requires **no** multicast entitlement [20]. Network.framework's P2P primitives are solid from iOS 13+, giving a broad OS floor.

**Technical feasibility verdict: HIGH** for the discovery + invitation + messaging core; **MODERATE-TO-HIGH** for full parity, with the mesh/membership layer and multi-device test infrastructure as the principal cost centers.

---

## 5. Market and Product Feasibility Analysis

### 5.1 Demand Signals

- **Dependent app categories:** co-located multiplayer and AR/MR games (RealityKit's `MultipeerConnectivityService` builds on MPC), classroom and presentation tools, offline file transfer, field-work photo/data handoff, kiosk/POS-adjacent local coordination, Unity co-located MR via MPC transport plugins.
- **Ecosystem evidence:** at least eight independent wrapper libraries exist solely to improve MPC's ergonomics — developers repeatedly rebuild the same layer, indicating durable demand for exactly this abstraction [10].
- **Pain evidence:** a decade-long, still-active stream of forum threads on MPC instability, iOS 14 Local Network breakage, SwiftUI impedance, and now the unfixed iOS 26 regression [3]. Every MPC-dependent app now faces a forced migration with no high-level target.

### 5.2 Sizing and Willingness to Pay

This is a **niche market**: realistically low thousands to low tens of thousands of apps touch local P2P. Willingness to pay for a library license is capped by Apple's free primitives below and cloud-relay SDKs (Photon's free tier) above. No public SDK-install count for MPC exists; 42matters is the paid source if hard sizing is later required. The realistic direct-revenue ceiling for a licensed Swift library here is small; the value of the asset is reach and reputation.

### 5.3 Open-Source Sustainability Precedents (Swift Ecosystem)

The consistent pattern: **the library is the funnel, not the revenue.** Point-Free gives away TCA and sells education; GRDB's maintainer explicitly channels sponsors toward "a regular business relationship" for private support and custom development; Vapor runs on sponsorships plus a surrounding services ecosystem [22]. Open-core paywalling of a Swift library is weakly precedented. For a consultancy, the proven model is: respected OSS package → inbound migration/audit/custom-development engagements.

---

## 6. Analysis of Alternatives

Five candidate strategies were evaluated. (Option 0 is the baseline of inaction.)

**Option 0 — Do nothing; each app migrates by hand per TN3213.**
Every affected team independently rebuilds mesh membership, invitation, resources, flow control, and encryption — duplicated, error-prone work (Quinn explicitly warns of jetsam-inducing flow-control mistakes [2]). This is the status quo the market is already unhappy with. *Baseline; no strategic value captured.*

**Option 1 — Pure OSS drop-in package (SPM).**
1:1 MPC-shaped API backed by Network.framework; cross-platform iOS/macOS/tvOS/visionOS; migration guide. Effort ~3–6 person-months to a credible 1.0. Direct revenue ≈ none; reach and credibility maximal; adoption fastest because migration cost approaches an import change. Legal caution on mirroring `MC` names (§4.3).

**Option 2 — Modern async core + MPC-compat shim, pure OSS (technical shape of Option 1, recommended design).**
Same economics as Option 1, better longevity: idiomatic Swift 6 concurrency core, `MPCCompat` module for near-drop-in migration, Wi-Fi Aware as a pluggable backend on iOS 26+ hardware. Slightly more design surface; sidesteps most trademark exposure.

**Option 3 — Open-core (OSS core + paid Pro tier).**
Paid tier aligned with a security brand: audited E2E encryption/key management, multi-hop mesh routing, compliance documentation, priority support. Effort 6–12+ person-months plus licensing/support infrastructure. Conversion risk is real in a niche market with weak Swift open-core precedent. *Defensible only if a design-partner customer pre-commits.*

**Option 4 — Consulting-led OSS (Option 2 as top-of-funnel; revenue from services).**
Ship the OSS package; monetize through MPC-migration engagements ("we will move your app off MPC before iOS 27 breaks it"), P2P/crypto security audits (squarely in Security Union's wheelhouse; the Bridgefy history illustrates demand for audited P2P crypto), and custom feature development — the GRDB model made explicit. Low incremental effort over Option 2; medium, realistic revenue tied to a concrete, deadline-driven pain.

**Option 5 — Full commercial SDK (closed, licensed).**
Competes against well-funded Ditto above and free Apple primitives below, requires a sales motion a small consultancy lacks. *Not recommended.*

### Evaluation Matrix

| Criterion | Opt 1 (OSS drop-in) | Opt 2 (OSS modern+shim) | Opt 3 (Open-core) | Opt 4 (Consulting-led OSS) | Opt 5 (Commercial SDK) |
|---|---|---|---|---|---|
| Engineering effort | Medium | Medium | High | Medium | Very high |
| Direct revenue | None | None | Modest/uncertain | Medium, realistic | Highest ceiling, high risk |
| Adoption speed | Fastest | Fast | Medium | Fast | Slow |
| Legal exposure | Elevated (name mirroring) | Low | Low | Low | Low |
| Longevity vs. Apple's roadmap | Medium | High | Medium | High | Low |
| Fit for small security consultancy | High | High | Medium | **Highest** | Low |

**Selected alternative: Option 2 executed as Option 4** — a pure-OSS, modern-core, MPC-compatible package operated as the funnel for migration and security-audit consulting.

---

## 7. Risk Analysis

Risks are stated in SEI condition–consequence form.

| # | Risk statement (condition; consequence) | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | *Given* Apple is actively investing in Network.framework and Wi-Fi Aware, *there is a possibility that* Apple ships a first-party high-level session API, *resulting in* loss of the package's reason to exist for new code. | Medium | High | Historical pattern: Apple ships primitives, not session frameworks (TN3213 confirms). Moats Apple is unlikely to cover: pre-iOS-26 devices, macOS/tvOS/visionOS coverage while Wi-Fi Aware is iOS-only, unified multi-backend API, SwiftUI-first ergonomics. Architect Wi-Fi Aware as a pluggable backend so first-party progress becomes a feature, not a threat. |
| R2 | *Given* the underlying peer-to-peer Wi-Fi stack has per-OS regressions (as the iOS 26 MPC breakage shows), *there is a possibility that* the replacement inherits platform-level flakiness, *resulting in* support burden and reputational damage attributed to the package. | Medium–High | Medium | Physical-device regression matrix per OS beta; documented known-issues page distinguishing platform bugs from package bugs; rapid FB-filing discipline (a security consultancy publishing precise radar analyses is itself marketing). |
| R3 | *Given* the package mirrors MPC API shapes, *there is a possibility of* trademark/API-copyright objection from Apple, *resulting in* forced rename or takedown. | Low–Medium | Medium | Design B: original names in the core; compat shim clearly labeled unofficial; no `MC` prefix; no Apple branding. |
| R4 | *Given* multi-device wireless testing lacks first-class CI and is the human-gated bottleneck under AI-driven development, *there is a possibility that* releases regress on real hardware, *resulting in* user churn. | Medium | Medium | Treat device-in-hand testing as the schedule driver (§4.4); maximize agent-automatable loopback coverage of framer/mesh logic; small physical device lab; community beta channel. |
| R5 | *Given* the market is a niche with free substitutes, *there is a possibility that* direct monetization fails, *resulting in* an unfunded maintenance tail. | High (for direct monetization) | Low (by design) | Adopt Option 4 explicitly: the package's ROI is measured in consulting pipeline, not license revenue; scope 1.0 tightly; maintenance tail is bounded by the 8-peer/local-proximity scope. |
| R6 | *Given* MPC still ships and formally deprecated APIs persist for years, *there is a possibility that* teams defer migration, *resulting in* slower adoption. | Medium | Low–Medium | The iOS 26 regression already breaks MPC's headline scenario today — messaging leads with "it is already broken," not "it will be removed." Deprecation warnings in Xcode 27 builds create a forcing function each release cycle. |

---

## 8. Recommendations

1. **Build the package; treat it as strategic marketing with engineering rigor (Options 2+4).** The niche is verified open, the technical path is clear, and the forcing function (formal deprecation + an already-broken framework) is active now. First-mover credibility in a vacated Apple niche compounds.

2. **Phase the delivery** (AI-driven development; calendar time is gated by hardware testing and review, not code production — see §4.4):
   - **Phase 1 — MVP (~1–2 weeks):** discovery, invitation handshake with context data, reliable + unreliable messaging, TLS-PSK by default, SwiftUI sample app, TN3213-anchored migration guide. Ship on SPM with a permissive license (MIT or Apache-2.0), Swift 6 strict concurrency, iOS 13+/macOS 10.15+ floor.
   - **Phase 2 — Parity (~4–8 weeks incremental):** 8-peer auto-mesh with roster gossip, resource transfer with `Progress`, `AsyncSequence` streams, certificate-identity auth, SwiftUI browser/invite components, `MPCCompat` shim. Front-load agent-automatable loopback test coverage to minimize device-in-hand debugging.
   - **Phase 3 — Differentiation:** Wi-Fi Aware backend (iOS 26+ paired/high-throughput scenarios), audited-cryptography write-up, optional larger-than-8 mesh.

3. **Lead with security.** Do proper TLS-PSK/certificate authentication (exceeding MPC's known-weak legacy handshake [21]), publish a threat model, and commission/self-publish a crypto review. This differentiates from every historical wrapper and aligns the package with the consultancy's brand.

4. **Stand up the consulting funnel on day one:** a "migrate off MultipeerConnectivity" services page, the migration guide as top-of-funnel content, and public teardown posts (the iOS 26 AWDL regression analysis writes itself).

5. **Avoid:** the closed commercial SDK (Option 5), exact `MC`-name mirroring in the core API, and any Bluetooth-parity promises (no current Apple API offers it — say so plainly in the README; honesty here is a trust signal).

6. **Naming/positioning:** an original name with a tagline of the form "the spiritual successor to MultipeerConnectivity, built on Network.framework." Verify availability on the Swift Package Index before announcement.

---

## 9. Conclusion

MultipeerConnectivity's deprecation is real, formal as of the OS 27 SDKs, and — more urgently — the framework's flagship capability is already broken on iOS 26 with no fix coming. Apple's replacement guidance hands developers low-level primitives and a list of hard problems (mesh membership, invitation, flow-controlled transfer, encryption setup) that MPC used to solve for them. No credible open-source or commercial product fills that gap as of July 2026: the popular packages die with MPC, the one true attempt is a two-month-old unlicensed experiment, and Apple's Wi-Fi Aware is pairing-gated, hardware-gated, and iOS-only.

Building the missing layer is technically feasible at modest scale — with AI-driven development, roughly one to two weeks to a useful MVP and two to three months to full parity, gated by physical multi-device testing rather than code production — because the hardest perceived gap (Bluetooth) turns out to be a decade-stale myth rather than a real regression. The direct-revenue market is small, but that is the wrong lens: for a security-focused consultancy, a well-executed, security-audited, MPC-compatible open-source package is a durable credibility engine attached to a deadline-driven migration pain that enterprises will pay to outsource. The recommended course is to build it in the open, lead with security, and let the package sell the services.

---

## Appendix A: MPC → Network.framework API Mapping

| MPC element | Network.framework realization | Parity confidence |
|---|---|---|
| `MCPeerID` | Library `PeerID` value type (UUID + display name), carried in Bonjour TXT record and invitation handshake; archivable for stability | High |
| `MCNearbyServiceAdvertiser` (+ `discoveryInfo`) | `NWListener` with `NWListener.Service(name:type:)`; `discoveryInfo` → `NWTXTRecord`; `includePeerToPeer = true` | High |
| `MCNearbyServiceBrowser` | `NWBrowser(for: .bonjour(type:domain:))`; TXT via `Result.metadata`; invitation is a custom handshake, not a browser feature | High (discovery) / Medium (invite) |
| Invitation with `context: Data` | First framer message over a fresh TLS connection: `Invitation{peerID, context}` → app accept/reject → `Accepted`/close | Medium |
| `MCSession` membership (≤8 peers, auto-mesh) | Library session layer: simultaneous listen+browse, deterministic dedup (lower peer ID dials), roster gossip, per-connection state aggregation | Medium (core net-new work) |
| `send(_:toPeers:with: .reliable)` | TCP/WebSocket `NWConnection` + `NWProtocolFramer` TLV codec (WWDC19 pattern) | High |
| `send(... .unreliable)` | Parallel UDP `NWConnection` negotiated over the reliable channel (TN3213 pattern) | Medium |
| `sendResource` + `Progress` + delegate start/finish | Chunked framer messages (name, length header), temp-file assembly, `Progress` with cancellation, back-pressure via send-completion pacing | Medium |
| `startStream` (`NSStream`) | `AsyncSequence`-based stream API over a dedicated connection; optional `NSStream` shim in compat module (`NSStream` itself is deprecation-bound) | Medium (modern) / Low (exact shim) |
| `MCEncryptionPreference` / `securityIdentity` | `NWProtocolTLS.Options`: PSK via `sec_protocol_options_add_pre_shared_key` (CryptoKit-derived) or identity via `sec_protocol_options_set_local_identity` | High (PSK) / Medium (identity) |
| `didReceiveCertificate` | `sec_protocol_options_set_verify_block` | High |
| `MCSessionDelegate` state callbacks | Aggregated from `NWConnection.stateUpdateHandler` across the mesh | High |
| `MCAdvertiserAssistant` | Library-provided SwiftUI invitation sheet | Medium (app-layer UI) |
| `MCBrowserViewController` | Library-provided SwiftUI peer picker (DeviceDiscoveryUI is pairing-oriented, not equivalent) | Medium |
| Bluetooth PAN transport (documented) | Non-existent in MPC for ~10 years; no third-party API offers it; parity with actual behavior maintained | N/A (myth) |
| Manual peer bootstrap (`nearbyConnectionData`) | Library-defined out-of-band join token (optional) | N/A |

Deployment: `NSLocalNetworkUsageDescription` + `NSBonjourServices` required (same as MPC); no multicast entitlement for standard Bonjour; Wi-Fi Aware backend additionally requires the `com.apple.developer.wifi-aware` entitlement and `WiFiAwareServices` declarations.

---

## References

[1] Apple Inc. *TN3213: Moving from Multipeer Connectivity to Network framework.* https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework

[2] Quinn "The Eskimo!" (Apple DTS). Forum cross-post of TN3213 with discussion. https://developer.apple.com/forums/thread/776069

[3] Apple Developer Forums. "Multipeer Connectivity connection is flaky on iOS 26" (incl. Kevin Elliott and Quinn, DTS, on the AWDL teardown regression and deprecation trajectory; June 2026 deprecation confirmation). https://developer.apple.com/forums/thread/803339

[4] Apple Inc. WWDC19 Session 713: *Advances in Networking, Part 2* (NWListener/NWBrowser/framer/TLS-PSK patterns). https://developer.apple.com/videos/play/wwdc2019/713/

[5] Apple Inc. WWDC25 Session 250: *Use structured concurrency with Network framework.* https://developer.apple.com/videos/play/wwdc2025/250/

[6] Apple Inc. Sample: *Building a custom peer-to-peer protocol.* https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol

[7] Apple Inc. *Multipeer Connectivity* framework documentation. https://developer.apple.com/documentation/multipeerconnectivity

[8] Quinn "The Eskimo!" (Apple DTS). On MPC's removed Bluetooth support and transport guidance. https://developer.apple.com/forums/thread/809565 and https://developer.apple.com/forums/thread/751839

[9] Apple Inc. `MCSession` documentation data (availability metadata "iOS: 7.0.0 – 27.0.0" et al.). https://developer.apple.com/tutorials/data/documentation/multipeerconnectivity/mcsession.md (retrieved July 25, 2026)

[10] insidegui. *MultipeerKit.* https://github.com/insidegui/MultipeerKit ; GitHub topic survey: https://github.com/topics/multipeerconnectivity?l=swift

[11] 1amageek. *swift-peer-connectivity.* https://github.com/1amageek/swift-peer-connectivity ; https://swiftpackageindex.com/1amageek/swift-peer-connectivity

[12] Apple Inc. *Wi-Fi Aware* framework documentation. https://developer.apple.com/documentation/WiFiAware

[13] 9to5Mac. "iOS 26 to let third-party apps build their own AirDrop alternative." https://9to5mac.com/2025/06/20/ios-26-to-let-third-party-apps-build-their-own-airdrop-alternative/ ; MacRumors coverage: https://www.macrumors.com/2025/06/21/ios-26-adding-two-new-wi-fi-features/

[14] Apple Inc. WWDC25 Session 228: *Supercharge device connectivity with Wi-Fi Aware.* https://developer.apple.com/videos/play/wwdc2025/228/ ; *DeviceDiscoveryUI.* https://developer.apple.com/documentation/devicediscoveryui

[15] Apple Developer Forums. Wi-Fi Aware absent from macOS 26 (FB17988268). https://developer.apple.com/forums/thread/787701

[16] TechCrunch. "Ditto lands $82M to synchronize data from the edge to the cloud" (March 2025). https://techcrunch.com/2025/03/12/ditto-lands-82m-to-synchronize-data-from-the-edge-to-the-cloud/ ; https://docs.ditto.live/home/about-ditto

[17] Google Nearby. Wi-Fi Aware iOS interop discussion. https://github.com/google/nearby/discussions/2447

[18] Apple Inc. `NWParameters.includePeerToPeer.` https://developer.apple.com/documentation/network/nwparameters/includepeertopeer

[19] Quinn "The Eskimo!" (Apple DTS). Peer-deduplication pattern for mesh over Network framework. https://developer.apple.com/forums/thread/663596

[20] Apple Inc. Multicast entitlement guidance (standard Bonjour exempt). https://developer.apple.com/news/?id=0oi77447

[21] evilsocket. *Reverse Engineering the Apple MultiPeer Connectivity Framework.* https://www.evilsocket.net/2022/10/20/Reverse-Engineering-the-Apple-MultiPeer-Connectivity-Framework/

[22] GRDB sponsorship model: https://github.com/groue/GRDB.swift ; Point-Free: https://github.com/pointfreeco/swift-composable-architecture ; Vapor: https://github.com/vapor/vapor ; GitHub Sponsors scale: https://github.blog/open-source/maintainers/100-million-for-open-source-a-milestone-built-by-the-community/

---

*Report prepared with multi-agent research: four parallel research tracks (deprecation analysis, ecosystem survey, technical feasibility, market analysis) synthesized July 25, 2026. Facts were verified against primary Apple sources where accessible; effort estimates and strategy assessments are professional judgment and are labeled as such in the text.*

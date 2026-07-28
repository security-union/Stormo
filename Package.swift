// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stormo",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        // Sans-I/O protocol engine: deterministic state machine + signal model,
        // fully testable without any transport (DD-6).
        .library(name: "StormoProtocol", targets: ["StormoProtocol"]),
        // Modern core: discovery, sessions, messaging, streams, resources over QUIC (DD-1).
        .library(name: "Stormo", targets: ["Stormo"]),
        // Near-drop-in migration surface for MultipeerConnectivity codebases (FR-24).
        .library(name: "MPCCompat", targets: ["MPCCompat"]),
        // SwiftUI peer picker and invitation consent components (FR-23).
        .library(name: "StormoUI", targets: ["StormoUI"]),
        // In-memory transport and mesh simulation for CI without radios (QA-8).
        .library(name: "StormoTestKit", targets: ["StormoTestKit"]),
        // Diagnostic CLI: advertise/browse/chat between real processes over
        // Bonjour + QUIC (the production discovery path).
        // Named "stormo-cli", not "Stormo": a product differing from the
        // Stormo library only by case collides on case-insensitive APFS when
        // xcodebuild materializes package products as modules.
        .executable(name: "stormo-cli", targets: ["StormoCLI"]),
    ],
    dependencies: [
        // Signaling plane serialization (DD-5). Pinned EXACTLY to match the
        // flatc in flake.nix — generated code and runtime must be the same
        // version (25.12.x split out a `Common` module the 25.2.10 codegen
        // doesn't import). Bump both together (DD-5 rule 4).
        .package(url: "https://github.com/google/flatbuffers.git", exact: "25.2.10"),
        // Pure-Swift X.509 for self-signed identity certificates (DD-2). Used by
        // the Stormo target only — StormoProtocol stays FlatBuffers-only.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
    ],
    targets: [
        // Sans-I/O (DD-6): the ONLY dependency is FlatBuffers (pure CPU).
        // No Network.framework, no clocks, no async — keep it that way.
        .target(
            name: "StormoProtocol",
            dependencies: [
                .product(name: "FlatBuffers", package: "flatbuffers")
            ]
        ),
        // Runtime shell: executes engine Effects against real transports.
        .target(
            name: "Stormo",
            dependencies: [
                "StormoProtocol",
                .product(name: "X509", package: "swift-certificates"),
                // The QUIC driver serializes the DD-7 `StreamHeader` prologue of
                // every dedicated stream (the generated FlatBuffers type lives in
                // StormoProtocol). Moving bytes onto the wire is driver work
                // (DD-6); no protocol decisions live here.
                .product(name: "FlatBuffers", package: "flatbuffers"),
            ]
        ),
        .target(name: "MPCCompat", dependencies: ["Stormo"]),
        .target(name: "StormoUI", dependencies: ["Stormo"]),
        .target(name: "StormoTestKit", dependencies: ["Stormo"]),
        .executableTarget(name: "StormoCLI", dependencies: ["Stormo"]),
        // Tier 1 (DD-6): engine tests — no transport, no radios, deterministic.
        .testTarget(name: "StormoProtocolTests", dependencies: ["StormoProtocol"]),
        .testTarget(
            name: "StormoTests",
            dependencies: ["Stormo", "StormoTestKit"]
        ),
        .testTarget(name: "MPCCompatTests", dependencies: ["MPCCompat", "StormoTestKit"]),
    ],
    swiftLanguageModes: [.v6]
)

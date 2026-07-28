/// Stromo wire-protocol version, negotiated once per connection via the
/// `PeerHello` bootstrap (peer_hello.fbs) — never per-signal.
///
/// Semver interop rule: peers talk iff `major` matches. `minor` is additive
/// (append-only schema evolution — the newer side adapts to the older);
/// `patch` never changes the wire. A mismatch surfaces as a typed error
/// naming both versions, so apps can tell the user "upgrade required". That
/// diagnosis is only possible because the QUIC ALPN is frozen: bumping it on
/// a major change would fail the handshake before hello, hiding the reason.
public struct ProtocolVersion: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let major: UInt16
    public let minor: UInt16
    public let patch: UInt16

    public init(major: UInt16, minor: UInt16, patch: UInt16) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The protocol version this build speaks. Bump `major` only for changes
    /// old peers must reject; `minor` for additive schema evolution.
    public static let current = ProtocolVersion(major: 1, minor: 0, patch: 0)

    public func isCompatible(with other: ProtocolVersion) -> Bool {
        major == other.major
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

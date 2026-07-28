import Foundation

/// A minimal mutex-guarded box for shared mutable state.
///
/// This lives in the sans-I/O `StromoProtocol` target (its only dependency is
/// FlatBuffers, DD-6) purely so the runtime shell and its transports — which
/// each need the same primitive — share one canonical implementation rather
/// than re-declaring it per module. `NSLock` is a synchronization primitive, not
/// I/O, so it does not violate the target's no-I/O rule.
package final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    package init(_ value: T) { self.stored = value }

    package var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Mutate the boxed value under the lock and return a result.
    package func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&stored) }
    }
}

extension Locked where T == Bool {
    /// Atomically set to `new` iff currently `expected`; returns whether it
    /// changed. The idiom that fires a one-shot completion (continuation resume,
    /// ready/close latch) exactly once across concurrent callbacks.
    package func compareAndSet(expected: Bool, new: Bool) -> Bool {
        withLock { current in
            guard current == expected else { return false }
            current = new
            return true
        }
    }
}

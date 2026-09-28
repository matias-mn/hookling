import Foundation

/// A monotonic time source, injectable so every timing rule can be tested
/// without sleeping.
///
/// Named `HooklingClock` rather than `Clock` to avoid colliding with the standard
/// library protocol of that name.
public protocol HooklingClock: Sendable {
    /// Nanoseconds since an arbitrary fixed origin. Never goes backwards, and is
    /// unaffected by wall-clock adjustments or sleep.
    var now: Nanoseconds { get }
}

/// The real clock: `mach_absolute_time` via `clock_gettime_nsec_np`, which keeps
/// counting correctly across a system clock change.
public struct MonotonicClock: HooklingClock {
    public init() {}

    public var now: Nanoseconds {
        Nanoseconds(bitPattern: UInt(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)))
    }
}

/// A clock the tests drive by hand.
public final class ManualClock: HooklingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Nanoseconds

    public init(now: Nanoseconds = 0) {
        self.current = now
    }

    public var now: Nanoseconds {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by delta: Nanoseconds) {
        lock.lock()
        defer { lock.unlock() }
        current += delta
    }

    public func advance(milliseconds: Int) {
        advance(by: nanoseconds(milliseconds: milliseconds))
    }

    public func advance(seconds value: TimeInterval) {
        advance(by: nanoseconds(seconds: value))
    }
}

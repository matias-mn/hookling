import Foundation

/// A source of randomness, injected for exactly the reason `HooklingClock` is.
///
/// Wandering is the only thing this pet does that is not a pure function of
/// events and elapsed time, so without this the behaviour would be untestable —
/// and "he sometimes walks somewhere" is precisely the kind of rule that needs a
/// test. Upstream Codex has no randomness at all (`docs/codex-pet-analysis.md`
/// §7), so there is nothing here to be faithful to; this is ours.
public protocol HooklingRandom: Sendable {
    /// A value in `0..<1`.
    func next() -> Double
}

public struct SystemRandom: HooklingRandom {
    public init() {}
    public func next() -> Double { Double.random(in: 0..<1) }
}

/// SplitMix64: small, well-distributed, and above all reproducible, so a test
/// that fixes the seed sees the same walk on every run.
public final class SeededRandom: HooklingRandom, @unchecked Sendable {
    private let lock = NSLock()
    private var state: UInt64

    public init(seed: UInt64 = 0x5EED) {
        self.state = seed
    }

    public func next() -> Double {
        lock.lock()
        defer { lock.unlock() }
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= (z >> 31)
        // The top 53 bits are the mantissa's worth, which is the standard way to
        // land in 0..<1 without bias.
        return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// How far and how often Hookling strolls, shaped like `SessionPolicy` so the two
/// sets of tunables read the same way.
public struct WanderPolicy: Sendable, Equatable {
    /// Shortest and longest pause between strolls.
    public var restMin: Nanoseconds
    public var restMax: Nanoseconds

    /// Shortest and longest distance of one stroll, in points.
    public var distanceMin: Double
    public var distanceMax: Double

    /// Points per second while walking, at `timingScale` 1.0.
    ///
    /// The walk cycle is 8 frames over ~1.06s, and the sprite is 96pt wide at 1x,
    /// so 40pt/s covers a little under half his body per stride — which is what
    /// stops it reading as a moonwalk.
    public var pointsPerSecond: Double

    public static let `default` = WanderPolicy(
        restMin: nanoseconds(seconds: 8),
        restMax: nanoseconds(seconds: 20),
        distanceMin: 150,
        distanceMax: 600,
        pointsPerSecond: 40
    )

    public init(
        restMin: Nanoseconds,
        restMax: Nanoseconds,
        distanceMin: Double,
        distanceMax: Double,
        pointsPerSecond: Double
    ) {
        self.restMin = restMin
        self.restMax = restMax
        self.distanceMin = distanceMin
        self.distanceMax = distanceMax
        self.pointsPerSecond = pointsPerSecond
    }
}

/// What the wander wants to happen this frame.
public struct WanderMotion: Equatable, Sendable {
    /// Points to move horizontally, positive to the right.
    public let dx: Double

    /// The walk cycle to draw, or `nil` when he is standing still.
    public let animationName: String?

    /// When to look again, so the renderer wakes up to start or finish a stroll
    /// even though the idle animation's own frames are far longer than that.
    public let nextDecisionIn: Nanoseconds?

    /// True on the frame a stroll completes — the app persists his position here
    /// rather than on every frame.
    public let didFinishStroll: Bool

    public init(
        dx: Double,
        animationName: String?,
        nextDecisionIn: Nanoseconds?,
        didFinishStroll: Bool
    ) {
        self.dx = dx
        self.animationName = animationName
        self.nextDecisionIn = nextDecisionIn
        self.didFinishStroll = didFinishStroll
    }

    /// Standing still, with nothing to wake up for.
    public static let still = WanderMotion(
        dx: 0, animationName: nil, nextDecisionIn: nil, didFinishStroll: false
    )
}

/// Decides when Hookling goes for a walk, which way, and how far.
///
/// Deliberately knows nothing about screens or windows: it emits a displacement
/// and the app clamps it, reporting back via `blocked()` when he has run out of
/// desk. That split is what keeps this testable without AppKit, and it is the
/// same division of labour as the rest of the core.
public final class WanderPlanner {
    public static let rightAnimation = "running-right"
    public static let leftAnimation = "running-left"

    /// How often to move while walking. The walk cycle only changes sprite every
    /// ~120ms, but stepping the *position* four times as often is what separates
    /// gliding from lurching — and `PetView.display` ignores a repeated sprite,
    /// so the extra frames cost a window move and nothing else.
    public static let stepInterval: Nanoseconds = nanoseconds(milliseconds: 50)

    private enum Phase {
        case resting(until: Nanoseconds)
        case walking(remaining: Double, goingRight: Bool)
    }

    private let clock: any HooklingClock
    private let random: any HooklingRandom
    private let policy: WanderPolicy

    private var phase: Phase
    private var lastTickAt: Nanoseconds

    /// The menu's "Wander when idle". Turning it off mid-stride stops him where
    /// he stands.
    public var isEnabled: Bool = true

    public init(
        clock: any HooklingClock = MonotonicClock(),
        random: any HooklingRandom = SystemRandom(),
        policy: WanderPolicy = .default
    ) {
        self.clock = clock
        self.random = random
        self.policy = policy
        self.lastTickAt = clock.now
        // Start out resting, so he does not set off the instant he appears.
        let span = max(policy.restMax - policy.restMin, 0)
        self.phase = .resting(
            until: clock.now + policy.restMin + Nanoseconds(Double(span) * random.next())
        )
    }

    public var isWalking: Bool {
        if case .walking = phase { return true }
        return false
    }

    // MARK: - Driving

    /// Advance the wander. Returns what the app should do about his position.
    public func tick(state: PetState, overlayActive: Bool, timingScale: Double) -> WanderMotion {
        let now = clock.now
        let elapsed = max(now - lastTickAt, 0)
        lastTickAt = now

        // He strolls only when genuinely idle, and never under a transient: a
        // wave or a jump plays on the spot. An interrupted stroll is abandoned
        // rather than remembered, so finishing a turn cannot make him lurch back
        // into a stride he started minutes ago.
        guard isEnabled, state == .idle, !overlayActive else {
            if isWalking { beginRest(now: now) }
            return .still
        }

        if case .resting(let until) = phase {
            guard now >= until else {
                return WanderMotion(
                    dx: 0,
                    animationName: nil,
                    nextDecisionIn: until - now,
                    didFinishStroll: false
                )
            }
            beginWalk()
            // The first frame of a stroll covers no ground on purpose: `elapsed`
            // here spans the whole rest, because the renderer was asleep on a
            // 1.9-second idle frame. Applying it would teleport him.
            return WanderMotion(
                dx: 0,
                animationName: currentAnimation,
                nextDecisionIn: Self.stepInterval,
                didFinishStroll: false
            )
        }

        guard case .walking(let remaining, let goingRight) = phase else { return .still }

        // Slower playback means slower travel, or his feet stop matching the
        // ground he covers.
        let speed = policy.pointsPerSecond / max(timingScale, 0.01)
        let travelled = min(speed * seconds(nanoseconds: elapsed), remaining)
        let left = remaining - travelled
        let dx = goingRight ? travelled : -travelled

        guard left > 0 else {
            beginRest(now: now)
            return WanderMotion(
                dx: dx,
                animationName: nil,
                nextDecisionIn: restRemaining(now: now),
                didFinishStroll: true
            )
        }

        phase = .walking(remaining: left, goingRight: goingRight)
        // Wake for the next step, or sooner if the stroll ends before then.
        let untilArrival = nanoseconds(seconds: left / speed)
        return WanderMotion(
            dx: dx,
            animationName: currentAnimation,
            nextDecisionIn: max(min(Self.stepInterval, untilArrival), 1),
            didFinishStroll: false
        )
    }

    /// He has run out of screen: turn around and spend what is left of the trip
    /// going the other way, so an edge reads as a turn rather than a stall.
    public func blocked() {
        guard case .walking(let remaining, let goingRight) = phase else { return }
        phase = .walking(remaining: remaining, goingRight: !goingRight)
    }

    /// Stop and take a fresh rest — the user has picked him up.
    public func suspend() {
        beginRest(now: clock.now)
    }

    // MARK: - Internals

    private var currentAnimation: String? {
        guard case .walking(_, let goingRight) = phase else { return nil }
        return goingRight ? Self.rightAnimation : Self.leftAnimation
    }

    private func beginRest(now: Nanoseconds) {
        let span = max(policy.restMax - policy.restMin, 0)
        phase = .resting(until: now + policy.restMin + Nanoseconds(Double(span) * random.next()))
    }

    private func beginWalk() {
        let span = max(policy.distanceMax - policy.distanceMin, 0)
        phase = .walking(
            remaining: policy.distanceMin + span * random.next(),
            goingRight: random.next() < 0.5
        )
    }

    private func restRemaining(now: Nanoseconds) -> Nanoseconds? {
        guard case .resting(let until) = phase else { return nil }
        return max(until - now, 1)
    }
}

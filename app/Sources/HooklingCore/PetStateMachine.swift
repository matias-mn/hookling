import Foundation

/// Everything the renderer needs for one screen update.
public struct PetTick: Equatable, Sendable {
    public let spriteIndex: Int

    /// When to tick again, or `nil` for "nothing will change" — the renderer then
    /// arms no timer at all.
    public let delay: Nanoseconds?

    public let animationName: String
    public let state: PetState

    /// True while a one-shot or a preview is playing over the persistent state.
    public let isOverlay: Bool

    /// Points to move horizontally this frame, positive to the right. Non-zero
    /// only while he is wandering; the app is what actually moves the window.
    public let movement: Double

    /// True on the frame a stroll completes, so the app can persist his new spot
    /// without writing preferences on every frame.
    public let didFinishStroll: Bool

    public init(
        spriteIndex: Int,
        delay: Nanoseconds?,
        animationName: String,
        state: PetState,
        isOverlay: Bool,
        movement: Double = 0,
        didFinishStroll: Bool = false
    ) {
        self.spriteIndex = spriteIndex
        self.delay = delay
        self.animationName = animationName
        self.state = state
        self.isOverlay = isOverlay
        self.movement = movement
        self.didFinishStroll = didFinishStroll
    }
}

/// Persistent state plus an optional overlay animation.
///
/// This is the structure the brief asked for instead of a pile of timers. There
/// are exactly two layers:
///
/// * a **persistent state**, which changes only when a meaningful event arrives
///   and otherwise animates indefinitely — so a 90-second Claude turn shows 90
///   seconds of running, not 2 seconds of running and 88 of idle;
/// * an optional **overlay**, which plays once (a wave, a jump, a flinch) or for
///   a fixed preview window, and on finishing hands control straight back to
///   whatever the persistent state is *at that moment*.
///
/// A state change that arrives mid-overlay is recorded immediately and takes
/// effect when the overlay ends. Overlays are all under 1.3 seconds, so nothing
/// visibly lags, and a heartbeat for a state that is already current is ignored
/// rather than restarting the animation from frame 0.
public final class PetStateMachine {
    private struct Overlay {
        let animation: Animation
        let startedAt: Nanoseconds
        let expiresAt: Nanoseconds
    }

    private let catalog: AnimationCatalog
    private let clock: any HooklingClock

    private var persistent: PetState
    private var persistentAnimation: Animation
    private var persistentStartedAt: Nanoseconds
    private var overlay: Overlay?
    private var substitute: String?

    /// While set, the persistent layer draws this track instead of the one the
    /// state implies.
    ///
    /// This is how wandering gets its walk cycle without inventing a state: he is
    /// still `idle`, he is just idle *and strolling*. Kept as a substitution
    /// rather than an overlay because overlays are one-shots that hand control
    /// back, and a wave arriving mid-stroll must still play over the top.
    public var substituteAnimation: String? {
        get { substitute }
        set {
            guard newValue != substitute else { return }
            substitute = newValue
            rebuildPersistentAnimation(restart: overlay == nil)
        }
    }

    /// When true, persistent states use Codex's exact composition: play the action
    /// three times, then loop idle. Off by default — see `docs/codex-pet-analysis.md` §8.
    public var faithfulLoops: Bool {
        didSet {
            guard faithfulLoops != oldValue else { return }
            rebuildPersistentAnimation(restart: true)
        }
    }

    /// How long every frame is held, as a multiple of the catalog's durations.
    /// 1.0 is Codex's exact timing; larger is slower.
    ///
    /// This is playback only, which is the point: `animations.json` stays a
    /// faithful copy of upstream's table, and taste lives in a preference. It
    /// changes the *pace* of a loop, never how many times anything repeats — a
    /// persistent state loops until the state changes either way, and an
    /// overlay's window is derived from its own scaled duration, so a slowed
    /// wave plays to the end rather than being cut off.
    public var timingScale: Double {
        get { scale }
        set {
            // A scale of zero would mean frames of no length; negative is
            // meaningless. Clamp rather than trap, so a bad preference cannot
            // take the pet down.
            let clamped = max(newValue, 0.01)
            guard clamped != scale else { return }
            scale = clamped
            rebuildPersistentAnimation(restart: true)
        }
    }

    private var scale: Double

    /// Honours the system "Reduce motion" setting the way Codex does when
    /// animations are disabled: hold the first frame, schedule nothing, ignore
    /// overlays. The pose still changes with state, so the pet stays informative.
    public var reducedMotion: Bool {
        didSet {
            guard reducedMotion != oldValue else { return }
            if reducedMotion { overlay = nil }
        }
    }

    public init(
        catalog: AnimationCatalog,
        clock: any HooklingClock = MonotonicClock(),
        initialState: PetState = .idle,
        faithfulLoops: Bool = false,
        reducedMotion: Bool = false,
        timingScale: Double = 1.0
    ) {
        self.catalog = catalog
        self.clock = clock
        self.persistent = initialState
        self.faithfulLoops = faithfulLoops
        self.reducedMotion = reducedMotion
        self.scale = max(timingScale, 0.01)
        self.persistentStartedAt = clock.now
        self.persistentAnimation = catalog.animationOrIdle(
            named: initialState.animationName,
            mode: faithfulLoops ? .codexTriple : .loopPrimary
        ).scaled(by: max(timingScale, 0.01))
    }

    // MARK: - Inputs

    public var state: PetState { persistent }

    public var isOverlayActive: Bool { overlay != nil }

    /// The track the persistent layer is actually drawing: the state's own, or a
    /// substitute while he is strolling. Reported by `hooklingctl status`, which
    /// should describe what is on screen rather than what the state implies.
    public var persistentAnimationName: String { persistentAnimation.name }

    /// Set the persistent state. A repeat of the current state is ignored, so
    /// heartbeat events (a tool call every few hundred milliseconds) do not
    /// restart the running cycle and leave it stuck on its first frame.
    public func setState(_ state: PetState) {
        guard state != persistent else { return }
        persistent = state
        rebuildPersistentAnimation(restart: overlay == nil)
    }

    /// Play an animation once over the current state, then revert.
    public func play(transient name: String) {
        guard !reducedMotion else { return }
        guard let animation = catalog.animation(named: name, mode: .once)?.scaled(by: scale)
        else { return }
        let now = clock.now
        overlay = Overlay(
            animation: animation,
            startedAt: now,
            expiresAt: now + max(animation.totalDuration, 1)
        )
    }

    /// Loop an animation for a fixed window without touching the persistent
    /// state. Used by `hooklingctl demo` to show each track long enough to compare
    /// against Codex.
    public func preview(_ name: String, duration: Nanoseconds) {
        guard let animation = catalog.animation(named: name, mode: .loopPrimary)?.scaled(by: scale)
        else { return }
        let now = clock.now
        overlay = Overlay(
            animation: animation,
            startedAt: now,
            expiresAt: now + max(duration, 1)
        )
    }

    public func endOverlay() {
        guard overlay != nil else { return }
        overlay = nil
        persistentStartedAt = clock.now
    }

    // MARK: - Output

    public func tick() -> PetTick {
        let now = clock.now

        if let active = overlay, now >= active.expiresAt {
            overlay = nil
            persistentStartedAt = now
        }

        let animation = overlay?.animation ?? persistentAnimation
        let startedAt = overlay?.startedAt ?? persistentStartedAt
        let isOverlay = overlay != nil

        // Frozen: hold the first frame and schedule nothing. Both "Reduce motion"
        // and the sleeping state land here, which is what makes idle CPU zero
        // rather than merely low.
        if reducedMotion || (persistent.isFrozen && !isOverlay) {
            return PetTick(
                spriteIndex: animation.frames.first?.spriteIndex ?? 0,
                delay: nil,
                animationName: animation.name,
                state: persistent,
                isOverlay: isOverlay
            )
        }

        guard let frame = AnimationPlayer.tick(animation, elapsed: now - startedAt) else {
            return PetTick(
                spriteIndex: 0,
                delay: nil,
                animationName: animation.name,
                state: persistent,
                isOverlay: isOverlay
            )
        }

        // While an overlay is up we must also wake when it expires, so the pet
        // switches back promptly instead of waiting out the current frame.
        var delay = frame.delay
        if let active = overlay {
            let untilExpiry = max(active.expiresAt - now, 1)
            delay = min(delay ?? untilExpiry, untilExpiry)
        }

        return PetTick(
            spriteIndex: frame.spriteIndex,
            delay: delay,
            animationName: animation.name,
            state: persistent,
            isOverlay: isOverlay
        )
    }

    // MARK: - Internals

    private func rebuildPersistentAnimation(restart: Bool) {
        // A substituted track always loops. `codexTriple` would play the walk
        // cycle three times and then settle into idle, which would leave him
        // sliding across the desk in a standing pose.
        let mode: PlaybackMode = (substitute == nil && faithfulLoops) ? .codexTriple : .loopPrimary
        persistentAnimation = catalog.animationOrIdle(
            named: substitute ?? persistent.animationName,
            mode: mode
        ).scaled(by: scale)
        if restart { persistentStartedAt = clock.now }
    }
}

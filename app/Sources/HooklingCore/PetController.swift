import Foundation

/// Things the app must do that the core cannot.
public enum PetSideEffect: Sendable, Equatable {
    case runDemo
    case reportStatus
    case writeSnapshot
    case quit
}

/// The engine: session tracking plus the state machine, with the wire protocol
/// applied to them.
///
/// The app layer owns windows, sockets and timers; everything that decides *what
/// the pet is doing* lives here, which is why the end-to-end behaviour can be
/// tested without AppKit, without sockets and without Claude Code.
public final class PetController {
    private let registry: SessionRegistry
    private let machine: PetStateMachine
    private let wander: WanderPlanner
    private let clock: any HooklingClock

    /// While true, adapter events are ignored — the menu's "Pause reactions".
    /// Commands from `hooklingctl` still work, so the pet stays debuggable.
    public var isPaused: Bool = false

    /// Set by `hooklingctl <state>`, cleared by the next real adapter event.
    ///
    /// Without this, a forced debug state would be overwritten by the session
    /// merge on the very next animation frame, making the debug controls useless.
    /// With it, a forced state sticks until Claude Code actually does something.
    private var manualOverride = false

    public let catalog: AnimationCatalog

    public init(
        catalog: AnimationCatalog,
        clock: any HooklingClock = MonotonicClock(),
        policy: SessionPolicy = .default,
        faithfulLoops: Bool = false,
        reducedMotion: Bool = false,
        timingScale: Double = 1.0,
        wanderPolicy: WanderPolicy = .default,
        random: any HooklingRandom = SystemRandom()
    ) {
        self.catalog = catalog
        self.clock = clock
        self.registry = SessionRegistry(clock: clock, policy: policy)
        self.wander = WanderPlanner(clock: clock, random: random, policy: wanderPolicy)
        self.machine = PetStateMachine(
            catalog: catalog,
            clock: clock,
            faithfulLoops: faithfulLoops,
            reducedMotion: reducedMotion,
            timingScale: timingScale
        )
    }

    // MARK: - Configuration

    public var faithfulLoops: Bool {
        get { machine.faithfulLoops }
        set { machine.faithfulLoops = newValue }
    }

    public var reducedMotion: Bool {
        get { machine.reducedMotion }
        set { machine.reducedMotion = newValue }
    }

    /// Frame durations as a multiple of the catalog's. See
    /// `PetStateMachine.timingScale`.
    public var timingScale: Double {
        get { machine.timingScale }
        set { machine.timingScale = newValue }
    }

    /// Whether he strolls about while idle.
    ///
    /// Independent of `isPaused` on purpose: pausing stops him *reacting* to
    /// Claude, which is not a reason to make him stand rigidly still.
    public var wanderEnabled: Bool {
        get { wander.isEnabled }
        set { wander.isEnabled = newValue }
    }

    public var isWandering: Bool { wander.isWalking }

    /// What the persistent layer is drawing, which is a walk cycle while he is
    /// strolling rather than the idle pose his state implies.
    public var currentAnimationName: String { machine.persistentAnimationName }

    /// The app clamped his movement, so he has reached the edge of the screen.
    public func wanderBlocked() { wander.blocked() }

    /// Stop strolling and take a fresh rest — he has been picked up.
    public func suspendWander() { wander.suspend() }

    public var state: PetState { machine.state }

    public var isManuallyOverridden: Bool { manualOverride }

    public var sessionCount: Int { registry.sessionCount }

    public func sessionSnapshot() -> [(session: String, state: PetState, ageSeconds: TimeInterval)] {
        registry.snapshot()
    }

    // MARK: - Input

    /// Apply one decoded socket message. Returns work for the app to do, if any.
    @discardableResult
    public func handle(_ message: PetMessage) -> PetSideEffect? {
        switch message {
        case .event(let event, let session):
            guard !isPaused else { return nil }
            manualOverride = false
            let reaction = registry.apply(event: event, session: session)
            machine.setState(reaction.state)
            if let transient = reaction.transient {
                machine.play(transient: transient)
            }
            return nil

        case .command(.setState(let state)):
            manualOverride = true
            machine.setState(state)
            return nil

        case .command(.play(let name)):
            machine.play(transient: name)
            return nil

        case .command(.pause(let paused)):
            isPaused = paused
            return nil

        case .command(.wander(let wandering)):
            wander.isEnabled = wandering
            return nil

        case .command(.reset):
            manualOverride = false
            registry.reset()
            machine.endOverlay()
            machine.setState(registry.mergedState())
            return nil

        case .command(.demo):
            return .runDemo

        case .command(.status):
            return .reportStatus

        case .command(.snapshot):
            return .writeSnapshot

        case .command(.quit):
            return .quit
        }
    }

    /// Loop an animation for a window, for the demo. Leaves the persistent state
    /// alone so the pet returns to whatever it was doing afterwards.
    public func preview(_ name: String, duration: Nanoseconds) {
        machine.preview(name, duration: duration)
    }

    public func endPreview() {
        machine.endOverlay()
    }

    // MARK: - Output

    /// Advance the pet. Re-derives the merged session state first, so states that
    /// expire on a timer (a crashed terminal stuck "working") resolve themselves
    /// without a dedicated sweep timer.
    public func tick() -> PetTick {
        if !isPaused && !manualOverride {
            machine.setState(registry.mergedState())
        }

        // "Reduce motion" rules out wandering for the same reason it rules out
        // overlays: sliding across the desk is the largest movement he makes, so
        // it is the first thing that setting ought to stop.
        let motion = machine.reducedMotion
            ? WanderMotion.still
            : wander.tick(
                state: machine.state,
                overlayActive: machine.isOverlayActive,
                timingScale: machine.timingScale
            )
        machine.substituteAnimation = motion.animationName

        let tick = machine.tick()

        // Wake in time to start or end a stroll. Without this he would be stuck
        // waiting out a 1.9-second idle frame before noticing either.
        var delay = tick.delay
        if let next = motion.nextDecisionIn {
            delay = min(delay ?? next, next)
        }

        return PetTick(
            spriteIndex: tick.spriteIndex,
            delay: delay,
            animationName: tick.animationName,
            state: tick.state,
            isOverlay: tick.isOverlay,
            movement: motion.dx,
            didFinishStroll: motion.didFinishStroll
        )
    }
}

import Foundation
import Testing
@testable import HooklingCore

/// The wander is the only part of this app that is not a pure function of events
/// and time, so it gets the most explicit tests: a fixed seed and a hand-driven
/// clock mean "he sometimes walks somewhere" becomes an exact assertion.
@Suite("Wandering")
struct WanderTests {

    /// Tight numbers so a stroll is easy to reason about: rest exactly 10s, walk
    /// exactly 100pt at 50pt/s — a two-second trip.
    private static let policy = WanderPolicy(
        restMin: nanoseconds(seconds: 10),
        restMax: nanoseconds(seconds: 10),
        distanceMin: 100,
        distanceMax: 100,
        pointsPerSecond: 50
    )

    private func makePlanner(_ clock: ManualClock, seed: UInt64 = 0x5EED) -> WanderPlanner {
        WanderPlanner(clock: clock, random: SeededRandom(seed: seed), policy: Self.policy)
    }

    private func makeController(
        _ clock: ManualClock,
        seed: UInt64 = 0x5EED
    ) throws -> PetController {
        PetController(
            catalog: try TestAssets.catalog(),
            clock: clock,
            wanderPolicy: Self.policy,
            random: SeededRandom(seed: seed)
        )
    }

    /// Walk the planner forward in `stepInterval` slices, totalling the distance.
    @discardableResult
    private func walk(
        _ planner: WanderPlanner,
        _ clock: ManualClock,
        steps: Int,
        state: PetState = .idle
    ) -> (distance: Double, animations: Set<String>) {
        var distance = 0.0
        var animations: Set<String> = []
        for _ in 0..<steps {
            clock.advance(by: WanderPlanner.stepInterval)
            let motion = planner.tick(state: state, overlayActive: false, timingScale: 1.0)
            distance += motion.dx
            if let name = motion.animationName { animations.insert(name) }
        }
        return (distance, animations)
    }

    // MARK: - Setting off

    @Test("he rests first, then sets off using a walk cycle")
    func restsThenWalks() {
        let clock = ManualClock()
        let planner = makePlanner(clock)

        // Still resting: no movement, but he asks to be woken when the rest ends.
        let resting = planner.tick(state: .idle, overlayActive: false, timingScale: 1.0)
        #expect(resting.dx == 0)
        #expect(resting.animationName == nil)
        #expect(resting.nextDecisionIn == nanoseconds(seconds: 10))
        #expect(!planner.isWalking)

        clock.advance(seconds: 10)
        let setOff = planner.tick(state: .idle, overlayActive: false, timingScale: 1.0)
        #expect(planner.isWalking)
        // The first frame of a stroll must not move him: `elapsed` spans the whole
        // rest, because the renderer was asleep on a long idle frame.
        #expect(setOff.dx == 0)
        #expect(setOff.animationName == "running-left" || setOff.animationName == "running-right")
    }

    @Test("a stroll covers exactly the distance the policy chose")
    func distanceMatchesPolicy() {
        let clock = ManualClock()
        let planner = makePlanner(clock)

        clock.advance(seconds: 10)
        _ = planner.tick(state: .idle, overlayActive: false, timingScale: 1.0)

        // 100pt at 50pt/s is 2s; walk well past that and he must stop at 100.
        let result = walk(planner, clock, steps: 100)
        #expect(abs(abs(result.distance) - 100) < 0.001)
        #expect(!planner.isWalking)
        #expect(result.animations.count == 1, "he does not change his mind mid-stroll")
    }

    @Test("a slower pace means slower travel, so his feet stay planted")
    func speedFollowsTimingScale() {
        let clock = ManualClock()
        let planner = makePlanner(clock)

        clock.advance(seconds: 10)
        _ = planner.tick(state: .idle, overlayActive: false, timingScale: 2.0)

        // One second of walking at half speed covers 25pt, not 50.
        var distance = 0.0
        for _ in 0..<20 {
            clock.advance(by: WanderPlanner.stepInterval)
            distance += planner.tick(state: .idle, overlayActive: false, timingScale: 2.0).dx
        }
        #expect(abs(abs(distance) - 25) < 0.001)
    }

    // MARK: - Being interrupted

    @Test("he stops the moment Claude does anything, and does not resume")
    func stopsWhenWorkStarts() {
        let clock = ManualClock()
        let planner = makePlanner(clock)

        clock.advance(seconds: 10)
        _ = planner.tick(state: .idle, overlayActive: false, timingScale: 1.0)
        walk(planner, clock, steps: 5)
        #expect(planner.isWalking)

        // A prompt arrives mid-stride.
        clock.advance(by: WanderPlanner.stepInterval)
        let interrupted = planner.tick(state: .working, overlayActive: false, timingScale: 1.0)
        #expect(interrupted.dx == 0)
        #expect(interrupted.animationName == nil)
        #expect(!planner.isWalking)

        // Back to idle: he takes a fresh rest rather than lurching back into the
        // stride he abandoned.
        clock.advance(seconds: 1)
        let after = planner.tick(state: .idle, overlayActive: false, timingScale: 1.0)
        #expect(after.dx == 0)
        #expect(!planner.isWalking)
    }

    @Test("a wave or a jump plays on the spot")
    func overlaysHoldHimStill() {
        let clock = ManualClock()
        let planner = makePlanner(clock)

        clock.advance(seconds: 10)
        _ = planner.tick(state: .idle, overlayActive: false, timingScale: 1.0)

        clock.advance(by: WanderPlanner.stepInterval)
        let covered = planner.tick(state: .idle, overlayActive: true, timingScale: 1.0)
        #expect(covered.dx == 0)
    }

    @Test("only idle wanders — never working, waiting, failed, review or asleep")
    func onlyIdleWanders() {
        for state in PetState.allCases where state != .idle {
            let clock = ManualClock()
            let planner = makePlanner(clock)
            clock.advance(seconds: 30)
            let motion = planner.tick(state: state, overlayActive: false, timingScale: 1.0)
            #expect(motion.dx == 0, "\(state.rawValue) must not move")
            #expect(motion.nextDecisionIn == nil, "\(state.rawValue) must not arm a timer")
        }
    }

    // MARK: - Edges and interruptions

    @Test("hitting a screen edge turns him around instead of stalling")
    func blockedReverses() {
        let clock = ManualClock()
        let planner = makePlanner(clock)

        clock.advance(seconds: 10)
        _ = planner.tick(state: .idle, overlayActive: false, timingScale: 1.0)

        clock.advance(by: WanderPlanner.stepInterval)
        let before = planner.tick(state: .idle, overlayActive: false, timingScale: 1.0)

        planner.blocked()
        clock.advance(by: WanderPlanner.stepInterval)
        let after = planner.tick(state: .idle, overlayActive: false, timingScale: 1.0)

        #expect(before.dx != 0)
        #expect(after.dx != 0)
        #expect((before.dx < 0) != (after.dx < 0), "direction must flip")
        #expect(planner.isWalking, "he keeps going the other way rather than giving up")
    }

    @Test("picking him up abandons the stroll")
    func suspendStops() {
        let clock = ManualClock()
        let planner = makePlanner(clock)

        clock.advance(seconds: 10)
        _ = planner.tick(state: .idle, overlayActive: false, timingScale: 1.0)
        #expect(planner.isWalking)

        planner.suspend()
        #expect(!planner.isWalking)

        clock.advance(by: WanderPlanner.stepInterval)
        #expect(planner.tick(state: .idle, overlayActive: false, timingScale: 1.0).dx == 0)
    }

    @Test("turning it off stops him where he stands")
    func disabledDoesNotMove() {
        let clock = ManualClock()
        let planner = makePlanner(clock)
        planner.isEnabled = false

        clock.advance(seconds: 30)
        let motion = planner.tick(state: .idle, overlayActive: false, timingScale: 1.0)
        #expect(motion.dx == 0)
        #expect(motion.nextDecisionIn == nil)
    }

    // MARK: - Through the controller

    @Test("the pet draws a walk cycle while strolling and idle art while resting")
    func controllerSubstitutesTheWalkCycle() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)

        #expect(controller.tick().animationName == "idle")

        clock.advance(seconds: 10)
        var tick = controller.tick()
        #expect(tick.state == .idle, "still idle — he is only strolling, not busy")
        #expect(tick.animationName == "running-left" || tick.animationName == "running-right")
        #expect(!tick.isOverlay, "a stroll is the persistent layer, not a one-shot")

        // Walk it out; he returns to the idle pose.
        for _ in 0..<100 {
            clock.advance(by: WanderPlanner.stepInterval)
            tick = controller.tick()
        }
        #expect(tick.animationName == "idle")
        #expect(controller.tick().movement == 0)
    }

    @Test("a stroll ending is reported once, so the app can save his spot")
    func strollEndIsSignalledOnce() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)

        clock.advance(seconds: 10)
        _ = controller.tick()

        var finishes = 0
        var travelled = 0.0
        for _ in 0..<100 {
            clock.advance(by: WanderPlanner.stepInterval)
            let tick = controller.tick()
            travelled += tick.movement
            if tick.didFinishStroll { finishes += 1 }
        }
        #expect(finishes == 1)
        #expect(abs(abs(travelled) - 100) < 0.001)
    }

    @Test("the renderer is woken in time to set off")
    func tickDelayShrinksToTheNextDecision() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)

        // The idle animation's first frame lasts 1680ms, but he sets off in 10s,
        // so the delay must be the shorter of the two at every point.
        let tick = controller.tick()
        #expect(tick.delay == nanoseconds(milliseconds: 1680))

        clock.advance(milliseconds: 9_990)
        let aboutToLeave = controller.tick()
        #expect((aboutToLeave.delay ?? 0) <= nanoseconds(milliseconds: 10))
    }

    // MARK: - The guarantees this must not break

    @Test("reduce motion rules out wandering entirely")
    func reducedMotionDoesNotWander() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)
        controller.reducedMotion = true

        clock.advance(seconds: 30)
        let tick = controller.tick()
        #expect(tick.movement == 0)
        #expect(tick.delay == nil, "reduce motion still arms no timer")
    }

    @Test("a sleeping pet still costs nothing")
    func sleepingStillSchedulesNothing() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)

        // Past the 15-minute sleep threshold with no events at all.
        clock.advance(seconds: 16 * 60)
        let tick = controller.tick()
        #expect(tick.state == .sleeping)
        #expect(tick.movement == 0)
        #expect(tick.delay == nil, "sleeping must arm no timer, wander or not")
    }

    @Test("the wander command round-trips over the wire")
    func wireFormat() throws {
        for on in [true, false] {
            let encoded = EventCodec.encode(command: .wander(on))
            #expect(try EventCodec.decode(line: encoded) == .command(.wander(on)))
        }
        #expect(throws: EventCodecError.self) {
            try EventCodec.decode(line: Data(#"{"cmd":"wander","value":"sideways"}"#.utf8))
        }
    }
}

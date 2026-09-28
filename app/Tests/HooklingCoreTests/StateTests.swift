import Testing
@testable import HooklingCore

@Suite("State priority")
struct StatePriorityTests {

    @Test("the confirmed priority order holds")
    func orderIsExplicit() {
        // "I must act now" beats everything; a finished turn never masks a
        // running one.
        #expect(PetState.waiting > PetState.failed)
        #expect(PetState.failed > PetState.working)
        #expect(PetState.working > PetState.review)
        #expect(PetState.review > PetState.idle)
        #expect(PetState.idle > PetState.sleeping)
    }

    @Test("the ephemeral states sit below real work")
    func ephemeralStatesRankLow() {
        // A new session saying hello must not outrank another terminal working.
        #expect(PetState.attentive < PetState.working)
        #expect(PetState.attentive > PetState.idle)
        // "Just finished" is a flourish, not a claim on attention.
        #expect(PetState.success < PetState.working)
        #expect(PetState.success > PetState.review)
    }

    @Test("priorities are a strict total order with no ties")
    func prioritiesAreUnique() {
        let priorities = PetState.allCases.map(\.priority)
        #expect(Set(priorities).count == PetState.allCases.count)
        #expect(priorities.sorted() == Array(0..<PetState.allCases.count))
    }

    @Test("only sleeping freezes")
    func onlySleepingFreezes() {
        for state in PetState.allCases {
            #expect(state.isFrozen == (state == .sleeping))
        }
    }

    @Test("labels follow Codex's vocabulary where the state exists upstream")
    func labelsMatchUpstream() {
        // PetNotificationKind::label in ambient.rs
        #expect(PetState.working.label == "Running")
        #expect(PetState.waiting.label == "Needs input")
        #expect(PetState.review.label == "Ready")
        #expect(PetState.failed.label == "Blocked")
    }
}

@Suite("State machine")
struct PetStateMachineTests {

    private func makeMachine(
        clock: ManualClock,
        faithful: Bool = false,
        reducedMotion: Bool = false
    ) throws -> PetStateMachine {
        PetStateMachine(
            catalog: try TestAssets.catalog(),
            clock: clock,
            faithfulLoops: faithful,
            reducedMotion: reducedMotion
        )
    }

    @Test("a persistent state keeps animating indefinitely")
    func persistentStatePersists() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock)
        machine.setState(.working)

        // The whole point of the divergence from upstream: two minutes in, still
        // visibly running rather than settled into idle.
        for second in 1...120 {
            clock.advance(seconds: 1)
            let tick = machine.tick()
            #expect(tick.state == .working)
            #expect(tick.animationName == "running")
            #expect(tick.delay != nil, "animation stalled at \(second)s")
            #expect(Set(56...61).contains(tick.spriteIndex))
        }
    }

    @Test("repeated heartbeats do not restart the animation")
    func heartbeatsDoNotRestart() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock)
        machine.setState(.working)

        // Advance into the third frame, then hammer setState with the same value
        // the way a burst of tool events would.
        clock.advance(milliseconds: 250)
        let before = machine.tick()
        for _ in 0..<50 { machine.setState(.working) }
        let after = machine.tick()

        #expect(after.spriteIndex == before.spriteIndex)
        // Had it restarted, we would be back on the first running frame.
        #expect(after.spriteIndex != 56)
    }

    @Test("a transient plays once and hands back to the persistent state")
    func transientRevertsToPersistent() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock)
        machine.setState(.working)
        machine.play(transient: "waving")

        var tick = machine.tick()
        #expect(tick.animationName == "waving")
        #expect(tick.isOverlay)
        #expect(tick.state == .working)   // the underlying state is unchanged

        // waving totals 700ms.
        clock.advance(milliseconds: 400)
        tick = machine.tick()
        #expect(tick.animationName == "waving")

        clock.advance(milliseconds: 300)
        tick = machine.tick()
        #expect(tick.animationName == "running")
        #expect(!tick.isOverlay)
        // And it restarts cleanly rather than resuming mid-cycle.
        #expect(tick.spriteIndex == 56)
    }

    @Test("a state change during a transient is honoured when the transient ends")
    func stateChangeDuringTransient() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock)
        machine.setState(.working)
        machine.play(transient: "jumping")

        // Change state mid-jump.
        clock.advance(milliseconds: 200)
        machine.setState(.waiting)
        var tick = machine.tick()
        #expect(tick.animationName == "jumping", "the transient should not be cut short")
        #expect(tick.state == .waiting, "but the new state is already recorded")

        // jumping totals 4x140 + 280 = 840ms.
        clock.advance(milliseconds: 700)
        tick = machine.tick()
        #expect(tick.animationName == "waiting")
        #expect(tick.state == .waiting)
    }

    @Test("the overlay expiry is scheduled, so the switch back is prompt")
    func overlayExpiryIsScheduled() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock)
        machine.setState(.working)
        machine.play(transient: "waving")

        // 690ms in: 10ms left on the overlay, and the delay must not overshoot it
        // even though the current frame has 280ms of nominal duration.
        clock.advance(milliseconds: 690)
        let tick = machine.tick()
        #expect(tick.delay == nanoseconds(milliseconds: 10))
    }

    @Test("a newer transient replaces an older one")
    func transientReplacesTransient() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock)
        machine.play(transient: "waving")
        clock.advance(milliseconds: 100)
        machine.play(transient: "jumping")

        let tick = machine.tick()
        #expect(tick.animationName == "jumping")
        #expect(tick.spriteIndex == 32)   // restarted from the beginning
    }

    @Test("an unknown transient is ignored rather than blanking the pet")
    func unknownTransientIgnored() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock)
        machine.setState(.working)
        machine.play(transient: "flip-out")

        let tick = machine.tick()
        #expect(tick.animationName == "running")
        #expect(!tick.isOverlay)
    }

    @Test("sleeping freezes on the first frame and schedules nothing")
    func sleepingIsFree() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock)
        machine.setState(.sleeping)

        let tick = machine.tick()
        #expect(tick.spriteIndex == 0)
        #expect(tick.delay == nil, "a sleeping pet must not wake the CPU")

        clock.advance(seconds: 3600)
        #expect(machine.tick().spriteIndex == 0)
    }

    @Test("a transient still plays while sleeping, then refreezes")
    func transientWakesSleeper() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock)
        machine.setState(.sleeping)
        machine.play(transient: "waving")

        var tick = machine.tick()
        #expect(tick.animationName == "waving")
        #expect(tick.delay != nil)

        clock.advance(milliseconds: 700)
        tick = machine.tick()
        #expect(tick.delay == nil, "back to frozen after the wave")
        #expect(tick.spriteIndex == 0)
    }

    @Test("reduced motion holds a pose per state and never animates")
    func reducedMotionHoldsPose() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock, reducedMotion: true)

        machine.setState(.working)
        var tick = machine.tick()
        #expect(tick.spriteIndex == 56)      // first running frame
        #expect(tick.delay == nil)

        // Transients are suppressed entirely, as upstream does when animations
        // are disabled.
        machine.play(transient: "jumping")
        tick = machine.tick()
        #expect(!tick.isOverlay)
        #expect(tick.spriteIndex == 56)

        machine.setState(.waiting)
        tick = machine.tick()
        #expect(tick.spriteIndex == 48)     // first waiting frame: pose still informative
        #expect(tick.delay == nil)
    }

    @Test("toggling faithful loops switches composition live")
    func faithfulToggle() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock)
        machine.setState(.working)

        // loopPrimary: still running after 90s.
        clock.advance(seconds: 90)
        #expect(Set(56...61).contains(machine.tick().spriteIndex))

        machine.faithfulLoops = true
        clock.advance(seconds: 90)
        // codexTriple: settled into the idle tail.
        #expect(Set(0...5).contains(machine.tick().spriteIndex))
    }

    @Test("a preview loops for its window without disturbing the state")
    func previewLoops() throws {
        let clock = ManualClock()
        let machine = try makeMachine(clock: clock)
        machine.setState(.waiting)
        machine.preview("running-left", duration: nanoseconds(seconds: 3))

        clock.advance(seconds: 2)
        var tick = machine.tick()
        #expect(tick.animationName == "running-left")
        #expect(tick.state == .waiting)
        #expect(tick.isOverlay)

        clock.advance(seconds: 1)
        tick = machine.tick()
        #expect(tick.animationName == "waiting")
        #expect(!tick.isOverlay)
    }
}

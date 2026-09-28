import Foundation
import Testing
@testable import HooklingCore

/// `timingScale` is a taste knob, so what matters is proving it changes *only*
/// taste: the same sprites in the same order, the same number of repeats, and
/// the same state lifetimes — just held longer.
@Suite("Animation pacing")
struct TimingScaleTests {

    /// Walk the animation frame by frame the way the renderer does: show a
    /// sprite, wait exactly as long as it asked for, look again.
    private func walk(
        _ machine: PetStateMachine,
        _ clock: ManualClock,
        steps: Int
    ) -> [(sprite: Int, delay: Nanoseconds)] {
        var seen: [(sprite: Int, delay: Nanoseconds)] = []
        for _ in 0..<steps {
            let tick = machine.tick()
            guard let delay = tick.delay else { break }
            seen.append((tick.spriteIndex, delay))
            clock.advance(by: delay)
        }
        return seen
    }

    private func machine(
        state: PetState = .working,
        scale: Double,
        faithful: Bool = false,
        clock: ManualClock
    ) throws -> PetStateMachine {
        PetStateMachine(
            catalog: try TestAssets.catalog(),
            clock: clock,
            initialState: state,
            faithfulLoops: faithful,
            timingScale: scale
        )
    }

    // MARK: - Pace

    @Test("every frame is held proportionally longer, and nothing else moves")
    func stretchesFramesOnly() throws {
        let fastClock = ManualClock()
        let slowClock = ManualClock()
        let fast = try machine(scale: 1.0, clock: fastClock)
        let slow = try machine(scale: 1.25, clock: slowClock)

        // Two full cycles of `running` (6 frames each).
        let fastFrames = walk(fast, fastClock, steps: 12)
        let slowFrames = walk(slow, slowClock, steps: 12)

        #expect(fastFrames.count == 12)
        #expect(slowFrames.count == 12)

        // Same artwork, same order.
        #expect(fastFrames.map(\.sprite) == slowFrames.map(\.sprite))

        // Every frame held exactly 1.25x as long. Upstream `running` is
        // 120ms x 5 then 220ms, so this is 150ms x 5 then 275ms.
        for (quick, lazy) in zip(fastFrames, slowFrames) {
            #expect(lazy.delay == Nanoseconds((Double(quick.delay) * 1.25).rounded()))
        }
        #expect(slowFrames[0].delay == nanoseconds(milliseconds: 150))
        #expect(slowFrames[5].delay == nanoseconds(milliseconds: 275))
    }

    @Test("a slower loop still loops forever, not fewer times")
    func loopsAreNotConsumedFaster() throws {
        let clock = ManualClock()
        let slow = try machine(scale: 2.0, clock: clock)

        // Ten cycles in and it is still running, still cycling the same sprites.
        let frames = walk(slow, clock, steps: 60)
        #expect(frames.count == 60)

        let cycle = Array(frames.prefix(6).map(\.sprite))
        for start in stride(from: 0, to: 60, by: 6) {
            #expect(Array(frames[start..<(start + 6)].map(\.sprite)) == cycle)
        }
        #expect(slow.tick().state == .working)
    }

    @Test("Codex-faithful mode still plays the action exactly three times")
    func faithfulRepeatCountIsPreserved() throws {
        let clock = ManualClock()
        let slow = try machine(scale: 2.0, faithful: true, clock: clock)

        // `codexTriple` is running x3 then the idle tail. Scaling must stretch
        // the frames without turning three repeats into some other number.
        let frames = walk(slow, clock, steps: 18)
        let running = Array(frames.prefix(18).map(\.sprite))
        let cycle = Array(running.prefix(6))

        #expect(Array(running[6..<12]) == cycle)
        #expect(Array(running[12..<18]) == cycle)
        // The 19th frame is the idle tail, not a fourth run cycle.
        #expect(!cycle.contains(slow.tick().spriteIndex))
    }

    // MARK: - Overlays

    @Test("a slowed one-shot plays to its end instead of being cut off")
    func overlayWindowFollowsTheScale() throws {
        let clock = ManualClock()
        let slow = try machine(state: .working, scale: 2.0, clock: clock)

        slow.play(transient: "waving")
        #expect(slow.tick().animationName == "waving")

        // `waving` is 700ms upstream, so at half speed it must still be up at
        // 900ms — the overlay's lifetime is derived from its scaled duration.
        clock.advance(milliseconds: 900)
        #expect(slow.tick().animationName == "waving")
        #expect(slow.tick().isOverlay)

        clock.advance(milliseconds: 600)
        #expect(!slow.tick().isOverlay)
        #expect(slow.tick().animationName == "running")
    }

    // MARK: - States

    @Test("pacing does not change how long a state lasts")
    func stateLifetimesAreIndependentOfPace() throws {
        // The thing a slower pace must *not* do: make Claude look like it
        // stopped working sooner, or keep it looking busy for longer. State
        // duration is the session policy's business, not the animation's.
        for scale in [1.0, 2.0] {
            let clock = ManualClock()
            let controller = PetController(
                catalog: try TestAssets.catalog(),
                clock: clock,
                timingScale: scale
            )

            controller.handle(.event(.promptSubmitted, session: "a1"))
            #expect(controller.tick().state == .working)

            clock.advance(seconds: 179)
            #expect(controller.tick().state == .working, "still working at 179s (scale \(scale))")

            clock.advance(seconds: 2)
            #expect(controller.tick().state == .idle, "expired at 181s (scale \(scale))")
        }
    }

    // MARK: - Robustness

    @Test("a nonsensical scale is clamped rather than hanging the renderer")
    func degenerateScaleIsClamped() throws {
        let clock = ManualClock()
        let subject = try machine(scale: 1.0, clock: clock)

        subject.timingScale = 0
        // Clamped, so frames still have positive length and the renderer still
        // gets a delay to arm a timer with.
        #expect((subject.tick().delay ?? 0) > 0)

        subject.timingScale = -5
        #expect((subject.tick().delay ?? 0) > 0)
    }
}

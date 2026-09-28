import Testing
@testable import HooklingCore

@Suite("Animation composition")
struct AnimationCompositionTests {

    @Test("codexTriple reproduces app_state_animation's frame list")
    func codexTripleMatchesUpstream() throws {
        let catalog = try TestAssets.catalog()
        let idleFrames = catalog.idleFrames

        for expected in UpstreamTable.tracks {
            let track = try #require(catalog.track(named: expected.name))
            let composed = track.composed(mode: .codexTriple, idleFrames: idleFrames)

            // frames = primary x3, then the idle tail.
            #expect(composed.frames.count == expected.frameCount * 3 + idleFrames.count)
            // loop_start = primary_frames.len() * 3
            #expect(composed.loopStart == expected.frameCount * 3)
            #expect(composed.fallback == "idle")

            // The three repeats are identical...
            let primary = Array(composed.frames[0..<expected.frameCount])
            #expect(Array(composed.frames[expected.frameCount..<(expected.frameCount * 2)]) == primary)
            #expect(Array(composed.frames[(expected.frameCount * 2)..<(expected.frameCount * 3)]) == primary)
            // ...and the tail is the idle animation.
            #expect(Array(composed.frames[(expected.frameCount * 3)...]) == idleFrames)
        }
    }

    @Test("loopPrimary loops just the action, which is the point of the divergence")
    func loopPrimaryLoopsAction() throws {
        let catalog = try TestAssets.catalog()
        let running = try #require(catalog.track(named: "running"))
        let composed = running.composed(mode: .loopPrimary, idleFrames: catalog.idleFrames)

        #expect(composed.frames == running.frames)
        #expect(composed.loopStart == 0)

        // The behavioural claim: still running after 90 seconds.
        let tick = try #require(AnimationPlayer.tick(composed, elapsed: nanoseconds(seconds: 90)))
        let runningIndices = Set(running.frames.map(\.spriteIndex))
        #expect(runningIndices.contains(tick.spriteIndex))
        #expect(tick.delay != nil)
    }

    @Test("codexTriple settles into idle, which is why loopPrimary is the default")
    func codexTripleSettlesToIdle() throws {
        let catalog = try TestAssets.catalog()
        let running = try #require(catalog.track(named: "running"))
        let composed = running.composed(mode: .codexTriple, idleFrames: catalog.idleFrames)

        // Three repeats of 5x120ms + 220ms = 820ms each => 2.46s of running.
        #expect(composed.frames[0..<6].reduce(0) { $0 + $1.duration } == nanoseconds(milliseconds: 820))

        // Well after that, upstream is showing idle frames, not running frames.
        let tick = try #require(AnimationPlayer.tick(composed, elapsed: nanoseconds(seconds: 90)))
        let idleIndices = Set(catalog.idleFrames.map(\.spriteIndex))
        #expect(idleIndices.contains(tick.spriteIndex))
    }

    @Test("once holds its last frame and schedules nothing")
    func onceHoldsLastFrame() throws {
        let catalog = try TestAssets.catalog()
        let waving = try #require(catalog.track(named: "waving"))
        let composed = waving.composed(mode: .once, idleFrames: catalog.idleFrames)

        #expect(composed.loopStart == nil)
        #expect(composed.frames == waving.frames)

        // 140 + 140 + 140 + 280 = 700ms
        #expect(composed.totalDuration == nanoseconds(milliseconds: 700))

        let finished = try #require(AnimationPlayer.tick(composed, elapsed: nanoseconds(milliseconds: 700)))
        #expect(finished.spriteIndex == 27)
        #expect(finished.delay == nil)
    }

    @Test("codexTriple of idle degrades to a plain loop instead of tripling itself")
    func idleTripleDegrades() throws {
        let catalog = try TestAssets.catalog()
        let idle = try #require(catalog.track(named: "idle"))
        let composed = idle.composed(mode: .codexTriple, idleFrames: catalog.idleFrames)

        #expect(composed.frames == idle.frames)
        #expect(composed.loopStart == 0)
    }
}

@Suite("Animation playback timing")
struct AnimationPlayerTests {

    /// The animation from Codex's own `animation_frame_uses_per_frame_duration`
    /// test (`ambient.rs`): two 10ms frames, looping from 0.
    private var upstreamTestAnimation: Animation {
        Animation(
            name: "test",
            frames: [
                AnimationFrame(spriteIndex: 0, milliseconds: 10),
                AnimationFrame(spriteIndex: 1, milliseconds: 10),
            ],
            loopStart: 0,
            fallback: "idle"
        )
    }

    @Test("matches upstream's own timing assertion: 15ms in, frame 1 with 5ms left")
    func matchesUpstreamAssertion() throws {
        let tick = try #require(
            AnimationPlayer.tick(upstreamTestAnimation, elapsed: nanoseconds(milliseconds: 15))
        )
        #expect(tick.spriteIndex == 1)
        #expect(tick.delay == nanoseconds(milliseconds: 5))
    }

    @Test("frame boundaries are exact, not off by one")
    func boundariesAreExact() throws {
        let animation = upstreamTestAnimation

        // t=0: start of frame 0, full 10ms remaining.
        var tick = try #require(AnimationPlayer.tick(animation, elapsed: 0))
        #expect(tick.spriteIndex == 0)
        #expect(tick.delay == nanoseconds(milliseconds: 10))

        // t=9.999ms: still frame 0.
        tick = try #require(AnimationPlayer.tick(animation, elapsed: nanoseconds(milliseconds: 10) - 1))
        #expect(tick.spriteIndex == 0)
        #expect(tick.delay == 1)

        // t=10ms exactly: frame 1 has begun.
        tick = try #require(AnimationPlayer.tick(animation, elapsed: nanoseconds(milliseconds: 10)))
        #expect(tick.spriteIndex == 1)
        #expect(tick.delay == nanoseconds(milliseconds: 10))

        // t=20ms: wrapped back to frame 0.
        tick = try #require(AnimationPlayer.tick(animation, elapsed: nanoseconds(milliseconds: 20)))
        #expect(tick.spriteIndex == 0)
        #expect(tick.delay == nanoseconds(milliseconds: 10))
    }

    @Test("a single-frame animation schedules nothing")
    func singleFrameSchedulesNothing() throws {
        let animation = Animation(
            name: "one",
            frames: [AnimationFrame(spriteIndex: 5, milliseconds: 100)],
            loopStart: 0,
            fallback: "idle"
        )
        let tick = try #require(AnimationPlayer.tick(animation, elapsed: nanoseconds(milliseconds: 999)))
        #expect(tick.spriteIndex == 5)
        #expect(tick.delay == nil)
    }

    @Test("looping wraps the suffix only, keeping the prefix a one-time intro")
    func wrapsSuffixNotWhole() throws {
        // Prefix: one 100ms frame (sprite 0). Loop: two 50ms frames (1, 2).
        let animation = Animation(
            name: "prefixed",
            frames: [
                AnimationFrame(spriteIndex: 0, milliseconds: 100),
                AnimationFrame(spriteIndex: 1, milliseconds: 50),
                AnimationFrame(spriteIndex: 2, milliseconds: 50),
            ],
            loopStart: 1,
            fallback: "idle"
        )
        #expect(animation.totalDuration == nanoseconds(milliseconds: 200))

        // Inside the prefix.
        var tick = try #require(AnimationPlayer.tick(animation, elapsed: nanoseconds(milliseconds: 50)))
        #expect(tick.spriteIndex == 0)

        // First pass through the loop.
        tick = try #require(AnimationPlayer.tick(animation, elapsed: nanoseconds(milliseconds: 120)))
        #expect(tick.spriteIndex == 1)

        // After the total: elapsed 250ms => prefix(100) + (250-100) % 100 = 150ms
        // => sprite 2. Crucially NOT sprite 0: the prefix never plays again.
        tick = try #require(AnimationPlayer.tick(animation, elapsed: nanoseconds(milliseconds: 250)))
        #expect(tick.spriteIndex == 2)

        tick = try #require(AnimationPlayer.tick(animation, elapsed: nanoseconds(milliseconds: 300)))
        #expect(tick.spriteIndex == 1)

        // A whole-animation modulo would have given sprite 0 here; check it doesn't.
        for cycle in 1...20 {
            let elapsed = nanoseconds(milliseconds: 200 + cycle * 37)
            let wrapped = try #require(AnimationPlayer.tick(animation, elapsed: elapsed))
            #expect(wrapped.spriteIndex != 0, "prefix frame replayed at \(elapsed)ns")
        }
    }

    @Test("a non-looping animation holds its final frame forever")
    func nonLoopingHoldsFinalFrame() throws {
        let animation = Animation(
            name: "oneshot",
            frames: [
                AnimationFrame(spriteIndex: 3, milliseconds: 10),
                AnimationFrame(spriteIndex: 4, milliseconds: 10),
            ],
            loopStart: nil,
            fallback: "idle"
        )
        var tick = try #require(AnimationPlayer.tick(animation, elapsed: nanoseconds(milliseconds: 5)))
        #expect(tick.spriteIndex == 3)
        #expect(tick.delay == nanoseconds(milliseconds: 5))

        tick = try #require(AnimationPlayer.tick(animation, elapsed: nanoseconds(milliseconds: 20)))
        #expect(tick.spriteIndex == 4)
        #expect(tick.delay == nil)

        tick = try #require(AnimationPlayer.tick(animation, elapsed: nanoseconds(seconds: 3600)))
        #expect(tick.spriteIndex == 4)
        #expect(tick.delay == nil)
    }

    @Test("zero-duration frames are clamped so playback cannot spin")
    func zeroDurationClamped() throws {
        let animation = Animation(
            name: "degenerate",
            frames: [
                AnimationFrame(spriteIndex: 0, duration: 0),
                AnimationFrame(spriteIndex: 1, duration: 0),
            ],
            loopStart: 0,
            fallback: "idle"
        )
        let tick = try #require(AnimationPlayer.tick(animation, elapsed: 0))
        #expect(tick.delay == 1)
    }

    @Test("negative elapsed time is treated as zero")
    func negativeElapsed() throws {
        let tick = try #require(AnimationPlayer.tick(upstreamTestAnimation, elapsed: -5_000))
        #expect(tick.spriteIndex == 0)
    }

    @Test("an empty animation yields no tick rather than crashing")
    func emptyAnimation() {
        let animation = Animation(name: "empty", frames: [], loopStart: 0, fallback: "idle")
        #expect(AnimationPlayer.tick(animation, elapsed: 0) == nil)
    }

    @Test("idle cycles through all six frames over its 6.6s period")
    func idleCyclesAllFrames() throws {
        let catalog = try TestAssets.catalog()
        let idle = catalog.animationOrIdle(named: "idle", mode: .loopPrimary)

        var seen: [Int] = []
        // Sample at each frame's midpoint using the upstream durations.
        var cursor: Nanoseconds = 0
        for frame in UpstreamTable.idleFrames {
            let duration = nanoseconds(milliseconds: frame.milliseconds)
            let tick = try #require(AnimationPlayer.tick(idle, elapsed: cursor + duration / 2))
            seen.append(tick.spriteIndex)
            cursor += duration
        }
        #expect(seen == [0, 1, 2, 3, 4, 5])

        // And it wraps: one full period later we are back at frame 0.
        let wrapped = try #require(AnimationPlayer.tick(idle, elapsed: nanoseconds(milliseconds: 6600)))
        #expect(wrapped.spriteIndex == 0)
    }
}

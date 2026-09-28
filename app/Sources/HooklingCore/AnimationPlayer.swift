import Foundation

/// What to show right now, and when to look again.
public struct AnimationTick: Equatable, Sendable {
    public let spriteIndex: Int

    /// Time until the displayed sprite changes, or `nil` when nothing further
    /// will happen — a single-frame animation, or a one-shot that has finished.
    ///
    /// `nil` is what lets the pet reach genuinely zero CPU: the renderer arms no
    /// timer at all rather than polling for a change that will never come.
    public let delay: Nanoseconds?

    public init(spriteIndex: Int, delay: Nanoseconds?) {
        self.spriteIndex = spriteIndex
        self.delay = delay
    }
}

/// Frame selection, ported from Codex's `pets/ambient.rs`
/// (`current_animation_frame` and `frame_at_elapsed`, lines 376-431).
///
/// Reimplemented rather than copied, but the semantics are preserved exactly,
/// including the details that are easy to get wrong:
///
/// * The wrap is **not** `elapsed % total`. Frames before `loopStart` are a
///   prefix that plays once; only the suffix repeats.
/// * A zero-duration frame is clamped to 1ns, so malformed data cannot spin.
/// * A finished one-shot holds its **last** frame, not its first.
public enum AnimationPlayer {
    public static func tick(_ animation: Animation, elapsed: Nanoseconds) -> AnimationTick? {
        guard let first = animation.frames.first else { return nil }

        // A single frame never changes, so there is nothing to schedule.
        if animation.frames.count <= 1 {
            return AnimationTick(spriteIndex: first.spriteIndex, delay: nil)
        }

        let elapsed = max(elapsed, 0)

        if let loopStart = animation.loopStart, loopStart < animation.frames.count {
            let total = animation.totalDuration
            let prefix = animation.frames[..<loopStart].reduce(0) { $0 + $1.duration }
            let loop = animation.frames[loopStart...].reduce(0) { $0 + $1.duration }

            let effectiveElapsed: Nanoseconds
            if elapsed >= total, loop > 0 {
                effectiveElapsed = prefix + (elapsed - prefix) % loop
            } else {
                effectiveElapsed = elapsed
            }
            return frame(in: animation, atElapsed: effectiveElapsed)
        }

        if elapsed >= animation.totalDuration {
            // One-shot, finished: hold the final frame and schedule nothing.
            guard let last = animation.frames.last else { return nil }
            return AnimationTick(spriteIndex: last.spriteIndex, delay: nil)
        }

        return frame(in: animation, atElapsed: elapsed)
    }

    /// Walk the frame list accumulating durations until `elapsed` lands inside a
    /// frame, returning that frame plus the time remaining on it.
    private static func frame(in animation: Animation, atElapsed elapsed: Nanoseconds) -> AnimationTick? {
        var remaining = elapsed
        for frame in animation.frames {
            let duration = max(frame.duration, 1)
            if remaining < duration {
                return AnimationTick(spriteIndex: frame.spriteIndex, delay: duration - remaining)
            }
            remaining -= duration
        }
        guard let last = animation.frames.last else { return nil }
        return AnimationTick(spriteIndex: last.spriteIndex, delay: nil)
    }
}

import Foundation

/// Durations are integer nanoseconds throughout.
///
/// Codex's playback maths (`ambient.rs`) works in `u128` nanoseconds and uses a
/// modulo to wrap looping animations. Doing the same in integers rather than
/// `TimeInterval` keeps our frame boundaries bit-identical to upstream instead of
/// drifting by a float epsilon every cycle.
public typealias Nanoseconds = Int

public let nanosPerMillisecond: Nanoseconds = 1_000_000
public let nanosPerSecond: Nanoseconds = 1_000_000_000

public func nanoseconds(milliseconds: Int) -> Nanoseconds {
    milliseconds * nanosPerMillisecond
}

public func nanoseconds(seconds: TimeInterval) -> Nanoseconds {
    Nanoseconds((seconds * TimeInterval(nanosPerSecond)).rounded())
}

public func seconds(nanoseconds: Nanoseconds) -> TimeInterval {
    TimeInterval(nanoseconds) / TimeInterval(nanosPerSecond)
}

/// One frame of an animation: which sprite to show, and for how long.
public struct AnimationFrame: Equatable, Sendable {
    public let spriteIndex: Int
    public let duration: Nanoseconds

    public init(spriteIndex: Int, duration: Nanoseconds) {
        self.spriteIndex = spriteIndex
        self.duration = duration
    }

    public init(spriteIndex: Int, milliseconds: Int) {
        self.init(spriteIndex: spriteIndex, duration: nanoseconds(milliseconds: milliseconds))
    }

    /// The same sprite, held for `factor` times as long.
    ///
    /// Clamped to 1ns for the same reason `AnimationPlayer` clamps: a frame of
    /// zero length is a frame the player can never advance past.
    public func scaled(by factor: Double) -> AnimationFrame {
        AnimationFrame(
            spriteIndex: spriteIndex,
            duration: max(Nanoseconds((Double(duration) * factor).rounded()), 1)
        )
    }
}

/// How a primary track is turned into a playable frame list.
///
/// The artwork and per-frame durations are identical in every mode; only the
/// repeat policy differs. See `docs/codex-pet-analysis.md` §8.
public enum PlaybackMode: String, Sendable, CaseIterable {
    /// Loop the primary frames forever. The default for persistent states, so a
    /// 90-second Claude turn shows 90 seconds of working animation.
    case loopPrimary

    /// Exactly what Codex's `app_state_animation` builds: the primary frames
    /// three times over, then the idle frames, looping the idle tail forever.
    case codexTriple

    /// Play the primary frames once and hold the last one. Used for transients,
    /// which hand control back to the persistent state when they finish.
    case once
}

/// A named track exactly as it appears in `animations.json` — the *primary*
/// frames only, before any repeat policy is applied.
public struct AnimationTrack: Equatable, Sendable {
    public let name: String
    public let row: Int
    public let frames: [AnimationFrame]
    public let loops: Bool
    public let fallback: String

    public init(name: String, row: Int, frames: [AnimationFrame], loops: Bool, fallback: String) {
        self.name = name
        self.row = row
        self.frames = frames
        self.loops = loops
        self.fallback = fallback
    }
}

/// A composed, playable animation.
public struct Animation: Equatable, Sendable {
    public let name: String
    public let frames: [AnimationFrame]

    /// Index into `frames` where looping restarts, or `nil` for a one-shot.
    ///
    /// Frames before `loopStart` play once (the "prefix"); frames from
    /// `loopStart` onwards repeat forever. `codexTriple` uses this to play an
    /// action three times and then loop the idle tail.
    public let loopStart: Int?

    /// The animation to hand back to when a one-shot finishes.
    public let fallback: String

    public init(name: String, frames: [AnimationFrame], loopStart: Int?, fallback: String) {
        self.name = name
        self.frames = frames
        self.loopStart = loopStart
        self.fallback = fallback
    }

    public var totalDuration: Nanoseconds {
        frames.reduce(0) { $0 + $1.duration }
    }

    public var isLooping: Bool { loopStart != nil }

    /// The same animation played `factor` times slower.
    ///
    /// Only the durations move. The sprites, their order and `loopStart` are
    /// untouched, so a looping track still loops forever over exactly the same
    /// frames — it simply takes longer to get round. Applied *after* composition
    /// so `codexTriple`'s "three times then idle" stays three times.
    public func scaled(by factor: Double) -> Animation {
        guard factor != 1.0 else { return self }
        return Animation(
            name: name,
            frames: frames.map { $0.scaled(by: factor) },
            loopStart: loopStart,
            fallback: fallback
        )
    }
}

extension AnimationTrack {
    /// Apply a repeat policy, producing a playable animation.
    ///
    /// `codexTriple` needs the idle frames because that is what upstream appends
    /// as the tail; for the idle track itself the tail would be redundant, so it
    /// degrades to `loopPrimary`.
    public func composed(mode: PlaybackMode, idleFrames: [AnimationFrame]) -> Animation {
        switch mode {
        case .loopPrimary:
            return Animation(name: name, frames: frames, loopStart: 0, fallback: fallback)

        case .once:
            return Animation(name: name, frames: frames, loopStart: nil, fallback: fallback)

        case .codexTriple:
            guard frames != idleFrames, !idleFrames.isEmpty else {
                return Animation(name: name, frames: frames, loopStart: 0, fallback: fallback)
            }
            let repeated = frames + frames + frames
            return Animation(
                name: name,
                frames: repeated + idleFrames,
                loopStart: repeated.count,
                fallback: fallback
            )
        }
    }
}

import Foundation

/// What the pet is expressing.
///
/// The four states Codex has map straight onto their upstream animations
/// (`working`→`running`, `waiting`→`waiting`, `review`→`review`,
/// `failed`→`failed`). The other four exist because Claude Code exposes more
/// lifecycle detail than Codex's four notification kinds, and they reuse existing
/// artwork rather than inventing any:
///
/// * `idle` — the upstream default.
/// * `attentive` — a session just opened; idle artwork under a wave transient.
/// * `sleeping` — idle frozen on frame 0, so the pet costs literally no CPU.
/// * `success` — a turn just landed; a jump transient that resolves to `review`.
public enum PetState: String, Sendable, CaseIterable, Comparable {
    case sleeping
    case idle
    case attentive
    case review
    case success
    case working
    case failed
    case waiting

    /// Higher wins when several Claude Code sessions disagree.
    ///
    /// `waiting` outranks everything because it is the only state that means "I
    /// am blocked until you do something". `failed` also wants attention but its
    /// turn is already over. `review` sits *below* `working` so that a finished
    /// turn in one terminal never masks a turn still running in another.
    ///
    /// `attentive` and `success` are the ephemeral bookends of a turn and sit low
    /// deliberately: a new session saying hello should not shout over real work.
    public var priority: Int {
        switch self {
        case .sleeping: return 0
        case .idle: return 1
        case .attentive: return 2
        case .review: return 3
        case .success: return 4
        case .working: return 5
        case .failed: return 6
        case .waiting: return 7
        }
    }

    public static func < (lhs: PetState, rhs: PetState) -> Bool {
        lhs.priority < rhs.priority
    }

    /// The animation track this state renders with.
    public var animationName: String {
        switch self {
        case .sleeping, .idle, .attentive: return "idle"
        case .working: return "running"
        case .waiting: return "waiting"
        case .review: return "review"
        case .failed: return "failed"
        case .success: return "jumping"
        }
    }

    /// `sleeping` holds the first idle frame and schedules nothing, which is how
    /// Codex renders the pet when animations are disabled
    /// (`ambient.rs:202-212`).
    public var isFrozen: Bool { self == .sleeping }

    /// A short human label, shown in the menu bar and by `hooklingctl status`.
    /// Wording follows Codex's `PetNotificationKind::label` where a state exists
    /// upstream, so the two are directly comparable.
    public var label: String {
        switch self {
        case .sleeping: return "Asleep"
        case .idle: return "Idle"
        case .attentive: return "Hello"
        case .working: return "Running"
        case .waiting: return "Needs input"
        case .review: return "Ready"
        case .success: return "Done"
        case .failed: return "Blocked"
        }
    }
}

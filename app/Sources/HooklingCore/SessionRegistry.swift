import Foundation

/// How long each state stays meaningful without a refresh, and when a session
/// record is forgotten entirely.
///
/// The point of these is that a Claude Code terminal that crashes, is killed, or
/// loses its `SessionEnd` hook cannot leave the pet stuck. Every state decays.
public struct SessionPolicy: Sendable, Equatable {
    /// Matches Codex's `RUNNING_LIFETIME` (`ambient.rs:41`). Refreshed by every
    /// tool event, so a genuinely long turn keeps the pet working — it is a
    /// watchdog for a dead terminal, not a cap on turn length.
    public var working: Nanoseconds

    /// Shorter than Codex's 24 hours: a desktop pet stuck looking anxious all day
    /// because a terminal died is worse than one that quietly settles.
    public var waiting: Nanoseconds

    /// Codex holds `Failed` for an hour. A minute is enough to notice on screen.
    public var failed: Nanoseconds

    /// Codex holds `Review` for a week because it is a status badge. Here it is a
    /// "just finished" flourish, so it fades quickly.
    public var review: Nanoseconds

    /// A greeting is over quickly.
    public var attentive: Nanoseconds

    /// Drop the session record entirely after this long with no events.
    public var record: Nanoseconds

    /// With every session idle for this long, the pet falls asleep and stops
    /// animating altogether.
    public var sleep: Nanoseconds

    public static let `default` = SessionPolicy(
        working: nanoseconds(seconds: 180),
        waiting: nanoseconds(seconds: 30 * 60),
        failed: nanoseconds(seconds: 60),
        review: nanoseconds(seconds: 90),
        attentive: nanoseconds(seconds: 10),
        record: nanoseconds(seconds: 6 * 60 * 60),
        sleep: nanoseconds(seconds: 15 * 60)
    )

    public init(
        working: Nanoseconds,
        waiting: Nanoseconds,
        failed: Nanoseconds,
        review: Nanoseconds,
        attentive: Nanoseconds,
        record: Nanoseconds,
        sleep: Nanoseconds
    ) {
        self.working = working
        self.waiting = waiting
        self.failed = failed
        self.review = review
        self.attentive = attentive
        self.record = record
        self.sleep = sleep
    }

    /// Time-to-live for a state, or `nil` if it never expires on its own.
    public func lifetime(of state: PetState) -> Nanoseconds? {
        switch state {
        case .working: return working
        case .waiting: return waiting
        case .failed: return failed
        case .review: return review
        case .attentive: return attentive
        case .success: return review
        case .idle, .sleeping: return nil
        }
    }
}

/// What an event did, so the caller can react.
public struct SessionReaction: Sendable, Equatable {
    /// A one-shot animation to play over the top, if the event warrants one.
    public let transient: String?

    /// The merged state across every live session, after applying the event.
    public let state: PetState

    public init(transient: String?, state: PetState) {
        self.transient = transient
        self.state = state
    }
}

/// Tracks one entry per Claude Code session and merges them into a single state.
///
/// Multiple terminals are the normal case, not an edge case, so the merge rule is
/// explicit: the highest-priority live state wins (see `PetState.priority`).
public final class SessionRegistry {
    public struct Session: Sendable, Equatable {
        public var state: PetState
        /// When `state` was last set or refreshed — the basis for expiry.
        public var updatedAt: Nanoseconds
    }

    /// Used when an adapter sends no session token. Everything still works; all
    /// such events simply share one bucket.
    public static let anonymousSessionKey = "anonymous"

    private let clock: any HooklingClock
    private let policy: SessionPolicy
    private var sessions: [String: Session] = [:]
    private var lastActivity: Nanoseconds

    public init(clock: any HooklingClock = MonotonicClock(), policy: SessionPolicy = .default) {
        self.clock = clock
        self.policy = policy
        self.lastActivity = clock.now
    }

    // MARK: - Applying events

    @discardableResult
    public func apply(event: PetEvent, session: String?) -> SessionReaction {
        let now = clock.now
        let key = session ?? Self.anonymousSessionKey
        lastActivity = now

        var transient: String?

        switch event {
        case .sessionStarted:
            sessions[key] = Session(state: .attentive, updatedAt: now)
            transient = "waving"

        case .promptSubmitted:
            // The wave is the greeting; the persistent state is already working,
            // so a turn that never calls a tool still shows as running.
            sessions[key] = Session(state: .working, updatedAt: now)
            transient = "waving"

        case .workStarted, .workProgress:
            sessions[key] = Session(state: .working, updatedAt: now)

        case .workFailed:
            // One tool failed but the turn carries on: flinch, keep working.
            sessions[key] = Session(state: .working, updatedAt: now)
            transient = "failed"

        case .attentionNeeded:
            sessions[key] = Session(state: .waiting, updatedAt: now)

        case .workFinished:
            sessions[key] = Session(state: .review, updatedAt: now)
            transient = "jumping"

        case .turnFailed:
            sessions[key] = Session(state: .failed, updatedAt: now)
            transient = "failed"

        case .sessionEnded:
            sessions.removeValue(forKey: key)
            transient = "waving"
        }

        return SessionReaction(transient: transient, state: mergedState())
    }

    // MARK: - Merging

    /// The state to display: the highest-priority live session state.
    ///
    /// Expired states are treated as idle, and once everything has been idle for
    /// `policy.sleep` the pet sleeps.
    public func mergedState() -> PetState {
        let now = clock.now
        prune(now: now)

        var winner: PetState = .idle
        for session in sessions.values {
            let effective = effectiveState(of: session, now: now)
            if effective > winner { winner = effective }
        }

        if winner == .idle, now - lastActivity >= policy.sleep {
            return .sleeping
        }
        return winner
    }

    private func effectiveState(of session: Session, now: Nanoseconds) -> PetState {
        guard let lifetime = policy.lifetime(of: session.state) else { return session.state }
        return (now - session.updatedAt >= lifetime) ? .idle : session.state
    }

    /// Forget sessions that have had no events for `policy.record`.
    ///
    /// Called from `mergedState`, so a caller that ticks the pet is also
    /// collecting garbage — there is no separate sweep timer to get wrong.
    private func prune(now: Nanoseconds) {
        sessions = sessions.filter { now - $0.value.updatedAt < policy.record }
    }

    // MARK: - Introspection

    public func reset() {
        sessions.removeAll()
        lastActivity = clock.now
    }

    public var sessionCount: Int { sessions.count }

    /// Snapshot for `hooklingctl status`, sorted for stable output. States are
    /// reported as currently effective, so an expired entry reads as idle.
    public func snapshot() -> [(session: String, state: PetState, ageSeconds: TimeInterval)] {
        let now = clock.now
        return sessions
            .map { key, session in
                (
                    session: key,
                    state: effectiveState(of: session, now: now),
                    ageSeconds: seconds(nanoseconds: now - session.updatedAt)
                )
            }
            .sorted { $0.session < $1.session }
    }
}

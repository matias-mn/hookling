import Foundation
import Testing
@testable import HooklingCore

@Suite("Session registry")
struct SessionRegistryTests {

    private func makeRegistry(_ clock: ManualClock) -> SessionRegistry {
        SessionRegistry(clock: clock, policy: .default)
    }

    @Test("each event maps to the expected state and reaction")
    func eventMapping() {
        let clock = ManualClock()

        func reaction(for event: PetEvent) -> SessionReaction {
            let registry = makeRegistry(clock)
            return registry.apply(event: event, session: "aa")
        }

        #expect(reaction(for: .sessionStarted) == SessionReaction(transient: "waving", state: .attentive))
        #expect(reaction(for: .promptSubmitted) == SessionReaction(transient: "waving", state: .working))
        #expect(reaction(for: .workStarted) == SessionReaction(transient: nil, state: .working))
        #expect(reaction(for: .workProgress) == SessionReaction(transient: nil, state: .working))
        #expect(reaction(for: .workFailed) == SessionReaction(transient: "failed", state: .working))
        #expect(reaction(for: .attentionNeeded) == SessionReaction(transient: nil, state: .waiting))
        #expect(reaction(for: .workFinished) == SessionReaction(transient: "jumping", state: .review))
        #expect(reaction(for: .turnFailed) == SessionReaction(transient: "failed", state: .failed))
    }

    @Test("a tool failure flinches but keeps the turn running")
    func toolFailureDoesNotEndTheTurn() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        registry.apply(event: .workStarted, session: "aa")

        let reaction = registry.apply(event: .workFailed, session: "aa")
        #expect(reaction.transient == "failed", "the pet should react visibly")
        #expect(reaction.state == .working, "but a single failed tool call is not a failed turn")
    }

    @Test("an ending session is forgotten")
    func sessionEndedForgets() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        registry.apply(event: .workStarted, session: "aa")
        #expect(registry.sessionCount == 1)

        let reaction = registry.apply(event: .sessionEnded, session: "aa")
        #expect(registry.sessionCount == 0)
        #expect(reaction.transient == "waving")
        #expect(reaction.state == .idle)
    }

    @Test("events without a session token share one bucket")
    func anonymousSessions() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        registry.apply(event: .workStarted, session: nil)
        registry.apply(event: .workProgress, session: nil)
        #expect(registry.sessionCount == 1)
        #expect(registry.mergedState() == .working)
    }

    // MARK: - Multiple sessions

    @Test("the highest-priority live session wins")
    func mergesByPriority() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)

        registry.apply(event: .workStarted, session: "aa")
        registry.apply(event: .workFinished, session: "bb")
        registry.apply(event: .sessionStarted, session: "cc")
        #expect(registry.sessionCount == 3)
        // working beats review and attentive.
        #expect(registry.mergedState() == .working)

        // A permission prompt anywhere outranks work everywhere.
        registry.apply(event: .attentionNeeded, session: "bb")
        #expect(registry.mergedState() == .waiting)

        // Resolving it drops back to the next-highest.
        registry.apply(event: .workProgress, session: "bb")
        #expect(registry.mergedState() == .working)
    }

    @Test("a finished turn never masks another still running")
    func reviewDoesNotMaskWorking() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        registry.apply(event: .workStarted, session: "aa")
        registry.apply(event: .workFinished, session: "bb")
        #expect(registry.mergedState() == .working)
    }

    @Test("a failure outranks work but not a permission prompt")
    func failureRanking() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        registry.apply(event: .workStarted, session: "aa")
        registry.apply(event: .turnFailed, session: "bb")
        #expect(registry.mergedState() == .failed)

        registry.apply(event: .attentionNeeded, session: "cc")
        #expect(registry.mergedState() == .waiting)
    }

    @Test("ten simultaneous sessions still resolve deterministically")
    func manySessions() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        for index in 0..<10 {
            registry.apply(event: .workProgress, session: String(format: "%02x", index))
        }
        #expect(registry.sessionCount == 10)
        #expect(registry.mergedState() == .working)

        registry.apply(event: .attentionNeeded, session: "07")
        #expect(registry.mergedState() == .waiting)
    }

    // MARK: - Expiry

    @Test("a crashed terminal cannot pin the pet to working")
    func workingExpires() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        registry.apply(event: .workStarted, session: "aa")
        #expect(registry.mergedState() == .working)

        // Just before the 180s watchdog.
        clock.advance(seconds: 179)
        #expect(registry.mergedState() == .working)

        // And after it: the terminal is presumed gone.
        clock.advance(seconds: 2)
        #expect(registry.mergedState() == .idle)
    }

    @Test("tool events refresh the watchdog, so a long turn keeps working")
    func heartbeatRefreshesWorking() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        registry.apply(event: .promptSubmitted, session: "aa")

        // Ten minutes of real work with a tool call every 60s.
        for _ in 0..<10 {
            clock.advance(seconds: 60)
            registry.apply(event: .workProgress, session: "aa")
            #expect(registry.mergedState() == .working)
        }
        // Then the terminal dies mid-turn.
        clock.advance(seconds: 181)
        #expect(registry.mergedState() == .idle)
    }

    @Test("every expiring state decays on schedule")
    func statesDecay() {
        let sleepThreshold: TimeInterval = 15 * 60
        let cases: [(PetEvent, PetState, TimeInterval)] = [
            (.attentionNeeded, .waiting, 30 * 60),
            (.turnFailed, .failed, 60),
            (.workFinished, .review, 90),
            (.sessionStarted, .attentive, 10),
        ]
        for (event, state, lifetime) in cases {
            let clock = ManualClock()
            let registry = makeRegistry(clock)
            registry.apply(event: event, session: "aa")
            #expect(registry.mergedState() == state)

            clock.advance(seconds: lifetime - 1)
            #expect(registry.mergedState() == state, "\(state.rawValue) expired early")

            clock.advance(seconds: 2)
            // A state whose lifetime outlasts the sleep threshold has, by
            // definition, spent that whole time with no events — so it decays
            // straight past idle into sleeping. An unanswered permission prompt
            // left for half an hour should find a sleeping pet, not an awake one.
            let expected: PetState = lifetime + 1 >= sleepThreshold ? .sleeping : .idle
            #expect(
                registry.mergedState() == expected,
                "\(state.rawValue) should decay to \(expected.rawValue)"
            )
        }
    }

    @Test("the pet falls asleep after long inactivity, and wakes on an event")
    func sleepsWhenQuiet() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        #expect(registry.mergedState() == .idle)

        clock.advance(seconds: 15 * 60 + 1)
        #expect(registry.mergedState() == .sleeping)

        registry.apply(event: .sessionStarted, session: "aa")
        #expect(registry.mergedState() == .attentive)
    }

    @Test("a working session prevents sleep even when idle-adjacent states expire")
    func doesNotSleepWhileWorking() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        registry.apply(event: .workStarted, session: "aa")

        // Keep it alive across the sleep threshold.
        for _ in 0..<20 {
            clock.advance(seconds: 60)
            registry.apply(event: .workProgress, session: "aa")
        }
        #expect(registry.mergedState() == .working)
    }

    @Test("abandoned session records are dropped entirely")
    func recordsArePruned() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        registry.apply(event: .workStarted, session: "aa")
        #expect(registry.sessionCount == 1)

        clock.advance(seconds: 6 * 60 * 60 + 1)
        _ = registry.mergedState()
        #expect(registry.sessionCount == 0, "a long-dead session should not be tracked forever")
    }

    @Test("reset clears everything")
    func resetClears() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        registry.apply(event: .attentionNeeded, session: "aa")
        registry.apply(event: .workStarted, session: "bb")

        registry.reset()
        #expect(registry.sessionCount == 0)
        #expect(registry.mergedState() == .idle)
    }

    @Test("the status snapshot reports effective, not stale, states")
    func snapshotReportsEffectiveState() {
        let clock = ManualClock()
        let registry = makeRegistry(clock)
        registry.apply(event: .workStarted, session: "aa")
        registry.apply(event: .attentionNeeded, session: "bb")

        clock.advance(seconds: 200)   // aa's working has expired; bb's waiting has not
        let snapshot = registry.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot[0].session == "aa")
        #expect(snapshot[0].state == .idle)
        #expect(snapshot[1].session == "bb")
        #expect(snapshot[1].state == .waiting)
        #expect(snapshot[0].ageSeconds >= 199)
    }
}

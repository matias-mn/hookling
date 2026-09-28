import Foundation
import Testing
@testable import HooklingCore

@Suite("Pet controller")
struct PetControllerTests {

    private func makeController(_ clock: ManualClock) throws -> PetController {
        let controller = PetController(catalog: try TestAssets.catalog(), clock: clock)
        // These tests are about the event -> state -> animation mapping. Ambient
        // wandering is orthogonal to all of it and would otherwise swap the idle
        // pose for a walk cycle wherever a test sits idle for a while, so it gets
        // its own suite (`WanderTests`) and is switched off here.
        controller.wanderEnabled = false
        return controller
    }

    /// Feed a raw wire line, the way the socket server does.
    private func send(_ text: String, to controller: PetController) throws -> PetSideEffect? {
        controller.handle(try EventCodec.decode(line: Data(text.utf8)))
    }

    // MARK: - The end-to-end session, with no Claude Code and no sockets

    @Test("a whole Claude Code turn drives the expected animations")
    func fullTurnSequence() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)

        // Nothing has happened yet.
        #expect(controller.tick().state == .idle)

        // SessionStart -> hello, then settle.
        _ = try send(#"{"event":"session_started","session":"a1"}"#, to: controller)
        var tick = controller.tick()
        #expect(tick.state == .attentive)
        #expect(tick.animationName == "waving")
        #expect(tick.isOverlay)

        clock.advance(milliseconds: 700)          // the wave finishes
        tick = controller.tick()
        #expect(tick.animationName == "idle")
        #expect(!tick.isOverlay)

        // UserPromptSubmit -> working, with a greeting over the top.
        _ = try send(#"{"event":"prompt_submitted","session":"a1"}"#, to: controller)
        tick = controller.tick()
        #expect(tick.state == .working)
        #expect(tick.animationName == "waving")

        clock.advance(milliseconds: 700)
        tick = controller.tick()
        #expect(tick.state == .working)
        #expect(tick.animationName == "running")

        // PreToolUse / PostToolUse -> heartbeats. The running cycle must keep
        // advancing rather than resetting on every event.
        var seenSprites: Set<Int> = []
        for _ in 0..<20 {
            _ = try send(#"{"event":"work_started","session":"a1"}"#, to: controller)
            clock.advance(milliseconds: 130)
            _ = try send(#"{"event":"work_progress","session":"a1"}"#, to: controller)
            seenSprites.insert(controller.tick().spriteIndex)
        }
        #expect(seenSprites.count > 1, "heartbeats froze the animation on one frame")
        #expect(seenSprites.isSubset(of: Set(56...61)))

        // A tool fails: visible flinch, but the turn is still running.
        _ = try send(#"{"event":"work_failed","session":"a1"}"#, to: controller)
        tick = controller.tick()
        #expect(tick.animationName == "failed")
        #expect(tick.state == .working)

        clock.advance(milliseconds: 1220)         // 7x140 + 240
        tick = controller.tick()
        #expect(tick.animationName == "running")

        // Stop -> celebrate, then show ready.
        _ = try send(#"{"event":"work_finished","session":"a1"}"#, to: controller)
        tick = controller.tick()
        #expect(tick.state == .review)
        #expect(tick.animationName == "jumping")

        clock.advance(milliseconds: 840)          // 4x140 + 280
        tick = controller.tick()
        #expect(tick.state == .review)
        #expect(tick.animationName == "review")

        // Ready fades back to idle on its own.
        clock.advance(seconds: 91)
        tick = controller.tick()
        #expect(tick.state == .idle)
        #expect(tick.animationName == "idle")

        // SessionEnd -> goodbye, and the session is forgotten.
        _ = try send(#"{"event":"session_ended","session":"a1"}"#, to: controller)
        tick = controller.tick()
        #expect(tick.animationName == "waving")
        #expect(controller.sessionCount == 0)
    }

    @Test("a permission prompt interrupts working and resolves back to it")
    func permissionPrompt() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)

        _ = try send(#"{"event":"prompt_submitted","session":"a1"}"#, to: controller)
        clock.advance(milliseconds: 700)
        #expect(controller.tick().state == .working)

        _ = try send(#"{"event":"attention_needed","session":"a1"}"#, to: controller)
        var tick = controller.tick()
        #expect(tick.state == .waiting)
        #expect(tick.animationName == "waiting")

        // Approving it resumes the turn.
        _ = try send(#"{"event":"work_started","session":"a1"}"#, to: controller)
        tick = controller.tick()
        #expect(tick.state == .working)
        #expect(tick.animationName == "running")
    }

    @Test("a failed turn shows the failure and then recovers")
    func failedTurn() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)

        _ = try send(#"{"event":"turn_failed","session":"a1"}"#, to: controller)
        var tick = controller.tick()
        #expect(tick.state == .failed)
        #expect(tick.animationName == "failed")

        clock.advance(seconds: 61)
        tick = controller.tick()
        #expect(tick.state == .idle)
    }

    @Test("two terminals: the one needing attention wins")
    func twoTerminals() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)

        _ = try send(#"{"event":"work_started","session":"a1"}"#, to: controller)
        _ = try send(#"{"event":"work_started","session":"b2"}"#, to: controller)
        clock.advance(milliseconds: 100)
        #expect(controller.tick().state == .working)

        _ = try send(#"{"event":"attention_needed","session":"b2"}"#, to: controller)
        #expect(controller.tick().state == .waiting)

        // The other terminal finishing does not clear the prompt in this one.
        _ = try send(#"{"event":"work_finished","session":"a1"}"#, to: controller)
        clock.advance(milliseconds: 900)
        #expect(controller.tick().state == .waiting)
    }

    @Test("a state expiring is noticed without a dedicated sweep timer")
    func expiryResolvesOnTick() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)
        _ = try send(#"{"event":"work_started","session":"a1"}"#, to: controller)
        #expect(controller.tick().state == .working)

        clock.advance(seconds: 200)
        // Ticking is what the renderer already does every frame; that alone must
        // be enough for the watchdog to fire.
        #expect(controller.tick().state == .idle)
    }

    // MARK: - Debug controls

    @Test("a forced state sticks instead of being overwritten on the next frame")
    func manualOverrideSticks() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)

        _ = try send(#"{"cmd":"state","value":"waiting"}"#, to: controller)
        #expect(controller.isManuallyOverridden)

        // Several frames later it is still waiting, even though no session is.
        for _ in 0..<5 {
            clock.advance(milliseconds: 200)
            #expect(controller.tick().state == .waiting)
        }

        // Real activity takes control back.
        _ = try send(#"{"event":"work_started","session":"a1"}"#, to: controller)
        #expect(!controller.isManuallyOverridden)
        #expect(controller.tick().state == .working)
    }

    @Test("every state and animation is reachable from the CLI")
    func debugCommandsCoverEverything() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)

        for state in PetState.allCases {
            _ = try send(#"{"cmd":"state","value":"\#(state.rawValue)"}"#, to: controller)
            #expect(controller.tick().state == state)
        }

        for name in controller.catalog.allNames {
            _ = try send(#"{"cmd":"play","value":"\#(name)"}"#, to: controller)
            let tick = controller.tick()
            #expect(tick.isOverlay, "animation \(name) did not play")
            controller.endPreview()
        }
    }

    @Test("side-effect commands are handed to the app")
    func sideEffects() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)
        #expect(try send(#"{"cmd":"demo"}"#, to: controller) == .runDemo)
        #expect(try send(#"{"cmd":"status"}"#, to: controller) == .reportStatus)
        #expect(try send(#"{"cmd":"snapshot"}"#, to: controller) == .writeSnapshot)
        #expect(try send(#"{"cmd":"quit"}"#, to: controller) == .quit)
        #expect(try send(#"{"cmd":"reset"}"#, to: controller) == nil)
    }

    @Test("pausing ignores adapter events but keeps the CLI working")
    func pauseIgnoresEvents() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)

        _ = try send(#"{"cmd":"pause","value":"on"}"#, to: controller)
        _ = try send(#"{"event":"work_started","session":"a1"}"#, to: controller)
        #expect(controller.tick().state == .idle, "a paused pet should not react")
        #expect(controller.sessionCount == 0)

        // Debug commands still land, so the pet remains inspectable while paused.
        _ = try send(#"{"cmd":"state","value":"review"}"#, to: controller)
        #expect(controller.tick().state == .review)

        _ = try send(#"{"cmd":"pause","value":"off"}"#, to: controller)
        _ = try send(#"{"event":"work_started","session":"a1"}"#, to: controller)
        #expect(controller.tick().state == .working)
    }

    @Test("reset returns the pet to idle and forgets sessions")
    func resetReturnsToIdle() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)
        _ = try send(#"{"event":"attention_needed","session":"a1"}"#, to: controller)
        #expect(controller.tick().state == .waiting)

        _ = try send(#"{"cmd":"reset"}"#, to: controller)
        #expect(controller.sessionCount == 0)
        #expect(controller.tick().state == .idle)
    }

    // MARK: - Robustness

    @Test("malformed and unknown messages leave the pet untouched")
    func malformedMessagesAreHarmless() throws {
        let clock = ManualClock()
        let controller = try makeController(clock)
        _ = try send(#"{"event":"work_started","session":"a1"}"#, to: controller)
        let before = controller.tick()

        // A hook from a future Claude Code version, a typo, junk, a truncated
        // line, and an attempt to smuggle content: all rejected at decode time,
        // so the controller never even sees them.
        let bad = [
            #"{"event":"quantum_entangled"}"#,
            #"{"event":"work_started","prompt":"secret"}"#,
            #"{"hook_event_name":"PostToolUse"}"#,
            #"{"event":"work_start"#,
            "",
            "garbage",
        ]
        for line in bad {
            #expect(throws: (any Error).self) {
                _ = try EventCodec.decode(line: Data(line.utf8))
            }
        }

        let after = controller.tick()
        #expect(after.state == before.state)
        #expect(controller.sessionCount == 1)
    }
}

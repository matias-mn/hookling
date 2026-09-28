import Foundation

/// The generic event vocabulary the pet understands.
///
/// This is deliberately *not* Claude Code's vocabulary. Each adapter under
/// `adapters/` translates its own tool's lifecycle into these names, so nothing
/// downstream of the socket knows which editor or agent is driving the pet.
/// Adding an adapter for Codex, Cursor or anything else means writing a new hook
/// configuration, not touching the app.
public enum PetEvent: String, Sendable, CaseIterable {
    /// A session opened. Registers it and says hello.
    case sessionStarted = "session_started"

    /// The user submitted a prompt: work is beginning.
    case promptSubmitted = "prompt_submitted"

    /// A tool call started. Also a heartbeat that keeps `working` alive.
    case workStarted = "work_started"

    /// A tool call finished, or any other sign of ongoing progress. Heartbeat.
    case workProgress = "work_progress"

    /// A single tool call failed. The turn continues, so this is a reaction
    /// rather than a state: the pet flinches and goes back to working.
    case workFailed = "work_failed"

    /// The agent is blocked on the user — a permission prompt, an elicitation,
    /// or an idle nudge.
    case attentionNeeded = "attention_needed"

    /// The turn completed successfully.
    case workFinished = "work_finished"

    /// The turn ended in an error.
    case turnFailed = "turn_failed"

    /// The session closed. Waves goodbye and forgets it.
    case sessionEnded = "session_ended"
}

/// Out-of-band instructions, used by `hooklingctl` for debugging. These bypass the
/// session model and drive the pet directly.
public enum PetCommand: Sendable, Equatable {
    /// Force a persistent state.
    case setState(PetState)

    /// Play a one-shot animation over the current state.
    case play(String)

    /// Walk every animation in the catalog, captioned.
    case demo

    /// Report current state, sessions and asset status back over the socket.
    case status

    /// Render what is on screen right now to a PNG.
    ///
    /// Takes no path on purpose: the destination is fixed, so this cannot become
    /// a "write a file anywhere" channel, and the charset restriction on command
    /// values stays intact.
    case snapshot

    /// Stop reacting to adapter events (menu "Pause reactions" equivalent).
    case pause(Bool)

    /// Let him stroll about while idle (menu "Wander when idle" equivalent).
    case wander(Bool)

    /// Forget all sessions and return to idle.
    case reset

    /// Quit the app.
    case quit
}

/// One decoded line from the socket.
public enum PetMessage: Sendable, Equatable {
    case event(PetEvent, session: String?)
    case command(PetCommand)
}

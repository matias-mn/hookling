import Foundation
import Testing
@testable import HooklingCore

@Suite("Wire format")
struct EventCodecTests {

    private func decode(_ text: String) throws -> PetMessage {
        try EventCodec.decode(line: Data(text.utf8))
    }

    @Test("every event name round-trips", arguments: PetEvent.allCases)
    func eventsRoundTrip(event: PetEvent) throws {
        let encoded = EventCodec.encode(event: event, session: "deadbeef")
        let trimmed = encoded.dropLast()   // strip the newline
        let decoded = try EventCodec.decode(line: Data(trimmed))
        #expect(decoded == .event(event, session: "deadbeef"))
    }

    @Test("an event without a session is valid")
    func eventWithoutSession() throws {
        #expect(try decode(#"{"event":"work_started"}"#) == .event(.workStarted, session: nil))
    }

    @Test("a timestamp is accepted and discarded")
    func timestampAccepted() throws {
        // `ts` is allowed so an adapter can include one, but nothing downstream
        // reads it: the pet trusts its own clock.
        #expect(try decode(#"{"event":"work_started","ts":1723600000}"#) == .event(.workStarted, session: nil))
    }

    @Test("commands decode")
    func commandsDecode() throws {
        #expect(try decode(#"{"cmd":"state","value":"working"}"#) == .command(.setState(.working)))
        #expect(try decode(#"{"cmd":"play","value":"waving"}"#) == .command(.play("waving")))
        #expect(try decode(#"{"cmd":"demo"}"#) == .command(.demo))
        #expect(try decode(#"{"cmd":"status"}"#) == .command(.status))
        #expect(try decode(#"{"cmd":"snapshot"}"#) == .command(.snapshot))
        #expect(try decode(#"{"cmd":"pause","value":"on"}"#) == .command(.pause(true)))
        #expect(try decode(#"{"cmd":"pause","value":"off"}"#) == .command(.pause(false)))
        #expect(try decode(#"{"cmd":"reset"}"#) == .command(.reset))
        #expect(try decode(#"{"cmd":"quit"}"#) == .command(.quit))
    }

    @Test("every command round-trips", arguments: [
        PetCommand.setState(.waiting), .play("jumping"), .demo, .status, .snapshot,
        .pause(true), .pause(false), .reset, .quit,
    ])
    func commandsRoundTrip(command: PetCommand) throws {
        let encoded = EventCodec.encode(command: command)
        let decoded = try EventCodec.decode(line: Data(encoded.dropLast()))
        #expect(decoded == .command(command))
    }

    @Test("every state name is reachable from the CLI", arguments: PetState.allCases)
    func statesReachable(state: PetState) throws {
        let decoded = try decode(#"{"cmd":"state","value":"\#(state.rawValue)"}"#)
        #expect(decoded == .command(.setState(state)))
    }

    // MARK: - Privacy: unknown keys are refused, not ignored

    @Test("an unknown key rejects the whole message")
    func unknownKeyRejected() {
        // This is the guarantee that matters: even if a hook were modified to
        // attach content, the app refuses the message rather than accepting the
        // parts it recognises.
        #expect(throws: EventCodecError.unknownKeys(["prompt"])) {
            try decode(#"{"event":"work_started","prompt":"my secret prompt"}"#)
        }
        #expect(throws: EventCodecError.unknownKeys(["cwd", "transcript_path"])) {
            try decode(#"{"event":"work_started","transcript_path":"/tmp/x.jsonl","cwd":"/repo"}"#)
        }
        #expect(throws: EventCodecError.unknownKeys(["tool_input"])) {
            try decode(#"{"cmd":"status","tool_input":"rm -rf /"}"#)
        }
    }

    @Test("the session field cannot carry prose")
    func sessionMustBeHex() {
        #expect(throws: EventCodecError.invalidSessionToken) {
            try decode(#"{"event":"work_started","session":"please summarise my repo"}"#)
        }
        // Uppercase hex is refused too, so there is exactly one canonical form.
        #expect(throws: EventCodecError.invalidSessionToken) {
            try decode(#"{"event":"work_started","session":"DEADBEEF"}"#)
        }
        // Over 32 characters.
        #expect(throws: EventCodecError.invalidSessionToken) {
            try decode(#"{"event":"work_started","session":"\#(String(repeating: "a", count: 33))"}"#)
        }
        #expect(EventCodec.isValidSessionToken("0123456789abcdef"))
        #expect(!EventCodec.isValidSessionToken(""))
        #expect(!EventCodec.isValidSessionToken("g"))
    }

    @Test("an animation name cannot carry prose")
    func animationNameRestricted() {
        #expect(throws: (any Error).self) {
            try decode(#"{"cmd":"play","value":"here is the file contents"}"#)
        }
        #expect(EventCodec.isValidAnimationName("running-right"))
        #expect(EventCodec.isValidAnimationName("move_left"))
        #expect(!EventCodec.isValidAnimationName("Waving"))
        #expect(!EventCodec.isValidAnimationName(""))
    }

    @Test("oversized messages are refused before parsing")
    func oversizedRefused() {
        let huge = String(repeating: "x", count: 2_000_000)
        #expect(throws: (any Error).self) {
            try decode(#"{"event":"work_started","session":"\#(huge)"}"#)
        }
        // Exactly at the limit is fine; one over is not.
        let atLimit = Data(repeating: 0x20, count: EventCodec.maximumMessageBytes)
        #expect(throws: (any Error).self) { try EventCodec.decode(line: atLimit) }
        let overLimit = Data(repeating: 0x20, count: EventCodec.maximumMessageBytes + 1)
        #expect(throws: EventCodecError.tooLarge(EventCodec.maximumMessageBytes + 1)) {
            try EventCodec.decode(line: overLimit)
        }
    }

    // MARK: - Malformed input

    @Test("malformed input is rejected", arguments: [
        "",
        "   ",
        "not json",
        "[]",
        "null",
        "123",
        #"{"event":"work_started""#,                     // truncated
        #"{"event":"nope"}"#,                            // unknown event
        #"{"cmd":"nope"}"#,                              // unknown command
        #"{}"#,                                          // neither
        #"{"event":"work_started","cmd":"status"}"#,      // both
        #"{"event":123}"#,                               // wrong type
        #"{"cmd":"state"}"#,                             // missing value
        #"{"cmd":"state","value":"nonsense"}"#,          // unknown state
        #"{"cmd":"pause","value":"maybe"}"#,             // bad enum
        #"{"cmd":"play"}"#,                              // missing value
    ])
    func malformedRejected(text: String) {
        #expect(throws: (any Error).self) { try decode(text) }
    }

    @Test("raw binary is rejected rather than crashing")
    func binaryRejected() {
        let binary = Data([0xFF, 0xFE, 0x00, 0x01, 0x7F, 0x80, 0x00, 0xC0])
        #expect(throws: (any Error).self) { try EventCodec.decode(line: binary) }
    }
}

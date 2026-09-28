import Foundation

public enum EventCodecError: Error, Equatable, CustomStringConvertible {
    case tooLarge(Int)
    case notAnObject
    case unknownKeys([String])
    case ambiguous
    case unknownEvent(String)
    case unknownCommand(String)
    case invalidValue(String)
    case invalidSessionToken

    public var description: String {
        switch self {
        case .tooLarge(let bytes): return "message is \(bytes) bytes, over the limit"
        case .notAnObject: return "message is not a JSON object"
        case .unknownKeys(let keys): return "message has unexpected keys: \(keys.joined(separator: ", "))"
        case .ambiguous: return "message must contain exactly one of 'event' or 'cmd'"
        case .unknownEvent(let name): return "unknown event '\(name)'"
        case .unknownCommand(let name): return "unknown command '\(name)'"
        case .invalidValue(let detail): return "invalid value: \(detail)"
        case .invalidSessionToken: return "session must be 1-32 lowercase hex characters"
        }
    }
}

/// The socket wire format.
///
/// Two shapes, and nothing else:
///
///     {"event": "work_started", "session": "3f2a1c8e0b4d5967"}
///     {"cmd": "state", "value": "working"}
///
/// Decoding is deliberately strict, and that strictness is a privacy control
/// rather than fussiness. The pet must never receive prompts, file contents, tool
/// arguments or command strings, so:
///
/// * **Unknown keys are rejected**, not ignored. A hook that tried to attach
///   `{"prompt": "..."}` would have its whole message dropped, so the guarantee
///   does not depend on the hook behaving.
/// * `event` and `cmd` must be values from a closed enum.
/// * `session` must look like an opaque hex token — the hook hashes the real
///   session id, and anything that is not a hash is refused.
/// * `value` is bounded and character-restricted, so it cannot carry prose.
public enum EventCodec {
    /// Generous for a message whose largest legitimate form is about 60 bytes,
    /// but small enough that nothing interesting fits.
    public static let maximumMessageBytes = 512

    private static let eventKeys: Set<String> = ["event", "session", "ts"]
    private static let commandKeys: Set<String> = ["cmd", "value"]

    // MARK: - Decoding

    public static func decode(line: Data) throws -> PetMessage {
        guard line.count <= maximumMessageBytes else {
            throw EventCodecError.tooLarge(line.count)
        }

        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw EventCodecError.notAnObject
            }
            object = parsed
        } catch let error as EventCodecError {
            throw error
        } catch {
            throw EventCodecError.notAnObject
        }

        let keys = Set(object.keys)
        let hasEvent = keys.contains("event")
        let hasCommand = keys.contains("cmd")
        guard hasEvent != hasCommand else { throw EventCodecError.ambiguous }

        if hasEvent {
            let unknown = keys.subtracting(eventKeys)
            guard unknown.isEmpty else { throw EventCodecError.unknownKeys(unknown.sorted()) }

            guard let name = object["event"] as? String else {
                throw EventCodecError.invalidValue("event must be a string")
            }
            guard let event = PetEvent(rawValue: name) else {
                throw EventCodecError.unknownEvent(name)
            }

            var session: String?
            if let raw = object["session"] {
                guard let token = raw as? String, isValidSessionToken(token) else {
                    throw EventCodecError.invalidSessionToken
                }
                session = token
            }
            return .event(event, session: session)
        }

        let unknown = keys.subtracting(commandKeys)
        guard unknown.isEmpty else { throw EventCodecError.unknownKeys(unknown.sorted()) }

        guard let name = object["cmd"] as? String else {
            throw EventCodecError.invalidValue("cmd must be a string")
        }
        let value = object["value"] as? String

        switch name {
        case "state":
            guard let value, let state = PetState(rawValue: value) else {
                throw EventCodecError.invalidValue("unknown state '\(value ?? "")'")
            }
            return .command(.setState(state))
        case "play":
            guard let value, isValidAnimationName(value) else {
                throw EventCodecError.invalidValue("animation name must be 1-32 characters of [a-z0-9_-]")
            }
            return .command(.play(value))
        case "demo":
            return .command(.demo)
        case "status":
            return .command(.status)
        case "snapshot":
            return .command(.snapshot)
        case "pause":
            guard let value, value == "on" || value == "off" else {
                throw EventCodecError.invalidValue("pause takes 'on' or 'off'")
            }
            return .command(.pause(value == "on"))
        case "wander":
            guard let value, value == "on" || value == "off" else {
                throw EventCodecError.invalidValue("wander takes 'on' or 'off'")
            }
            return .command(.wander(value == "on"))
        case "reset":
            return .command(.reset)
        case "quit":
            return .command(.quit)
        default:
            throw EventCodecError.unknownCommand(name)
        }
    }

    // MARK: - Encoding

    public static func encode(event: PetEvent, session: String? = nil) -> Data {
        var json = #"{"event":"\#(event.rawValue)""#
        if let session, isValidSessionToken(session) {
            json += #","session":"\#(session)""#
        }
        json += "}\n"
        return Data(json.utf8)
    }

    public static func encode(command: PetCommand) -> Data {
        let json: String
        switch command {
        case .setState(let state):
            json = #"{"cmd":"state","value":"\#(state.rawValue)"}"#
        case .play(let name):
            json = #"{"cmd":"play","value":"\#(name)"}"#
        case .demo:
            json = #"{"cmd":"demo"}"#
        case .status:
            json = #"{"cmd":"status"}"#
        case .snapshot:
            json = #"{"cmd":"snapshot"}"#
        case .pause(let paused):
            json = #"{"cmd":"pause","value":"\#(paused ? "on" : "off")"}"#
        case .wander(let wandering):
            json = #"{"cmd":"wander","value":"\#(wandering ? "on" : "off")"}"#
        case .reset:
            json = #"{"cmd":"reset"}"#
        case .quit:
            json = #"{"cmd":"quit"}"#
        }
        return Data((json + "\n").utf8)
    }

    // MARK: - Validation

    /// An opaque 1-32 character lowercase hex token. The adapter produces this by
    /// hashing the session id, so the pet never holds the id itself.
    public static func isValidSessionToken(_ token: String) -> Bool {
        guard (1...32).contains(token.count) else { return false }
        return token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public static func isValidAnimationName(_ name: String) -> Bool {
        guard (1...32).contains(name.count) else { return false }
        return name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}

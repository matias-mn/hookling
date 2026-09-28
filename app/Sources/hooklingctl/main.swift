import Foundation
import HooklingCore

// hooklingctl - drive and inspect the pet without involving Claude Code.
//
// Two audiences in one binary: a person debugging animations, and (optionally) an
// adapter hook. Either way it exits 0 when the pet is not running, so wiring it
// into a hook can never interfere with the tool that called it.

let socketPath = HooklingSocket.resolvedPath()

func printUsage() {
    let states = PetState.allCases.map(\.rawValue).joined(separator: " | ")
    let events = PetEvent.allCases.map(\.rawValue).joined(separator: "\n                  ")
    print("""
    hooklingctl - control the Hookling desktop pet

    USAGE
      hooklingctl <state>            set a state directly (debug)
      hooklingctl play <animation>   play an animation once over the current state
      hooklingctl <animation>        shorthand for `play <animation>`
      hooklingctl demo               walk every animation, captioned on screen
      hooklingctl list               list the animations in animations.json
      hooklingctl status             report state, sessions and artwork
      hooklingctl snapshot           write a PNG of the frame on screen right now,
                                  next to the socket
      hooklingctl emit <event>       send a generic adapter event
      hooklingctl pause | resume     stop or resume reacting to adapter events
      hooklingctl wander on | off    let him stroll about while idle
      hooklingctl reset              forget all sessions and return to idle
      hooklingctl quit               quit the pet
      hooklingctl testsheet <path>   write a numbered diagnostic spritesheet, so the
                                  sprite mapping can be verified without any
                                  third-party artwork

    STATES
      \(states)

    EVENTS
      \(events)

    NOTES
      Exits 0 when the pet is not running, so this is safe to call from a hook.
      Socket: \(socketPath)
      Override with \(HooklingSocket.environmentVariable).
    """)
}

/// Send one message. Returns the process exit code.
@discardableResult
func send(_ payload: Data, awaitReply: Bool = false, quiet: Bool = false) -> Int32 {
    switch SocketClient.send(payload, path: socketPath, awaitReply: awaitReply) {
    case .delivered(let reply):
        if let reply, !reply.isEmpty { print(reply, terminator: reply.hasSuffix("\n") ? "" : "\n") }
        return 0
    case .notRunning:
        // Deliberately not an error: "Hookling isn't running" is a normal state.
        if !quiet { FileHandle.standardError.write(Data("hooklingctl: Hookling is not running\n".utf8)) }
        return 0
    case .failed(let reason):
        if !quiet { FileHandle.standardError.write(Data("hooklingctl: \(reason)\n".utf8)) }
        return quiet ? 0 : 1
    }
}

/// Load the catalog so animation names can be validated and listed locally,
/// without asking the pet.
func loadCatalog() -> AnimationCatalog? {
    guard let url = CatalogLocator.animationsURL() else { return nil }
    return try? AnimationCatalog.load(contentsOf: url)
}

private extension String {
    /// Left-align in a column of `width`. Never truncates: an over-long name
    /// should push the table out of shape rather than quietly lose characters.
    func padding(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

func listAnimations() -> Int32 {
    guard let catalog = loadCatalog() else {
        FileHandle.standardError.write(Data("hooklingctl: could not find animations.json\n".utf8))
        return 1
    }

    print("\(catalog.sheetFileName)  -  \(catalog.geometry.columns)x\(catalog.geometry.rows) grid "
          + "of \(catalog.geometry.frameWidth)x\(catalog.geometry.frameHeight) frames")
    print("")
    print("  animation        row  frames  sprites                  total")
    print("  ---------------  ---  ------  -----------------------  -------")
    for name in catalog.canonicalNames {
        guard let track = catalog.track(named: name) else { continue }
        let sprites = track.frames.map { String($0.spriteIndex) }.joined(separator: ",")
        let total = track.frames.reduce(0) { $0 + $1.duration }
        // Padded here rather than with a `%-15@` width: Foundation ignores width
        // specifiers on `%@`, which silently collapses the table into one ragged
        // column.
        print("  \(name.padding(15))  "
              + String(format: "%3d", track.row) + "  "
              + String(format: "%6d", track.frames.count) + "  "
              + sprites.padding(23) + "  "
              + String(format: "%5.0fms", seconds(nanoseconds: total) * 1000))
    }
    if !catalog.aliases.isEmpty {
        print("")
        print("  aliases: " + catalog.aliases.sorted { $0.key < $1.key }
            .map { "\($0.key) -> \($0.value)" }
            .joined(separator: ", "))
    }
    return 0
}

// MARK: - Argument handling

let arguments = Array(CommandLine.arguments.dropFirst())

guard let first = arguments.first else {
    printUsage()
    exit(2)
}

var exitCode: Int32 = 0

switch first {
case "-h", "--help", "help":
    printUsage()

case "list", "animations":
    exitCode = listAnimations()

case "status":
    exitCode = send(EventCodec.encode(command: .status), awaitReply: true)

case "snapshot":
    exitCode = send(EventCodec.encode(command: .snapshot), awaitReply: true)

case "demo":
    // Print the table locally as well, so the terminal has the labels while the
    // captions appear on screen.
    _ = listAnimations()
    print("")
    print("Playing each animation in turn. Watch Hookling - the caption under him "
          + "names the current animation.")
    exitCode = send(EventCodec.encode(command: .demo), awaitReply: true)

case "pause":
    exitCode = send(EventCodec.encode(command: .pause(true)))

case "resume", "unpause":
    exitCode = send(EventCodec.encode(command: .pause(false)))

case "wander":
    guard arguments.count >= 2, arguments[1] == "on" || arguments[1] == "off" else {
        FileHandle.standardError.write(Data("hooklingctl: wander takes 'on' or 'off'\n".utf8))
        exit(2)
    }
    exitCode = send(EventCodec.encode(command: .wander(arguments[1] == "on")))

case "reset":
    exitCode = send(EventCodec.encode(command: .reset))

case "quit", "exit":
    exitCode = send(EventCodec.encode(command: .quit))

case "testsheet":
    guard arguments.count >= 2 else {
        FileHandle.standardError.write(Data("hooklingctl: testsheet needs an output path\n".utf8))
        exit(2)
    }
    let output = URL(fileURLWithPath: arguments[1])
    let geometry = loadCatalog()?.geometry ?? .codexDefault
    do {
        try TestSheet.write(to: output, geometry: geometry)
        print("wrote \(geometry.sheetWidth)x\(geometry.sheetHeight) diagnostic sheet "
              + "(\(geometry.frameCount) numbered frames) to \(output.path)")
        print("point Hookling at it with:  HOOKLING_SPRITESHEET=\(output.path) ./scripts/run.sh")
    } catch {
        FileHandle.standardError.write(Data("hooklingctl: \(error)\n".utf8))
        exit(1)
    }

case "play":
    guard arguments.count >= 2 else {
        FileHandle.standardError.write(Data("hooklingctl: play needs an animation name\n".utf8))
        exit(2)
    }
    exitCode = send(EventCodec.encode(command: .play(arguments[1])))

case "emit", "event":
    guard arguments.count >= 2, let event = PetEvent(rawValue: arguments[1]) else {
        let known = PetEvent.allCases.map(\.rawValue).joined(separator: ", ")
        FileHandle.standardError.write(Data("hooklingctl: emit needs one of: \(known)\n".utf8))
        exit(2)
    }
    // An optional opaque session token, so multi-session behaviour can be
    // exercised by hand.
    let session = arguments.count >= 3 ? arguments[2] : nil
    exitCode = send(EventCodec.encode(event: event, session: session))

default:
    // Bare word: a state name, or an animation name.
    if let state = PetState(rawValue: first) {
        exitCode = send(EventCodec.encode(command: .setState(state)))
    } else if let catalog = loadCatalog(), catalog.track(named: first) != nil {
        exitCode = send(EventCodec.encode(command: .play(first)))
    } else if EventCodec.isValidAnimationName(first) {
        // No catalog to check against; let the pet decide and ignore it if unknown.
        exitCode = send(EventCodec.encode(command: .play(first)))
    } else {
        FileHandle.standardError.write(Data("hooklingctl: unknown command '\(first)'\n".utf8))
        printUsage()
        exit(2)
    }
}

exit(exitCode)

import Foundation
import HooklingCore

/// Puts the hook where the Claude Code plugin can always find it.
///
/// A plugin installed from GitHub is a checkout of the repository, and the hook
/// is a compiled binary that is deliberately not committed. So the app carries
/// the hook inside its bundle and, on every launch, copies it to one fixed place:
///
///     ~/Library/Application Support/Hookling/bin/hookling-hook
///
/// `hooks.json` prefers a hook built into the plugin directory (a source checkout)
/// and falls back to this one. The hook is copied rather than linked so that it
/// keeps working if the app is moved, or was launched from a translocated
/// read-only location. `hooklingctl` is linked instead: it reads
/// `animations.json` from the bundle, so it has to run from there.
enum HookInstaller {
    static let hookName = "hookling-hook"
    static let controlName = "hooklingctl"

    /// `~/Library/Application Support/Hookling/bin`
    static func binDirectory(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(HooklingSocket.directoryName)
            .appendingPathComponent("bin")
    }

    /// Returns a line for the log, or nil when running outside a bundle (for
    /// example `swift run`), where there is nothing to install.
    static func installFromMainBundle() -> String? {
        guard let hook = Bundle.main.url(forAuxiliaryExecutable: hookName) else { return nil }
        let directory = binDirectory()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let changed = try copyIfDifferent(hook, to: directory.appendingPathComponent(hookName))
            if let control = Bundle.main.url(forAuxiliaryExecutable: controlName) {
                try link(directory.appendingPathComponent(controlName), to: control)
            }
            return changed
                ? "installed the Claude Code hook in \(directory.path)"
                : "Claude Code hook is up to date in \(directory.path)"
        } catch {
            return "could not install the Claude Code hook in \(directory.path): \(error)"
        }
    }

    /// Atomic, so a hook that fires mid-update runs either the old binary or the
    /// new one, never half of one.
    private static func copyIfDifferent(_ source: URL, to destination: URL) throws -> Bool {
        let data = try Data(contentsOf: source)
        if let existing = try? Data(contentsOf: destination), existing == data { return false }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        if rename(temporary.path, destination.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        return true
    }

    private static func link(_ link: URL, to target: URL) throws {
        let fileManager = FileManager.default
        if let current = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
           current == target.path {
            return
        }
        try? fileManager.removeItem(at: link)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
    }
}

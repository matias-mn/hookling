import Foundation

/// Finds `animations.json`.
///
/// Lives in the core because both the app and `hooklingctl` need it — the CLI reads
/// the catalog directly so it can validate and list animation names without a
/// running pet.
///
/// There is exactly one copy of the file in the repository; `scripts/build.sh`
/// copies it into the app bundle. Nothing embeds a second copy, so the shipped
/// data and the tested data cannot drift apart.
public enum CatalogLocator {
    public static let environmentVariable = "HOOKLING_ANIMATIONS"

    public static func animationsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment[environmentVariable], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let bundled = Bundle.main.url(forResource: "animations", withExtension: "json") {
            return bundled
        }
        // `hooklingctl` is usually run through the link the app puts in
        // ~/Library/Application Support/Hookling/bin. Bundle.main does not follow
        // that link, so also look in the bundle the real executable lives in.
        if let executable = Bundle.main.executableURL {
            let url = executable.resolvingSymlinksInPath()
                .deletingLastPathComponent()                // Contents/MacOS
                .deletingLastPathComponent()                // Contents
                .appendingPathComponent("Resources/animations.json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let root = repositoryRoot() {
            let url = root.appendingPathComponent("assets/pet/animations.json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Walk up from the running binary looking for the project checkout.
    ///
    /// Handles both layouts without special-casing either: `.build/…/Hookling`
    /// during development, and `Hookling.app/Contents/MacOS/Hookling` once
    /// bundled — including a bundle sitting in the checkout's `build/` directory.
    public static func repositoryRoot(
        startingAt executablePath: String = CommandLine.arguments.first ?? ""
    ) -> URL? {
        guard !executablePath.isEmpty else { return nil }
        var directory = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()

        for _ in 0..<8 {
            let marker = directory.appendingPathComponent("assets/pet/animations.json")
            if FileManager.default.fileExists(atPath: marker.path) { return directory }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}

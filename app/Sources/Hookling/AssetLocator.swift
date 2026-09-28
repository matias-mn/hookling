import Foundation
import HooklingCore

/// Finds the spritesheet.
///
/// The search order matters for licensing reasons, not just convenience. Reading
/// the copy Codex already placed in the user's own cache means this project
/// neither distributes the artwork nor makes a copy of it — see
/// `docs/licensing.md`. So the Codex cache is preferred over a local copy in
/// `assets/`, and the app never downloads anything itself.
///
/// `animations.json` is located by ``CatalogLocator`` in HooklingCore, because
/// `hooklingctl` needs it too.
enum AssetLocator {
    static let spritesheetEnvironmentVariable = "HOOKLING_SPRITESHEET"

    /// Where a spritesheet was found, so the UI can explain itself.
    enum Source: Equatable {
        case environment
        case preference
        case codexCache
        case projectAssets
        case appBundle

        var description: String {
            switch self {
            case .environment: return "HOOKLING_SPRITESHEET"
            case .preference: return "chosen from the menu"
            case .codexCache: return "your Codex cache"
            case .projectAssets: return "assets/pet"
            case .appBundle: return "the app bundle"
            }
        }
    }

    static func spritesheet(
        named fileName: String,
        preferredPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (url: URL, source: Source)? {
        var candidates: [(URL, Source)] = []

        if let override = environment[spritesheetEnvironmentVariable], !override.isEmpty {
            candidates.append((URL(fileURLWithPath: override), .environment))
        }
        if let preferredPath, !preferredPath.isEmpty {
            candidates.append((URL(fileURLWithPath: preferredPath), .preference))
        }
        // Preferred: the file Codex itself downloaded, read in place.
        candidates.append((codexCacheURL(named: fileName, environment: environment), .codexCache))

        if let root = CatalogLocator.repositoryRoot() {
            candidates.append((
                root.appendingPathComponent("assets/pet/\(fileName)"), .projectAssets
            ))
        }
        if let bundled = Bundle.main.url(
            forResource: (fileName as NSString).deletingPathExtension,
            withExtension: (fileName as NSString).pathExtension
        ) {
            candidates.append((bundled, .appBundle))
        }

        for (url, source) in candidates where FileManager.default.fileExists(atPath: url.path) {
            return (url, source)
        }
        return nil
    }

    /// `$CODEX_HOME/cache/tui-pets/v1/assets/<file>`, the path Codex installs to
    /// (`codex-rs/tui/src/pets/asset_pack.rs`).
    static func codexCacheURL(
        named fileName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() + "/.codex")
        return URL(fileURLWithPath: home)
            .appendingPathComponent("cache/tui-pets/v1/assets")
            .appendingPathComponent(fileName)
    }
}

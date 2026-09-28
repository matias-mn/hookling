import Foundation
@testable import HooklingCore

/// Locates the real `assets/pet/animations.json`.
///
/// The animation data has exactly one copy in this repository — the app copies it
/// into its bundle at build time — so the tests read that same file rather than a
/// fixture. A drift between what ships and what is tested is therefore impossible.
enum TestAssets {
    static var repositoryRoot: URL {
        // .../app/Tests/HooklingCoreTests/TestSupport.swift -> repository root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HooklingCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repository root
    }

    static var animationsURL: URL {
        repositoryRoot
            .appendingPathComponent("assets")
            .appendingPathComponent("pet")
            .appendingPathComponent("animations.json")
    }

    static func catalog() throws -> AnimationCatalog {
        try AnimationCatalog.load(contentsOf: animationsURL)
    }
}

/// The upstream animation table, transcribed from Codex's
/// `codex-rs/tui/src/pets/model.rs` `default_animations()`.
///
/// Written out by hand on purpose: these tests compare our data file against an
/// independent transcription of upstream, so a typo in `animations.json` fails
/// rather than being silently blessed.
enum UpstreamTable {
    struct Track {
        let name: String
        let row: Int
        let frameCount: Int
        let frameMilliseconds: Int
        let finalFrameMilliseconds: Int
    }

    /// `idle_animation()` — explicit per-frame durations, `model.rs:584-596`.
    static let idleFrames: [(index: Int, milliseconds: Int)] = [
        (0, 1680), (1, 660), (2, 660), (3, 840), (4, 840), (5, 1920),
    ]

    /// `app_state_animation(row, count, ms, finalMs)` calls, `model.rs:486-577`.
    static let tracks: [Track] = [
        Track(name: "running-right", row: 1, frameCount: 8, frameMilliseconds: 120, finalFrameMilliseconds: 220),
        Track(name: "running-left", row: 2, frameCount: 8, frameMilliseconds: 120, finalFrameMilliseconds: 220),
        Track(name: "waving", row: 3, frameCount: 4, frameMilliseconds: 140, finalFrameMilliseconds: 280),
        Track(name: "jumping", row: 4, frameCount: 5, frameMilliseconds: 140, finalFrameMilliseconds: 280),
        Track(name: "failed", row: 5, frameCount: 8, frameMilliseconds: 140, finalFrameMilliseconds: 240),
        Track(name: "waiting", row: 6, frameCount: 6, frameMilliseconds: 150, finalFrameMilliseconds: 260),
        Track(name: "running", row: 7, frameCount: 6, frameMilliseconds: 120, finalFrameMilliseconds: 220),
        Track(name: "review", row: 8, frameCount: 6, frameMilliseconds: 150, finalFrameMilliseconds: 280),
    ]

    /// Upstream's aliases: separate catalog entries with identical parameters.
    static let aliases: [String: String] = [
        "move_right": "running-right",
        "move_left": "running-left",
        "wave": "waving",
        "bounce": "jumping",
        "sad": "failed",
    ]
}

/// A minimal catalog for tests that need specific shapes rather than real data.
func makeCatalog(
    geometry: SpriteGeometry = .codexDefault,
    tracks: [AnimationTrack]
) -> AnimationCatalog {
    var byName: [String: AnimationTrack] = [:]
    for track in tracks { byName[track.name] = track }
    return AnimationCatalog(
        geometry: geometry,
        sheetFileName: "test.webp",
        tracks: byName,
        aliases: [:]
    )
}

func makeTrack(
    name: String,
    row: Int = 0,
    frames: [(Int, Int)],
    loops: Bool = true,
    fallback: String = "idle"
) -> AnimationTrack {
    AnimationTrack(
        name: name,
        row: row,
        frames: frames.map { AnimationFrame(spriteIndex: $0.0, milliseconds: $0.1) },
        loops: loops,
        fallback: fallback
    )
}

/// An idle track shaped like the real one, for machines under test.
func idleTrack() -> AnimationTrack {
    makeTrack(name: "idle", row: 0, frames: UpstreamTable.idleFrames.map { ($0.index, $0.milliseconds) })
}

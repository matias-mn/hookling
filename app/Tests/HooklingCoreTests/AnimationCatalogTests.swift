import Foundation
import Testing
@testable import HooklingCore

@Suite("Animation catalog")
struct AnimationCatalogTests {

    @Test("the shipped animations.json loads and matches Codex's geometry")
    func loadsShippedCatalog() throws {
        let catalog = try TestAssets.catalog()
        #expect(catalog.geometry == .codexDefault)
        #expect(catalog.sheetFileName == "seedy-spritesheet-v4.webp")
        #expect(catalog.tracks.count == 9)
    }

    @Test("idle frames match Codex's idle_animation() exactly")
    func idleMatchesUpstream() throws {
        let catalog = try TestAssets.catalog()
        let idle = try #require(catalog.track(named: "idle"))

        #expect(idle.row == 0)
        #expect(idle.frames.count == UpstreamTable.idleFrames.count)
        for (actual, expected) in zip(idle.frames, UpstreamTable.idleFrames) {
            #expect(actual.spriteIndex == expected.index)
            #expect(actual.duration == nanoseconds(milliseconds: expected.milliseconds))
        }

        // 1680 + 660 + 660 + 840 + 840 + 1920 = 6600ms
        #expect(idle.frames.reduce(0) { $0 + $1.duration } == nanoseconds(milliseconds: 6600))
    }

    @Test("every track matches app_state_animation's output", arguments: UpstreamTable.tracks)
    func trackMatchesUpstream(expected: UpstreamTable.Track) throws {
        let catalog = try TestAssets.catalog()
        let track = try #require(catalog.track(named: expected.name), "missing track \(expected.name)")

        #expect(track.row == expected.row)
        #expect(track.frames.count == expected.frameCount)

        for (offset, frame) in track.frames.enumerated() {
            // sprite_index = row_index * DEFAULT_FRAME_COLUMNS + column_index
            #expect(frame.spriteIndex == expected.row * 8 + offset)

            // Every frame the same length except the last, which is held longer.
            let expectedMs = (offset == expected.frameCount - 1)
                ? expected.finalFrameMilliseconds
                : expected.frameMilliseconds
            #expect(frame.duration == nanoseconds(milliseconds: expectedMs))
        }
    }

    @Test("upstream's aliases resolve to the same track")
    func aliasesResolve() throws {
        let catalog = try TestAssets.catalog()
        for (alias, target) in UpstreamTable.aliases {
            let aliased = try #require(catalog.track(named: alias), "missing alias \(alias)")
            let canonical = try #require(catalog.track(named: target))
            #expect(aliased.frames == canonical.frames)
            #expect(aliased.name == canonical.name)
        }
    }

    @Test("every PetState resolves to a track that exists")
    func statesResolve() throws {
        let catalog = try TestAssets.catalog()
        for state in PetState.allCases {
            #expect(
                catalog.track(named: state.animationName) != nil,
                "state \(state.rawValue) wants missing animation \(state.animationName)"
            )
        }
    }

    @Test("unknown names fall back to idle rather than nothing")
    func unknownFallsBackToIdle() throws {
        let catalog = try TestAssets.catalog()
        #expect(catalog.animation(named: "does-not-exist", mode: .loopPrimary) == nil)
        let fallback = catalog.animationOrIdle(named: "does-not-exist", mode: .loopPrimary)
        #expect(fallback.name == "idle")
        #expect(!fallback.frames.isEmpty)
    }

    @Test("demo order walks the sheet top to bottom")
    func canonicalOrderFollowsRows() throws {
        let catalog = try TestAssets.catalog()
        let names = catalog.canonicalNames
        #expect(names.first == "idle")
        let rows = names.compactMap { catalog.track(named: $0)?.row }
        #expect(rows == rows.sorted())
        #expect(rows == Array(0...8))
    }

    // MARK: - Validation

    @Test("a sprite index off the end of the sheet is rejected")
    func rejectsOutOfRangeIndex() throws {
        let json = """
        {"sheet":{"frameWidth":192,"frameHeight":208,"columns":8,"rows":9},
         "animations":{"idle":{"frames":[{"index":72,"durationMs":100}]}}}
        """
        #expect(throws: AnimationCatalogError.spriteIndexOutOfRange(
            animation: "idle", index: 72, frameCount: 72
        )) {
            try AnimationCatalog.load(json: Data(json.utf8))
        }
    }

    @Test("an index that contradicts its declared row is rejected")
    func rejectsRowMismatch() throws {
        // Index 8 is on row 1, but the track claims row 3.
        let json = """
        {"sheet":{"frameWidth":192,"frameHeight":208,"columns":8,"rows":9},
         "animations":{"idle":{"frames":[{"index":0,"durationMs":100}]},
                       "oops":{"row":3,"frames":[{"index":8,"durationMs":100}]}}}
        """
        #expect(throws: AnimationCatalogError.rowMismatch(
            animation: "oops", index: 8, declaredRow: 3, actualRow: 1
        )) {
            try AnimationCatalog.load(json: Data(json.utf8))
        }
    }

    @Test("an empty frame list is rejected")
    func rejectsEmptyAnimation() throws {
        let json = """
        {"sheet":{"frameWidth":192,"frameHeight":208,"columns":8,"rows":9},
         "animations":{"idle":{"frames":[]}}}
        """
        #expect(throws: AnimationCatalogError.emptyAnimation("idle")) {
            try AnimationCatalog.load(json: Data(json.utf8))
        }
    }

    @Test("a missing idle animation is rejected")
    func requiresIdle() throws {
        let json = """
        {"sheet":{"frameWidth":192,"frameHeight":208,"columns":8,"rows":9},
         "animations":{"running":{"row":7,"frames":[{"index":56,"durationMs":100}]}}}
        """
        #expect(throws: AnimationCatalogError.missingIdleAnimation) {
            try AnimationCatalog.load(json: Data(json.utf8))
        }
    }

    @Test("a fallback naming a missing animation is rejected")
    func rejectsDanglingFallback() throws {
        let json = """
        {"sheet":{"frameWidth":192,"frameHeight":208,"columns":8,"rows":9},
         "animations":{"idle":{"frames":[{"index":0,"durationMs":100}]},
                       "wave":{"row":3,"frames":[{"index":24,"durationMs":100}],"fallback":"nope"}}}
        """
        #expect(throws: AnimationCatalogError.unknownFallback(animation: "wave", fallback: "nope")) {
            try AnimationCatalog.load(json: Data(json.utf8))
        }
    }

    @Test("an alias pointing nowhere is rejected")
    func rejectsDanglingAlias() throws {
        let json = """
        {"sheet":{"frameWidth":192,"frameHeight":208,"columns":8,"rows":9},
         "animations":{"idle":{"frames":[{"index":0,"durationMs":100}]}},
         "aliases":{"hi":"nope"}}
        """
        #expect(throws: AnimationCatalogError.unknownAliasTarget(alias: "hi", target: "nope")) {
            try AnimationCatalog.load(json: Data(json.utf8))
        }
    }

    @Test("garbage input is rejected rather than crashing")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            try AnimationCatalog.load(json: Data("not json at all".utf8))
        }
        #expect(throws: (any Error).self) {
            try AnimationCatalog.load(json: Data("[]".utf8))
        }
        #expect(throws: (any Error).self) {
            try AnimationCatalog.load(json: Data())
        }
    }
}

import Testing
@testable import HooklingCore

@Suite("Sprite geometry")
struct SpriteSheetTests {
    let geometry = SpriteGeometry.codexDefault

    @Test("Codex's built-in geometry")
    func codexGeometry() {
        #expect(geometry.frameWidth == 192)
        #expect(geometry.frameHeight == 208)
        #expect(geometry.columns == 8)
        #expect(geometry.rows == 9)
        #expect(geometry.frameCount == 72)
        #expect(geometry.sheetWidth == 1536)
        #expect(geometry.sheetHeight == 1872)
    }

    @Test("sprite index maps to a row-major rectangle")
    func rectForIndex() {
        // First frame.
        #expect(geometry.rect(forSpriteIndex: 0) == SpriteRect(x: 0, y: 0, width: 192, height: 208))
        // Last column of the first row.
        #expect(geometry.rect(forSpriteIndex: 7) == SpriteRect(x: 7 * 192, y: 0, width: 192, height: 208))
        // Wraps to the start of the second row.
        #expect(geometry.rect(forSpriteIndex: 8) == SpriteRect(x: 0, y: 208, width: 192, height: 208))
        // Arbitrary interior frame: column 7, row 7.
        #expect(geometry.rect(forSpriteIndex: 63) == SpriteRect(x: 7 * 192, y: 7 * 208, width: 192, height: 208))
        // Final frame: column 7, row 8.
        #expect(geometry.rect(forSpriteIndex: 71) == SpriteRect(x: 7 * 192, y: 8 * 208, width: 192, height: 208))
    }

    @Test("out-of-range indices clamp instead of trapping")
    func rectClamps() {
        #expect(geometry.rect(forSpriteIndex: -1) == geometry.rect(forSpriteIndex: 0))
        #expect(geometry.rect(forSpriteIndex: 72) == geometry.rect(forSpriteIndex: 71))
        #expect(geometry.rect(forSpriteIndex: 10_000) == geometry.rect(forSpriteIndex: 71))
        #expect(geometry.contains(spriteIndex: 71))
        #expect(!geometry.contains(spriteIndex: 72))
        #expect(!geometry.contains(spriteIndex: -1))
    }

    @Test("row lookup matches the animation table's rows")
    func rowForIndex() {
        #expect(geometry.row(forSpriteIndex: 0) == 0)
        #expect(geometry.row(forSpriteIndex: 7) == 0)
        #expect(geometry.row(forSpriteIndex: 8) == 1)
        #expect(geometry.row(forSpriteIndex: 56) == 7)
        #expect(geometry.row(forSpriteIndex: 64) == 8)
    }

    @Test("only an exactly-sized sheet is accepted")
    func validatesSheetSize() {
        #expect(geometry.accepts(imageWidth: 1536, imageHeight: 1872))
        #expect(!geometry.accepts(imageWidth: 1536, imageHeight: 1871))
        #expect(!geometry.accepts(imageWidth: 1535, imageHeight: 1872))
        // A 2x sheet is still wrong: silently downscaling would blur the pixel art.
        #expect(!geometry.accepts(imageWidth: 3072, imageHeight: 3744))
    }
}

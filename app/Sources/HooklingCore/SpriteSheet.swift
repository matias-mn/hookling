import Foundation

/// A rectangle in spritesheet pixel space, with the origin at the top-left.
///
/// Deliberately not a `CGRect`: `HooklingCore` stays free of graphics frameworks so
/// the geometry can be tested in isolation. The app layer converts.
public struct SpriteRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The frame grid of a pet spritesheet.
///
/// Mirrors the constants in Codex's `pets/catalog.rs` and the slicing arithmetic
/// in `pets/frames.rs`: frames are laid out **row-major**, so sprite index `i`
/// lives at column `i % columns`, row `i / columns`.
public struct SpriteGeometry: Equatable, Sendable {
    public let frameWidth: Int
    public let frameHeight: Int
    public let columns: Int
    public let rows: Int

    /// Codex's built-in pet geometry (`catalog.rs`): 192x208 frames in an 8x9
    /// grid, giving a 1536x1872 sheet with 72 frames.
    public static let codexDefault = SpriteGeometry(
        frameWidth: 192, frameHeight: 208, columns: 8, rows: 9
    )

    public init(frameWidth: Int, frameHeight: Int, columns: Int, rows: Int) {
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.columns = columns
        self.rows = rows
    }

    public var frameCount: Int { columns * rows }
    public var sheetWidth: Int { frameWidth * columns }
    public var sheetHeight: Int { frameHeight * rows }

    public func contains(spriteIndex: Int) -> Bool {
        spriteIndex >= 0 && spriteIndex < frameCount
    }

    /// The source rectangle for a sprite index.
    ///
    /// Out-of-range indices are clamped rather than trapping: a malformed
    /// animation file should show the wrong frame, not crash the pet. Callers
    /// that care about validity should use ``contains(spriteIndex:)`` — and
    /// ``AnimationCatalog`` rejects out-of-range indices at load time anyway.
    public func rect(forSpriteIndex spriteIndex: Int) -> SpriteRect {
        let clamped = min(max(spriteIndex, 0), frameCount - 1)
        let column = clamped % columns
        let row = clamped / columns
        return SpriteRect(
            x: column * frameWidth,
            y: row * frameHeight,
            width: frameWidth,
            height: frameHeight
        )
    }

    /// The row a sprite index falls on. Used to validate that the animation data
    /// agrees with the row it claims to come from.
    public func row(forSpriteIndex spriteIndex: Int) -> Int {
        spriteIndex / columns
    }

    /// Whether a decoded image can be used with this geometry.
    ///
    /// Codex applies the same check in `asset_pack.rs`
    /// (`validate_cached_spritesheet`) and treats a mismatch as "asset
    /// unavailable" rather than trying to adapt. So do we: a wrong-sized sheet
    /// fails loudly instead of rendering sliced garbage.
    public func accepts(imageWidth: Int, imageHeight: Int) -> Bool {
        imageWidth == sheetWidth && imageHeight == sheetHeight
    }
}

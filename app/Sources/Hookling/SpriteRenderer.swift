import AppKit
import ImageIO
import HooklingCore

enum SpriteRendererError: Error, CustomStringConvertible {
    case cannotDecode(URL)
    case wrongDimensions(URL, width: Int, height: Int, expectedWidth: Int, expectedHeight: Int)

    var description: String {
        switch self {
        case .cannotDecode(let url):
            return "Could not decode \(url.lastPathComponent) as an image."
        case .wrongDimensions(let url, let w, let h, let ew, let eh):
            return """
            \(url.lastPathComponent) is \(w)x\(h), but a pet spritesheet must be \
            exactly \(ew)x\(eh) — an 8 x 9 grid of 192x208 frames.
            """
        }
    }
}

/// Slices frames out of a single spritesheet image.
///
/// The whole sheet is decoded once; individual frames are `CGImage.cropping(to:)`
/// views over it, cached on first use. That is why there are no 72 PNG files on
/// disk: Codex writes them out (`pets/frames.rs`) only because terminal image
/// protocols need a file path per frame, which does not apply to a CALayer.
final class SpriteRenderer {
    let geometry: SpriteGeometry
    let sheetURL: URL
    let source: AssetLocator.Source

    private let sheet: CGImage
    private var frameCache: [Int: CGImage] = [:]

    /// Built on first hit test. `NSBitmapImageRep`'s pixel origin is documented as
    /// top-left, matching sprite coordinates, which avoids the usual Core Graphics
    /// row-order guessing game.
    private lazy var alphaRep: NSBitmapImageRep? = NSBitmapImageRep(cgImage: sheet)

    init(url: URL, source: AssetLocator.Source, geometry: SpriteGeometry) throws {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                imageSource, 0, [kCGImageSourceShouldCache: true] as CFDictionary
              )
        else {
            throw SpriteRendererError.cannotDecode(url)
        }

        // Same check Codex applies in asset_pack.rs before trusting a cached
        // sheet: a mismatch means "unusable", not "adapt to it". Silently scaling
        // would blur the pixel art, and silently re-slicing would show garbage.
        guard geometry.accepts(imageWidth: image.width, imageHeight: image.height) else {
            throw SpriteRendererError.wrongDimensions(
                url,
                width: image.width, height: image.height,
                expectedWidth: geometry.sheetWidth, expectedHeight: geometry.sheetHeight
            )
        }

        self.sheet = image
        self.sheetURL = url
        self.source = source
        self.geometry = geometry
    }

    /// The frame for a sprite index, cached.
    func image(forSpriteIndex index: Int) -> CGImage? {
        if let cached = frameCache[index] { return cached }
        let rect = geometry.rect(forSpriteIndex: index)
        guard let cropped = sheet.cropping(to: CGRect(
            x: rect.x, y: rect.y, width: rect.width, height: rect.height
        )) else { return nil }
        frameCache[index] = cropped
        return cropped
    }

    /// Whether a point inside a frame is visibly painted.
    ///
    /// `u` and `v` are normalised within the frame, with `v` measured from the
    /// top. Used so that clicks on Hookling's transparent surroundings do not grab
    /// him — see `PetView.hitTest`.
    func isVisible(spriteIndex: Int, u: CGFloat, v: CGFloat, threshold: CGFloat = 10.0 / 255.0) -> Bool {
        guard (0...1).contains(u), (0...1).contains(v) else { return false }
        guard let rep = alphaRep else { return true }   // fail open: stay draggable

        let rect = geometry.rect(forSpriteIndex: spriteIndex)
        let x = rect.x + min(Int(u * CGFloat(rect.width)), rect.width - 1)
        let y = rect.y + min(Int(v * CGFloat(rect.height)), rect.height - 1)

        guard let color = rep.colorAt(x: x, y: y) else { return true }
        return color.alphaComponent > threshold
    }
}

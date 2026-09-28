import AppKit
import HooklingCore

/// Generates a numbered diagnostic spritesheet.
///
/// Two reasons this exists rather than being a throwaway script:
///
/// 1. **Verification.** Every frame is labelled with its sprite index and row, so
///    you can watch `hooklingctl demo` and confirm by eye that, say, `waiting` really
///    is sprites 48-53 on row 6 — the mapping is checked visually, not just by
///    unit test.
/// 2. **Licensing.** It lets the whole pipeline — window, renderer, timing, demo,
///    hooks — be exercised end to end without any third-party artwork on the
///    machine. See `docs/licensing.md`.
///
/// The output has real transparency: each frame is a rounded blob on a clear
/// background, so click-through and the alpha hit test can be checked too.
enum TestSheet {

    static func write(to url: URL, geometry: SpriteGeometry = .codexDefault) throws {
        let width = geometry.sheetWidth
        let height = geometry.sheetHeight

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestSheetError.cannotCreateContext
        }

        // Fully transparent to start with: the gaps between blobs must have real
        // alpha 0 so the pet window stays click-through there.
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        for index in 0..<geometry.frameCount {
            let rect = geometry.rect(forSpriteIndex: index)
            // Core Graphics counts y upward; sprite rows count downward.
            let frame = CGRect(
                x: CGFloat(rect.x),
                y: CGFloat(height - rect.y - rect.height),
                width: CGFloat(rect.width),
                height: CGFloat(rect.height)
            )
            draw(index: index, row: rect.y / geometry.frameHeight, in: frame, geometry: geometry)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { throw TestSheetError.cannotCreateContext }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw TestSheetError.cannotEncodePNG
        }
        try data.write(to: url)
    }

    private static func draw(index: Int, row: Int, in frame: CGRect, geometry: SpriteGeometry) {
        // A distinct hue per row makes it obvious at a glance which row an
        // animation is playing from.
        let hue = CGFloat(row) / CGFloat(max(geometry.rows, 1))
        let fill = NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.85, alpha: 1.0)

        // Inset so neighbouring frames never touch: any bleed between frames shows
        // up immediately as a seam.
        let blob = frame.insetBy(dx: frame.width * 0.14, dy: frame.height * 0.14)
        let path = NSBezierPath(roundedRect: blob, xRadius: 18, yRadius: 18)
        fill.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 4
        path.stroke()

        // A marker in one corner, so a vertically flipped or mirrored render is
        // obvious rather than subtle.
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(ovalIn: CGRect(
            x: blob.minX + 12, y: blob.maxY - 30, width: 18, height: 18
        )).fill()

        let text = "\(index)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: blob.midX - size.width / 2, y: blob.midY - size.height / 2),
            withAttributes: attributes
        )

        let subtitle = "r\(row)" as NSString
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .medium),
            .foregroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
        let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
        subtitle.draw(
            at: NSPoint(x: blob.midX - subtitleSize.width / 2, y: blob.minY + 14),
            withAttributes: subtitleAttributes
        )
    }

    enum TestSheetError: Error, CustomStringConvertible {
        case cannotCreateContext
        case cannotEncodePNG

        var description: String {
            switch self {
            case .cannotCreateContext: return "could not create the bitmap context"
            case .cannotEncodePNG: return "could not encode the sheet as PNG"
            }
        }
    }
}

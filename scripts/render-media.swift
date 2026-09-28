// Render the README's demo media from a spritesheet, without recording the screen.
//
//   swift scripts/render-media.swift <spritesheet> <frames-dir> <states.png> "<credit>"
//
// Writes a numbered PNG sequence for the demo (turned into a GIF by
// scripts/render-media.sh) and a still grid of the states. Frames are cut
// straight from the sheet and played with the timings in assets/pet/animations.json,
// so what you see is exactly what the app draws, with nothing from your desktop
// behind it.
import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 5 else {
    FileHandle.standardError.write(Data("usage: render-media.swift <spritesheet> <frames-dir> <states.png> <credit>\n".utf8))
    exit(2)
}
let sheetPath = arguments[1]
let framesDirectory = URL(fileURLWithPath: arguments[2])
let statesPath = URL(fileURLWithPath: arguments[3])
let credit = arguments[4]

// MARK: - Inputs

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = try JSONSerialization.jsonObject(
    with: Data(contentsOf: repoRoot.appendingPathComponent("assets/pet/animations.json"))
) as! [String: Any]
let animations = catalog["animations"] as! [String: [String: Any]]

struct Frame { let index: Int; let durationMs: Int }
func frames(of animation: String) -> [Frame] {
    (animations[animation]!["frames"] as! [[String: Any]]).map {
        Frame(index: $0["index"] as! Int, durationMs: $0["durationMs"] as! Int)
    }
}

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: sheetPath) as CFURL, nil),
      let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
      sheet.width == 1536, sheet.height == 1872 else {
    FileHandle.standardError.write(Data("render-media: \(sheetPath) is not a 1536x1872 spritesheet\n".utf8))
    exit(1)
}
func sprite(_ index: Int) -> CGImage {
    sheet.cropping(to: CGRect(x: (index % 8) * 192, y: (index / 8) * 208, width: 192, height: 208))!
}

// MARK: - Drawing

let background = NSColor(red: 0.165, green: 0.173, blue: 0.2, alpha: 1)     // #2a2c33, light enough for a black pet
let panel = NSColor(red: 0.212, green: 0.22, blue: 0.255, alpha: 1)         // #363841
let primaryText = NSColor(white: 0.96, alpha: 1)
let secondaryText = NSColor(white: 0.66, alpha: 1)
let accent = NSColor(red: 0.98, green: 0.62, blue: 0.36, alpha: 1)

func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.interpolationQuality = .none   // pixel art: never smooth
    draw(context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func fill(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

/// Draws text centred horizontally on `x`, with its baseline area starting at `y`
/// (AppKit coordinates: origin bottom-left).
func text(_ string: String, centerX x: CGFloat, y: CGFloat, size: CGFloat,
          weight: NSFont.Weight, color: NSColor) {
    let attributed = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ])
    let bounds = attributed.size()
    attributed.draw(at: CGPoint(x: x - bounds.width / 2, y: y))
}

func textLeft(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
              weight: NSFont.Weight, color: NSColor) {
    NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]).draw(at: CGPoint(x: x, y: y))
}

func textRight(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor) {
    let attributed = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .regular),
        .foregroundColor: color,
    ])
    attributed.draw(at: CGPoint(x: x - attributed.size().width, y: y))
}

func save(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - The demo: one Claude Code turn, start to finish

struct Scene {
    let animation: String
    let label: String
    let caption: String
    let seconds: Double
}

let scenes = [
    Scene(animation: "waving", label: "Hello", caption: "You open a Claude Code session", seconds: 2.2),
    Scene(animation: "running", label: "Running", caption: "Claude is running tools", seconds: 3.0),
    Scene(animation: "waiting", label: "Needs input", caption: "Claude is waiting for your permission", seconds: 3.0),
    Scene(animation: "running", label: "Running", caption: "Back to work", seconds: 2.0),
    Scene(animation: "jumping", label: "Done", caption: "The turn finished", seconds: 2.2),
    Scene(animation: "review", label: "Ready", caption: "Your move: waiting for the next prompt", seconds: 2.6),
    Scene(animation: "idle", label: "Idle", caption: "Nothing happening, so it idles", seconds: 3.0),
]

let demoWidth = 560, demoHeight = 350
let fps = 25.0
try? FileManager.default.removeItem(at: framesDirectory)
try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)

var frameNumber = 0
for (sceneIndex, scene) in scenes.enumerated() {
    let track = frames(of: scene.animation)
    let cycleMs = track.reduce(0) { $0 + $1.durationMs }
    let tickCount = Int(scene.seconds * fps)
    for tick in 0..<tickCount {
        var elapsed = Int(Double(tick) * 1000 / fps) % cycleMs
        var current = track[0]
        for frame in track {
            if elapsed < frame.durationMs { current = frame; break }
            elapsed -= frame.durationMs
        }
        let rep = render(width: demoWidth, height: demoHeight) { context in
            fill(CGRect(x: 0, y: 0, width: demoWidth, height: demoHeight), background)
            let petRect = CGRect(x: (demoWidth - 192) / 2, y: 112, width: 192, height: 208)
            context.draw(sprite(current.index), in: petRect)

            fill(CGRect(x: 20, y: 28, width: demoWidth - 40, height: 74), panel, radius: 12)
            text(scene.label, centerX: CGFloat(demoWidth) / 2, y: 64, size: 20, weight: .semibold, color: accent)
            text(scene.caption, centerX: CGFloat(demoWidth) / 2, y: 40, size: 15, weight: .regular, color: primaryText)

            // Progress dots, one per scene, so the loop reads as a story.
            let dotSpacing: CGFloat = 14
            let dotsWidth = dotSpacing * CGFloat(scenes.count - 1)
            for dot in 0..<scenes.count {
                let x = CGFloat(demoWidth) / 2 - dotsWidth / 2 + CGFloat(dot) * dotSpacing
                fill(CGRect(x: x - 3, y: CGFloat(demoHeight) - 18, width: 6, height: 6),
                     dot == sceneIndex ? accent : NSColor(white: 0.35, alpha: 1), radius: 3)
            }
            textRight(credit, x: CGFloat(demoWidth) - 20, y: 8, size: 10, color: secondaryText)
        }
        try save(rep, to: framesDirectory.appendingPathComponent(String(format: "frame-%05d.png", frameNumber)))
        frameNumber += 1
    }
}

// MARK: - The still: every state at a glance

struct Tile { let animation: String; let frameOffset: Int; let label: String; let caption: String }
let tiles = [
    Tile(animation: "running", frameOffset: 2, label: "Running", caption: "Tools are running"),
    Tile(animation: "waiting", frameOffset: 3, label: "Needs input", caption: "A permission prompt"),
    Tile(animation: "jumping", frameOffset: 2, label: "Done", caption: "A turn just landed"),
    Tile(animation: "review", frameOffset: 2, label: "Ready", caption: "Waiting on your next move"),
    Tile(animation: "failed", frameOffset: 2, label: "Blocked", caption: "A turn ended in an error"),
    Tile(animation: "idle", frameOffset: 0, label: "Idle", caption: "Nothing happening"),
]
let columns = 3, tileWidth = 240, tileHeight = 300, gap = 16, margin = 24
let gridWidth = margin * 2 + columns * tileWidth + (columns - 1) * gap
let rows = (tiles.count + columns - 1) / columns
let gridHeight = margin * 2 + rows * tileHeight + (rows - 1) * gap + 20

let grid = render(width: gridWidth, height: gridHeight) { context in
    fill(CGRect(x: 0, y: 0, width: gridWidth, height: gridHeight), background)
    for (position, tile) in tiles.enumerated() {
        let column = position % columns, row = position / columns
        let x = margin + column * (tileWidth + gap)
        let y = gridHeight - margin - (row + 1) * tileHeight - row * gap
        fill(CGRect(x: x, y: y, width: tileWidth, height: tileHeight), panel, radius: 14)
        let track = frames(of: tile.animation)
        let frame = track[min(tile.frameOffset, track.count - 1)]
        context.draw(sprite(frame.index),
                     in: CGRect(x: x + (tileWidth - 192) / 2, y: y + 76, width: 192, height: 208))
        text(tile.label, centerX: CGFloat(x + tileWidth / 2), y: CGFloat(y + 42), size: 18, weight: .semibold, color: accent)
        text(tile.caption, centerX: CGFloat(x + tileWidth / 2), y: CGFloat(y + 18), size: 13, weight: .regular, color: primaryText)
    }
    textRight(credit, x: CGFloat(gridWidth - margin), y: 12, size: 11, color: secondaryText)
}
try save(grid, to: statesPath)

print("rendered \(frameNumber) demo frames and \(statesPath.lastPathComponent)")

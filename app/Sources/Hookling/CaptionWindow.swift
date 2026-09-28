import AppKit

/// A small label that appears under Hookling during the animation demo.
///
/// Kept as its own window so the pet's window stays exactly one sprite with
/// nothing else in it — no layout to get wrong, and no chance of the caption
/// affecting the pet's hit testing or transparency.
final class CaptionWindow: NSWindow {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 26),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        animationBehavior = .none

        let background = NSView(frame: .zero)
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        background.layer?.cornerRadius = 6
        background.layer?.cornerCurve = .continuous

        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        contentView = background
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show `text` centred just below `anchor` (the pet's window frame).
    func show(text: String, below anchor: NSRect) {
        label.stringValue = text
        let width = max(label.intrinsicContentSize.width + 24, 90)
        let size = NSSize(width: width, height: 26)
        setFrame(
            NSRect(
                x: anchor.midX - size.width / 2,
                y: anchor.minY - size.height - 6,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}

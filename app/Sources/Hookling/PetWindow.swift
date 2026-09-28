import AppKit

/// The transparent, chrome-less window Hookling lives in.
///
/// Two properties matter most and both are about *not* behaving like an app
/// window: it never becomes key or main, so changing animation can never steal
/// focus from the editor or terminal you are actually using; and it is fully
/// transparent, so the window server passes clicks on empty pixels through to
/// whatever is behind — a desktop pet, not a floating rectangle.
final class PetWindow: NSWindow {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Follow the user across Spaces and sit above full-screen apps, without
        // becoming part of any Space's window ordering.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // Not a document: no resize snapping, no window-menu entry, no tabbing.
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        tabbingMode = .disallowed
        ignoresMouseEvents = false
    }

    /// Refusing key and main status is what keeps the pet from stealing focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var isAlwaysOnTop: Bool = true {
        didSet { level = isAlwaysOnTop ? .floating : .normal }
    }

    /// Show without activating the app or taking focus.
    func present() {
        orderFrontRegardless()
    }

    /// Resize around the bottom-centre, so Hookling grows upward from his feet
    /// instead of drifting sideways when the scale changes.
    func setContentSize(keepingBottomCentre size: NSSize) {
        let old = frame
        let origin = NSPoint(
            x: old.midX - size.width / 2,
            y: old.minY
        )
        setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

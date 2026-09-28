import AppKit
import HooklingCore

/// Draws the current sprite, and handles dragging.
///
/// Rendering is a single `CALayer` whose `contents` is swapped per frame. Both
/// scaling filters are set to `nearest`, which is the whole ballgame for pixel
/// art: any interpolation turns crisp 192x208 artwork into mush.
final class PetView: NSView {

    /// Called when he is picked up, so a stroll in progress can be abandoned
    /// rather than fighting the cursor.
    var onDragBegan: (() -> Void)?

    /// Called when a drag finishes, so the position can be persisted.
    var onDragEnded: (() -> Void)?

    /// Called for a right-click or control-click, to show the menu.
    var onContextMenu: ((NSEvent) -> Void)?

    private let renderer: SpriteRenderer
    private var currentSpriteIndex: Int = 0
    private var dragOffset: NSPoint?

    /// Top-left origin, so view coordinates line up with sprite coordinates and
    /// the hit test needs no vertical flip.
    override var isFlipped: Bool { true }

    init(renderer: SpriteRenderer, frame: NSRect) {
        self.renderer = renderer
        super.init(frame: frame)

        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = .clear
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        // Nothing is ever drawn outside the frame, and disabling this keeps the
        // layer from allocating a mask.
        layer?.masksToBounds = false

        display(spriteIndex: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Rendering

    /// The sprite currently on screen. Read by `hooklingctl snapshot`, which writes
    /// exactly this frame rather than asking the state machine again — the answer
    /// is then what a person is actually looking at, not what they should be.
    var displayedSpriteIndex: Int { currentSpriteIndex }

    func display(spriteIndex: Int) {
        guard spriteIndex != currentSpriteIndex || layer?.contents == nil else { return }
        currentSpriteIndex = spriteIndex
        layer?.contents = renderer.image(forSpriteIndex: spriteIndex)
    }

    /// Keep the layer at the display's native pixel density, so 1x really is one
    /// sprite pixel per screen pixel and moving between monitors stays crisp.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    // MARK: - Mouse handling

    /// Only visibly painted pixels belong to Hookling.
    ///
    /// The window server already passes clicks through fully transparent regions
    /// of a non-opaque window. This adds the near-transparent ones, and — more
    /// noticeably — stops a click in the empty corner of his bounding box from
    /// starting a drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), bounds.width > 0, bounds.height > 0 else { return nil }

        let u = local.x / bounds.width
        let v = local.y / bounds.height     // already top-down: the view is flipped
        return renderer.isVisible(spriteIndex: currentSpriteIndex, u: u, v: v) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        // Remember where inside the sprite he was grabbed, so he does not jump to
        // centre himself under the cursor.
        dragOffset = event.locationInWindow
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let offset = dragOffset else { return }
        let mouseOnScreen = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: mouseOnScreen.x - offset.x,
            y: mouseOnScreen.y - offset.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOffset != nil else { return }
        dragOffset = nil
        onDragEnded?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }

    /// Control-click is the same gesture on a one-button mouse.
    override func otherMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onContextMenu?(event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Returning the menu here lets AppKit handle control-click and trackpad
        // secondary-click without us duplicating the gesture logic.
        menu
    }
}

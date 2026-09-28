import AppKit
import HooklingCore

/// What the menu needs to know and be able to do. Implemented by AppDelegate.
protocol MenuBarDelegate: AnyObject {
    var petState: PetState { get }
    var isPetVisible: Bool { get }
    var isPaused: Bool { get }
    var isAlwaysOnTop: Bool { get }
    var usesFaithfulLoops: Bool { get }
    var wandersWhenIdle: Bool { get }
    var currentScale: PetScale { get }
    var currentPace: PetPace { get }
    var assetSummary: String { get }
    var isLaunchAtLoginEnabled: Bool { get }

    func toggleVisibility()
    func togglePause()
    func toggleAlwaysOnTop()
    func toggleFaithfulLoops()
    func toggleWander()
    func toggleLaunchAtLogin()
    func setScale(_ scale: PetScale)
    func setPace(_ pace: PetPace)
    func resetPosition()
    func runDemo()
    func chooseSpritesheet()
    func showArtworkHelp()
    func quit()
}

/// The menu bar item and the context menu, which share one menu instance.
///
/// The icon is an SF Symbol rather than custom artwork: this app must not present
/// itself with anyone's logo, least of all OpenAI's or Anthropic's.
final class MenuBarController: NSObject {
    weak var delegate: (any MenuBarDelegate)?

    let menu = NSMenu()
    private var statusItem: NSStatusItem?

    private let stateItem = NSMenuItem(title: "Hookling", action: nil, keyEquivalent: "")
    private let assetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let visibilityItem = NSMenuItem(title: "Hide Hookling", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause reactions", action: nil, keyEquivalent: "")
    private let onTopItem = NSMenuItem(title: "Always on top", action: nil, keyEquivalent: "")
    private let faithfulItem = NSMenuItem(
        title: "Codex-faithful animation loops", action: nil, keyEquivalent: ""
    )
    private let wanderItem = NSMenuItem(title: "Wander when idle", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at login", action: nil, keyEquivalent: "")
    private var scaleItems: [PetScale: NSMenuItem] = [:]
    private var paceItems: [PetPace: NSMenuItem] = [:]

    override init() {
        super.init()
        menu.delegate = self
        buildMenu()
    }

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "pawprint.fill",
            accessibilityDescription: "Hookling"
        )
        item.button?.image?.isTemplate = true
        item.menu = menu
        statusItem = item
    }

    func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    /// Reflect the pet's state in the menu bar tooltip and header.
    func refreshStatus() {
        guard let delegate else { return }
        stateItem.title = "Hookling: \(delegate.petState.label)"
        statusItem?.button?.toolTip = "Hookling: \(delegate.petState.label)"
    }

    // MARK: - Building

    private func buildMenu() {
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        assetItem.isEnabled = false
        menu.addItem(assetItem)
        menu.addItem(.separator())

        add(visibilityItem, #selector(MenuBarController.toggleVisibility))
        add(pauseItem, #selector(MenuBarController.togglePause))
        menu.addItem(.separator())

        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for scale in PetScale.allCases {
            let item = NSMenuItem(
                title: scale.title,
                action: #selector(MenuBarController.setScale(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = scale.rawValue
            sizeMenu.addItem(item)
            scaleItems[scale] = item
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let paceItem = NSMenuItem(title: "Animation speed", action: nil, keyEquivalent: "")
        let paceMenu = NSMenu()
        for pace in PetPace.allCases {
            let item = NSMenuItem(
                title: pace.title,
                action: #selector(MenuBarController.setPace(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = pace.rawValue
            paceMenu.addItem(item)
            paceItems[pace] = item
        }
        paceItem.submenu = paceMenu
        paceItem.toolTip = """
        Stretches every frame. It changes how fast a loop runs, never how long \
        Hookling stays in a state or how many times a wave or a jump plays.
        """
        menu.addItem(paceItem)

        add(wanderItem, #selector(MenuBarController.toggleWander))
        wanderItem.toolTip = """
        When Claude is not doing anything, Hookling strolls about using the walk \
        cycles in the spritesheet. He stops the moment work starts, and turns \
        around at the edge of the screen he is on rather than crossing to another.
        """

        add(onTopItem, #selector(MenuBarController.toggleAlwaysOnTop))
        add(faithfulItem, #selector(MenuBarController.toggleFaithfulLoops))
        faithfulItem.toolTip = """
        Codex plays each action three times and then loops idle. Off (the default) \
        keeps the action looping for as long as Claude is actually in that state.
        """
        menu.addItem(.separator())

        add(
            NSMenuItem(title: "Reset position", action: nil, keyEquivalent: ""),
            #selector(MenuBarController.resetPosition)
        )
        add(
            NSMenuItem(title: "Run animation demo", action: nil, keyEquivalent: ""),
            #selector(MenuBarController.runDemo)
        )
        menu.addItem(.separator())

        add(
            NSMenuItem(title: "Choose pet artwork\u{2026}", action: nil, keyEquivalent: ""),
            #selector(MenuBarController.chooseSpritesheet)
        )
        add(
            NSMenuItem(title: "How to get pet artwork\u{2026}", action: nil, keyEquivalent: ""),
            #selector(MenuBarController.showArtworkHelp)
        )
        add(loginItem, #selector(MenuBarController.toggleLaunchAtLogin))
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Hookling", action: #selector(MenuBarController.quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func add(_ item: NSMenuItem, _ action: Selector) {
        item.action = action
        item.target = self
        menu.addItem(item)
    }

}

// MARK: - Actions

extension MenuBarController {
    @objc fileprivate func toggleVisibility() { delegate?.toggleVisibility() }
    @objc fileprivate func togglePause() { delegate?.togglePause() }
    @objc fileprivate func toggleAlwaysOnTop() { delegate?.toggleAlwaysOnTop() }
    @objc fileprivate func toggleFaithfulLoops() { delegate?.toggleFaithfulLoops() }
    @objc fileprivate func toggleWander() { delegate?.toggleWander() }
    @objc fileprivate func toggleLaunchAtLogin() { delegate?.toggleLaunchAtLogin() }
    @objc fileprivate func resetPosition() { delegate?.resetPosition() }
    @objc fileprivate func runDemo() { delegate?.runDemo() }
    @objc fileprivate func chooseSpritesheet() { delegate?.chooseSpritesheet() }
    @objc fileprivate func showArtworkHelp() { delegate?.showArtworkHelp() }
    @objc fileprivate func quit() { delegate?.quit() }

    @objc fileprivate func setScale(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let scale = PetScale(rawValue: raw)
        else { return }
        delegate?.setScale(scale)
    }

    @objc fileprivate func setPace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let pace = PetPace(rawValue: raw)
        else { return }
        delegate?.setPace(pace)
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    /// Refresh checkmarks and titles when the menu opens, so nothing has to be
    /// kept in sync as state changes elsewhere.
    func menuWillOpen(_ menu: NSMenu) {
        guard let delegate else { return }
        stateItem.title = "Hookling: \(delegate.petState.label)"
        assetItem.title = delegate.assetSummary
        visibilityItem.title = delegate.isPetVisible ? "Hide Hookling" : "Show Hookling"
        pauseItem.state = delegate.isPaused ? .on : .off
        onTopItem.state = delegate.isAlwaysOnTop ? .on : .off
        faithfulItem.state = delegate.usesFaithfulLoops ? .on : .off
        wanderItem.state = delegate.wandersWhenIdle ? .on : .off
        loginItem.state = delegate.isLaunchAtLoginEnabled ? .on : .off
        for (scale, item) in scaleItems {
            item.state = (scale == delegate.currentScale) ? .on : .off
        }
        for (pace, item) in paceItems {
            item.state = (pace == delegate.currentPace) ? .on : .off
        }
    }
}

import AppKit
import ImageIO
import ServiceManagement
import UniformTypeIdentifiers
import HooklingCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let menuBar = MenuBarController()
    private let captionWindow = CaptionWindow()

    private var controller: PetController?
    private var renderer: SpriteRenderer?
    private var window: PetWindow?
    private var petView: PetView?
    private var server: EventServer?
    private var frameTimer: Timer?

    private var assetProblem: String?
    private var demo: DemoRunner?

    /// How long each animation is shown by `hooklingctl demo`.
    private static let demoStepSeconds: TimeInterval = 2.5

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An accessory app: no Dock icon, no menu bar of its own, and it never
        // becomes the active application just because the pet moved.
        NSApp.setActivationPolicy(.accessory)

        menuBar.delegate = self
        menuBar.installStatusItem()

        loadCatalogAndRenderer()
        startServer()
        if let result = HookInstaller.installFromMainBundle() { log(result) }
        observeSystemChanges()

        if let controller {
            controller.isPaused = preferences.isPaused
            controller.faithfulLoops = preferences.faithfulLoops
            controller.timingScale = preferences.pace.durationScale
            controller.wanderEnabled = preferences.wander
            controller.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        if renderer != nil && !preferences.isHidden {
            showPet()
        }

        if assetProblem != nil && !preferences.hasLaunchedBefore {
            preferences.hasLaunchedBefore = true
            showArtworkHelp()
        }
        preferences.hasLaunchedBefore = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Wherever he wandered to is where he should reappear.
        savePosition()

        // Leave nothing behind: no timer, no listener, no socket file.
        frameTimer?.invalidate()
        frameTimer = nil
        server?.stop()
        server = nil
        menuBar.removeStatusItem()
    }

    /// Never quit just because the (only, invisible) window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Setup

    private func loadCatalogAndRenderer() {
        guard let animationsURL = CatalogLocator.animationsURL() else {
            assetProblem = """
            Could not find animations.json. Expected it in the app bundle or at \
            assets/pet/animations.json in the project checkout.
            """
            log(assetProblem!)
            return
        }

        let catalog: AnimationCatalog
        do {
            catalog = try AnimationCatalog.load(contentsOf: animationsURL)
        } catch {
            assetProblem = "animations.json is invalid: \(error)"
            log(assetProblem!)
            return
        }

        controller = PetController(catalog: catalog)

        guard let found = AssetLocator.spritesheet(
            named: catalog.sheetFileName,
            preferredPath: preferences.spritesheetPath
        ) else {
            assetProblem = """
            Seedy's artwork (\(catalog.sheetFileName)) is not on this machine yet. \
            It is OpenAI's and cannot be shipped with this app.
            """
            log(assetProblem!)
            return
        }

        do {
            renderer = try SpriteRenderer(
                url: found.url, source: found.source, geometry: catalog.geometry
            )
            assetProblem = nil
            log("spritesheet: \(found.url.path)  (via \(found.source.description))")
        } catch {
            assetProblem = "\(error)"
            log("spritesheet unusable: \(error)")
        }
    }

    private func startServer() {
        let path = HooklingSocket.resolvedPath()
        let server = EventServer(path: path) { [weak self] result in
            self?.handle(result) ?? nil
        }
        do {
            try server.start()
            self.server = server
            log("listening on \(path)")
        } catch {
            // A second pet, or an unusable path. Everything except the bridge
            // still works, so carry on rather than refusing to launch.
            log("could not listen on \(path): \(error)")
        }
    }

    private func observeSystemChanges() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func reduceMotionChanged() {
        controller?.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        scheduleNextFrame(after: 0)
    }

    /// A monitor was added, removed or rearranged: make sure Hookling is still
    /// somewhere visible.
    @objc private func screensChanged() {
        guard let window, window.isVisible else { return }
        window.setFrameOrigin(clampToVisibleScreen(window.frame))
        savePosition()
    }

    // MARK: - Pet window

    private func showPet() {
        guard let renderer, controller != nil else { return }

        let size = preferences.scale.size(for: renderer.geometry)
        let window = self.window ?? PetWindow(contentRect: NSRect(origin: .zero, size: size))
        self.window = window

        if petView == nil {
            let view = PetView(renderer: renderer, frame: NSRect(origin: .zero, size: size))
            view.autoresizingMask = [.width, .height]
            view.menu = menuBar.menu
            view.onDragBegan = { [weak self] in self?.controller?.suspendWander() }
            view.onDragEnded = { [weak self] in self?.savePosition() }
            view.onContextMenu = { [weak self] event in
                guard let self, let view = self.petView else { return }
                NSMenu.popUpContextMenu(self.menuBar.menu, with: event, for: view)
            }
            window.contentView = view
            petView = view
        }

        window.setContentSize(keepingBottomCentre: size)
        window.isAlwaysOnTop = preferences.alwaysOnTop
        window.setFrameOrigin(restoredOrigin(for: size))
        window.present()

        petView?.viewDidChangeBackingProperties()
        preferences.isHidden = false
        scheduleNextFrame(after: 0)
    }

    private func hidePet() {
        window?.orderOut(nil)
        captionWindow.dismiss()
        frameTimer?.invalidate()
        frameTimer = nil
        preferences.isHidden = true
    }

    /// Where to put Hookling at launch: his saved spot if it still exists, otherwise
    /// a sensible default near the bottom-right of the main screen.
    private func restoredOrigin(for size: CGSize) -> NSPoint {
        if let saved = preferences.savedPosition {
            let rect = NSRect(origin: saved.point, size: size)
            // Prefer the display he was on; accept any display that still
            // contains him; otherwise fall through to clamping.
            if let screen = screen(withDisplayID: saved.displayID),
               screen.frame.intersects(rect) {
                return clampToVisibleScreen(rect)
            }
            if NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) {
                return clampToVisibleScreen(rect)
            }
        }

        guard let screen = NSScreen.main else { return .zero }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
    }

    private func clampToVisibleScreen(_ rect: NSRect) -> NSPoint {
        let screens = NSScreen.screens
        let target = screens.max(by: {
            $0.frame.intersection(rect).area < $1.frame.intersection(rect).area
        }) ?? NSScreen.main

        guard let visible = target?.visibleFrame else { return rect.origin }
        // Keep at least a corner of him reachable, and never let him hide under
        // the menu bar or the Dock.
        return NSPoint(
            x: min(max(rect.minX, visible.minX), visible.maxX - rect.width),
            y: min(max(rect.minY, visible.minY), visible.maxY - rect.height)
        )
    }

    private func screen(withDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }

    private func savePosition() {
        guard let window, window.isVisible else { return }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let displayID = (window.screen?.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
        preferences.savedPosition = (window.frame.origin, CGDirectDisplayID(displayID))
    }

    // MARK: - The render loop

    /// One timer, re-armed for exactly as long as the current frame lasts.
    ///
    /// When the animation has nothing more to do — a sleeping pet, or "Reduce
    /// motion" — no timer is armed at all, so the process stops waking entirely
    /// rather than merely polling slowly.
    private func scheduleNextFrame(after delay: TimeInterval) {
        frameTimer?.invalidate()
        frameTimer = nil

        guard delay > 0 else {
            renderFrame()
            return
        }

        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.renderFrame()
        }
        // Let macOS coalesce our wakeup with others nearby: kinder to the battery
        // and invisible at these frame lengths.
        timer.tolerance = min(delay * 0.1, 0.05)
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func renderFrame() {
        guard let controller, let window, window.isVisible else { return }

        let tick = controller.tick()
        petView?.display(spriteIndex: tick.spriteIndex)
        applyWander(tick, to: window, controller: controller)
        menuBar.refreshStatus()
        demo?.frameRendered(caption: tick.animationName)

        if let delay = tick.delay {
            scheduleNextFrame(after: seconds(nanoseconds: delay))
        } else {
            // Nothing will change until an event arrives.
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    /// Move him along by however far the wander asked for, and tell the core when
    /// he has run out of desk.
    ///
    /// The core deliberately knows nothing about screens, so this is the only
    /// place the two meet: it clamps, and a clamp that actually bit means he has
    /// reached an edge and should turn around.
    private func applyWander(_ tick: PetTick, to window: PetWindow, controller: PetController) {
        if tick.movement != 0 {
            let frame = window.frame
            let desired = NSPoint(x: frame.minX + tick.movement, y: frame.minY)
            let clamped = clampToVisibleScreen(NSRect(origin: desired, size: frame.size))
            if abs(clamped.x - desired.x) > 0.5 { controller.wanderBlocked() }
            window.setFrameOrigin(clamped)
        }

        // Persist only when a stroll ends, not on every frame: he should reappear
        // where you last saw him without writing preferences 20 times a second.
        if tick.didFinishStroll { savePosition() }
    }

    // MARK: - Socket messages

    private func handle(_ result: Result<PetMessage, any Error>) -> String? {
        guard let controller else { return "hookling: not ready\n" }

        switch result {
        case .failure(let error):
            // Malformed or unknown: drop it and stay up. A future Claude Code
            // event name we do not map lands here and is harmless.
            log("ignored message: \(error)")
            return nil

        case .success(let message):
            let effect = controller.handle(message)

            // Any message can change what should be on screen, so re-render now
            // rather than waiting for a timer that may not be armed.
            if window?.isVisible == true { scheduleNextFrame(after: 0) }

            switch effect {
            case .runDemo:
                startDemo()
                return "hookling: running the animation demo\n"
            case .reportStatus:
                return statusReport()
            case .writeSnapshot:
                return writeSnapshot()
            case .quit:
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return "hookling: quitting\n"
            case nil:
                if case .command(.pause(let paused)) = message {
                    preferences.isPaused = paused
                }
                if case .command(.wander(let wandering)) = message {
                    preferences.wander = wandering
                }
                return nil
            }
        }
    }

    private func statusReport() -> String {
        guard let controller else { return "hookling: not ready\n" }
        var lines: [String] = []
        lines.append("state:      \(controller.state.rawValue)  (\(controller.state.label))")
        lines.append("animation:  \(controller.currentAnimationName)")
        lines.append("paused:     \(controller.isPaused)")
        lines.append("overridden: \(controller.isManuallyOverridden)")
        lines.append("loops:      \(controller.faithfulLoops ? "codex-faithful" : "continuous")")
        lines.append("visible:    \(window?.isVisible == true)")
        lines.append("scale:      \(preferences.scale.title)")
        lines.append("pace:       \(preferences.pace.title)")
        lines.append("wander:     \(controller.wanderEnabled ? "on" : "off")"
                     + (controller.isWandering ? "  (strolling)" : ""))
        if let renderer {
            lines.append("artwork:    \(renderer.sheetURL.path)")
            lines.append("            via \(renderer.source.description)")
        } else {
            lines.append("artwork:    MISSING - \(assetProblem ?? "unknown reason")")
        }
        lines.append("sessions:   \(controller.sessionCount)")
        for entry in controller.sessionSnapshot() {
            // Padded by hand: Foundation ignores the width in `%-10@`.
            let state = entry.state.rawValue
            let padded = state.count >= 10
                ? state
                : state + String(repeating: " ", count: 10 - state.count)
            lines.append("  \(entry.session)  \(padded)  "
                         + String(format: "%.1fs ago", entry.ageSeconds))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Snapshot

    /// Fixed destination, alongside the socket rather than in a fixed absolute
    /// path, so a second pet started with `HOOKLING_SOCKET` writes its own file
    /// instead of fighting the first one for this one.
    private var snapshotURL: URL {
        URL(fileURLWithPath: HooklingSocket.resolvedPath())
            .deletingLastPathComponent()
            .appendingPathComponent("snapshot.png")
    }

    /// Write the frame that is on screen right now to a PNG.
    ///
    /// Cut from the spritesheet rather than captured from the display, which
    /// matters more than it sounds: it needs no screen-recording permission, it
    /// cannot accidentally include whatever window is sitting on top of him, and
    /// it comes out at native sprite resolution however the window is scaled. The
    /// cost is that it proves the *rendering* is right, not that the window is
    /// really visible — `status` answers that.
    private func writeSnapshot() -> String {
        guard let renderer else {
            return "hookling: no artwork loaded - \(assetProblem ?? "unknown reason")\n"
        }
        guard let petView else {
            return "hookling: the pet has not been shown yet, so no frame is on screen\n"
        }

        let index = petView.displayedSpriteIndex
        guard let frame = renderer.image(forSpriteIndex: index) else {
            return "hookling: sprite \(index) is outside the spritesheet\n"
        }

        let url = snapshotURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            return "hookling: could not create \(url.deletingLastPathComponent().path): \(error)\n"
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            return "hookling: could not open \(url.path) for writing\n"
        }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else {
            return "hookling: could not encode \(url.path)\n"
        }

        let state = controller?.state.rawValue ?? "?"
        return "wrote \(frame.width)x\(frame.height) PNG of sprite \(index) (\(state)) "
             + "to \(url.path)\n"
    }

    // MARK: - Demo

    private func startDemo() {
        guard let controller, renderer != nil else { return }
        demo?.cancel()
        let runner = DemoRunner(
            names: controller.catalog.canonicalNames + controller.catalog.aliases.keys.sorted(),
            stepSeconds: Self.demoStepSeconds,
            onStep: { [weak self] name, index, total in
                guard let self else { return }
                self.controller?.preview(name, duration: nanoseconds(seconds: Self.demoStepSeconds))
                let track = self.controller?.catalog.track(named: name)
                let row = track.map { "row \($0.row)" } ?? "?"
                let indices = track?.frames.map { String($0.spriteIndex) }.joined(separator: ",") ?? "?"
                self.log("demo [\(index + 1)/\(total)] \(name)  \(row)  sprites \(indices)")
                if let frame = self.window?.frame {
                    self.captionWindow.show(text: "\(name)  ·  \(row)", below: frame)
                }
                self.scheduleNextFrame(after: 0)
            },
            onFinish: { [weak self] in
                self?.captionWindow.dismiss()
                self?.controller?.endPreview()
                self?.demo = nil
                self?.scheduleNextFrame(after: 0)
                self?.log("demo finished")
            }
        )
        demo = runner
        runner.start()
    }

    // MARK: - Logging

    /// Plain stdout, captured by `scripts/run.sh` into a log file. Never anything
    /// derived from a hook payload — see the privacy notes in the README.
    private func log(_ message: String) {
        FileHandle.standardOutput.write(Data("hookling: \(message)\n".utf8))
    }
}

// MARK: - MenuBarDelegate

extension AppDelegate: MenuBarDelegate {
    var petState: PetState { controller?.state ?? .idle }
    var isPetVisible: Bool { window?.isVisible == true }
    var isPaused: Bool { controller?.isPaused ?? false }
    var isAlwaysOnTop: Bool { preferences.alwaysOnTop }
    var usesFaithfulLoops: Bool { preferences.faithfulLoops }
    var wandersWhenIdle: Bool { preferences.wander }
    var currentScale: PetScale { preferences.scale }
    var currentPace: PetPace { preferences.pace }

    var assetSummary: String {
        if let renderer {
            return "Artwork: \(renderer.source.description)"
        }
        return "Artwork: not found"
    }

    var isLaunchAtLoginEnabled: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    func toggleVisibility() {
        if isPetVisible { hidePet() } else { showPet() }
    }

    func togglePause() {
        guard let controller else { return }
        controller.isPaused.toggle()
        preferences.isPaused = controller.isPaused
        scheduleNextFrame(after: 0)
    }

    func toggleAlwaysOnTop() {
        preferences.alwaysOnTop.toggle()
        window?.isAlwaysOnTop = preferences.alwaysOnTop
    }

    func toggleFaithfulLoops() {
        preferences.faithfulLoops.toggle()
        controller?.faithfulLoops = preferences.faithfulLoops
        scheduleNextFrame(after: 0)
    }

    func toggleWander() {
        preferences.wander.toggle()
        controller?.wanderEnabled = preferences.wander
        // Turning it off should stop him now, not at the end of the current
        // stroll; turning it on starts the clock on his first rest.
        controller?.suspendWander()
        scheduleNextFrame(after: 0)
    }

    func toggleLaunchAtLogin() {
        guard Bundle.main.bundleIdentifier != nil else {
            presentAlert(
                title: "Launch at login needs the app bundle",
                message: """
                Run ./scripts/build.sh to produce Hookling.app, then launch \
                that. Login items are registered per bundled application, so the \
                bare development binary cannot register one.
                """
            )
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            presentAlert(title: "Could not change the login item", message: "\(error)")
        }
    }

    func setScale(_ scale: PetScale) {
        guard let renderer else { return }
        preferences.scale = scale
        let size = scale.size(for: renderer.geometry)
        petView?.setFrameSize(size)
        window?.setContentSize(keepingBottomCentre: size)
        petView?.viewDidChangeBackingProperties()
        savePosition()
    }

    func setPace(_ pace: PetPace) {
        preferences.pace = pace
        controller?.timingScale = pace.durationScale
        scheduleNextFrame(after: 0)
    }

    func resetPosition() {
        guard let renderer else { return }
        preferences.savedPosition = nil
        window?.setFrameOrigin(restoredOrigin(for: preferences.scale.size(for: renderer.geometry)))
        savePosition()
    }

    func runDemo() {
        startDemo()
    }

    func chooseSpritesheet() {
        let panel = NSOpenPanel()
        panel.message = """
        Choose a pet spritesheet: an 8 x 9 grid of 192 x 208 frames \
        (1536 x 1872 in total).
        """
        panel.allowedContentTypes = [.webP, .png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        // The panel needs the app to be frontmost to be usable at all, which is
        // the one moment an accessory app legitimately activates.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        preferences.spritesheetPath = url.path
        reloadArtwork()
    }

    func showArtworkHelp() {
        let sheetName = controller?.catalog.sheetFileName ?? "seedy-spritesheet-v4.webp"
        presentAlert(
            title: "Seedy's artwork is not bundled with this app",
            message: """
            The Seedy spritesheet belongs to OpenAI and is not redistributable, so \
            this app never ships or downloads it by default. It looks for a copy \
            already on your Mac.

            The safest way to get one:

              1. Run  codex
              2. Type  /pets  and choose Seedy

            Codex then downloads \(sheetName) into its own cache, and it will \
            appear here the next time you launch Hookling.

            Alternatively, run  ./scripts/fetch-pet.sh  for the options, or use \
            "Choose pet artwork…" to point at any 1536 x 1872 sheet you already \
            have.

            See docs/licensing.md for the full reasoning.
            """
        )
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func reloadArtwork() {
        renderer = nil
        petView = nil
        window?.contentView = nil
        loadCatalogAndRenderer()
        if renderer != nil {
            showPet()
        } else {
            presentAlert(title: "That spritesheet cannot be used", message: assetProblem ?? "")
        }
    }

    private func presentAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

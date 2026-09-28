import Foundation

/// Walks every animation in turn so the sprite mapping can be checked by eye
/// against Codex.
///
/// Kept separate from the AppDelegate because it is a sequencer, not app state: it
/// owns one timer, hands each step back to a closure, and can be cancelled
/// cleanly if a second demo is started or the pet is hidden mid-run.
final class DemoRunner {
    private let names: [String]
    private let stepSeconds: TimeInterval
    private let onStep: (String, Int, Int) -> Void
    private let onFinish: () -> Void

    private var index = 0
    private var timer: Timer?

    init(
        names: [String],
        stepSeconds: TimeInterval,
        onStep: @escaping (String, Int, Int) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.names = names
        self.stepSeconds = stepSeconds
        self.onStep = onStep
        self.onFinish = onFinish
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard !names.isEmpty else {
            onFinish()
            return
        }
        index = 0
        advance()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// Called after each rendered frame. The demo does not need it, but having the
    /// hook keeps the caption in step if the window moves during a run.
    func frameRendered(caption: String) {}

    private func advance() {
        guard index < names.count else {
            cancel()
            onFinish()
            return
        }

        onStep(names[index], index, names.count)
        index += 1

        let timer = Timer(timeInterval: stepSeconds, repeats: false) { [weak self] _ in
            self?.advance()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

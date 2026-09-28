import AppKit
import HooklingCore

/// How large Hookling is drawn.
///
/// `x1` is 96x104 points, which on a 2x Retina display is exactly 192x208 device
/// pixels — one sprite pixel per screen pixel, the sharpest the artwork can
/// possibly look. The larger sizes are integer and half-integer multiples of that.
enum PetScale: String, CaseIterable {
    case x1
    case x1_5
    case x2

    var multiplier: CGFloat {
        switch self {
        case .x1: return 1.0
        case .x1_5: return 1.5
        case .x2: return 2.0
        }
    }

    var title: String {
        switch self {
        case .x1: return "1x  (96 x 104)"
        case .x1_5: return "1.5x  (144 x 156)"
        case .x2: return "2x  (192 x 208)"
        }
    }

    /// Base size: half the native sprite, so 1x is pixel-perfect on Retina.
    func size(for geometry: SpriteGeometry) -> CGSize {
        CGSize(
            width: CGFloat(geometry.frameWidth) / 2 * multiplier,
            height: CGFloat(geometry.frameHeight) / 2 * multiplier
        )
    }
}

/// How fast Hookling animates.
///
/// `normal` is Codex's exact frame table, which is tuned for a pet a few lines
/// tall in a terminal; on a desktop at 1x or larger the run cycle in particular
/// reads as frantic. The slower paces multiply every frame duration and change
/// nothing else — same artwork, same frames, same loop structure, and a state
/// still lasts exactly as long as Claude is really in it.
enum PetPace: String, CaseIterable {
    case normal
    case relaxed
    case slow
    case verySlow

    /// What every frame duration is multiplied by.
    var durationScale: Double {
        switch self {
        case .normal: return 1.0
        case .relaxed: return 1.25
        case .slow: return 1.5
        case .verySlow: return 2.0
        }
    }

    var title: String {
        switch self {
        case .normal: return "Normal  (Codex timing)"
        case .relaxed: return "Relaxed  (80% speed)"
        case .slow: return "Slow  (67% speed)"
        case .verySlow: return "Very slow  (50% speed)"
        }
    }
}

/// Persisted settings.
///
/// Stored in an explicit preferences domain rather than relying on the bundle
/// identifier, so the app behaves identically whether it is run as
/// `Hookling.app` or straight out of `.build/release` during development.
final class Preferences {
    static let domain = "dev.hookling"

    private let defaults: UserDefaults

    private enum Key {
        static let positionX = "positionX"
        static let positionY = "positionY"
        static let displayID = "displayID"
        static let scale = "scale"
        static let pace = "pace"
        static let alwaysOnTop = "alwaysOnTop"
        static let paused = "paused"
        static let hidden = "hidden"
        static let faithfulLoops = "faithfulLoops"
        static let wander = "wander"
        static let spritesheetPath = "spritesheetPath"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Preferences.domain) ?? .standard
        self.defaults.register(defaults: [
            Key.scale: PetScale.x1.rawValue,
            // Not Codex's timing: see PetPace. Upstream is one menu click away.
            Key.pace: PetPace.relaxed.rawValue,
            Key.alwaysOnTop: true,
            Key.paused: false,
            Key.hidden: false,
            Key.faithfulLoops: false,
            Key.wander: true,
        ])
    }

    // MARK: - Position

    /// Saved window origin, together with the display it was on.
    ///
    /// Both are needed: the point alone is meaningless if the monitor it referred
    /// to has been unplugged, and the display alone does not say where on it.
    var savedPosition: (point: CGPoint, displayID: CGDirectDisplayID)? {
        get {
            guard defaults.object(forKey: Key.positionX) != nil,
                  defaults.object(forKey: Key.positionY) != nil
            else { return nil }
            return (
                CGPoint(
                    x: defaults.double(forKey: Key.positionX),
                    y: defaults.double(forKey: Key.positionY)
                ),
                CGDirectDisplayID(defaults.integer(forKey: Key.displayID))
            )
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.positionX)
                defaults.removeObject(forKey: Key.positionY)
                defaults.removeObject(forKey: Key.displayID)
                return
            }
            defaults.set(newValue.point.x, forKey: Key.positionX)
            defaults.set(newValue.point.y, forKey: Key.positionY)
            defaults.set(Int(newValue.displayID), forKey: Key.displayID)
        }
    }

    // MARK: - Appearance and behaviour

    var scale: PetScale {
        get { PetScale(rawValue: defaults.string(forKey: Key.scale) ?? "") ?? .x1 }
        set { defaults.set(newValue.rawValue, forKey: Key.scale) }
    }

    var pace: PetPace {
        get { PetPace(rawValue: defaults.string(forKey: Key.pace) ?? "") ?? .relaxed }
        set { defaults.set(newValue.rawValue, forKey: Key.pace) }
    }

    var alwaysOnTop: Bool {
        get { defaults.bool(forKey: Key.alwaysOnTop) }
        set { defaults.set(newValue, forKey: Key.alwaysOnTop) }
    }

    var isPaused: Bool {
        get { defaults.bool(forKey: Key.paused) }
        set { defaults.set(newValue, forKey: Key.paused) }
    }

    var isHidden: Bool {
        get { defaults.bool(forKey: Key.hidden) }
        set { defaults.set(newValue, forKey: Key.hidden) }
    }

    var faithfulLoops: Bool {
        get { defaults.bool(forKey: Key.faithfulLoops) }
        set { defaults.set(newValue, forKey: Key.faithfulLoops) }
    }

    var wander: Bool {
        get { defaults.bool(forKey: Key.wander) }
        set { defaults.set(newValue, forKey: Key.wander) }
    }

    /// An explicit spritesheet chosen from the menu, which wins over discovery.
    var spritesheetPath: String? {
        get { defaults.string(forKey: Key.spritesheetPath) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.spritesheetPath) }
            else { defaults.removeObject(forKey: Key.spritesheetPath) }
        }
    }

    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Key.hasLaunchedBefore) }
    }
}

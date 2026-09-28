import Foundation

public enum AnimationCatalogError: Error, CustomStringConvertible, Equatable {
    case malformedJSON(String)
    case missingField(String)
    case emptyAnimation(String)
    case spriteIndexOutOfRange(animation: String, index: Int, frameCount: Int)
    case rowMismatch(animation: String, index: Int, declaredRow: Int, actualRow: Int)
    case unknownFallback(animation: String, fallback: String)
    case unknownAliasTarget(alias: String, target: String)
    case missingIdleAnimation

    public var description: String {
        switch self {
        case .malformedJSON(let detail):
            return "animations.json is not valid JSON: \(detail)"
        case .missingField(let path):
            return "animations.json is missing required field '\(path)'"
        case .emptyAnimation(let name):
            return "animation '\(name)' must include at least one frame"
        case .spriteIndexOutOfRange(let name, let index, let count):
            return "animation '\(name)' references sprite index \(index), but the sheet has \(count) frames"
        case .rowMismatch(let name, let index, let declared, let actual):
            return "animation '\(name)' declares row \(declared) but sprite index \(index) is on row \(actual)"
        case .unknownFallback(let name, let fallback):
            return "animation '\(name)' falls back to '\(fallback)', which does not exist"
        case .unknownAliasTarget(let alias, let target):
            return "alias '\(alias)' points at '\(target)', which does not exist"
        case .missingIdleAnimation:
            return "animations.json must define an 'idle' animation"
        }
    }
}

/// The animation data, loaded from `assets/pet/animations.json`.
///
/// Validation follows Codex's `pets/model.rs` (`normalize_animations` /
/// `validate_animation_indices`): every animation needs at least one frame,
/// every sprite index must exist on the sheet, and every fallback must name a
/// real animation. We add a row check, which catches data-entry mistakes in the
/// JSON that upstream cannot make because it computes indices from the row.
public struct AnimationCatalog: Sendable {
    public let geometry: SpriteGeometry
    public let sheetFileName: String
    public let tracks: [String: AnimationTrack]
    public let aliases: [String: String]

    public static let idleAnimationName = "idle"

    public init(
        geometry: SpriteGeometry,
        sheetFileName: String,
        tracks: [String: AnimationTrack],
        aliases: [String: String]
    ) {
        self.geometry = geometry
        self.sheetFileName = sheetFileName
        self.tracks = tracks
        self.aliases = aliases
    }

    /// Canonical track names, sorted by row so `hooklingctl demo` walks the sheet
    /// top to bottom — the same order you would read it in an image editor.
    public var canonicalNames: [String] {
        tracks.values
            .sorted { ($0.row, $0.name) < ($1.row, $1.name) }
            .map(\.name)
    }

    /// Every name that can be asked for, canonical first then aliases.
    public var allNames: [String] {
        canonicalNames + aliases.keys.sorted()
    }

    public var idleFrames: [AnimationFrame] {
        tracks[Self.idleAnimationName]?.frames ?? []
    }

    /// Resolve a name through the alias table.
    public func track(named name: String) -> AnimationTrack? {
        if let track = tracks[name] { return track }
        if let target = aliases[name] { return tracks[target] }
        return nil
    }

    /// Compose a playable animation. Returns `nil` for an unknown name.
    public func animation(named name: String, mode: PlaybackMode) -> Animation? {
        guard let track = track(named: name) else { return nil }
        return track.composed(mode: mode, idleFrames: idleFrames)
    }

    /// Compose an animation, falling back to idle for unknown names so a
    /// mis-typed state can never leave the renderer with nothing to draw.
    public func animationOrIdle(named name: String, mode: PlaybackMode) -> Animation {
        if let animation = animation(named: name, mode: mode) { return animation }
        return animation(named: Self.idleAnimationName, mode: .loopPrimary)
            ?? Animation(
                name: Self.idleAnimationName,
                frames: [AnimationFrame(spriteIndex: 0, milliseconds: 1000)],
                loopStart: 0,
                fallback: Self.idleAnimationName
            )
    }

    // MARK: - Loading

    public static func load(contentsOf url: URL) throws -> AnimationCatalog {
        try load(json: try Data(contentsOf: url))
    }

    public static func load(json data: Data) throws -> AnimationCatalog {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AnimationCatalogError.malformedJSON("top level is not an object")
            }
            root = object
        } catch let error as AnimationCatalogError {
            throw error
        } catch {
            throw AnimationCatalogError.malformedJSON(error.localizedDescription)
        }

        guard let sheet = root["sheet"] as? [String: Any] else {
            throw AnimationCatalogError.missingField("sheet")
        }
        guard let frameWidth = sheet["frameWidth"] as? Int else {
            throw AnimationCatalogError.missingField("sheet.frameWidth")
        }
        guard let frameHeight = sheet["frameHeight"] as? Int else {
            throw AnimationCatalogError.missingField("sheet.frameHeight")
        }
        guard let columns = sheet["columns"] as? Int else {
            throw AnimationCatalogError.missingField("sheet.columns")
        }
        guard let rows = sheet["rows"] as? Int else {
            throw AnimationCatalogError.missingField("sheet.rows")
        }
        let sheetFileName = sheet["file"] as? String ?? "seedy-spritesheet-v4.webp"

        let geometry = SpriteGeometry(
            frameWidth: frameWidth, frameHeight: frameHeight, columns: columns, rows: rows
        )

        guard let animationsObject = root["animations"] as? [String: Any] else {
            throw AnimationCatalogError.missingField("animations")
        }

        var tracks: [String: AnimationTrack] = [:]
        for (name, value) in animationsObject {
            guard let spec = value as? [String: Any] else {
                throw AnimationCatalogError.missingField("animations.\(name)")
            }
            guard let frameSpecs = spec["frames"] as? [[String: Any]], !frameSpecs.isEmpty else {
                throw AnimationCatalogError.emptyAnimation(name)
            }
            let declaredRow = spec["row"] as? Int

            var frames: [AnimationFrame] = []
            frames.reserveCapacity(frameSpecs.count)
            for frameSpec in frameSpecs {
                guard let index = frameSpec["index"] as? Int else {
                    throw AnimationCatalogError.missingField("animations.\(name).frames[].index")
                }
                guard let durationMs = frameSpec["durationMs"] as? Int else {
                    throw AnimationCatalogError.missingField("animations.\(name).frames[].durationMs")
                }
                guard geometry.contains(spriteIndex: index) else {
                    throw AnimationCatalogError.spriteIndexOutOfRange(
                        animation: name, index: index, frameCount: geometry.frameCount
                    )
                }
                if let declaredRow {
                    let actualRow = geometry.row(forSpriteIndex: index)
                    guard actualRow == declaredRow else {
                        throw AnimationCatalogError.rowMismatch(
                            animation: name, index: index,
                            declaredRow: declaredRow, actualRow: actualRow
                        )
                    }
                }
                frames.append(AnimationFrame(spriteIndex: index, milliseconds: durationMs))
            }

            tracks[name] = AnimationTrack(
                name: name,
                row: declaredRow ?? geometry.row(forSpriteIndex: frames[0].spriteIndex),
                frames: frames,
                loops: spec["loop"] as? Bool ?? true,
                fallback: (spec["fallback"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? idleAnimationName
            )
        }

        guard tracks[idleAnimationName] != nil else {
            throw AnimationCatalogError.missingIdleAnimation
        }

        for track in tracks.values where tracks[track.fallback] == nil {
            throw AnimationCatalogError.unknownFallback(
                animation: track.name, fallback: track.fallback
            )
        }

        var aliases: [String: String] = [:]
        if let aliasObject = root["aliases"] as? [String: String] {
            for (alias, target) in aliasObject {
                guard tracks[target] != nil else {
                    throw AnimationCatalogError.unknownAliasTarget(alias: alias, target: target)
                }
                aliases[alias] = target
            }
        }

        return AnimationCatalog(
            geometry: geometry,
            sheetFileName: sheetFileName,
            tracks: tracks,
            aliases: aliases
        )
    }
}

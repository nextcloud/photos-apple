// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosNetworking
import Synchronization

// MARK: - Looks: what Copy Edits and presets carry

extension EditRecipe {
    /// The look of the edit (SPEC §21.6.5): colour, tone, curves, colour mixer, masks, noise reduction, filter and RAW
    /// settings — without the crop, turns, straighten and mirror (they belong to one picture), the Live Photo effect and
    /// the original's description. What Copy Edits copies and a preset keeps.
    public var look: EditRecipe {
        var edits = self.edits.normalized
        edits.rotation = 0
        edits.straighten = 0
        edits.flipped = false
        edits.aspect = .original
        edits.aspectLocked = false
        edits.crop = nil
        return EditRecipe(edits: edits, raw: raw, updatedAt: updatedAt)
    }

    /// The look has something to copy.
    public var hasLook: Bool { !look.isIdentity }

    /// This edit with its look replaced by `look` (Paste Edits, a preset): the photo keeps its own crop, turns,
    /// straighten, mirror and Live Photo effect. RAW settings are taken over only by a photo developed from RAW.
    public func withLook(_ look: EditRecipe, developsRAW: Bool) -> EditRecipe {
        var result = self
        let geometry = edits
        result.edits = look.look.edits
        result.edits.rotation = geometry.rotation
        result.edits.straighten = geometry.straighten
        result.edits.flipped = geometry.flipped
        result.edits.aspect = geometry.aspect
        result.edits.aspectLocked = geometry.aspectLocked
        result.edits.crop = geometry.crop
        if developsRAW, let raw = look.raw { result.raw = raw }
        return result
    }
}

/// The look Copy Edits took, for Paste Edits on other photos (SPEC §21.6.5). One for the whole app, as in Photos.
public enum EditClipboard {
    private static let stored = Mutex<EditRecipe?>(nil)

    public static var look: EditRecipe? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue?.look } }
    }
}

// MARK: - Presets

/// A saved look (SPEC §21.6.5): built in, or made by the user from an edit and synced between their devices.
public struct EditPreset: Hashable, Sendable, Identifiable {
    public var id: String
    /// The user's name for it; built-in presets are named by the app (`EditPreset.BuiltIn`).
    public var name: String
    public var recipe: EditRecipe
    public var updatedAt: Date
    /// Removed (kept as a marker so the removal reaches the other devices).
    public var deleted = false

    public init(id: String = UUID().uuidString, name: String, recipe: EditRecipe, updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id
        self.name = name
        self.recipe = recipe.look
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    /// The presets the app comes with. Their names are shown in the user's language by the app (keyed by `id`).
    public enum BuiltIn: String, CaseIterable, Sendable {
        case vivid, warm, cool, matte, blackAndWhite, dramaticSky, portrait, night

        public var recipe: EditRecipe {
            var edits = PhotoEdits()
            switch self {
            case .vivid:
                edits.vibrance = 0.35
                edits.contrast = 1.06
                edits.curves.rgb = ToneCurve(points: [
                    .init(x: 0, y: 0), .init(x: 0.25, y: 0.22), .init(x: 0.75, y: 0.79), .init(x: 1, y: 1),
                ])
            case .warm:
                edits.warmth = 0.3
                edits.colorMixer[.orange] = ColorMixer.Adjustment(saturation: 0.12, luminance: 0.08)
                edits.colorMixer[.yellow] = ColorMixer.Adjustment(saturation: 0.1)
            case .cool:
                edits.warmth = -0.25
                edits.colorMixer[.blue] = ColorMixer.Adjustment(saturation: 0.15, luminance: -0.05)
                edits.colorMixer[.aqua] = ColorMixer.Adjustment(saturation: 0.1)
            case .matte:
                edits.saturation = 0.9
                edits.curves.rgb = ToneCurve(points: [.init(x: 0, y: 0.08), .init(x: 0.5, y: 0.5), .init(x: 1, y: 0.94)])
            case .blackAndWhite:
                edits.saturation = 0
                edits.contrast = 1.12
                edits.curves.rgb = ToneCurve(points: [
                    .init(x: 0, y: 0.02), .init(x: 0.3, y: 0.25), .init(x: 0.7, y: 0.76), .init(x: 1, y: 1),
                ])
            case .dramaticSky:
                var sky = MaskAdjustment(target: .sky)
                sky.exposure = -0.45
                sky.contrast = 1.15
                sky.saturation = 1.2
                edits.masks = [sky]
            case .portrait:
                var subject = MaskAdjustment(target: .subject)
                subject.exposure = 0.25
                subject.vibrance = 0.15
                var background = MaskAdjustment(target: .background)
                background.exposure = -0.2
                background.saturation = 0.85
                edits.masks = [subject, background]
            case .night:
                edits.noiseReduction = 0.45
                edits.colorNoiseReduction = 0.7
                edits.shadows = 0.25
                edits.highlights = 0.85
            }
            return EditRecipe(edits: edits, updatedAt: Date(timeIntervalSince1970: 0))
        }

        public var preset: EditPreset {
            EditPreset(id: "builtin.\(rawValue)", name: rawValue, recipe: recipe, updatedAt: Date(timeIntervalSince1970: 0))
        }
    }

    public var isBuiltIn: Bool { id.hasPrefix("builtin.") }
}

/// The file of the user's presets: `/.nextcloud-photos/edit-presets.json` (docs/EDIT-FORMAT.md).
struct EditPresetFile: Codable, Equatable {
    static let format = "nextcloud-photos-edit-presets"
    static let version = 1

    struct Preset: Codable, Equatable {
        var id: String
        var name: String?
        var updatedAt: Date
        var deleted: Bool?
        /// A recipe as an edit file has it (without geometry).
        var recipe: EditRecipe?
    }

    var format = Self.format
    var version = Self.version
    var presets: [Preset] = []

    init(_ presets: [EditPreset]) {
        self.presets = presets.map { preset in
            Preset(
                id: preset.id, name: preset.deleted ? nil : preset.name, updatedAt: preset.updatedAt, deleted: preset.deleted ? true : nil,
                recipe: preset.deleted ? nil : preset.recipe)
        }
    }

    var editPresets: [EditPreset] {
        presets.compactMap { preset in
            if preset.deleted == true {
                return EditPreset(id: preset.id, name: "", recipe: EditRecipe(), updatedAt: preset.updatedAt, deleted: true)
            }
            guard let name = preset.name, let recipe = preset.recipe else { return nil }
            return EditPreset(id: preset.id, name: name, recipe: recipe, updatedAt: preset.updatedAt)
        }
    }

    /// Dates with milliseconds: two devices changing a preset within the same second still tell which change was later.
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func decode(_ data: Data) -> [EditPreset]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? dateStyle.parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
        }
        guard let file = try? decoder.decode(EditPresetFile.self, from: data), file.format == format, file.version <= version else {
            return nil
        }
        return file.editPresets
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(EditPresetFile.dateStyle))
        }
        return try encoder.encode(self)
    }

    /// Now, to the millisecond the file keeps.
    static func now() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

/// The user's own presets (SPEC §21.6.5), kept on the device and in the user's Nextcloud
/// (`/.nextcloud-photos/edit-presets.json`), so a preset made on the Mac is there on the iPhone. Two devices that changed
/// presets at the same time are merged preset by preset: the later change of each wins, a removal included.
public actor EditPresetLibrary {
    public static let path = "/.nextcloud-photos/edit-presets.json"

    struct State: Codable {
        var presets: Data?
        var serverEtag: String?
        var pending = false
    }

    private let dav: DAVClient
    private let file: URL?
    private var presets: [EditPreset]
    private var serverEtag: String?
    private var pending: Bool
    private nonisolated let current = Mutex<[EditPreset]>([])
    /// When the presets were last compared with the server's.
    private var lastSync: Date?
    /// How often the library's sync also looks at the presets (the editor syncs them whenever it opens).
    static let syncInterval: TimeInterval = 15 * 60
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "edit-presets")

    public init(dav: DAVClient, file: URL?) {
        self.dav = dav
        self.file = file
        var loaded: [EditPreset] = []
        var etag: String?
        var pending = false
        if let file, let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(State.self, from: data) {
            loaded = state.presets.flatMap(EditPresetFile.decode) ?? []
            etag = state.serverEtag
            pending = state.pending
        }
        presets = loaded
        serverEtag = etag
        self.pending = pending
        current.withLock { $0 = loaded.filter { !$0.deleted } }
    }

    /// The user's presets, newest first.
    public nonisolated func userPresets() -> [EditPreset] {
        current.withLock { $0 }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Saves a preset (a new one, or one renamed or changed).
    public func save(_ preset: EditPreset) async {
        var preset = preset
        preset.updatedAt = EditPresetFile.now()
        presets.removeAll { $0.id == preset.id }
        presets.append(preset)
        changed()
        await sync()
    }

    public func delete(id: String) async {
        presets.removeAll { $0.id == id }
        presets.append(EditPreset(id: id, name: "", recipe: EditRecipe(), updatedAt: EditPresetFile.now(), deleted: true))
        changed()
        await sync()
    }

    /// Two lists of presets as one: for each preset the later change wins (a removal too).
    static func merge(_ local: [EditPreset], _ remote: [EditPreset]) -> [EditPreset] {
        var byId: [String: EditPreset] = [:]
        for preset in local + remote {
            if let known = byId[preset.id], known.updatedAt >= preset.updatedAt { continue }
            byId[preset.id] = preset
        }
        return byId.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Syncs unless that was done in the last `syncInterval` (and nothing waits to be sent): the library's sync runs
    /// every few minutes, presets change rarely.
    public func syncIfDue(now: Date = Date()) async {
        if !pending, let lastSync, now.timeIntervalSince(lastSync) < Self.syncInterval { return }
        await sync()
    }

    /// Sends local changes and takes over the other devices'. Errors leave everything for the next sync.
    public func sync() async {
        lastSync = Date()
        let url = dav.connection.filesURL(Self.path)
        do {
            for _ in 0..<3 {
                if pending {
                    let data = try EditPresetFile(presets).encoded()
                    let headers = serverEtag.map { ["If-Match": "\"\($0)\""] } ?? ["If-None-Match": "*"]
                    do {
                        let response = try await putCreatingFolder(url, data: data, headers: headers)
                        serverEtag = EditLibrary.etag(of: response)
                        pending = false
                        persist()
                        return
                    } catch NetworkError.preconditionFailed {
                        try await pull(url)
                        continue
                    }
                }
                let head = try await dav.propfind(url, depth: 0, properties: [DAVProp.etag])
                let etag = head.first?.string(DAVProp.etag).map(EditLibrary.unquoted)
                if etag != nil, etag == serverEtag { return }
                try await pull(url)
                if !pending { return }
            }
        } catch NetworkError.notFound {
            // No file yet: the first preset creates it.
            serverEtag = nil
            if pending, let data = try? EditPresetFile(presets).encoded() {
                if let response = try? await putCreatingFolder(url, data: data, headers: ["If-None-Match": "*"]) {
                    serverEtag = EditLibrary.etag(of: response)
                    pending = false
                }
            }
            persist()
        } catch {
            logger.error("presets not synced: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pull(_ url: URL) async throws {
        let response = try await dav.get(url)
        let remote = EditPresetFile.decode(response.data) ?? []
        let merged = Self.merge(presets, remote)
        // Something of this device's is not on the server yet: it goes out with the next PUT.
        pending =
            pending
            || Set(merged.map { "\($0.id)|\($0.updatedAt.timeIntervalSince1970)" })
                != Set(remote.map { "\($0.id)|\($0.updatedAt.timeIntervalSince1970)" })
        presets = merged
        serverEtag = EditLibrary.etag(of: response)
        current.withLock { $0 = merged.filter { !$0.deleted } }
        persist()
    }

    private func putCreatingFolder(_ url: URL, data: Data, headers: [String: String]) async throws -> HTTPResponse {
        let all = headers.merging(["Content-Type": "application/json"]) { $1 }
        do {
            return try await dav.put(url, data: data, headers: all)
        } catch NetworkError.conflict {
            try await dav.mkcolRecursive(userPath: (Self.path as NSString).deletingLastPathComponent)
        } catch NetworkError.notFound {
            try await dav.mkcolRecursive(userPath: (Self.path as NSString).deletingLastPathComponent)
        }
        return try await dav.put(url, data: data, headers: all)
    }

    private func changed() {
        pending = true
        current.withLock { $0 = presets.filter { !$0.deleted } }
        persist()
    }

    private func persist() {
        guard let file else { return }
        let state = State(presets: try? EditPresetFile(presets).encoded(), serverEtag: serverEtag, pending: pending)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("presets not stored: \(error.localizedDescription, privacy: .public)")
        }
    }
}

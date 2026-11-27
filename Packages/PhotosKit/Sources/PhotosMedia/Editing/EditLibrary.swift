// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosModel
import PhotosNetworking
import Synchronization

/// The edit recipes of one account (SPEC §16.3.1): kept on the device, synced with the user's Nextcloud.
///
/// Where they live on the server: one file per photo, `/.nextcloud-photos/edits/<fileId>.json` in the user's own files.
/// - Keyed by file id, not by name: a photo moved or renamed in the web, the Files app or the desktop client keeps its
///   file id, so its edit follows it. A copy is a new file without the edit.
/// - In a hidden folder: the web's Files app hides dot folders by default, the desktop client does not sync hidden files
///   by default, and the Photos web app only lists pictures and videos, so the recipes clutter nothing. Next to the
///   original (`IMG_1.edit.json`) they would show up in every folder and break with every move.
/// - A photo shared with the user is edited in the user's own folder: the edit is the user's view of it, nobody else's.
/// - Deleting a photo leaves its recipe: restoring the photo from the trash bin brings its edit back. Recipes of photos
///   that are gone are a few hundred bytes each.
///
/// Writes are ETag-safe: a recipe is replaced only with `If-Match` of the version this device knows (`If-None-Match: *`
/// for a new one). When another device changed it in the meantime (412), the newer of the two edits — by the time the
/// user made it — wins, and the server keeps the replaced one in its file versions. Reverting deletes the file the same
/// way. Changes made offline wait and go out with the next sync.
public actor EditLibrary {
    public static let folder = "/.nextcloud-photos/edits"

    struct Entry: Codable, Equatable {
        /// The recipe's file as this device has it (also one of a newer format, kept so it is not lost).
        var data: Data?
        /// ETag of the server's file this entry is based on; nil when the server has none.
        var serverEtag: String?
        var pending: Pending?
        /// Counted up with every local change: an upload finishing after another change does not mark the newer one sent.
        var generation = 0
    }

    enum Pending: Codable, Equatable {
        case upload
        /// Reverted to the original at that time.
        case delete(at: Date)
    }

    struct State: Codable {
        var entries: [FileID: Entry] = [:]
        /// ETag of the server's folder at the last pull; an unchanged folder needs no listing.
        var folderEtag: String?
    }

    private let dav: DAVClient
    private let file: URL?
    private var state: State
    /// The recipes every view applies, readable without waiting for the actor (the image pipeline asks for each tile).
    private nonisolated let current = Mutex<[FileID: EditRecipe]>([:])
    /// Told which photos' edits changed, after the change.
    private var observers: [UUID: @Sendable (Set<FileID>) -> Void] = [:]
    /// The sync that runs; another one waits for it.
    private var running: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "edits")
    /// The user's edit presets (SPEC §21.6.5), synced with the recipes.
    public nonisolated let presets: EditPresetLibrary

    /// - Parameter file: where the recipes are kept on the device; nil keeps them in memory (tests, previews).
    public init(dav: DAVClient, file: URL?) {
        self.dav = dav
        self.file = file
        presets = EditPresetLibrary(dav: dav, file: file?.deletingLastPathComponent().appending(path: "presets.json"))
        var loaded = State()
        if let file, let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(State.self, from: data) {
            loaded = decoded
        }
        state = loaded
        current.withLock { $0 = Self.effective(loaded.entries) }
    }

    // MARK: Reading

    /// The edit shown for a photo; nil for the original.
    public nonisolated func recipe(for fileId: FileID) -> EditRecipe? {
        current.withLock { $0[fileId] }
    }

    /// Every edited photo with its recipe.
    public nonisolated func all() -> [FileID: EditRecipe] {
        current.withLock { $0 }
    }

    /// The photo's recipe is of a newer format than this app reads: it is not applied, and saving replaces it.
    public func hasNewerFormat(_ fileId: FileID) -> Bool {
        guard let data = state.entries[fileId]?.data else { return false }
        do {
            _ = try EditRecipe.decode(data)
            return false
        } catch EditRecipe.Failure.newerFormat {
            return true
        } catch {
            return false
        }
    }

    /// Photos whose change has not reached the server yet.
    public func pendingCount() -> Int {
        state.entries.values.filter { $0.pending != nil }.count
    }

    @discardableResult
    public func observe(_ observer: @escaping @Sendable (Set<FileID>) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: Changing

    /// Saves an edit (replacing the photo's previous one); it is shown at once and sent to the server in the
    /// background. A recipe that changes nothing reverts the photo instead.
    public func save(_ recipe: EditRecipe, for fileId: FileID) {
        if recipe.isIdentity {
            revert(fileId, at: recipe.updatedAt)
            return
        }
        guard let data = try? recipe.encoded() else { return }
        var entry = state.entries[fileId] ?? Entry()
        entry.data = data
        entry.pending = .upload
        entry.generation += 1
        state.entries[fileId] = entry
        changed([fileId])
        scheduleSync()
    }

    /// Puts several photos back to given recipes at once (an undo of a rotate of many photos): nil reverts.
    public func restore(_ recipes: [FileID: EditRecipe?]) {
        let now = Date()
        for (fileId, recipe) in recipes {
            var entry = state.entries[fileId] ?? Entry()
            if var recipe, !recipe.isIdentity, let data = try? Self.stamped(&recipe, now).encoded() {
                entry.data = data
                entry.pending = .upload
            } else {
                guard entry.data != nil || entry.serverEtag != nil else { continue }
                entry.data = nil
                entry.pending = entry.serverEtag == nil ? nil : .delete(at: now)
            }
            entry.generation += 1
            state.entries[fileId] = entry
        }
        changed(Set(recipes.keys))
        scheduleSync()
    }

    private static func stamped(_ recipe: inout EditRecipe, _ date: Date) -> EditRecipe {
        recipe.updatedAt = date
        return recipe
    }

    /// Back to the original: the photo's recipe is removed here and on the server.
    public func revert(_ fileId: FileID, at date: Date = Date()) {
        guard var entry = state.entries[fileId], entry.data != nil || entry.serverEtag != nil else { return }
        entry.data = nil
        entry.pending = entry.serverEtag == nil ? nil : .delete(at: date)
        entry.generation += 1
        state.entries[fileId] = entry.pending == nil && entry.serverEtag == nil ? nil : entry
        changed([fileId])
        scheduleSync()
    }

    // MARK: Sync

    /// Sends what changed here, then takes over what changed on the server. Called after every library sync; errors
    /// leave everything as it is for the next one.
    public func sync() async {
        await sync(pullFirst: true)
        await presets.syncIfDue()
    }

    /// Sends local changes without waiting for the server.
    private func scheduleSync() {
        Task { await self.sync(pullFirst: false) }
    }

    private func sync(pullFirst: Bool) async {
        let previous = running
        let task = Task {
            await previous?.value
            await self.push()
            if pullFirst { await self.pull() }
        }
        running = task
        await task.value
    }

    /// Waits until the changes made so far have been sent (or failed to be).
    public func waitUntilIdle() async {
        await sync(pullFirst: false)
    }

    private func push() async {
        for fileId in state.entries.filter({ $0.value.pending != nil }).keys.sorted() {
            do {
                try await push(fileId)
            } catch {
                // Offline or the server refused: the change stays pending.
                logger.error("edit \(fileId) not sent: \(error.localizedDescription, privacy: .public)")
                if case NetworkError.offline = error { return }
            }
        }
        persist()
    }

    private func url(_ fileId: FileID) -> URL {
        dav.connection.filesURL("\(Self.folder)/\(fileId).json")
    }

    private func push(_ fileId: FileID) async throws {
        // A few rounds at most: each one sees a newer version on the server (or a newer change here) and decides again.
        for _ in 0..<4 {
            guard let entry = state.entries[fileId], let pending = entry.pending else { return }
            let generation = entry.generation
            switch pending {
            case .upload:
                guard let data = entry.data else {
                    state.entries[fileId]?.pending = nil
                    return
                }
                do {
                    let response = try await put(data, fileId: fileId, over: entry.serverEtag)
                    var etag = Self.etag(of: response)
                    if etag == nil { etag = try? await remoteEtag(fileId) }
                    finished(fileId, generation: generation, serverEtag: etag, keepData: true)
                } catch NetworkError.preconditionFailed {
                    // Changed (or reverted) elsewhere since this device saw it.
                    try await resolveConflict(fileId, localDate: Self.date(of: data))
                }
            case .delete(let date):
                guard let etag = entry.serverEtag else {
                    finished(fileId, generation: generation, serverEtag: nil, keepData: false)
                    continue
                }
                do {
                    try await dav.delete(url(fileId), ifMatch: etag)
                    finished(fileId, generation: generation, serverEtag: nil, keepData: false)
                } catch NetworkError.notFound {
                    finished(fileId, generation: generation, serverEtag: nil, keepData: false)
                } catch NetworkError.preconditionFailed {
                    try await resolveConflict(fileId, localDate: date)
                }
            }
        }
    }

    /// PUT with `If-Match` (or `If-None-Match: *` for a new recipe); the folder is created when it is missing.
    private func put(_ data: Data, fileId: FileID, over etag: String?) async throws -> HTTPResponse {
        let headers = etag.map { ["If-Match": "\"\($0)\""] } ?? ["If-None-Match": "*"]
        do {
            return try await dav.put(url(fileId), data: data, headers: headers.merging(["Content-Type": "application/json"]) { $1 })
        } catch NetworkError.conflict where etag == nil {
            try await dav.mkcolRecursive(userPath: Self.folder)
        } catch NetworkError.notFound where etag == nil {
            try await dav.mkcolRecursive(userPath: Self.folder)
        }
        return try await dav.put(url(fileId), data: data, headers: headers.merging(["Content-Type": "application/json"]) { $1 })
    }

    /// The server has another version than the one this device's change is based on. The change made later wins: the
    /// server's when it is newer (this device's change is dropped and the server's shown), else this device's, which is
    /// then sent over the server's version (its ETag is known now).
    private func resolveConflict(_ fileId: FileID, localDate: Date) async throws {
        guard var entry = state.entries[fileId] else { return }
        let remote: (data: Data, etag: String?)?
        do {
            let response = try await dav.get(url(fileId))
            remote = (response.data, Self.etag(of: response))
        } catch NetworkError.notFound {
            remote = nil
        }
        guard let remote else {
            // Reverted elsewhere. This device's change is newer than anything it knew of: it is sent as a new recipe
            // (a revert is done already).
            entry.serverEtag = nil
            if case .delete = entry.pending { entry.pending = nil }
            state.entries[fileId] = entry.data == nil && entry.pending == nil ? nil : entry
            return
        }
        let remoteDate = Self.date(of: remote.data)
        if remoteDate > localDate {
            logger.notice("edit \(fileId): a newer edit from another device wins")
            state.entries[fileId] = Entry(data: remote.data, serverEtag: remote.etag, pending: nil, generation: entry.generation + 1)
            changed([fileId])
        } else {
            entry.serverEtag = remote.etag
            state.entries[fileId] = entry
        }
    }

    /// The change of `generation` reached the server.
    private func finished(_ fileId: FileID, generation: Int, serverEtag: String?, keepData: Bool) {
        guard var entry = state.entries[fileId] else { return }
        entry.serverEtag = serverEtag
        // Changed again while the request ran: that change stays pending, now based on what the server has.
        if entry.generation == generation {
            entry.pending = nil
            if !keepData { entry.data = nil }
        }
        state.entries[fileId] = entry.data == nil && entry.pending == nil && entry.serverEtag == nil ? nil : entry
    }

    /// Takes over the recipes other devices saved, changed or removed.
    private func pull() async {
        do {
            let folder = try await dav.propfind(dav.connection.filesURL(Self.folder), depth: 0, properties: [DAVProp.etag])
            let folderEtag = folder.first?.string(DAVProp.etag).map(Self.unquoted)
            if folderEtag != nil, folderEtag == state.folderEtag { return }
            let listing = try await dav.propfind(
                dav.connection.filesURL(Self.folder), depth: 1, properties: [DAVProp.etag, DAVProp.resourceType])
            var remote: [FileID: String] = [:]
            for resource in listing where !resource.isCollection {
                let name = (resource.href as NSString).lastPathComponent
                guard name.hasSuffix(".json"), let fileId = FileID(name.dropLast(5)),
                    let etag = resource.string(DAVProp.etag).map(Self.unquoted)
                else { continue }
                remote[fileId] = etag
            }
            try await apply(remote: remote)
            state.folderEtag = folderEtag
        } catch NetworkError.notFound {
            // No folder: no recipes on the server (none saved yet, or the folder was deleted).
            try? await apply(remote: [:])
            state.folderEtag = nil
        } catch {
            logger.error("edits not synced: \(error.localizedDescription, privacy: .public)")
        }
        persist()
    }

    private func apply(remote: [FileID: String]) async throws {
        var changedIds: Set<FileID> = []
        // Gone from the server: reverted on another device (pending local changes are left to `push`).
        for (fileId, entry) in state.entries where entry.pending == nil && remote[fileId] == nil {
            state.entries[fileId] = nil
            if entry.data != nil { changedIds.insert(fileId) }
        }
        for (fileId, etag) in remote where state.entries[fileId]?.serverEtag != etag {
            if let entry = state.entries[fileId], entry.pending != nil { continue }
            let response = try await dav.get(url(fileId))
            state.entries[fileId] = Entry(
                data: response.data, serverEtag: Self.etag(of: response) ?? etag, pending: nil,
                generation: (state.entries[fileId]?.generation ?? 0) + 1)
            changedIds.insert(fileId)
        }
        if !changedIds.isEmpty { changed(changedIds) }
    }

    private func remoteEtag(_ fileId: FileID) async throws -> String? {
        try await dav.propfind(url(fileId), depth: 0, properties: [DAVProp.etag]).first?.string(DAVProp.etag).map(Self.unquoted)
    }

    // MARK: Helpers

    private func changed(_ ids: Set<FileID>) {
        let effective = Self.effective(state.entries)
        current.withLock { $0 = effective }
        persist()
        for observer in observers.values { observer(ids) }
    }

    private func persist() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("edits not stored: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func effective(_ entries: [FileID: Entry]) -> [FileID: EditRecipe] {
        var result: [FileID: EditRecipe] = [:]
        for (fileId, entry) in entries {
            guard let data = entry.data, let recipe = try? EditRecipe.decode(data), !recipe.isIdentity else { continue }
            result[fileId] = recipe
        }
        return result
    }

    /// When the user made the edit in `data`; the distant past for a file that is not a readable recipe.
    static func date(of data: Data) -> Date {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct Stamp: Decodable { var updatedAt: Date? }
        return ((try? decoder.decode(Stamp.self, from: data))?.updatedAt) ?? .distantPast
    }

    static func etag(of response: HTTPResponse) -> String? {
        (response.header("oc-etag") ?? response.header("etag")).map(unquoted)
    }

    static func unquoted(_ etag: String) -> String {
        var value = etag
        if value.hasPrefix("W/") { value.removeFirst(2) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

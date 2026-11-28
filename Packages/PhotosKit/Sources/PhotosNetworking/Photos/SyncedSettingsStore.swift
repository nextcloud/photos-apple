// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Synchronization

/// One kind of settings shared by the user's devices (SPEC §22.5), kept on the device and in the user's Nextcloud as
/// `/.nextcloud-photos/<kind>.json` (`SyncedSettingsDocument`).
///
/// - A change is shown at once (`value`, readable without waiting for the actor) and sent in the background; offline
///   changes wait for the next `sync()`.
/// - Writes name the version they replace (`If-Match`, `If-None-Match: *` for a new file); when another device wrote in
///   between, the store reads again, merges key by key (last writer wins, nothing typed is lost) and retries.
/// - `sync()` costs one `PROPFIND` (depth 0) when nothing changed on either side; the file is read only when its ETag
///   changed.
/// - Observers hear which keys changed, from this device or another one.
///
/// Who uses which kind (§22.5): `settings` (app settings that follow the user, `SyncedDefaults`), `people` (on-device
/// People names and assignments, §22.3), `family` (family library options and decisions, §16.7.2).
public actor SyncedSettingsStore {
    /// A kind of settings: the file's name without `.json`.
    public struct Kind: RawRepresentable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// App settings that follow the user from device to device.
        public static let settings = Kind(rawValue: "settings")
        /// On-device People: names, merges, assignments (§22.3, written by the people feature).
        public static let people = Kind(rawValue: "people")
        /// The family library: options and the decisions about suggested photos (§16.7.2).
        public static let family = Kind(rawValue: "family")

        public var fileName: String { "\(rawValue).json" }
    }

    struct State: Codable {
        var document: Data?
        var serverEtag: String?
        var pending = false
    }

    public let kind: Kind
    private let files: AppDataFiles
    private let localFile: URL?
    private var document: SyncedSettingsDocument
    private var serverEtag: String?
    private var pending: Bool
    private nonisolated let current: Mutex<SyncedSettingsDocument>
    private var observers: [UUID: @Sendable (Set<String>) -> Void] = [:]
    /// The sync that runs; another one waits for it.
    private var running: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "synced-settings")
    /// How long a change waits before it is sent, so a slider or a burst of changes goes out as one write.
    let sendDelay: Duration

    /// - Parameter localFile: where the copy on the device is kept; nil keeps it in memory (tests, previews).
    public init(files: AppDataFiles, kind: Kind, localFile: URL?, sendDelay: Duration = .seconds(2)) {
        self.files = files
        self.kind = kind
        self.localFile = localFile
        self.sendDelay = sendDelay
        var loaded = SyncedSettingsDocument(kind: kind.rawValue)
        var etag: String?
        var pending = false
        if let localFile, let data = try? Data(contentsOf: localFile), let state = try? JSONDecoder().decode(State.self, from: data) {
            loaded = state.document.flatMap(SyncedSettingsDocument.decoded) ?? loaded
            etag = state.serverEtag
            pending = state.pending
        }
        loaded.kind = kind.rawValue
        document = loaded
        serverEtag = etag
        self.pending = pending
        current = Mutex(loaded)
    }

    // MARK: Reading (without waiting)

    /// The whole document as this device has it.
    public nonisolated func snapshot() -> SyncedSettingsDocument { current.withLock { $0 } }

    public nonisolated func value(_ key: String) -> JSONValue? { snapshot().value(key) }

    public nonisolated func value<T: Decodable>(_ key: String, as type: T.Type) -> T? { snapshot().value(key, as: type) }

    /// Live values by key, optionally only those whose key starts with `prefix`.
    public nonisolated func values(prefix: String = "") -> [String: JSONValue] { snapshot().values(prefix: prefix) }

    /// Values of a key that lost against another device's change made at the same time (newest first).
    public nonisolated func replacedValues(_ key: String) -> [JSONValue] { snapshot().entries[key]?.replaced ?? [] }

    /// Whether changes made here have not reached the server yet.
    public func hasPendingChanges() -> Bool { pending }

    // MARK: Changing

    /// Sets (nil removes) one key; sent to the server shortly.
    public func set(_ value: JSONValue?, for key: String, now: Date = Date()) {
        set([key: value], now: now)
    }

    /// Sets an encodable value.
    public func set<T: Encodable & Sendable>(encoding value: T, for key: String, now: Date = Date()) {
        var copy = document
        guard copy.set(encoding: value, for: key, now: now) else { return }
        apply(copy, changed: [key], local: true)
    }

    /// Sets (nil removes) several keys in one change.
    public func set(_ values: [String: JSONValue?], now: Date = Date()) {
        var copy = document
        var changed: Set<String> = []
        for (key, value) in values where copy.set(value, for: key, now: now) { changed.insert(key) }
        guard !changed.isEmpty else { return }
        apply(copy, changed: changed, local: true)
    }

    /// Takes over entries that were changed elsewhere on this device (another account's copy of the app settings): merged
    /// key by key, sent with the next sync. Returns the keys whose value changed here.
    @discardableResult
    public func merge(_ other: SyncedSettingsDocument, now: Date = Date()) -> Set<String> {
        let merged = document.merged(with: other, now: now)
        guard merged != document else { return [] }
        let changed = Self.changedKeys(document, merged)
        apply(merged, changed: changed, local: true)
        return changed
    }

    @discardableResult
    public func observe(_ observer: @escaping @Sendable (Set<String>) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    // MARK: Sync

    /// Sends what changed here and takes over what other devices changed. Errors leave everything for the next sync.
    /// Returns the keys whose value changed on this device through the sync.
    @discardableResult
    public func sync() async -> Set<String> {
        await sync(listing: nil)
    }

    /// - Parameter listing: the server file's ETag from a listing of the folder made just before (`.some(nil)`: the file
    ///   is not there), which saves the store its own look.
    @discardableResult
    func sync(listing: String??) async -> Set<String> {
        let previous = running
        let before = document
        let task = Task {
            await previous?.value
            await self.performSync(listing: listing)
        }
        running = task
        await task.value
        return Self.changedKeys(before, document)
    }

    /// Waits until changes made so far have been sent (or failed to be).
    public func waitUntilIdle() async {
        scheduled?.cancel()
        scheduled = nil
        if pending { await sync() } else { await running?.value }
    }

    private func performSync(listing: String??) async {
        do {
            if !pending {
                let remote: String?
                if let listing { remote = listing } else { remote = try await remoteEtag() }
                // Unchanged on the server, or nothing on either side.
                if remote == serverEtag && (remote != nil || document.entries.isEmpty) { return }
            }
            let local = document
            let written = try await files.update(kind.fileName) { content in
                if content == nil && local.entries.isEmpty { return nil }
                var server = content.flatMap { SyncedSettingsDocument.decoded($0.data) } ?? SyncedSettingsDocument(kind: local.kind)
                // A file of a newer version is read (keys this version knows) but never written over.
                if server.version > SyncedSettingsDocument.currentVersion { return nil }
                server.kind = local.kind
                let merged = server.merged(with: local)
                if content != nil && merged == server { return nil }
                return try merged.encoded()
            }
            let remote = written.flatMap { SyncedSettingsDocument.decoded($0.data) } ?? SyncedSettingsDocument(kind: kind.rawValue)
            // Changes made here while the request ran stay pending.
            let merged = document.merged(with: remote)
            let stillPending = merged.entries != remote.entries
            serverEtag = written?.etag
            pending = stillPending
            let changed = Self.changedKeys(document, merged)
            if merged != document || !changed.isEmpty {
                apply(merged, changed: changed, local: false)
            } else {
                persist()
            }
        } catch {
            logger.error("\(self.kind.rawValue, privacy: .public) not synced: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func remoteEtag() async throws -> String? {
        do {
            let url = files.dav.connection.filesURL(AppDataFiles.path(kind.fileName))
            return try await files.dav.propfind(url, depth: 0, properties: [DAVProp.etag]).first?.string(DAVProp.etag)
                .map(AppDataFiles.unquoted)
        } catch NetworkError.notFound {
            return nil
        }
    }

    // MARK: Helpers

    private func apply(_ updated: SyncedSettingsDocument, changed: Set<String>, local: Bool) {
        document = updated
        current.withLock { $0 = updated }
        if local {
            pending = true
            scheduleSend()
        }
        persist()
        guard !changed.isEmpty else { return }
        for observer in observers.values { observer(changed) }
    }

    private func scheduleSend() {
        scheduled?.cancel()
        let delay = sendDelay
        scheduled = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.sync()
        }
    }

    /// Keys whose value (not only stamp) differs.
    static func changedKeys(_ a: SyncedSettingsDocument, _ b: SyncedSettingsDocument) -> Set<String> {
        var keys: Set<String> = []
        for key in Set(a.entries.keys).union(b.entries.keys) where a.entries[key]?.value != b.entries[key]?.value {
            keys.insert(key)
        }
        return keys
    }

    private func persist() {
        guard let localFile else { return }
        do {
            try FileManager.default.createDirectory(at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = State(document: try document.encoded(), serverEtag: serverEtag, pending: pending)
            try JSONEncoder().encode(state).write(to: localFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("\(self.kind.rawValue, privacy: .public) not stored: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The synced settings files of one account, one store per kind, made when first asked for (SPEC §22.5).
public final class SyncedSettingsFiles: Sendable {
    private let files: AppDataFiles
    private let directory: URL?
    private let stores = Mutex<[SyncedSettingsStore.Kind: SyncedSettingsStore]>([:])

    /// - Parameter directory: where the copies on the device are kept (`<kind>.json` each); nil keeps them in memory.
    public init(dav: DAVClient, directory: URL?) {
        self.files = AppDataFiles(dav: dav)
        self.directory = directory
    }

    /// The store of a kind (always the same one for this account).
    public func store(_ kind: SyncedSettingsStore.Kind) -> SyncedSettingsStore {
        stores.withLock { stores in
            if let store = stores[kind] { return store }
            let store = SyncedSettingsStore(files: files, kind: kind, localFile: directory?.appending(path: kind.fileName))
            stores[kind] = store
            return store
        }
    }

    /// Syncs every store that was made so far (after a library sync): one listing of the folder tells which files
    /// changed, so an unchanged set costs one request.
    public func syncAll() async {
        let all = stores.withLock { Array($0.values) }
        guard !all.isEmpty else { return }
        var etags: [String: String]?
        do {
            let listing = try await files.dav.propfind(
                files.dav.connection.filesURL(AppDataFiles.folder), depth: 1, properties: [DAVProp.etag, DAVProp.resourceType])
            var found: [String: String] = [:]
            for resource in listing.dropFirst() where !resource.isCollection {
                guard let etag = resource.string(DAVProp.etag) else { continue }
                found[resource.lastPathComponent] = AppDataFiles.unquoted(etag)
            }
            etags = found
        } catch NetworkError.notFound {
            etags = [:]
        } catch {
            etags = nil
        }
        for store in all {
            if let etags {
                await store.sync(listing: .some(etags[store.kind.fileName]))
            } else {
                await store.sync()
            }
        }
    }
}

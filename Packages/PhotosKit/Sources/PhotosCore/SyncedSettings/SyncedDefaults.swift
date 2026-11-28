// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosNetworking

/// The app settings that follow the user from device to device (SPEC §22.5.2), and how each is kept in `UserDefaults`.
public enum SyncedDefaultsCatalog {
    public struct Item: Sendable, Hashable {
        /// The `UserDefaults` key; `{account}` stands for the account's id (settings kept per account).
        public var defaultsKey: String
        /// The key in `settings.json`; for an expanded dictionary, the prefix of its entries' keys (`films/<memory>`).
        public var syncedKey: String
        /// A dictionary whose entries are synced one by one (merged per entry, not as a whole).
        public var expands = false
        /// Stored as JSON in a `Data` value rather than as property list values.
        public var jsonData = false

        public var isPerAccount: Bool { defaultsKey.contains("{account}") }

        public init(_ defaultsKey: String, synced syncedKey: String? = nil, expands: Bool = false, jsonData: Bool = false) {
            self.defaultsKey = defaultsKey
            self.syncedKey = syncedKey ?? defaultsKey
            self.expands = expands
            self.jsonData = jsonData
        }

        func defaultsKey(account: String) -> String { defaultsKey.replacingOccurrences(of: "{account}", with: account) }
    }

    /// Every synced setting. Device-specific ones (cache sizes, grid columns, backup, app lock, notifications, on-device
    /// analysis…) are deliberately missing: SPEC §22.5.2 lists them with the reason.
    public static let items: [Item] = [
        // Library display (Settings › Library).
        Item("showsMemoriesStrip"), Item("memoriesStyle"), Item("showsMoments"), Item("squareTiles"), Item("stackCopies"),
        // Appearance (§16.8).
        Item("lookViewerBackdrop"), Item("lookHeaderTint"), Item("lookLiveCovers"),
        // Slideshow and films.
        Item("slideshowInterval"), Item("slideshowRepeats"), Item("throughTheYearsSpeed"),
        Item("memoryFilmChoices", synced: "films/", expands: true, jsonData: true),
        Item("throughTheYearsBirthdays.{account}", synced: "birthdays/", expands: true),
        // Culling and the loupe (§16.5).
        Item("cullingAutoAdvance"), Item("loupe.peaking"), Item("loupe.clipping"), Item("loupe.histogram"),
        // Editing (§21.6.6), naming patterns and sort orders.
        Item("editing.applyEditsToFile"), Item("batchRenamePattern"), Item("cardImportPattern"),
        Item("albumsSortOrder"), Item("albumPhotosSortOrder"),
    ]
}

/// Keeps the settings of `SyncedDefaultsCatalog` in `UserDefaults` in step with the account's `settings.json`
/// (SPEC §22.5.2).
///
/// A journal on the device (a `SyncedSettingsDocument` of its own) stamps every change of a synced setting when it is
/// noticed: at once while the app runs (`UserDefaults.didChangeNotification`), else at the next sync. Before a sync the
/// journal is merged into the account's store, after it the store's values come back into the journal and into
/// `UserDefaults` where they won. On the first sync of a device its existing settings count as old (stamped at 1970),
/// so the account's settings win and the device's only fill in what the account has not got. Settings kept per account
/// are journalled under the account's id and synced only with that account.
@MainActor
public final class SyncedDefaults {
    /// Settings › Advanced › Same Settings on All Devices (on by default), a setting of this device.
    public static let enabledKey = "syncedSettings.enabled"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    struct State: Codable {
        var journal: Data?
        /// The values the synced settings had when last noticed or applied, by journal key.
        var snapshot: [String: JSONValue] = [:]
        var started = false
    }

    private let defaults: UserDefaults
    private let file: URL?
    private let items: [SyncedDefaultsCatalog.Item]
    private var journal = SyncedSettingsDocument(kind: SyncedSettingsStore.Kind.settings.rawValue)
    private var snapshot: [String: JSONValue] = [:]
    private var started = false
    private var observer: (any NSObjectProtocol)?
    private var pendingNotice: Task<Void, Never>?
    private weak var attached: SyncedSettingsStore?
    private var attachedAccount: String?
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "synced-settings")

    public init(defaults: UserDefaults = .standard, file: URL?, items: [SyncedDefaultsCatalog.Item] = SyncedDefaultsCatalog.items) {
        self.defaults = defaults
        self.file = file
        self.items = items
        if let file, let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(State.self, from: data) {
            journal = state.journal.flatMap(SyncedSettingsDocument.decoded) ?? journal
            snapshot = state.snapshot
            started = state.started
        }
    }

    /// The one of the app, kept next to the accounts list.
    public static let shared = SyncedDefaults(
        file: AppPaths.layout.accountsFile.deletingLastPathComponent().appending(path: "synced-settings.json"))

    // MARK: Following changes while the app runs

    /// Sends changes of synced settings made on this device to `store` soon after they are made (debounced).
    public func attach(_ store: SyncedSettingsStore, account: String) {
        attached = store
        attachedAccount = account
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleNotice() }
        }
    }

    private func scheduleNotice() {
        guard Self.isEnabled(defaults), attached != nil else { return }
        pendingNotice?.cancel()
        pendingNotice = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let store = self.attached, let account = self.attachedAccount else { return }
            if self.noticeChanges(account: account) { await self.prepare(store, account: account) }
        }
    }

    // MARK: Sync

    /// Before the store syncs: notes what changed here and hands the journal to the store.
    public func prepare(_ store: SyncedSettingsStore, account: String, now: Date = Date()) async {
        guard Self.isEnabled(defaults) else { return }
        noticeChanges(account: account, now: now)
        await store.merge(storeDocument(account: account))
    }

    /// After the store synced: takes over what won and writes it into `UserDefaults`.
    public func apply(_ store: SyncedSettingsStore, account: String) {
        guard Self.isEnabled(defaults) else { return }
        // Changes made since `prepare` are noted first, so they are not overwritten by what was there before.
        noticeChanges(account: account)
        let remote = store.snapshot()
        var mapped = SyncedSettingsDocument(kind: journal.kind)
        for (key, entry) in remote.entries {
            guard let journalKey = journalKey(forStoreKey: key, account: account) else { continue }
            mapped.entries[journalKey] = entry
        }
        journal = journal.merged(with: mapped)
        for item in items where !isLaunchArgument(item, account: account) {
            let wanted = journalValues(item, account: account)
            let current = read(item, account: account)
            guard wanted != current else { continue }
            write(wanted, item, account: account)
            logger.info("setting \(item.defaultsKey, privacy: .public) taken over from another device")
        }
        let now = currentValues(account: account)
        for key in snapshotKeys(account: account) where now[key] == nil { snapshot[key] = nil }
        for (key, value) in now { snapshot[key] = value }
        persist()
    }

    /// One sync of the settings: `prepare`, the store's sync, `apply`.
    public func sync(_ store: SyncedSettingsStore, account: String) async {
        await prepare(store, account: account)
        await store.sync()
        apply(store, account: account)
    }

    // MARK: Noticing changes

    /// Compares the synced settings with the snapshot and stamps what changed. Returns whether anything did.
    @discardableResult
    func noticeChanges(account: String, now: Date = Date()) -> Bool {
        let current = currentValues(account: account)
        // The first look of a device: what it has counts as old, the account's settings win.
        let stamp = started ? now : Date(timeIntervalSince1970: 0)
        var changed = false
        for key in Set(current.keys).union(snapshotKeys(account: account)) where current[key] != snapshot[key] {
            if journal.set(current[key], for: key, now: stamp) { changed = true }
            snapshot[key] = current[key]
        }
        if !started || changed {
            started = true
            persist()
        }
        return changed
    }

    /// The journal's entries for this account, with the store's keys.
    func storeDocument(account: String) -> SyncedSettingsDocument {
        var document = SyncedSettingsDocument(kind: journal.kind)
        let prefix = "\(account)|"
        for (key, entry) in journal.entries {
            if key.hasPrefix(prefix) {
                document.entries[String(key.dropFirst(prefix.count))] = entry
            } else if !key.contains("|") {
                document.entries[key] = entry
            }
        }
        return document
    }

    private func journalKey(forStoreKey key: String, account: String) -> String? {
        guard let item = items.first(where: { $0.expands ? key.hasPrefix($0.syncedKey) : key == $0.syncedKey }) else { return nil }
        return item.isPerAccount ? "\(account)|\(key)" : key
    }

    private func journalPrefix(_ item: SyncedDefaultsCatalog.Item, account: String) -> String {
        item.isPerAccount ? "\(account)|\(item.syncedKey)" : item.syncedKey
    }

    private func snapshotKeys(account: String) -> [String] {
        snapshot.keys.filter { key in
            items.contains { item in
                guard !isLaunchArgument(item, account: account) else { return false }
                let prefix = journalPrefix(item, account: account)
                return item.expands ? key.hasPrefix(prefix) : key == prefix
            }
        }
    }

    /// The synced settings as `UserDefaults` has them now, by journal key.
    func currentValues(account: String) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for item in items where !isLaunchArgument(item, account: account) {
            let prefix = journalPrefix(item, account: account)
            guard let value = read(item, account: account) else { continue }
            if item.expands {
                for (sub, entry) in value.object ?? [:] { result[prefix + sub] = entry }
            } else {
                result[prefix] = value
            }
        }
        return result
    }

    /// What the journal says a setting should be.
    private func journalValues(_ item: SyncedDefaultsCatalog.Item, account: String) -> JSONValue? {
        let prefix = journalPrefix(item, account: account)
        guard item.expands else { return journal.value(prefix) }
        let entries = journal.values(prefix: prefix)
        guard !entries.isEmpty else { return nil }
        var object: [String: JSONValue] = [:]
        for (key, value) in entries { object[String(key.dropFirst(prefix.count))] = value }
        return .object(object)
    }

    // MARK: UserDefaults

    /// A setting given as a launch argument (`-memoriesStyle strip`, UI tests and screenshots) is for this launch only:
    /// neither sent nor overwritten.
    private func isLaunchArgument(_ item: SyncedDefaultsCatalog.Item, account: String) -> Bool {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[item.defaultsKey(account: account)] != nil
    }

    func read(_ item: SyncedDefaultsCatalog.Item, account: String) -> JSONValue? {
        guard let object = defaults.object(forKey: item.defaultsKey(account: account)) else { return nil }
        let value: JSONValue?
        if item.jsonData {
            value = (object as? Data).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        } else {
            value = Self.json(object)
        }
        // An empty dictionary says nothing an absent one does not.
        if item.expands, value?.object?.isEmpty ?? true { return nil }
        return value
    }

    private func write(_ value: JSONValue?, _ item: SyncedDefaultsCatalog.Item, account: String) {
        let key = item.defaultsKey(account: account)
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        if item.jsonData {
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        } else if let object = Self.propertyList(value) {
            defaults.set(object, forKey: key)
        }
    }

    /// A property list value as JSON; nil for what JSON cannot carry (dates, data).
    static func json(_ object: Any) -> JSONValue? {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let string as String: return .string(string)
        case let array as [Any]:
            let values = array.compactMap(json)
            return values.count == array.count ? .array(values) : nil
        case let dictionary as [String: Any]:
            var result: [String: JSONValue] = [:]
            for (key, value) in dictionary {
                guard let converted = json(value) else { return nil }
                result[key] = converted
            }
            return .object(result)
        default: return nil
        }
    }

    /// JSON as a property list value; whole numbers as integers.
    static func propertyList(_ value: JSONValue) -> Any? {
        switch value {
        case .null: return nil
        case .bool(let bool): return bool
        case .number(let number):
            return number == number.rounded() && abs(number) < 1e15 ? Int(number) : number
        case .string(let string): return string
        case .array(let array): return array.compactMap(propertyList)
        case .object(let object): return object.compactMapValues(propertyList)
        }
    }

    private func persist() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = State(journal: try journal.encoded(), snapshot: snapshot, started: started)
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
        } catch {
            logger.error("synced settings journal not stored: \(error.localizedDescription, privacy: .public)")
        }
    }
}

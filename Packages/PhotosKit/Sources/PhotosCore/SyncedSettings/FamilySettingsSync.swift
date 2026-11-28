// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosNetworking
import PhotosStore

/// The family library's options and decisions shared by the user's devices through `family.json` (SPEC §22.5.1):
/// `settings` → `FamilyLibrarySettings`, `decision/<fileId>` → `dismissed` / `moved` / `copied`. A photo dismissed on the
/// iPhone is not suggested on the Mac; "Show dismissed again" and another folder remove the decisions everywhere.
struct FamilySettingsSync: Sendable {
    static let settingsKey = "settings"
    static let decisionPrefix = "decision/"

    let store: SyncedSettingsStore
    let family: FamilyStore

    static func key(_ fileId: FileID) -> String { "\(decisionPrefix)\(fileId)" }

    func publish(_ settings: FamilyLibrarySettings) async {
        await store.set(encoding: settings, for: Self.settingsKey)
    }

    func publish(_ decision: FamilyStore.Decision, for fileIds: [FileID]) async {
        var values: [String: JSONValue?] = [:]
        for fileId in fileIds { values[Self.key(fileId)] = .string(decision.rawValue) }
        await store.set(values)
    }

    /// Every decision is forgotten, on all devices.
    func forgetAll() async {
        var values: [String: JSONValue?] = [:]
        for key in store.values(prefix: Self.decisionPrefix).keys { values[key] = .some(nil) }
        await store.set(values)
    }

    /// Before the store syncs: what this device had before decisions were synced goes into the file (once; a key the
    /// file knows, also as removed, is the file's).
    func publishUnsynced(_ settings: FamilyLibrarySettings) async throws {
        let document = store.snapshot()
        if document.entries[Self.settingsKey] == nil && settings.isSetUp { await publish(settings) }
        var values: [String: JSONValue?] = [:]
        for (fileId, decision) in try family.decisions() where document.entries[Self.key(fileId)] == nil {
            values[Self.key(fileId)] = .string(decision.rawValue)
        }
        if !values.isEmpty { await store.set(values) }
    }

    /// After the store synced: the decisions of the file into the database. Returns the file's settings when they differ
    /// from `current` (the caller takes them over).
    func takeOver(current: FamilyLibrarySettings) throws -> FamilyLibrarySettings? {
        let document = store.snapshot()
        let local = try family.decisions()
        var forget: [FileID] = []
        var record: [FamilyStore.Decision: [FileID]] = [:]
        for (key, entry) in document.entries where key.hasPrefix(Self.decisionPrefix) {
            guard let fileId = FileID(key.dropFirst(Self.decisionPrefix.count)) else { continue }
            if let value = entry.value?.string, let decision = FamilyStore.Decision(rawValue: value) {
                if local[fileId] != decision { record[decision, default: []].append(fileId) }
            } else if entry.isDeleted, local[fileId] != nil {
                forget.append(fileId)
            }
        }
        if !forget.isEmpty { try family.forget(forget) }
        for (decision, fileIds) in record { try family.record(decision, for: fileIds) }
        guard let remote = document.value(Self.settingsKey, as: FamilyLibrarySettings.self), remote != current else { return nil }
        return remote
    }
}

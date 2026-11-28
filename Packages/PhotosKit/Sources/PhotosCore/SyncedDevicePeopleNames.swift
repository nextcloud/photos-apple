// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosMedia
import PhotosNetworking

/// The names and assignments of People found on the user's devices, shared through `.nextcloud-photos/people.json`
/// (SPEC §22.3, §22.5): one record per person (`person/<id>`), so two devices that changed different people never touch
/// each other's records, and two that changed the same person at once keep both devices' faces
/// (`DevicePeopleDocument.merged`).
///
/// Names that were kept on this device only before they were shared (`device-people.json`) are taken in once.
actor SyncedDevicePeopleNames: DevicePeopleNames {
    static let prefix = "person/"
    let records: SyncedRecords<DevicePeopleDocument.Person>
    /// The file of the names kept on this device only, taken in at the first load and then removed.
    private var legacyFile: URL?

    init(store: SyncedSettingsStore, legacyFile: URL?) {
        records = SyncedRecords(store: store, prefix: Self.prefix) { Self.merge($0, $1) }
        self.legacyFile = legacyFile
    }

    /// Two versions of one person in one: the newer name, deletion and merge, the faces of both.
    static func merge(_ a: DevicePeopleDocument.Person, _ b: DevicePeopleDocument.Person) -> DevicePeopleDocument.Person {
        DevicePeopleDocument(people: ["p": a]).merged(with: DevicePeopleDocument(people: ["p": b])).people["p"] ?? a
    }

    func load() async throws -> DevicePeopleDocument {
        try await takeInLegacyFile()
        return DevicePeopleDocument(people: records.load())
    }

    @discardableResult
    func update(_ change: @Sendable (inout DevicePeopleDocument) -> Void) async throws -> DevicePeopleDocument {
        var document = try await load()
        change(&document)
        await records.replace(document.people)
        return document
    }

    /// Moves the names kept on this device only into the shared records (merged, so a name another device gave meanwhile
    /// is kept when it is newer), then removes the old file.
    private func takeInLegacyFile() async throws {
        guard let file = legacyFile else { return }
        legacyFile = nil
        // A file that can't be read stays where it is (nothing is removed that wasn't taken in).
        guard FileManager.default.fileExists(atPath: file.path), let local = try? await LocalDevicePeopleNames(file: file).load()
        else { return }
        if !local.people.isEmpty {
            let merged = DevicePeopleDocument(people: records.load()).merged(with: local)
            await records.replace(merged.people)
        }
        try? FileManager.default.removeItem(at: file)
    }
}

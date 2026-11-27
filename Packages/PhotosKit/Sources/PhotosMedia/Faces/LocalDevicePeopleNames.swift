// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain

/// The names and assignments of People on this device, kept in a file of the account (SPEC §22.3).
///
/// TODO(tidy, SPEC §22.5): share them between the user's devices: the settings code reads `.nextcloud-photos/people.json`,
/// merges it with this file (`DevicePeopleDocument.merged`) and writes it back ETag-safely, then `load()` returns the
/// merged document and `update` writes through. Until then the names stay on this device.
public actor LocalDevicePeopleNames: DevicePeopleNames {
    let file: URL
    private var cached: DevicePeopleDocument?

    public init(file: URL) {
        self.file = file
    }

    public func load() throws -> DevicePeopleDocument {
        if let cached { return cached }
        let document: DevicePeopleDocument
        if let data = try? Data(contentsOf: file) {
            document = try JSONDecoder().decode(DevicePeopleDocument.self, from: data)
        } else {
            document = DevicePeopleDocument()
        }
        cached = document
        return document
    }

    @discardableResult
    public func update(_ change: @Sendable (inout DevicePeopleDocument) -> Void) throws -> DevicePeopleDocument {
        var document = try load()
        change(&document)
        try save(document)
        return document
    }

    /// Takes another device's version (the shared file, once it is read from the server) into this one.
    public func merge(_ other: DevicePeopleDocument) throws -> DevicePeopleDocument {
        let merged = try load().merged(with: other)
        try save(merged)
        return merged
    }

    func save(_ document: DevicePeopleDocument) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: file, options: .atomic)
        cached = document
    }
}

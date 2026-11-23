// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import PhotosAppUI

/// The share extension's temporary copies (review r2 item 11).
@Suite struct SharedItemsTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "SharedItemsTests-\(UUID().uuidString)")

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    func makeFile(_ name: String) throws -> URL {
        let file = directory.appending(path: "source/\(name)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 64).write(to: file)
        return file
    }

    @MainActor @Test func itemsThatCannotBeReadAreCounted() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = try #require(NSItemProvider(contentsOf: try makeFile("a.jpg")))
        // An image whose data cannot be loaded (a photo that is only in iCloud, a file that went away).
        let broken = NSItemProvider()
        broken.registerFileRepresentation(for: .jpeg, visibility: .all) { completion in
            completion(nil, false, CocoaError(.fileReadNoSuchFile))
            return nil
        }
        // Something that is no file at all.
        let nothing = NSItemProvider()
        let copies = directory.appending(path: "copies")

        let loaded = await SharedItems.load([good, broken, nothing], into: copies)
        #expect(loaded.files.count == 1)
        #expect(loaded.unreadable == 2)
        let copy = try #require(loaded.files.first)
        #expect(copy.path(percentEncoded: false).hasPrefix(copies.path(percentEncoded: false)))
        #expect(try Data(contentsOf: copy).count == 64)

        // Cancel or completion: the copies of this share go.
        SharedItems.remove(copies)
        #expect(!exists(copies))
    }

    @Test func theNoteSaysHowManyAreMissing() {
        #expect(SharedItems.unreadableNote(unreadable: 0, of: 5) == nil)
        #expect(SharedItems.unreadableNote(unreadable: 2, of: 5) == "2 of 5 items could not be read.")
        #expect(SharedItems.unreadableNote(unreadable: 1, of: 2) == "1 of 2 items could not be read.")
        #expect(SharedItems.unreadableNote(unreadable: 1, of: 1) == "The item could not be read.")
    }

    @Test func leftoversOfEarlierSharesAreRemovedAtTheStart() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = FileManager.default
        let old = directory.appending(path: "old-share")
        let running = directory.appending(path: "running-share")
        for share in [old, running] {
            try files.createDirectory(at: share.appending(path: "item"), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 10).write(to: share.appending(path: "item/a.jpg"))
        }
        let now = Date()
        try files.setAttributes([.modificationDate: now.addingTimeInterval(-2 * SharedItems.leftoverAge)], ofItemAtPath: old.path(percentEncoded: false))
        SharedItems.removeLeftovers(in: directory, now: now)
        #expect(!exists(old))
        // Another share that is uploading right now keeps its files.
        #expect(exists(running))
        // A directory that is not there is nothing to remove.
        SharedItems.removeLeftovers(in: directory.appending(path: "missing"))
    }
}

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhotosModel

/// A sticker in the app's sticker book.
public struct Sticker: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    /// The photo it was made from.
    public var sourceFileId: FileID?
    /// The person's name when it belongs to a person's sticker pack.
    public var pack: String?
    /// `StickerStyle` raw value.
    public var style: String
    public var width: Int
    public var height: Int

    /// The PNG's file name in the sticker book's folder.
    public var fileName: String { "\(id.uuidString).png" }
}

/// The sticker book (SPEC §15.8.2): the stickers made in the app, per account, on this device. A folder of transparent
/// PNGs with a small JSON list; removed with the account. Stickers are not uploaded: a sticker can be shared, copied or
/// added to the system's stickers, and saved to the library as any image.
@MainActor
@Observable
public final class StickerBook {
    public private(set) var stickers: [Sticker] = []
    public nonisolated let directory: URL
    @ObservationIgnored private var loaded = false

    public init(directory: URL) {
        self.directory = directory
    }

    var listFile: URL { directory.appending(path: "stickers.json") }

    public func url(of sticker: Sticker) -> URL { directory.appending(path: sticker.fileName) }

    /// Reads the list once (the first screen that needs it).
    public func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: listFile), let list = try? JSONDecoder().decode([Sticker].self, from: data) else { return }
        // Entries whose file is gone (a restore without the folder) are dropped.
        stickers = list.filter { FileManager.default.fileExists(atPath: url(of: $0).path(percentEncoded: false)) }
    }

    /// Adds a sticker (newest first) and returns it.
    @discardableResult
    public func add(png: Data, width: Int, height: Int, source: FileID?, pack: String?, style: String) throws -> Sticker {
        load()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sticker = Sticker(
            id: UUID(), createdAt: Date(), sourceFileId: source, pack: pack, style: style, width: width, height: height)
        try png.write(to: url(of: sticker), options: .atomic)
        stickers.insert(sticker, at: 0)
        try save()
        return sticker
    }

    public func remove(_ ids: Set<UUID>) {
        load()
        for sticker in stickers where ids.contains(sticker.id) { try? FileManager.default.removeItem(at: url(of: sticker)) }
        stickers.removeAll { ids.contains($0.id) }
        try? save()
    }

    /// The names of the people with a sticker pack, in the order their newest sticker was made.
    public var packs: [String] {
        var seen = Set<String>()
        return stickers.compactMap(\.pack).filter { seen.insert($0).inserted }
    }

    private func save() throws {
        try JSONEncoder().encode(stickers).write(to: listFile, options: .atomic)
    }
}

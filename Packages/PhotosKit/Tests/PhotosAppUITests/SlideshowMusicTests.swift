// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosAppUI

/// The music of memory slideshows (SPEC ME-4).
@MainActor
@Suite struct SlideshowMusicTests {
    @Test func theChoiceIsStoredAndAFileCopyIsKeptOnlyWhileChosen() throws {
        let defaults = try #require(UserDefaults(suiteName: "music-\(UUID().uuidString)"))
        let base = FileManager.default.temporaryDirectory.appending(path: "music-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appending(path: "SlideshowMusic")
        let source = base.appending(path: "Summer Song.m4a")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: source)

        #expect(SlideshowMusicStore.current(defaults: defaults) == nil)
        let music = try SlideshowMusicStore.importFile(source, folder: folder)
        #expect(music.title == "Summer Song")
        guard case .file(let name) = music.source else { Issue.record("not a file"); return }
        #expect(name.hasSuffix(".m4a"))
        #expect(FileManager.default.fileExists(atPath: SlideshowMusicStore.fileURL(name, folder: folder).path(percentEncoded: false)))
        // The original can go away: the app plays its own copy.
        try FileManager.default.removeItem(at: source)
        SlideshowMusicStore.save(music, defaults: defaults, folder: folder)
        #expect(SlideshowMusicStore.current(defaults: defaults) == music)
        #expect(SlideshowMusic(stored: music.stored) == music)

        // A song of the Music library instead: the copy is deleted.
        let song = SlideshowMusic(source: .library(42), title: "Song")
        SlideshowMusicStore.save(song, defaults: defaults, folder: folder)
        #expect(SlideshowMusicStore.current(defaults: defaults) == song)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty)
        // No music.
        SlideshowMusicStore.save(nil, defaults: defaults, folder: folder)
        #expect(SlideshowMusicStore.current(defaults: defaults) == nil)
        #expect(SlideshowMusic(stored: "") == nil)
        #expect(SlideshowMusic(stored: "{not json") == nil)
    }
}

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PhotosDomain
@testable import PhotosMedia
@testable import PhotosModel
@testable import PhotosStore

/// People on this device with real Vision, on the Mac (SPEC §22.3): the photos of a folder (`PHOTOS_FACES_FOLDER`, e.g.
/// the test library) analysed as 1024-pixel previews and grouped as the app does; the groups and the time per photo
/// are written to `PHOTOS_FACES_REPORT` (JSON) for measuring how well people are found (docs/STATUS.md §22.3).
@Suite(.timeLimit(.minutes(20))) struct DevicePeopleVisionTests {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["PHOTOS_FACES_FOLDER"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    struct Report: Codable {
        struct Face: Codable {
            var file: String
            var box: FaceBox
            var quality: Float?
            var side: Double
            var person: Int64?
        }

        var photos: Int
        var faces: [Face]
        var usableFaces: Int
        var people: Int
        var secondsPerPhoto: Double
        var groupingSeconds: Double
    }

    @Test(.enabled(if: !TestEnvironment.isSimulator && folder != nil, "Set PHOTOS_FACES_FOLDER to a folder of photos"))
    func groupsTheFacesOfAFolder() async throws {
        let folder = try #require(Self.folder)
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        let database = try AccountDatabase.temporary()
        let items = files.enumerated().map { index, url in
            MediaItem(
                fileId: FileID(index + 1), path: "/Photos/\(url.lastPathComponent)", mimeType: "image/jpeg", etag: "e",
                capturedAt: Date(timeIntervalSince1970: Double(1_600_000_000 + index)))
        }
        try LibraryStore(database: database).upsert(items)
        let store = DeviceFaceStore(database: database)
        var mean = try store.mean()
        let start = ContinuousClock.now
        for (index, url) in files.enumerated() {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: FaceAnalysis.analysisBucket,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary)
            else { continue }
            let faces = try await FaceAnalysis.analyze(image)
            try store.save(DeviceFaceStore.Candidate(fileId: FileID(index + 1), etag: "e"), faces: faces)
            for face in faces { if let print = face.print { mean.add(print) } }
        }
        let analysed = ContinuousClock.now - start
        try store.saveMean(mean)
        let names = LocalDevicePeopleNames(file: FileManager.default.temporaryDirectory.appending(path: "people-\(UUID()).json"))
        let engine = DevicePeopleEngine(database: database, names: names)
        let groupingStart = ContinuousClock.now
        try await engine.group(scanFinished: true)
        let grouping = ContinuousClock.now - groupingStart
        let faces = try store.allFaces()
        let usable = try store.progress().faces
        let people = try store.people()
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let report = Report(
            photos: files.count,
            faces: faces.map { face in
                Report.Face(
                    file: files[Int(face.fileId) - 1].lastPathComponent, box: face.box, quality: face.quality, side: 0,
                    person: people.contains { $0.id == face.personId } ? face.personId : nil)
            }, usableFaces: usable, people: people.count, secondsPerPhoto: seconds(analysed) / Double(max(1, files.count)),
            groupingSeconds: seconds(grouping))
        if let path = ProcessInfo.processInfo.environment["PHOTOS_FACES_REPORT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(filePath: path))
        }
        #expect(!faces.isEmpty)
        // No person has two faces in one photo.
        for person in people {
            let members = faces.filter { $0.personId == person.id }
            #expect(Set(members.map(\.fileId)).count == members.count)
        }
    }
}

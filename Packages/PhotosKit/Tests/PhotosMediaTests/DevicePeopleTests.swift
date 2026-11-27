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

/// People on this device (SPEC §22.3): looking at cached previews, grouping, what the user says, and the names shared
/// with the user's other devices. Vision itself is replaced by fixed answers here (`DevicePeopleVisionTests` runs it).
@Suite(.timeLimit(.minutes(5))) struct DevicePeopleTests {
    static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAAAAABX3VL4AAAADklEQVR4nGNoaGBoaAAABgYCASzBUNcAAAAASUVORK5CYII=")!
    /// A tile that shows a face (4 × 4 pixels: the fake detector says yes to it).
    static let faceTile: Data = {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    /// Prints: what all faces share, a little of each person, noise.
    struct Prints {
        var state: UInt64 = 7
        var common: [Float] = []
        var people: [[Float]] = []

        init() {
            common = vector()
            people = (0..<3).map { _ in vector() }
        }

        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Double(state >> 11) / Double(1 << 53)) * 2 - 1
        }

        mutating func vector() -> [Float] { FaceClustering.normalized((0..<64).map { _ in next() }) }

        mutating func face(_ person: Int) -> [Float] {
            let noise = vector()
            return FaceClustering.normalized((0..<64).map { common[$0] + 0.6 * people[person][$0] + 0.08 * noise[$0] })
        }
    }

    /// Who is in which photo: photos 1–4 Anna (0) and photos 2–3 Ben (1) too; photo 5 nobody.
    static let cast: [FileID: [Int]] = [1: [0], 2: [0, 1], 3: [1, 0], 4: [0], 5: [], 6: [1]]

    static func box(_ person: Int, jitter: Double = 0) -> FaceBox {
        FaceBox(x: 0.1 + Double(person) * 0.4 + jitter, y: 0.2, width: 0.2, height: 0.25)
    }

    struct Device {
        let database: AccountDatabase
        let cache: PreviewCache
        let directory: URL
        let names: LocalDevicePeopleNames
        let engine: DevicePeopleEngine
        var store: DeviceFaceStore { DeviceFaceStore(database: database) }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "photos-faces-\(UUID().uuidString)")
            database = try AccountDatabase.temporary()
            try LibraryStore(database: database).upsert(
                DevicePeopleTests.cast.keys.sorted().map {
                    MediaItem(
                        fileId: $0, path: "/Photos/\($0).jpg", mimeType: "image/jpeg", etag: "e\($0)",
                        capturedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + $0)))
                })
            cache = PreviewCache(directory: directory.appending(path: "cache"))
            names = LocalDevicePeopleNames(file: directory.appending(path: "people.json"))
            engine = DevicePeopleEngine(database: database, names: names)
        }

        /// Analyses the photos as Vision would, with `prints` (one per face, in the cast's order).
        func scan(_ prints: [FileID: [[Float]]], jitter: Double = 0) async throws -> Int {
            for fileId in DevicePeopleTests.cast.keys where fileId != 6 {
                cache.store(DevicePeopleTests.png, fileId: fileId, etag: "e\(fileId)", bucket: fileId == 5 ? 256 : 1024)
            }
            // Photo 6 has only its tile: it shows a face, so the 1024 preview is needed.
            cache.store(DevicePeopleTests.faceTile, fileId: 6, etag: "e6", bucket: 256)
            let byFile = prints
            let order = Counter()
            let indexer = FaceIndexer(
                database: database, cache: cache, fetchPreview: nil,
                analyze: { _ in
                    // The indexer goes by descending file id.
                    let fileId = order.nextFile()
                    return (byFile[fileId] ?? []).enumerated().map { index, print in
                        let person = DevicePeopleTests.cast[fileId]![index]
                        return DeviceFaceStore.FoundFace(
                            box: DevicePeopleTests.box(index, jitter: jitter), quality: person == 1 && fileId == 3 ? 0.6 : 0.5,
                            side: 120, print: print)
                    }
                }, detect: { image in image.width == 4 })
            return try await indexer.run()
        }

        func person(named name: String) throws -> DeviceFaceStore.PersonSummary? {
            try store.people().first { $0.name == name }
        }
    }

    /// Hands out the file ids in the order the indexer analyses them (descending, cached 1024 previews only).
    final class Counter: @unchecked Sendable {
        // `@unchecked Sendable`: only touched under `lock`.
        private let lock = NSLock()
        private var files: [FileID] = [4, 3, 2, 1]

        func nextFile() -> FileID {
            lock.lock()
            defer { lock.unlock() }
            return files.isEmpty ? 0 : files.removeFirst()
        }
    }

    static func prints() -> [FileID: [[Float]]] {
        var generator = Prints()
        var result: [FileID: [[Float]]] = [:]
        for fileId in cast.keys.sorted() { result[fileId] = cast[fileId]!.map { generator.face($0) } }
        return result
    }

    @Test func looksAtCachedPreviewsAndGroupsTheFaces() async throws {
        let device = try Device()
        defer { try? FileManager.default.removeItem(at: device.directory) }
        let prints = Self.prints()
        // Photos 1–4 analysed; photo 5 (tile only) has no face; photo 6 needs its 1024 preview, which is not there.
        #expect(try await device.scan(prints) == 5)
        let progress = try device.store.progress()
        #expect(progress.scanned == 5)
        #expect(progress.total == 6)
        #expect(progress.faces == 6)
        // Nothing is looked at twice.
        #expect(try await device.scan(prints) == 0)
        #expect(try await device.engine.group(scanFinished: true) == 6)
        let people = try device.store.people()
        #expect(people.count == 2)
        #expect(people.map(\.photoCount).sorted() == [2, 4])
        // No person has two faces of one photo.
        for person in people {
            let faces = try device.store.faces(ofPerson: person.id)
            #expect(Set(faces.map(\.item.fileId)).count == faces.count)
        }
    }

    @Test func namesAssignmentsAndRejectionsReachAnotherDevice() async throws {
        let phone = try Device()
        let mac = try Device()
        defer {
            try? FileManager.default.removeItem(at: phone.directory)
            try? FileManager.default.removeItem(at: mac.directory)
        }
        let prints = Self.prints()
        _ = try await phone.scan(prints)
        try await phone.engine.group(scanFinished: true)
        // The Mac finds the same faces a little apart.
        _ = try await mac.scan(prints, jitter: 0.004)
        try await mac.engine.group(scanFinished: true)

        let anna = try #require(try phone.store.people().first { $0.photoCount == 4 })
        try await phone.engine.rename(anna.id, to: "Anna")
        let document = try await phone.names.load()
        let shared = try #require(document.people.first { $0.value.name == "Anna" })
        #expect(shared.value.faces.count == 4)

        // The Mac reads the shared document (what `.nextcloud-photos/people.json` carries) and knows Anna.
        _ = try await mac.names.merge(document)
        #expect(try await mac.engine.applySharedNames())
        let macAnna = try #require(try mac.person(named: "Anna"))
        #expect(macAnna.photoCount == 4)
        #expect(macAnna.syncId == shared.key)

        // "Not this person" on the phone for Anna's face in photo 1.
        let face = try #require(try phone.store.faces(ofPerson: anna.id).first { $0.item.fileId == 1 })
        try await phone.engine.reject([face.face.id], from: anna.id)
        #expect(try phone.person(named: "Anna")?.photoCount == 3)
        _ = try await mac.names.merge(try await phone.names.load())
        try await mac.engine.applySharedNames()
        #expect(try mac.person(named: "Anna")?.photoCount == 3)
        // Grouping again does not put the face back.
        try await mac.engine.group(scanFinished: true)
        #expect(try mac.person(named: "Anna")?.photoCount == 3)

        // Named people are where search, memories and smart albums look for people.
        try phone.store.mirrorNamedPeople()
        let labels = LabelStore(database: phone.database)
        #expect(try labels.personNames() == ["Anna"])
        #expect(try labels.fileIds(ofPerson: "Anna") == [2, 3, 4])
        try phone.store.removeMirror()
        #expect(try labels.personNames().isEmpty)
    }

    @Test func assignMergeAndRemove() async throws {
        let device = try Device()
        defer { try? FileManager.default.removeItem(at: device.directory) }
        _ = try await device.scan(Self.prints())
        try await device.engine.group(scanFinished: true)
        let people = try device.store.people()
        let anna = try #require(people.first { $0.photoCount == 4 })
        let ben = try #require(people.first { $0.photoCount == 2 })
        // A new person, given one of Ben's faces.
        let carl = try await device.engine.create(named: "Carl")
        let benFace = try #require(try device.store.faces(ofPerson: ben.id).first)
        try await device.engine.move([benFace.face.id], from: ben.id, to: carl)
        #expect(try device.person(named: "Carl")?.photoCount == 1)
        let document = try await device.names.load()
        let carlShared = try #require(document.people.first { $0.value.name == "Carl" })
        #expect(carlShared.value.faces.count == 1)
        // Merged: Ben's remaining face goes to Carl; Ben was unnamed, Carl keeps his name.
        try await device.engine.merge(ben.id, into: carl)
        #expect(try device.person(named: "Carl")?.photoCount == 2)
        #expect(try device.store.people().contains { $0.id == ben.id } == false)
        // Removed: Anna's faces are no one's and are offered as unassigned faces.
        try await device.engine.rename(anna.id, to: "Anna")
        try await device.engine.delete(anna.id)
        #expect(try device.person(named: "Anna") == nil)
        #expect(try device.store.unassignedFaces().count == 4)
        #expect(try await device.names.load().people.values.contains { $0.name == "Anna" && $0.deleted })
        try device.store.deleteAll()
        #expect(try device.store.progress().scanned == 0)
    }
}

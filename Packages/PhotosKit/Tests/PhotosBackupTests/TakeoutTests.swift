// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import PhotosBackup
@testable import PhotosModel
@testable import PhotosNetworking
@testable import PhotosStore

@Suite struct TakeoutSidecarTests {
    func find(_ media: String, _ sidecars: [String]) -> String? {
        TakeoutSidecars.sidecar(for: media, in: TakeoutSidecars.index(sidecars))
    }

    @Test func matchesTheNamingSchemesOfTakeout() {
        #expect(find("IMG_1234.jpg", ["IMG_1234.jpg.json"]) == "IMG_1234.jpg.json")
        #expect(find("IMG_1234.jpg", ["IMG_1234.jpg.supplemental-metadata.json"]) == "IMG_1234.jpg.supplemental-metadata.json")
        #expect(find("IMG_1234.jpg", ["IMG_1234.jpg.supplemental-me.json"]) == "IMG_1234.jpg.supplemental-me.json", "cut short")
        // Copies: the counter is behind the extension in the sidecar's name.
        #expect(find("IMG_1234(1).jpg", ["IMG_1234.jpg.json", "IMG_1234.jpg(1).json"]) == "IMG_1234.jpg(1).json")
        #expect(find("IMG_1234.jpg", ["IMG_1234.jpg.json", "IMG_1234.jpg(1).json"]) == "IMG_1234.jpg.json")
        // Edited copies and Live Photo videos share the picture's sidecar.
        #expect(find("IMG_1234-edited.jpg", ["IMG_1234.jpg.json"]) == "IMG_1234.jpg.json")
        #expect(find("IMG_1234-bearbeitet.jpg", ["IMG_1234.jpg.json"]) == "IMG_1234.jpg.json")
        #expect(find("IMG_1234.MP4", ["IMG_1234.HEIC.json"]) == "IMG_1234.HEIC.json")
        // Long names are truncated (here to 46 characters before ".json").
        let long = "PXL_20240501_123045123.LONG_EXPOSURE-02.ORIGINAL.jpg"
        #expect(find(long, [String(long.prefix(46)) + ".json"]) == String(long.prefix(46)) + ".json")
        // Without the extension.
        #expect(find("IMG_1234.jpg", ["IMG_1234.json"]) == "IMG_1234.json")
        #expect(find("IMG_9999.jpg", ["IMG_1234.jpg.json"]) == nil)
    }

    @Test func readsTimePositionAndDescription() throws {
        let data = Data(
            """
            {"title":"IMG_1.jpg","description":" Grandma's birthday ","photoTakenTime":{"timestamp":"1561291200","formatted":"…"},
             "geoData":{"latitude":0.0,"longitude":0.0,"altitude":0.0},
             "geoDataExif":{"latitude":38.7169,"longitude":-9.1399,"altitude":12.5}}
            """.utf8)
        let metadata = try #require(TakeoutSidecars.parse(data))
        #expect(metadata.takenAt == Date(timeIntervalSince1970: 1_561_291_200))
        #expect(metadata.latitude == 38.7169, "0/0 means no position; the EXIF copy is used")
        #expect(metadata.longitude == -9.1399)
        #expect(metadata.altitude == 12.5)
        #expect(metadata.description == "Grandma's birthday")

        #expect(TakeoutSidecars.parse(Data(#"{"title":"x","geoData":{"latitude":0,"longitude":0}}"#.utf8)) == nil)
        #expect(TakeoutSidecars.parse(Data(#"{"photoTakenTime":{"timestamp":"-5"}}"#.utf8)) == nil)
        #expect(TakeoutSidecars.parse(Data("not json".utf8)) == nil)
        #expect(TakeoutSidecars.albumTitle(Data(#"{"title":"Trip to Lisbon","date":{}}"#.utf8)) == "Trip to Lisbon")
    }
}

/// Builds small exports on disk for the tests.
struct TakeoutFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "takeout-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ path: String, _ content: Data) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url)
        return url
    }

    func sidecar(_ path: String, time: Int, latitude: Double = 0, description: String = "") throws {
        try write(
            path,
            Data(
                """
                {"photoTakenTime":{"timestamp":"\(time)"},"geoData":{"latitude":\(latitude),"longitude":\(latitude == 0 ? 0 : 10.5)},
                 "description":"\(description)"}
                """.utf8))
    }

    /// A small export: a year folder, an album holding a copy of one of its photos, a copy with a counter, the trash.
    func standardExport() throws {
        let photos = "Takeout/Google Photos"
        try write("\(photos)/Photos from 2019/IMG_0001.jpg", Data(repeating: 1, count: 1000))
        try sidecar("\(photos)/Photos from 2019/IMG_0001.jpg.supplemental-metadata.json", time: 1_561_291_200, latitude: 38.7)
        try write("\(photos)/Photos from 2019/IMG_0001(1).jpg", Data(repeating: 2, count: 1200))
        try sidecar("\(photos)/Photos from 2019/IMG_0001.jpg.supplemental-metadata(1).json", time: 1_561_291_260)
        try write("\(photos)/Photos from 2020/VID_0002.mp4", Data(repeating: 3, count: 3000))
        try sidecar("\(photos)/Photos from 2020/VID_0002.mp4.json", time: 1_590_000_000, description: "Beach")
        try write("\(photos)/Photos from 2020/no-sidecar.png", Data(repeating: 4, count: 500))
        try write("\(photos)/Trip to Lisbon/IMG_0001.jpg", Data(repeating: 1, count: 1000))
        try sidecar("\(photos)/Trip to Lisbon/IMG_0001.jpg.supplemental-metadata.json", time: 1_561_291_200, latitude: 38.7)
        try write("\(photos)/Trip to Lisbon/metadata.json", Data(#"{"title":"Lisbon / Porto"}"#.utf8))
        try write("\(photos)/Trash/deleted.jpg", Data(repeating: 5, count: 100))
        try write("\(photos)/print-subscriptions.json", Data("{}".utf8))
        try write("archive_browser.html", Data("<html></html>".utf8))
    }

    /// Packs the export into a ZIP with `ditto` (deflate), `zip -0` (stored) or `zip -fz` (ZIP64 records).
    func zip(stored: Bool = false, zip64: Bool = false) throws -> URL {
        let target = root.deletingLastPathComponent().appending(path: "takeout-\(UUID().uuidString).zip")
        let process = Process()
        if stored || zip64 {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-q", "-r", stored ? "-0" : "-fz", target.path, "."]
            process.currentDirectoryURL = root
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", root.path, target.path]
        }
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return target
    }
}

@Suite struct TakeoutPlanTests {
    @Test func buildsItemsAlbumsAndSkipsTrashAndCopies() throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        try fixture.standardExport()
        let plan = try TakeoutPlan.build(try TakeoutSource.open([fixture.root.appending(path: "Takeout")]))

        #expect(plan.items.map(\.name) == ["no-sidecar.png", "IMG_0001.jpg", "IMG_0001(1).jpg", "VID_0002.mp4"])
        #expect(plan.albums == ["Lisbon / Porto"], "the album's own title; year folders, the root and the trash are no albums")
        #expect(plan.duplicatesInExport == 1, "the album's copy of IMG_0001.jpg is the year folder's file")
        #expect(plan.skippedTrash == 1)
        #expect(plan.withoutSidecar == 1)
        let photo = try #require(plan.items.first { $0.name == "IMG_0001.jpg" })
        #expect(photo.albums == ["Lisbon / Porto"])
        #expect(photo.metadata?.latitude == 38.7)
        #expect(photo.file.path == "Google Photos/Photos from 2019/IMG_0001.jpg")
        #expect(plan.items.first { $0.name == "IMG_0001(1).jpg" }?.takenAt == Date(timeIntervalSince1970: 1_561_291_260))
        #expect(plan.items.first { $0.name == "VID_0002.mp4" }?.kind == .video)
        #expect(plan.items.first { $0.name == "VID_0002.mp4" }?.metadata?.description == "Beach")
        // The same export gives the same key (resume), whether unpacked or zipped.
        let zipped = try TakeoutPlan.build(try TakeoutSource.open([try fixture.zip()]))
        #expect(zipped.key == plan.key)
        #expect(zipped.items.map(\.name) == plan.items.map(\.name))
    }

    @Test func yearFoldersInOtherLanguages() {
        #expect(TakeoutPlan.isYearFolder("Photos from 2019"))
        #expect(TakeoutPlan.isYearFolder("Fotos von 2019"))
        #expect(TakeoutPlan.isYearFolder("Photos de 2021"))
        #expect(!TakeoutPlan.isYearFolder("Trip 2019 Lisbon"))
        #expect(!TakeoutPlan.isYearFolder("Holidays"))
    }
}

@Suite struct ZipReaderTests {
    @Test(arguments: ["deflate", "stored", "zip64"]) func readsDeflatedStoredAndZip64Entries(format: String) throws {
        let stored = format == "stored"
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        // Compressible and random-ish content, larger than one read chunk.
        var big = Data()
        for index in 0..<300_000 { big.append(contentsOf: [UInt8(index % 251), UInt8((index * 7) % 13)]) }
        try fixture.write("a/big.bin", big)
        try fixture.write("a/b/small.txt", Data("hello zip".utf8))
        try fixture.write("a/b/ünïcode name.jpg", Data(repeating: 9, count: 10))
        let zip = try fixture.zip(stored: stored, zip64: format == "zip64")
        defer { try? FileManager.default.removeItem(at: zip) }

        let reader = try ZipReader(url: zip)
        let files = reader.entries.filter { !$0.isDirectory }
        let big0 = try #require(files.first { $0.path.hasSuffix("big.bin") })
        #expect(big0.size == UInt64(big.count))
        #expect(stored ? big0.method == 0 : big0.method == 8)
        let target = fixture.root.appending(path: "out.bin")
        try reader.extract(big0, to: target)
        #expect(try Data(contentsOf: target) == big)
        let small = try #require(files.first { $0.path.hasSuffix("small.txt") })
        #expect(try reader.data(of: small) == Data("hello zip".utf8))
        #expect(files.contains { $0.path.hasSuffix("ünïcode name.jpg") })
    }

    @Test func detectsDamagedData() throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        try fixture.write("x.txt", Data(repeating: 65, count: 5000))
        let zip = try fixture.zip(stored: true)
        defer { try? FileManager.default.removeItem(at: zip) }
        var bytes = try Data(contentsOf: zip)
        let reader = try ZipReader(url: zip)
        let entry = try #require(reader.entries.first { $0.path.hasSuffix("x.txt") })
        // Flip one byte of the stored content (after the local header, its name and its extra fields).
        let header = Int(entry.localHeaderOffset)
        let nameLength = Int(bytes[header + 26]) | (Int(bytes[header + 27]) << 8)
        let extraLength = Int(bytes[header + 28]) | (Int(bytes[header + 29]) << 8)
        let skip = nameLength + extraLength
        let index = header + 30 + skip + 100
        bytes[index] ^= 0xFF
        try bytes.write(to: zip)
        #expect(throws: ZipReader.ZipError.self) { _ = try ZipReader(url: zip).data(of: entry) }
        #expect(throws: ZipReader.ZipError.notAZip) { _ = try ZipReader(url: fixture.root.appending(path: "x.txt")) }
    }
}

/// A server for the importer: records uploads and albums; candidates are given by the test.
final class FakeTakeoutRemote: TakeoutRemote {
    struct State {
        var candidates: [RemoteCandidate] = []
        var uploads: [(name: String, folder: String, capturedAt: Date?, size: Int)] = []
        var albums: Set<String> = []
        var albumItems: [String: [String]] = [:]
        var comments: [FileID: String] = [:]
        var nextId: FileID = 1000
        var failNames: Set<String> = []
        var cancelAfterUploads: Int?
    }

    let state = Mutex(State())
    /// Cancels the running import after a number of uploads.
    let onUpload = Mutex<(@Sendable () -> Void)?>(nil)

    func candidates(from start: Date, to end: Date) async throws -> [RemoteCandidate] {
        state.withLock { state in
            state.candidates.filter { candidate in
                let time = candidate.capturedAt ?? candidate.modifiedAt
                return time >= start.addingTimeInterval(-14 * 3600) && time <= end.addingTimeInterval(14 * 3600)
            }
        }
    }

    func upload(file: URL, fileName: String, folder: String, capturedAt: Date?) async throws -> UploadedFile {
        let size = (try? Data(contentsOf: file).count) ?? -1
        let result: UploadedFile = try state.withLock { state in
            if state.failNames.contains(fileName) { throw NetworkError.http(status: 500, message: "boom") }
            state.uploads.append((fileName, folder, capturedAt, size))
            state.nextId += 1
            return UploadedFile(fileId: state.nextId, path: folder + "/" + fileName, etag: nil)
        }
        onUpload.withLock { $0 }?()
        return result
    }

    func didUpload(_ uploaded: UploadedFile, metadata: TakeoutMetadata?, comment: Bool) async {
        if comment, let text = metadata?.description { state.withLock { $0.comments[uploaded.fileId] = text } }
    }

    func albumNames() async throws -> Set<String> { state.withLock { $0.albums } }

    func createAlbum(_ name: String) async throws { _ = state.withLock { $0.albums.insert(name) } }

    func addToAlbum(_ name: String, path: String) async throws {
        state.withLock { $0.albumItems[name, default: []].append(path) }
    }
}

@Suite struct TakeoutImporterTests {
    func makePlan(_ fixture: TakeoutFixture, zipped: Bool = true) throws -> (TakeoutSource, TakeoutPlan) {
        try fixture.standardExport()
        let source = try TakeoutSource.open([zipped ? try fixture.zip() : fixture.root])
        return (source, try TakeoutPlan.build(source))
    }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func importsWithCaptureTimesSkipsServerCopiesAndCreatesAlbums() async throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        let (source, plan) = try makePlan(fixture)
        let remote = FakeTakeoutRemote()
        // IMG_0001(1).jpg is on the server already (backed up from a phone under the Files app's name).
        remote.state.withLock {
            $0.candidates = [
                RemoteCandidate(
                    fileId: 7, path: "/Photos/2019/19-06-23 12-01-00 0001.jpg", kind: .image, size: 1200,
                    capturedAt: Date(timeIntervalSince1970: 1_561_291_260), modifiedAt: Date())
            ]
        }
        let journal = fixture.root.appending(path: "journal")
        let importer = TakeoutImporter(
            source: source, plan: plan, remote: remote, options: TakeoutOptions(destination: "/Photos/Google Photos"),
            journalDirectory: journal, calendar: utc)
        let result = await importer.run { _ in }

        #expect(result.phase == .finished)
        #expect(result.total == 4)
        #expect(result.uploaded == 3)
        #expect(result.duplicates == 1)
        #expect(result.failed == 0)
        let uploads = remote.state.withLock { $0.uploads }
        #expect(uploads.map(\.name) == ["no-sidecar.png", "IMG_0001.jpg", "VID_0002.mp4"])
        #expect(uploads[1].folder == "/Photos/Google Photos/2019")
        #expect(uploads[1].capturedAt == Date(timeIntervalSince1970: 1_561_291_200), "sent as X-OC-MTime")
        #expect(uploads[1].size == 1000, "the file itself, unchanged")
        #expect(uploads[0].folder == "/Photos/Google Photos", "no capture time: no year folder")
        #expect(uploads[0].capturedAt == nil)
        // The album gets the uploaded photo; "/" is not allowed in album names.
        let albums = remote.state.withLock { ($0.albums, $0.albumItems) }
        #expect(albums.0 == ["Lisbon - Porto"])
        #expect(albums.1["Lisbon - Porto"] == ["/Photos/Google Photos/2019/IMG_0001.jpg"])
        #expect(remote.state.withLock { Array($0.comments.values) } == ["Beach"])

        // A second run of the same export does nothing again.
        let again = await TakeoutImporter(
            source: source, plan: plan, remote: remote, options: TakeoutOptions(destination: "/Photos/Google Photos"),
            journalDirectory: journal, calendar: utc
        ).run { _ in }
        #expect(again.phase == .finished)
        #expect(again.uploaded == 3 && again.duplicates == 1)
        #expect(remote.state.withLock { $0.uploads.count } == 3)
        #expect(remote.state.withLock { $0.albumItems["Lisbon - Porto"]?.count } == 1)
    }

    @Test func aCancelledImportContinuesWhereItStopped() async throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        let (source, plan) = try makePlan(fixture, zipped: false)
        let remote = FakeTakeoutRemote()
        let journal = fixture.root.appending(path: "journal")
        let options = TakeoutOptions(destination: "/Photos/Import", createAlbums: false)
        let running = Mutex<Task<TakeoutProgress, Never>?>(nil)
        remote.onUpload.withLock { $0 = { running.withLock { $0?.cancel() } } }
        let task = Task {
            await TakeoutImporter(source: source, plan: plan, remote: remote, options: options, journalDirectory: journal).run { _ in }
        }
        running.withLock { $0 = task }
        let first = await task.value
        #expect(first.phase == .cancelled)
        #expect(remote.state.withLock { $0.uploads.count } == 1)
        #expect(TakeoutJournal.load(from: journal, planKey: plan.key)?.completed == 1)

        remote.onUpload.withLock { $0 = nil }
        let second = await TakeoutImporter(source: source, plan: plan, remote: remote, options: options, journalDirectory: journal)
            .run { _ in }
        #expect(second.phase == .finished)
        #expect(second.uploaded == 4)
        #expect(remote.state.withLock { $0.uploads.count } == 4, "the first file is not uploaded twice")
    }

    @Test func aFailedFileIsReportedAndTriedAgainNextTime() async throws {
        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        let (source, plan) = try makePlan(fixture)
        let remote = FakeTakeoutRemote()
        remote.state.withLock { $0.failNames = ["VID_0002.mp4"] }
        let journal = fixture.root.appending(path: "journal")
        let options = TakeoutOptions(destination: "/Photos/Import")
        let first = await TakeoutImporter(source: source, plan: plan, remote: remote, options: options, journalDirectory: journal)
            .run { _ in }
        #expect(first.phase == .finished)
        #expect(first.failed == 1)
        #expect(first.failures.count == 1 && first.failures[0].hasPrefix("VID_0002.mp4"))

        remote.state.withLock { $0.failNames = [] }
        let second = await TakeoutImporter(source: source, plan: plan, remote: remote, options: options, journalDirectory: journal)
            .run { _ in }
        #expect(second.failed == 0)
        #expect(remote.state.withLock { $0.uploads.map(\.name) }.last == "VID_0002.mp4")
    }

    @Test func groupsItemsIntoDayWindows() {
        func item(_ id: String, _ time: TimeInterval?) -> TakeoutItem {
            TakeoutItem(
                id: id, file: TakeoutSource.File(path: id, size: 1), kind: .image,
                metadata: time.map { TakeoutMetadata(takenAt: Date(timeIntervalSince1970: $0)) }, albums: [])
        }
        let windows = TakeoutImporter.windows([
            item("a", nil), item("b", 0), item("c", 3600), item("d", 100_000), item("e", 100_001),
        ])
        #expect(windows.map { $0.map(\.id) } == [["a"], ["b", "c"], ["d", "e"]])
    }
}

/// Imports a small export into a real server (PHOTOS_IT_SERVER/USER/PASSWORD), checks dates, albums and comments, imports it
/// again without uploading anything, and removes what it created.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PHOTOS_IT_SERVER"] != nil))
struct TakeoutIntegrationTests {
    @Test func importsAndFindsTheSecondTimeThatEverythingIsThere() async throws {
        let env = ProcessInfo.processInfo.environment
        let user = env["PHOTOS_IT_USER"] ?? "admin"
        let http = HTTPClient(trustStore: TrustStore(directory: nil))
        let connection = ServerConnection(
            serverURL: URL(string: env["PHOTOS_IT_SERVER"]!)!, userId: user, loginName: user, appPassword: env["PHOTOS_IT_PASSWORD"] ?? "",
            userAgent: "tests")
        let api = PhotosAPI(dav: DAVClient(http: http, connection: connection), ocs: OCSClient(http: http, connection: connection))
        let run = String(UUID().uuidString.prefix(6))
        let destination = "/Photos/r3-E3-takeout-\(run)"
        let album = "r3-E3-album-\(run)"

        let fixture = try TakeoutFixture()
        defer { fixture.remove() }
        // Distinct content per run, so the server has no copy from an earlier run.
        let photos = "Takeout/Google Photos"
        let taken = 1_600_000_000 + Int.random(in: 0..<1_000_000)
        try fixture.write("\(photos)/Photos from 2020/r3E3_\(run)_1.jpg", Data((0..<4000).map { _ in UInt8.random(in: 0...255) }))
        try fixture.sidecar("\(photos)/Photos from 2020/r3E3_\(run)_1.jpg.supplemental-metadata.json", time: taken, description: "Caption")
        try fixture.write("\(photos)/\(album)/r3E3_\(run)_2.jpg", Data((0..<5000).map { _ in UInt8.random(in: 0...255) }))
        try fixture.sidecar("\(photos)/\(album)/r3E3_\(run)_2.jpg.json", time: taken + 3600)
        let zip = try fixture.zip()
        defer { try? FileManager.default.removeItem(at: zip) }
        let source = try TakeoutSource.open([zip])
        let plan = try TakeoutPlan.build(source)
        #expect(plan.items.count == 2)
        #expect(plan.albums == [album])

        let database = try AccountDatabase.temporary()
        let features = ServerFeatures(serverVersion: ServerVersion(major: 36), enabled: [.comments])
        let journal = fixture.root.appending(path: "journal")
        defer {
            Task {
                try? await api.dav.delete(connection.filesURL(destination))
                try? await api.deleteAlbum(Album(kind: .own, name: album))
            }
        }
        let options = TakeoutOptions(destination: destination)
        let first = await TakeoutImporter(
            source: source, plan: plan, api: api, database: database, features: features, options: options, journalDirectory: journal
        ).run { _ in }
        #expect(first.phase == .finished, "\(first.failures)")
        #expect(first.uploaded == 2)

        // The capture time arrived as the file's time.
        let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(taken)))
        let path = "\(destination)/\(year)/r3E3_\(run)_1.jpg"
        let resource = try #require(
            try await api.dav.propfind(connection.filesURL(path), depth: 0, properties: DAVProp.mediaIndex).first)
        let item = try #require(MediaParser.mediaItem(from: resource, connection: connection))
        #expect(item.modifiedAt == Date(timeIntervalSince1970: TimeInterval(taken)))
        // The album holds the album's photo.
        let content = try await api.albumContent(Album(kind: .own, name: album))
        #expect(content.map(\.item.name) == ["r3E3_\(run)_2.jpg"])

        // A second import (no journal) finds both on the server and uploads nothing.
        let second = await TakeoutImporter(
            source: source, plan: plan, api: api, database: database, features: features, options: options,
            journalDirectory: fixture.root.appending(path: "journal2")
        ).run { _ in }
        #expect(second.phase == .finished)
        #expect(second.duplicates == 2)
        #expect(second.uploaded == 0)

        try await api.dav.delete(connection.filesURL(destination))
        try await api.deleteAlbum(Album(kind: .own, name: album))
    }
}

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import GRDB
import PhotosDomain
import PhotosModel

/// People on this device (SPEC §22.3): the faces Vision found in the cached previews and the people they were grouped
/// into, for servers without Recognize. Never uploaded; only names and assignments are shared between the user's devices
/// (`DevicePeopleDocument`). Named people are also written into `person`/`personItem`, where search, smart albums,
/// memories and the family features find them as they find Recognize's.
public struct DeviceFaceStore: Sendable {
    public let database: AccountDatabase

    public init(database: AccountDatabase) {
        self.database = database
    }

    /// Migration `v_r12_people_device_faces`.
    static func migrate(_ db: Database) throws {
        // Which version of which photo was looked at, and how many faces it had (0 for most photos).
        try db.create(table: "deviceFaceScan") { t in
            t.primaryKey("fileId", .integer)
            t.column("etag", .text).notNull()
            t.column("faceCount", .integer).notNull()
            t.column("scannedAt", .double).notNull()
        }
        try db.create(table: "devicePerson") { t in
            t.autoIncrementedPrimaryKey("id")
            // The id in the shared document (`DevicePeopleDocument`), once named or assigned.
            t.column("syncId", .text).unique()
            t.column("name", .text)
            // The sum of the members' prints (little-endian Float32) and their number: the centre is sum / count.
            t.column("sum", .blob)
            t.column("faceCount", .integer).notNull().defaults(to: 0)
            t.column("updatedAt", .double).notNull().defaults(to: 0)
        }
        try db.create(table: "deviceFace") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("fileId", .integer).notNull()
            t.column("etag", .text).notNull()
            // Normalized, top-left origin (like Recognize's boxes).
            t.column("x", .double).notNull()
            t.column("y", .double).notNull()
            t.column("width", .double).notNull()
            t.column("height", .double).notNull()
            t.column("quality", .double)
            // The face's width in the analysed picture (pixels).
            t.column("side", .double).notNull().defaults(to: 0)
            // Normalized Vision feature print of the aligned crop (little-endian Float32); nil: not usable for grouping.
            t.column("print", .blob)
            t.column("personId", .integer).references("devicePerson", onDelete: .setNull)
            // Grouped already (or not usable): the grouping takes the others in order.
            t.column("clustered", .boolean).notNull().defaults(to: false)
            // The user put this face to its person (it stays there).
            t.column("pinned", .boolean).notNull().defaults(to: false)
        }
        try db.create(index: "deviceFace_file", on: "deviceFace", columns: ["fileId"])
        try db.create(index: "deviceFace_person", on: "deviceFace", columns: ["personId"])
        try db.create(table: "deviceFaceRejection") { t in
            t.column("faceId", .integer).notNull().references("deviceFace", onDelete: .cascade)
            t.column("personId", .integer).notNull().references("devicePerson", onDelete: .cascade)
            t.primaryKey(["faceId", "personId"])
        }
        // Faces and scans of deleted photos go with them; their people's centres are corrected at the next grouping.
        try db.execute(
            sql: """
                CREATE TRIGGER media_deviceFace_delete AFTER DELETE ON media BEGIN
                    DELETE FROM deviceFace WHERE fileId = OLD.fileId;
                    DELETE FROM deviceFaceScan WHERE fileId = OLD.fileId;
                END
                """)
    }

    // MARK: Types

    /// A photo whose preview can be looked at for faces.
    public struct Candidate: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String

        public init(fileId: FileID, etag: String) {
            self.fileId = fileId
            self.etag = etag
        }
    }

    /// A face as Vision found it.
    public struct FoundFace: Sendable, Equatable {
        public var box: FaceBox
        public var quality: Float?
        public var side: Double
        /// Normalized; nil when the face is not usable for grouping.
        public var print: [Float]?

        public init(box: FaceBox, quality: Float?, side: Double, print: [Float]?) {
            self.box = box
            self.quality = quality
            self.side = side
            self.print = print
        }
    }

    /// A stored face.
    public struct Face: Sendable, Hashable, Identifiable {
        public var id: Int64
        public var fileId: FileID
        public var box: FaceBox
        public var quality: Float?
        public var personId: Int64?
        public var pinned: Bool
    }

    /// A person as the People screens show them.
    public struct PersonSummary: Sendable, Hashable, Identifiable {
        public var id: Int64
        public var name: String?
        public var syncId: String?
        public var faceCount: Int
        public var photoCount: Int
        public var coverFileId: FileID?
        public var coverBox: FaceBox?
    }

    // MARK: Scanning

    /// Images not looked at in their current version, by descending file id, after `before` (a run pages through them and
    /// skips what it cannot do now, a photo without a cached preview, without asking again).
    public func candidates(limit: Int, before: FileID? = nil) throws -> [Candidate] {
        try database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT media.fileId, media.etag FROM media LEFT JOIN deviceFaceScan ON deviceFaceScan.fileId = media.fileId
                    WHERE media.kind = 'image' AND media.isLivePhotoVideo = 0 AND media.hasPreview = 1 AND media.fileId < ?
                        AND (deviceFaceScan.fileId IS NULL OR deviceFaceScan.etag <> media.etag)
                    ORDER BY media.fileId DESC LIMIT ?
                    """, arguments: [before ?? FileID.max, limit]
            )
            .map { Candidate(fileId: $0["fileId"], etag: $0["etag"]) }
        }
    }

    /// Stores what was found in one version of a photo, replacing what an older version had. Returns the faces of the
    /// older version that were in a person (their prints come off the person's centre at the next grouping).
    @discardableResult
    public func save(_ candidate: Candidate, faces: [FoundFace], at date: Date = Date()) throws -> [Face] {
        try database.writer.write { db in
            let old = try Self.faces(db, where: "fileId = ?", [candidate.fileId])
            for face in old where face.personId != nil {
                try Self.subtract(db, faceId: face.id, from: face.personId!)
            }
            try db.execute(sql: "DELETE FROM deviceFace WHERE fileId = ?", arguments: [candidate.fileId])
            for face in faces {
                try db.execute(
                    sql: """
                        INSERT INTO deviceFace(fileId, etag, x, y, width, height, quality, side, print, clustered)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        candidate.fileId, candidate.etag, face.box.x, face.box.y, face.box.width, face.box.height,
                        face.quality.map { Double($0) }, face.side, face.print.map { Self.data(floats: $0) }, face.print == nil,
                    ])
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO deviceFaceScan(fileId, etag, faceCount, scannedAt) VALUES (?, ?, ?, ?)",
                arguments: [candidate.fileId, candidate.etag, faces.count, date.timeIntervalSince1970])
            return old.filter { $0.personId != nil }
        }
    }

    /// Takes a face's print off its person's sum (inside a write).
    static func subtract(_ db: Database, faceId: Int64, from personId: Int64) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT print FROM deviceFace WHERE id = ?", arguments: [faceId]),
            let stored = row["print"] as Data?
        else { return }
        let print = floats(stored)
        guard let person = try Row.fetchOne(db, sql: "SELECT sum, faceCount FROM devicePerson WHERE id = ?", arguments: [personId])
        else { return }
        var sum = (person["sum"] as Data?).map(floats) ?? []
        if sum.count == print.count { for index in sum.indices { sum[index] -= print[index] } }
        let count = max(0, (person["faceCount"] as Int? ?? 0) - 1)
        try db.execute(
            sql: "UPDATE devicePerson SET sum = ?, faceCount = ? WHERE id = ?", arguments: [data(floats: sum), count, personId])
    }

    /// How many photos have been looked at and how many there are (Settings).
    public func progress() throws -> (scanned: Int, total: Int, faces: Int) {
        try database.writer.read { db in
            let total =
                try Int.fetchOne(db, sql: "SELECT count(*) FROM media WHERE kind = 'image' AND isLivePhotoVideo = 0 AND hasPreview = 1")
                ?? 0
            let scanned =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT count(*) FROM deviceFaceScan JOIN media ON media.fileId = deviceFaceScan.fileId AND media.etag = deviceFaceScan.etag
                        WHERE media.kind = 'image' AND media.isLivePhotoVideo = 0 AND media.hasPreview = 1
                        """) ?? 0
            let faces = try Int.fetchOne(db, sql: "SELECT count(*) FROM deviceFace WHERE print IS NOT NULL") ?? 0
            return (scanned, total, faces)
        }
    }

    // MARK: Grouping

    /// The running mean of the usable prints.
    public func mean() throws -> FacePrintMean {
        try database.writer.read { db in
            guard let value = try database.syncValue(db, Self.meanKey), let data = Data(base64Encoded: value) else {
                return FacePrintMean()
            }
            let floats = Self.floats(data)
            guard let count = floats.last, floats.count > 1 else { return FacePrintMean() }
            return FacePrintMean(sum: Array(floats.dropLast()), count: Int(count))
        }
    }

    public func saveMean(_ mean: FacePrintMean) throws {
        try database.writer.write { db in
            let data = Self.data(floats: mean.sum + [Float(mean.count)])
            try db.execute(
                sql: "INSERT OR REPLACE INTO syncState(key, value) VALUES (?, ?)", arguments: [Self.meanKey, data.base64EncodedString()])
        }
    }

    static let meanKey = "deviceFaceMean"

    /// Faces not grouped yet, oldest photos first (people are found in the order their photos were taken).
    public func ungrouped(limit: Int) throws -> [(face: Face, print: [Float])] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT deviceFace.* FROM deviceFace JOIN media ON media.fileId = deviceFace.fileId
                    WHERE deviceFace.clustered = 0 AND deviceFace.print IS NOT NULL
                    ORDER BY \(LibraryStore.timestamp), deviceFace.id LIMIT ?
                    """, arguments: [limit])
            return rows.compactMap { row in
                guard let data = row["print"] as Data? else { return nil }
                return (Self.face(row), Self.floats(data))
            }
        }
    }

    /// How many usable faces wait to be grouped.
    public func ungroupedCount() throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM deviceFace WHERE clustered = 0 AND print IS NOT NULL") ?? 0
        }
    }

    /// The people the grouping compares new faces with: everyone with two faces or more or a name, and the most recent
    /// `recentSingles` people of one face (older ones stay as they are: their faces are offered as unassigned faces).
    public func clusters(recentSingles: Int = 4000) throws -> [FaceClusterer.Cluster] {
        try database.writer.read { db in
            var files: [Int64: Set<FileID>] = [:]
            let faceRows = try Row.fetchCursor(db, sql: "SELECT personId, fileId FROM deviceFace WHERE personId IS NOT NULL")
            while let row = try faceRows.next() { files[row["personId"], default: []].insert(row["fileId"]) }
            var rejected: [Int64: Set<Int64>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT faceId, personId FROM deviceFaceRejection") {
                rejected[row["personId"], default: []].insert(row["faceId"])
            }
            let singles = Set(
                try Int64.fetchAll(
                    db, sql: "SELECT id FROM devicePerson WHERE faceCount = 1 AND name IS NULL ORDER BY id DESC LIMIT ?",
                    arguments: [recentSingles]))
            var result: [FaceClusterer.Cluster] = []
            for row in try Row.fetchAll(db, sql: "SELECT id, name, sum, faceCount FROM devicePerson WHERE faceCount > 0") {
                let id: Int64 = row["id"]
                let count: Int = row["faceCount"]
                let name: String? = row["name"]
                guard count >= 2 || name != nil || singles.contains(id), let data = row["sum"] as Data? else { continue }
                result.append(
                    FaceClusterer.Cluster(
                        id: id, sum: Self.floats(data), count: count, files: files[id] ?? [], rejected: rejected[id] ?? [], name: name))
            }
            return result
        }
    }

    /// Makes an empty person and returns their id.
    public func createPerson(name: String? = nil, syncId: String? = nil, at date: Date = Date()) throws -> Int64 {
        try database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO devicePerson(name, syncId, faceCount, updatedAt) VALUES (?, ?, 0, ?)",
                arguments: [name, syncId, date.timeIntervalSince1970])
            return db.lastInsertedRowID
        }
    }

    /// Writes what the grouping decided: faces to people (all of them marked grouped) and the people's sums.
    public func saveGrouping(assignments: [Int64: Int64?], grouped: [Int64], people: [FaceClusterer.Cluster], deleted: [Int64] = [])
        throws
    {
        try database.writer.write { db in
            for (faceId, personId) in assignments {
                try db.execute(sql: "UPDATE deviceFace SET personId = ? WHERE id = ?", arguments: [personId, faceId])
            }
            for start in stride(from: 0, to: grouped.count, by: 500) {
                let chunk = Array(grouped[start..<min(start + 500, grouped.count)])
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                try db.execute(sql: "UPDATE deviceFace SET clustered = 1 WHERE id IN (\(marks))", arguments: StatementArguments(chunk))
            }
            for person in people {
                try db.execute(
                    sql: "UPDATE devicePerson SET sum = ?, faceCount = ?, name = coalesce(?, name) WHERE id = ?",
                    arguments: [Self.data(floats: person.sum), person.count, person.name, person.id])
            }
            for id in deleted {
                try db.execute(sql: "UPDATE deviceFace SET personId = NULL WHERE personId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM devicePerson WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Moves every face of `from` to `into` (a merge), keeping the pins and the rejections. The kept person takes the
    /// other's name and shared id when they have none.
    public func mergePerson(_ from: Int64, into: Int64, sum: [Float], count: Int) throws {
        guard from != into else { return }
        try database.writer.write { db in
            let source = try Row.fetchOne(db, sql: "SELECT name, syncId FROM devicePerson WHERE id = ?", arguments: [from])
            try db.execute(sql: "UPDATE deviceFace SET personId = ? WHERE personId = ?", arguments: [into, from])
            try db.execute(
                sql: "INSERT OR IGNORE INTO deviceFaceRejection(faceId, personId) SELECT faceId, ? FROM deviceFaceRejection WHERE personId = ?",
                arguments: [into, from])
            try db.execute(sql: "DELETE FROM devicePerson WHERE id = ?", arguments: [from])
            try db.execute(
                sql: """
                    UPDATE devicePerson SET sum = ?, faceCount = ?, name = coalesce(name, ?), syncId = coalesce(syncId, ?) WHERE id = ?
                    """,
                arguments: [Self.data(floats: sum), count, source?["name"] as String?, source?["syncId"] as String?, into])
        }
    }

    /// Faces leave their person; with `reject` the user said they are not that person, so they never join them again.
    /// Returns their prints (to take off the person's sum).
    public func removeFaces(_ faceIds: [Int64], from personId: Int64, reject: Bool) throws {
        try database.writer.write { db in
            for faceId in faceIds {
                guard try Int64.fetchOne(db, sql: "SELECT personId FROM deviceFace WHERE id = ?", arguments: [faceId]) == personId else {
                    continue
                }
                try Self.subtract(db, faceId: faceId, from: personId)
                // Grouped: it is not offered to the same person again; it waits as an unassigned face.
                try db.execute(sql: "UPDATE deviceFace SET personId = NULL, pinned = 0, clustered = 1 WHERE id = ?", arguments: [faceId])
                if reject {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO deviceFaceRejection(faceId, personId) VALUES (?, ?)", arguments: [faceId, personId])
                }
            }
        }
    }

    /// Puts faces to a person for good (the user assigned them), taking them from whoever had them.
    public func assignFaces(_ faceIds: [Int64], to personId: Int64) throws {
        try database.writer.write { db in
            for faceId in faceIds {
                guard let row = try Row.fetchOne(db, sql: "SELECT personId, print FROM deviceFace WHERE id = ?", arguments: [faceId]) else {
                    continue
                }
                let previous: Int64? = row["personId"]
                if let previous, previous != personId { try Self.subtract(db, faceId: faceId, from: previous) }
                if previous != personId, let data = row["print"] as Data? {
                    let print = Self.floats(data)
                    let person = try Row.fetchOne(db, sql: "SELECT sum, faceCount FROM devicePerson WHERE id = ?", arguments: [personId])
                    var sum = (person?["sum"] as Data?).map(Self.floats) ?? []
                    if sum.count != print.count { sum = [Float](repeating: 0, count: print.count) }
                    for index in sum.indices { sum[index] += print[index] }
                    try db.execute(
                        sql: "UPDATE devicePerson SET sum = ?, faceCount = faceCount + 1 WHERE id = ?",
                        arguments: [Self.data(floats: sum), personId])
                }
                try db.execute(sql: "UPDATE deviceFace SET personId = ?, pinned = 1, clustered = 1 WHERE id = ?", arguments: [personId, faceId])
                try db.execute(sql: "DELETE FROM deviceFaceRejection WHERE faceId = ? AND personId = ?", arguments: [faceId, personId])
            }
        }
    }

    public func rename(_ personId: Int64, to name: String?, syncId: String?, at date: Date = Date()) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE devicePerson SET name = ?, syncId = coalesce(?, syncId), updatedAt = ? WHERE id = ?",
                arguments: [name, syncId, date.timeIntervalSince1970, personId])
        }
    }

    /// Removes a person: their faces are no one's and are not grouped again.
    public func deletePerson(_ personId: Int64) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE deviceFace SET personId = NULL, pinned = 0, clustered = 1 WHERE personId = ?", arguments: [personId])
            try db.execute(sql: "DELETE FROM devicePerson WHERE id = ?", arguments: [personId])
        }
    }

    // MARK: Reading

    static func face(_ row: Row) -> Face {
        Face(
            id: row["id"], fileId: row["fileId"],
            box: FaceBox(x: row["x"], y: row["y"], width: row["width"], height: row["height"]),
            quality: (row["quality"] as Double?).map { Float($0) }, personId: row["personId"], pinned: row["pinned"])
    }

    static func faces(_ db: Database, where condition: String, _ arguments: StatementArguments) throws -> [Face] {
        try Row.fetchAll(
            db, sql: "SELECT id, fileId, x, y, width, height, quality, personId, pinned FROM deviceFace WHERE \(condition)",
            arguments: arguments
        ).map(face)
    }

    /// The people to show: named ones, and unnamed ones with faces in at least `minimumPhotos` photos; most photos first.
    public func people(minimumPhotos: Int = FaceClustering.minimumPhotos) throws -> [PersonSummary] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT devicePerson.id, devicePerson.name, devicePerson.syncId, count(deviceFace.id) AS faces,
                        count(DISTINCT deviceFace.fileId) AS photos
                    FROM devicePerson JOIN deviceFace ON deviceFace.personId = devicePerson.id
                    JOIN media ON media.fileId = deviceFace.fileId AND \(LibraryStore.visible)
                    GROUP BY devicePerson.id
                    HAVING devicePerson.name IS NOT NULL OR count(DISTINCT deviceFace.fileId) >= ?
                    ORDER BY (devicePerson.name IS NULL), photos DESC, devicePerson.id
                    """, arguments: [minimumPhotos])
            return try rows.map { row in
                let id: Int64 = row["id"]
                // The clearest face is the cover.
                let cover = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT deviceFace.* FROM deviceFace JOIN media ON media.fileId = deviceFace.fileId AND \(LibraryStore.visible)
                        WHERE personId = ? ORDER BY pinned DESC, coalesce(quality, 0) * min(side, 200) DESC LIMIT 1
                        """, arguments: [id]
                ).map(Self.face)
                return PersonSummary(
                    id: id, name: row["name"], syncId: row["syncId"], faceCount: row["faces"], photoCount: row["photos"],
                    coverFileId: cover?.fileId, coverBox: cover?.box)
            }
        }
    }

    public func person(_ id: Int64) throws -> PersonSummary? {
        try people(minimumPhotos: 0).first { $0.id == id }
    }

    /// The person with this name (names are unique among the people of this device).
    public func personId(named name: String) throws -> Int64? {
        try database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM devicePerson WHERE name = ? COLLATE NOCASE", arguments: [name])
        }
    }

    /// The faces of a person with their photos, newest first.
    public func faces(ofPerson id: Int64) throws -> [(face: Face, item: MediaItem)] {
        try faceItems(where: "deviceFace.personId = ?", [id])
    }

    /// Faces that are no one's and clear enough to be someone: in no shown person, newest first.
    public func unassignedFaces(minimumPhotos: Int = FaceClustering.minimumPhotos, limit: Int = 2000) throws -> [(face: Face, item: MediaItem)] {
        let shown = try people(minimumPhotos: minimumPhotos).map(\.id)
        let marks = shown.isEmpty ? "-1" : shown.map(String.init).joined(separator: ",")
        return try faceItems(
            where: "deviceFace.print IS NOT NULL AND (deviceFace.personId IS NULL OR deviceFace.personId NOT IN (\(marks)))", [],
            limit: limit)
    }

    /// The faces found in one photo, left to right.
    public func faces(inFile fileId: FileID) throws -> [Face] {
        try database.writer.read { db in try Self.faces(db, where: "fileId = ? ORDER BY x", [fileId]) }
    }

    /// The prints of some faces.
    public func prints(of faceIds: [Int64]) throws -> [Int64: [Float]] {
        guard !faceIds.isEmpty else { return [:] }
        return try database.writer.read { db in
            var result: [Int64: [Float]] = [:]
            let marks = faceIds.map { _ in "?" }.joined(separator: ",")
            for row in try Row.fetchAll(
                db, sql: "SELECT id, print FROM deviceFace WHERE print IS NOT NULL AND id IN (\(marks))",
                arguments: StatementArguments(faceIds))
            {
                let data: Data = row["print"]
                result[row["id"]] = Self.floats(data)
            }
            return result
        }
    }

    /// Every stored face with its person (applying the shared names and assignments).
    public func allFaces() throws -> [Face] {
        try database.writer.read { db in try Self.faces(db, where: "1", []) }
    }

    /// Every person with their shared id and name.
    public func allPeople() throws -> [(id: Int64, syncId: String?, name: String?)] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT id, syncId, name FROM devicePerson").map { ($0["id"], $0["syncId"], $0["name"]) }
        }
    }

    public func setSyncId(_ syncId: String?, of personId: Int64) throws {
        try database.writer.write { db in
            if let syncId { try db.execute(sql: "UPDATE devicePerson SET syncId = NULL WHERE syncId = ? AND id <> ?", arguments: [syncId, personId]) }
            try db.execute(sql: "UPDATE devicePerson SET syncId = ? WHERE id = ?", arguments: [syncId, personId])
        }
    }

    func faceItems(where condition: String, _ arguments: StatementArguments, limit: Int = Int.max) throws -> [(face: Face, item: MediaItem)] {
        try database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT deviceFace.id AS faceId, deviceFace.x AS faceX, deviceFace.y AS faceY, deviceFace.width AS faceWidth,
                        deviceFace.height AS faceHeight, deviceFace.quality AS faceQuality, deviceFace.personId AS facePerson,
                        deviceFace.pinned AS facePinned, media.*
                    FROM deviceFace JOIN media ON media.fileId = deviceFace.fileId AND \(LibraryStore.visible)
                    WHERE \(condition) \(LibraryStore.displayOrder) LIMIT ?
                    """, arguments: arguments + [limit])
            return try rows.map { row in
                let face = Face(
                    id: row["faceId"], fileId: row["fileId"],
                    box: FaceBox(x: row["faceX"], y: row["faceY"], width: row["faceWidth"], height: row["faceHeight"]),
                    quality: (row["faceQuality"] as Double?).map { Float($0) }, personId: row["facePerson"], pinned: row["facePinned"])
                return (face, try MediaItem(row: row))
            }
        }
    }

    // MARK: Search, memories and the rest of the app

    /// Writes the named people into `person`/`personItem` (search, smart albums, memories, family), replacing what was
    /// written before. Only on servers without Recognize: there `LabelSync` owns these tables.
    public func mirrorNamedPeople() throws {
        try database.writer.write { db in
            try Self.removeMirror(db)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT devicePerson.name AS name, deviceFace.id AS faceId, deviceFace.fileId AS fileId, deviceFace.x AS x,
                        deviceFace.y AS y, deviceFace.width AS width, deviceFace.height AS height
                    FROM devicePerson JOIN deviceFace ON deviceFace.personId = devicePerson.id
                    WHERE devicePerson.name IS NOT NULL
                    """)
            var names: Set<String> = []
            for row in rows {
                let name: String = row["name"]
                if names.insert(name).inserted {
                    // A person of the server's with the same name (left over from Recognize) keeps theirs.
                    try db.execute(sql: "INSERT OR IGNORE INTO person(name, itemCount) VALUES (?, 0)", arguments: [name])
                }
                let box = FaceBox(x: row["x"], y: row["y"], width: row["width"], height: row["height"])
                let faceId: Int64 = row["faceId"]
                try db.execute(
                    sql: "INSERT OR IGNORE INTO personItem(person, detectionId, fileId, childName, box) VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        name, -faceId, row["fileId"] as FileID, "device-\(faceId)",
                        String(decoding: try JSONEncoder().encode(box), as: UTF8.self),
                    ])
            }
            try db.execute(
                sql: """
                    UPDATE person SET itemCount = (SELECT count(DISTINCT fileId) FROM personItem WHERE personItem.person = person.name)
                    WHERE name IN (SELECT DISTINCT person FROM personItem WHERE detectionId < 0)
                    """)
            try db.execute(
                sql: "INSERT OR REPLACE INTO syncState(key, value) VALUES (?, ?)",
                arguments: [Self.mirrorKey, String(decoding: try JSONEncoder().encode(names.sorted()), as: UTF8.self)])
        }
    }

    /// Takes the device's people out of `person`/`personItem` (the server has Recognize now, or the feature was turned off).
    public func removeMirror() throws {
        try database.writer.write { db in try Self.removeMirror(db) }
    }

    static let mirrorKey = "deviceFaceMirror"

    static func removeMirror(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM personItem WHERE detectionId < 0")
        let written = try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [mirrorKey])
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        for name in written {
            try db.execute(
                sql: "DELETE FROM person WHERE name = ? AND NOT EXISTS (SELECT 1 FROM personItem WHERE person = ?)", arguments: [name, name])
        }
        try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [mirrorKey])
    }

    /// Forgets every face and person (the user turned the feature off).
    public func deleteAll() throws {
        try database.writer.write { db in
            try Self.removeMirror(db)
            try db.execute(sql: "DELETE FROM deviceFaceRejection")
            try db.execute(sql: "DELETE FROM deviceFace")
            try db.execute(sql: "DELETE FROM devicePerson")
            try db.execute(sql: "DELETE FROM deviceFaceScan")
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [Self.meanKey])
        }
    }

    // MARK: Encoding

    static func data(floats: [Float]) -> Data { SimilarityStore.data(floats: floats) }
    static func floats(_ data: Data) -> [Float] { SimilarityStore.floats(data) }
}

extension AccountDatabase {
    /// A sync value read inside a transaction.
    func syncValue(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [key])
    }
}

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import OSLog
import PhotosDomain
import PhotosModel
import PhotosStore

/// Looks for faces in the library's cached previews, a batch at a time, in the background (SPEC §22.3).
///
/// The small tile every photo has (256) says whether a photo shows anyone at all; most do not, and are done with that.
/// A photo with faces is analysed on its 1024 preview: the cached one, else (only when `fetchPreview` is given: an
/// unconstrained network) one asked from the server for the analysis and not kept. What is found is stored per version of
/// the photo (`DeviceFaceStore`), so a run can stop at any time and the next one goes on where it stopped.
public struct FaceIndexer: Sendable {
    let store: DeviceFaceStore
    let cache: PreviewCache
    /// The 1024 preview of a photo from the server, when the network allows it; nil: only cached previews are used.
    let fetchPreview: (@Sendable (FileID, String) async -> Data?)?
    /// Vision's work (`FaceAnalysis`); tests give their own.
    let analyze: @Sendable (CGImage) async throws -> [DeviceFaceStore.FoundFace]
    let detect: @Sendable (CGImage) async throws -> Bool
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "faces")

    public init(
        database: AccountDatabase, cache: PreviewCache, fetchPreview: (@Sendable (FileID, String) async -> Data?)? = nil,
        analyze: @escaping @Sendable (CGImage) async throws -> [DeviceFaceStore.FoundFace] = FaceAnalysis.analyze,
        detect: @escaping @Sendable (CGImage) async throws -> Bool = FaceAnalysis.hasFaces
    ) {
        store = DeviceFaceStore(database: database)
        self.cache = cache
        self.fetchPreview = fetchPreview
        self.analyze = analyze
        self.detect = detect
    }

    /// Looks at photos until there are none left or `shouldContinue` says stop. Returns how many photos were looked at.
    @discardableResult
    public func run(batchSize: Int = 24, pause: Duration = .zero, shouldContinue: @escaping @Sendable () -> Bool = { true }) async throws
        -> Int
    {
        var cursor: FileID?
        var scanned = 0
        var failures = 0
        var mean = try store.mean()
        let started = ContinuousClock.now
        while shouldContinue(), !Task.isCancelled, failures < 3 {
            let batch = try store.candidates(limit: batchSize, before: cursor)
            guard let last = batch.last else { break }
            cursor = last.fileId
            var did = 0
            for candidate in batch {
                guard shouldContinue(), !Task.isCancelled, failures < 3 else { break }
                do {
                    guard let faces = try await faces(in: candidate) else { continue }
                    try store.save(candidate, faces: faces)
                    for face in faces { if let print = face.print { mean.add(print) } }
                    did += 1
                } catch is FaceAnalysis.SimulatorUnsupported {
                    return scanned
                } catch {
                    logger.error("faces of \(candidate.fileId) failed: \(error.localizedDescription, privacy: .public)")
                    failures += 1
                }
            }
            if did > 0 { try store.saveMean(mean) }
            scanned += did
            if pause > .zero, did > 0 { try? await Task.sleep(for: pause) } else { await Task.yield() }
        }
        if scanned > 0 {
            let elapsed = ContinuousClock.now - started
            let perPhoto = elapsed / scanned
            logger.info("looked at \(scanned) photos for faces, \(perPhoto, privacy: .public) per photo")
        }
        return scanned
    }

    /// The faces of a photo; nil when it cannot be looked at now (no cached preview, or a preview it needs is not there).
    func faces(in candidate: DeviceFaceStore.Candidate) async throws -> [DeviceFaceStore.FoundFace]? {
        let size = FaceAnalysis.analysisBucket
        if let url = cache.cachedPreviewURL(fileId: candidate.fileId, etag: candidate.etag, buckets: [size]) {
            guard let image = ImageDecoding.decode(url: url, maxPixelSize: size) else { return [] }
            return try await analyze(image)
        }
        guard
            let url = cache.cachedPreviewURL(
                fileId: candidate.fileId, etag: candidate.etag, buckets: [FaceAnalysis.detectionBucket, 512])
        else { return nil }
        guard let tile = ImageDecoding.decode(url: url, maxPixelSize: FaceAnalysis.detectionBucket) else { return [] }
        guard try await detect(tile) else { return [] }
        guard let fetchPreview, let data = await fetchPreview(candidate.fileId, candidate.etag),
            let image = ImageDecoding.decode(data: data, maxPixelSize: size)
        else { return nil }
        return try await analyze(image)
    }
}

/// Groups the faces found into people and carries out what the user says about them (SPEC §22.3), keeping this device's
/// people and the shared names and assignments (`DevicePeopleNames`) in step.
public actor DevicePeopleEngine {
    let store: DeviceFaceStore
    let names: any DevicePeopleNames
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "faces")
    /// Faces needed before grouping starts, so the mean they are compared around means something (fewer when the whole
    /// library has fewer).
    static let bootstrapFaces = 100

    public init(database: AccountDatabase, names: any DevicePeopleNames) {
        store = DeviceFaceStore(database: database)
        self.names = names
    }

    // MARK: Grouping

    /// Groups the faces that are not grouped yet, then merges people who turned out to be one. Returns how many faces
    /// were grouped.
    /// - Parameter scanFinished: every photo has been looked at (grouping may start with fewer faces than usual).
    @discardableResult
    public func group(scanFinished: Bool, shouldContinue: @Sendable () -> Bool = { true }) async throws -> Int {
        let mean = try store.mean()
        guard mean.count >= Self.bootstrapFaces || (scanFinished && mean.count >= 2) else { return 0 }
        var clusterer = FaceClusterer(clusters: try store.clusters(), mean: mean.mean)
        var grouped = 0
        var touched = Set<Int64>()
        while shouldContinue(), !Task.isCancelled {
            let batch = try store.ungrouped(limit: 500)
            guard !batch.isEmpty else { break }
            var assignments: [Int64: Int64?] = [:]
            for (face, print) in batch {
                let id: Int64
                if let match = clusterer.bestMatch(for: print, fileId: face.fileId, faceId: face.id) {
                    id = match.id
                } else {
                    id = try store.createPerson()
                }
                clusterer.add(print, fileId: face.fileId, to: id)
                assignments[face.id] = id
                touched.insert(id)
            }
            try store.saveGrouping(
                assignments: assignments, grouped: batch.map(\.face.id), people: touched.compactMap { clusterer.clusters[$0] })
            grouped += batch.count
        }
        guard !touched.isEmpty else { return grouped }
        let before = try store.allPeople()
        let syncIds = Dictionary(before.map { ($0.id, $0.syncId) }, uniquingKeysWith: { first, _ in first })
        var documentMerges: [(String, String)] = []
        for merge in clusterer.consolidate(touched: touched) {
            guard let kept = clusterer.clusters[merge.keep] else { continue }
            if let from = syncIds[merge.merge] ?? nil, let into = syncIds[merge.keep] ?? nil { documentMerges.append((from, into)) }
            try store.mergePerson(merge.merge, into: merge.keep, sum: kept.sum, count: kept.count)
        }
        if !documentMerges.isEmpty {
            let merges = documentMerges
            let time = Date().timeIntervalSince1970
            try await names.update { document in for (from, into) in merges { document.merge(from, into: into, at: time) } }
        }
        logger.info("grouped \(grouped) faces")
        return grouped
    }

    // MARK: What the user says

    /// The faces of a person to share with their name, so other devices can find them: the pinned ones and the clearest.
    func anchors(of personId: Int64, at time: Double) throws -> [DevicePeopleDocument.FaceRef] {
        let faces = try store.faces(ofPerson: personId).map(\.face)
        let chosen = faces.sorted { ($0.pinned ? 1 : 0, $0.quality ?? 0) > ($1.pinned ? 1 : 0, $1.quality ?? 0) }
            .prefix(DevicePeopleDocument.anchorsPerPerson)
        return chosen.map { DevicePeopleDocument.FaceRef(fileId: $0.fileId, box: $0.box, at: time) }
    }

    /// The person's id in the shared document, made (with the faces that find them) when they have none yet.
    func sharedId(of personId: Int64, name: String?, at time: Double) async throws -> String {
        if let known = try store.allPeople().first(where: { $0.id == personId })?.syncId { return known }
        let id = UUID().uuidString
        try store.setSyncId(id, of: personId)
        let anchors = try anchors(of: personId, at: time)
        try await names.update { document in
            var person = DevicePeopleDocument.Person(name: name, updatedAt: time, faces: anchors)
            if let existing = document.people[id] { person = existing }
            document.people[id] = person
        }
        return id
    }

    public func rename(_ personId: Int64, to name: String, at date: Date = Date()) async throws {
        let time = date.timeIntervalSince1970
        let id = try await sharedId(of: personId, name: name, at: time)
        try store.rename(personId, to: name, syncId: id, at: date)
        let anchors = try anchors(of: personId, at: time)
        try await names.update { $0.name(id, name, anchors: anchors, at: time) }
    }

    /// A new, empty person with a name (to assign faces to).
    public func create(named name: String, at date: Date = Date()) async throws -> Int64 {
        let time = date.timeIntervalSince1970
        let id = UUID().uuidString
        let personId = try store.createPerson(name: name, syncId: id, at: date)
        try await names.update { $0.name(id, name, anchors: [], at: time) }
        return personId
    }

    public func assign(_ faceIds: [Int64], to personId: Int64, at date: Date = Date()) async throws {
        let time = date.timeIntervalSince1970
        let faces = try store.allFaces().filter { faceIds.contains($0.id) }
        try store.assignFaces(faceIds, to: personId)
        let name = try store.allPeople().first { $0.id == personId }?.name
        let id = try await sharedId(of: personId, name: name, at: time)
        let refs = faces.map { DevicePeopleDocument.FaceRef(fileId: $0.fileId, box: $0.box, at: time) }
        try await names.update { $0.assign(refs, to: id, at: time) }
    }

    /// "Not this person".
    public func reject(_ faceIds: [Int64], from personId: Int64, at date: Date = Date()) async throws {
        let time = date.timeIntervalSince1970
        let faces = try store.allFaces().filter { faceIds.contains($0.id) }
        try store.removeFaces(faceIds, from: personId, reject: true)
        guard let id = try store.allPeople().first(where: { $0.id == personId })?.syncId else { return }
        let refs = faces.map { DevicePeopleDocument.FaceRef(fileId: $0.fileId, box: $0.box, at: time) }
        try await names.update { $0.reject(refs, from: id, at: time) }
    }

    /// Moves faces to another person ("Move to another person…"): not the old one, the new one.
    public func move(_ faceIds: [Int64], from personId: Int64?, to target: Int64, at date: Date = Date()) async throws {
        if let personId { try await reject(faceIds, from: personId, at: date) }
        try await assign(faceIds, to: target, at: date)
    }

    public func merge(_ personId: Int64, into target: Int64, at date: Date = Date()) async throws {
        guard personId != target else { return }
        let time = date.timeIntervalSince1970
        let people = try store.allPeople()
        let from = people.first { $0.id == personId }
        let into = people.first { $0.id == target }
        let fromShared = from?.syncId
        // The person kept takes the other's name when they have none.
        let name = into?.name ?? from?.name
        let sums = try store.clusters(recentSingles: Int.max)
        let a = sums.first { $0.id == personId }
        let b = sums.first { $0.id == target }
        var sum = b?.sum ?? a?.sum ?? []
        if let a, sum.count == a.sum.count, b != nil { for index in sum.indices { sum[index] += a.sum[index] } }
        try store.mergePerson(personId, into: target, sum: sum, count: (a?.count ?? 0) + (b?.count ?? 0))
        let intoShared = try await sharedId(of: target, name: name, at: time)
        if let name, into?.name == nil { try store.rename(target, to: name, syncId: intoShared, at: date) }
        let anchors = try anchors(of: target, at: time)
        try await names.update { document in
            if let name { document.name(intoShared, name, anchors: anchors, at: time) }
            if let fromShared { document.merge(fromShared, into: intoShared, at: time) }
        }
    }

    public func delete(_ personId: Int64, at date: Date = Date()) async throws {
        let shared = try store.allPeople().first { $0.id == personId }?.syncId
        try store.deletePerson(personId)
        if let shared {
            let time = date.timeIntervalSince1970
            try await names.update { $0.delete(shared, at: time) }
        }
    }

    // MARK: The shared names and assignments

    /// Brings this device's people in line with the shared document: names, faces assigned or rejected on another
    /// device, people merged or removed there. Returns whether anything changed.
    @discardableResult
    public func applySharedNames() async throws -> Bool {
        let document = try await names.load()
        return try apply(document)
    }

    func apply(_ document: DevicePeopleDocument) throws -> Bool {
        var changed = false
        var people = try store.allPeople()
        let faces = try store.allFaces()
        func personId(shared key: String) -> Int64? { people.first { $0.syncId == key }?.id }
        for (key, entry) in document.people.sorted(by: { $0.key < $1.key }) where !entry.deleted && entry.mergedInto == nil {
            let theirs = faces.filter { entry.says($0.fileId, $0.box) == true }
            var target = personId(shared: key)
            if target == nil {
                // The group of this device that has most of their faces, if it is no one else's yet.
                var votes: [Int64: Int] = [:]
                for face in theirs {
                    if let id = face.personId, people.first(where: { $0.id == id })?.syncId == nil { votes[id, default: 0] += 1 }
                }
                if let best = votes.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) })?.key {
                    try store.setSyncId(key, of: best)
                    target = best
                } else if !theirs.isEmpty {
                    target = try store.createPerson(name: entry.name, syncId: key)
                } else {
                    continue
                }
                changed = true
                people = try store.allPeople()
            }
            guard let target else { continue }
            if let name = entry.name, people.first(where: { $0.id == target })?.name != name {
                try store.rename(target, to: name, syncId: key)
                changed = true
            }
            let moving = theirs.filter { $0.personId != target || !$0.pinned }.map(\.id)
            if !moving.isEmpty {
                try store.assignFaces(moving, to: target)
                changed = true
            }
            let leaving = faces.filter { $0.personId == target && entry.says($0.fileId, $0.box) == false }.map(\.id)
            if !leaving.isEmpty {
                try store.removeFaces(leaving, from: target, reject: true)
                changed = true
            }
        }
        // Removed or merged on another device.
        for (key, entry) in document.people where entry.deleted || entry.mergedInto != nil {
            guard let local = personId(shared: key) else { continue }
            if let into = document.resolved(key), let target = personId(shared: into), target != local {
                let sums = try store.clusters(recentSingles: Int.max)
                let a = sums.first { $0.id == local }
                let b = sums.first { $0.id == target }
                var sum = b?.sum ?? []
                if let a, sum.count == a.sum.count { for index in sum.indices { sum[index] += a.sum[index] } }
                try store.mergePerson(local, into: target, sum: sum, count: (a?.count ?? 0) + (b?.count ?? 0))
            } else {
                try store.deletePerson(local)
            }
            changed = true
            people = try store.allPeople()
        }
        return changed
    }
}

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

/// Synthetic face prints: what all faces share, what one person's faces share, and noise (SPEC §22.3).
struct SyntheticFaces {
    var state: UInt64
    let dimensions: Int
    var common: [Float] = []
    var identities: [[Float]] = []

    init(seed: UInt64 = 42, dimensions: Int = 768, people: Int = 6) {
        state = seed
        self.dimensions = dimensions
        common = vector()
        identities = (0..<people).map { _ in vector() }
    }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }

    /// A random unit vector.
    mutating func vector() -> [Float] {
        FaceClustering.normalized((0..<dimensions).map { _ in Float(next() * 2 - 1) })
    }

    /// A face of person `index`: mostly what all faces share, some of the person, a little noise.
    mutating func face(of index: Int, noise: Float = 0.25) -> [Float] {
        let own = identities[index]
        let random = vector()
        return FaceClustering.normalized((0..<dimensions).map { common[$0] + 0.6 * own[$0] + noise * random[$0] })
    }
}

@Suite struct FaceClusteringTests {
    @Test func facesOfOnePersonGoTogetherAndOthersApart() {
        var faces = SyntheticFaces()
        var mean = FacePrintMean()
        var samples: [(person: Int, print: [Float], file: FileID)] = []
        for round in 0..<8 {
            for person in 0..<6 {
                let print = faces.face(of: person)
                samples.append((person, print, FileID(round * 10 + person)))
                mean.add(print)
            }
        }
        var clusterer = FaceClusterer(mean: mean.mean)
        var next: Int64 = 1
        var assigned: [Int: Set<Int64>] = [:]
        for sample in samples {
            let id = clusterer.bestMatch(for: sample.print, fileId: sample.file)?.id ?? next
            if id == next { next += 1 }
            clusterer.add(sample.print, fileId: sample.file, to: id)
            assigned[sample.person, default: []].insert(id)
        }
        // Each person in one group, no group shared by two people.
        for person in 0..<6 { #expect(assigned[person]?.count == 1) }
        #expect(Set(assigned.values.flatMap { $0 }).count == 6)
    }

    @Test func aSecondFaceInThePhotoIsSomeoneElseAndRejectionsHold() {
        var faces = SyntheticFaces()
        var mean = FacePrintMean()
        let prints = (0..<4).map { _ in faces.face(of: 0, noise: 0.15) } + (0..<4).map { _ in faces.face(of: 1, noise: 0.15) }
        for person in 2..<6 { mean.add(faces.face(of: person)) }
        for print in prints { mean.add(print) }
        var clusterer = FaceClusterer(mean: mean.mean)
        clusterer.add(prints[0], fileId: 1, to: 1)
        clusterer.add(prints[1], fileId: 2, to: 1)
        // The same person again, but in photo 1, which already has their face: not them (a mirror, a poster…).
        #expect(clusterer.bestMatch(for: prints[2], fileId: 1) == nil)
        #expect(clusterer.bestMatch(for: prints[2], fileId: 3)?.id == 1)
        // The user said face 77 is not person 1.
        clusterer.remove(prints[1], fileId: 2, faceId: 77, from: 1, rejected: true)
        #expect(clusterer.bestMatch(for: prints[1], fileId: 2, faceId: 77) == nil)
        #expect(clusterer.bestMatch(for: prints[1], fileId: 2, faceId: 78)?.id == 1)
        // Someone else never joins.
        #expect(clusterer.bestMatch(for: prints[5], fileId: 9) == nil)
    }

    @Test func peopleThatAreOneAreMergedButNamesAreNeverMixed() {
        var faces = SyntheticFaces()
        var mean = FacePrintMean()
        let anna = (0..<6).map { _ in faces.face(of: 0, noise: 0.15) }
        let ben = (0..<3).map { _ in faces.face(of: 1, noise: 0.15) }
        for print in anna + ben { mean.add(print) }
        var clusterer = FaceClusterer(mean: mean.mean)
        // Anna in two groups (e.g. found before the mean settled), Ben in a third.
        for (index, print) in anna.enumerated() { clusterer.add(print, fileId: FileID(index), to: index < 3 ? 1 : 2) }
        for (index, print) in ben.enumerated() { clusterer.add(print, fileId: FileID(100 + index), to: 3) }
        clusterer.rename(1, to: "Anna")
        let merges = clusterer.consolidate()
        #expect(merges.count == 1)
        #expect(merges.first?.keep == 1)
        #expect(clusterer.clusters[1]?.count == 6)
        #expect(clusterer.clusters[2] == nil)
        #expect(clusterer.clusters[3]?.count == 3)

        // Two groups of one person with different names stay apart (the user said so).
        var named = FaceClusterer(mean: mean.mean)
        for (index, print) in anna.enumerated() { named.add(print, fileId: FileID(index), to: index < 3 ? 1 : 2) }
        named.rename(1, to: "Anna")
        named.rename(2, to: "Hanna")
        #expect(named.consolidate().isEmpty)
        // Nor are two groups merged that have faces in one photo.
        var together = FaceClusterer(mean: mean.mean)
        for (index, print) in anna.enumerated() { together.add(print, fileId: FileID(index % 3), to: index < 3 ? 1 : 2) }
        #expect(together.consolidate().isEmpty)
    }

    @Test func onlyChangedPeopleAreComparedAndMeansAreKept() {
        var faces = SyntheticFaces()
        var mean = FacePrintMean()
        let prints = (0..<4).map { _ in faces.face(of: 2, noise: 0.15) }
        for print in prints { mean.add(print) }
        // The mean is of the whole library: other people too.
        for person in [0, 1, 3, 4, 5] { mean.add(faces.face(of: person)) }
        #expect(mean.count == 9)
        #expect(mean.mean.count == 768)
        var clusterer = FaceClusterer(mean: mean.mean)
        for (index, print) in prints.enumerated() { clusterer.add(print, fileId: FileID(index), to: Int64(index + 1)) }
        // Nothing touched: nothing compared.
        #expect(clusterer.mergeCandidates(touched: []).isEmpty)
        #expect(!clusterer.mergeCandidates(touched: [1]).isEmpty)
        clusterer.consolidate(touched: [1])
        #expect(clusterer.clusters.count == 1)
    }

    @Test func boxesOfTheSameFaceOverlap() {
        let box = FaceBox(x: 0.2, y: 0.3, width: 0.1, height: 0.12)
        let found = FaceBox(x: 0.205, y: 0.298, width: 0.098, height: 0.121)
        #expect(FaceClustering.overlap(box, found) > 0.85)
        #expect(FaceClustering.overlap(box, FaceBox(x: 0.5, y: 0.3, width: 0.1, height: 0.12)) == 0)
        #expect(FaceClustering.isUsable(quality: 0.5, sideInPixels: 80))
        #expect(!FaceClustering.isUsable(quality: 0.1, sideInPixels: 200))
        #expect(!FaceClustering.isUsable(quality: 0.9, sideInPixels: 20))
        #expect(!FaceClustering.isUsable(quality: nil, sideInPixels: 200))
    }
}

/// The names and assignments shared between the user's devices (`.nextcloud-photos/people.json`).
@Suite struct DevicePeopleDocumentTests {
    let face = FaceBox(x: 0.2, y: 0.3, width: 0.1, height: 0.12)
    let sameFace = FaceBox(x: 0.201, y: 0.302, width: 0.099, height: 0.119)

    @Test func theNewerNameWinsAndNoFaceIsLost() {
        var phone = DevicePeopleDocument()
        let id = phone.name(nil, "Anna", anchors: [.init(fileId: 1, box: face, at: 10)], at: 10)
        var mac = phone
        // Renamed on the Mac later, a face added on the phone meanwhile.
        mac.name(id, "Anna Schmidt", anchors: [], at: 20)
        phone.assign([.init(fileId: 2, box: face, at: 15)], to: id, at: 15)
        let merged = phone.merged(with: mac)
        #expect(merged.people[id]?.name == "Anna Schmidt")
        #expect(merged.people[id]?.faces.count == 2)
        // The same both ways round.
        #expect(mac.merged(with: phone).people[id]?.name == "Anna Schmidt")
        #expect(mac.merged(with: phone).people[id]?.faces.count == 2)
    }

    @Test func aFaceSaidBothWaysKeepsTheNewerWord() {
        var document = DevicePeopleDocument()
        let id = document.name(nil, "Ben", anchors: [.init(fileId: 1, box: face, at: 1)], at: 1)
        #expect(document.people[id]?.says(1, sameFace) == true)
        document.reject([.init(fileId: 1, box: sameFace, at: 5)], from: id, at: 5)
        #expect(document.people[id]?.says(1, face) == false)
        document.assign([.init(fileId: 1, box: face, at: 9)], to: id, at: 9)
        #expect(document.people[id]?.says(1, face) == true)
        #expect(document.people[id]?.says(2, face) == nil)
        // A face assigned to someone else leaves the first person.
        let other = document.name(nil, "Carla", anchors: [], at: 10)
        document.assign([.init(fileId: 1, box: face, at: 11)], to: other, at: 11)
        #expect(document.people[id]?.says(1, face) == nil)
        #expect(document.people[other]?.says(1, face) == true)
    }

    @Test func mergesAndDeletionsResolve() {
        var document = DevicePeopleDocument()
        let a = document.name(nil, "Anna", anchors: [.init(fileId: 1, box: face, at: 1)], at: 1)
        let b = document.name(nil, "Anna S.", anchors: [.init(fileId: 2, box: face, at: 1)], at: 1)
        let c = document.name(nil, "Carl", anchors: [], at: 1)
        document.merge(b, into: a, at: 2)
        #expect(document.resolved(b) == a)
        #expect(document.people[a]?.faces.count == 2)
        #expect(document.activePeople.keys.sorted() == [a, c].sorted())
        document.delete(c, at: 3)
        #expect(document.resolved(c) == nil)
        #expect(document.activePeople.count == 1)
    }

    @Test func readsWhatAnotherVersionWrote() throws {
        // A newer app may write more; an older document may leave fields out.
        let json = """
            {"version": 2, "people": {"p1": {"name": "Anna", "faces": [{"fileId": 5, "box": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2}, "at": 3}], "colour": "red"}}}
            """
        let document = try JSONDecoder().decode(DevicePeopleDocument.self, from: Data(json.utf8))
        #expect(document.version == 2)
        #expect(document.people["p1"]?.name == "Anna")
        #expect(document.people["p1"]?.updatedAt == 0)
        #expect(document.people["p1"]?.rejected.isEmpty == true)
        let again = try JSONDecoder().decode(DevicePeopleDocument.self, from: try JSONEncoder().encode(document))
        #expect(again == document)
    }
}

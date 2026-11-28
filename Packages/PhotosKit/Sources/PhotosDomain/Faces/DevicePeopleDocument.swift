// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// The names and assignments of the people found on the user's devices (SPEC §22.3), as they are shared between the
/// devices: `.nextcloud-photos/people.json` (one JSON file per kind, SPEC §22.5).
///
/// Each device finds faces and groups them by itself; what it shares is what only the user can say: who someone is
/// (a name), which faces are theirs (faces the user assigned, and some of the faces they had when named, so another
/// device can find the same person among its own groups) and which are not. A face is its photo's file id and its box,
/// which every device finds again in the same place on the same preview.
public struct DevicePeopleDocument: Codable, Equatable, Sendable {
    public static let fileName = "people.json"
    public static let currentVersion = 1
    /// How many faces of a person are written when they are named (the clearest ones).
    public static let anchorsPerPerson = 24

    public var version: Int
    /// People by a random id that stays theirs on every device.
    public var people: [String: Person]

    public init(version: Int = Self.currentVersion, people: [String: Person] = [:]) {
        self.version = version
        self.people = people
    }

    /// A face, with when the user said something about it.
    public struct FaceRef: Codable, Hashable, Sendable {
        public var fileId: FileID
        /// Normalized, top-left origin, rounded to 1/1000.
        public var box: FaceBox
        /// Seconds since 1970.
        public var at: Double

        public init(fileId: FileID, box: FaceBox, at: Double) {
            self.fileId = fileId
            self.box = Self.rounded(box)
            self.at = at
        }

        static func rounded(_ box: FaceBox) -> FaceBox {
            func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
            return FaceBox(x: round(box.x), y: round(box.y), width: round(box.width), height: round(box.height))
        }

        /// The same face: the same photo and boxes that overlap by more than half.
        public func isSameFace(_ fileId: FileID, _ box: FaceBox) -> Bool {
            self.fileId == fileId && FaceClustering.overlap(self.box, box) > FaceClustering.sameFaceOverlap
        }
    }

    public struct Person: Codable, Equatable, Sendable {
        public var name: String?
        /// When the name, `deleted` or `mergedInto` last changed (seconds since 1970): the newest wins.
        public var updatedAt: Double
        /// Removed by the user: their faces are no one's.
        public var deleted: Bool
        /// Put together with this person (the id of the other one).
        public var mergedInto: String?
        /// Faces that are this person.
        public var faces: [FaceRef]
        /// Faces that are not this person ("Not this person").
        public var rejected: [FaceRef]

        public init(
            name: String? = nil, updatedAt: Double, deleted: Bool = false, mergedInto: String? = nil, faces: [FaceRef] = [],
            rejected: [FaceRef] = []
        ) {
            self.name = name
            self.updatedAt = updatedAt
            self.deleted = deleted
            self.mergedInto = mergedInto
            self.faces = faces
            self.rejected = rejected
        }

        enum CodingKeys: String, CodingKey {
            case name, updatedAt, deleted, mergedInto, faces, rejected
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            updatedAt = try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
            deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
            mergedInto = try container.decodeIfPresent(String.self, forKey: .mergedInto)
            faces = try container.decodeIfPresent([FaceRef].self, forKey: .faces) ?? []
            rejected = try container.decodeIfPresent([FaceRef].self, forKey: .rejected) ?? []
        }

        /// Whether the user said this face is the person (true), is not (false), or nothing (nil): the newest word wins.
        public func says(_ fileId: FileID, _ box: FaceBox) -> Bool? {
            let yes = faces.filter { $0.isSameFace(fileId, box) }.map(\.at).max()
            let no = rejected.filter { $0.isSameFace(fileId, box) }.map(\.at).max()
            switch (yes, no) {
            case (nil, nil): return nil
            case (_?, nil): return true
            case (nil, _?): return false
            case (let yes?, let no?): return yes > no
            }
        }
    }

    /// The people that are still in use: not deleted, not merged into someone else.
    public var activePeople: [String: Person] {
        people.filter { !$0.value.deleted && $0.value.mergedInto == nil }
    }

    /// Where a person ended up after merges (itself when not merged; nil when that person was deleted).
    public func resolved(_ id: String) -> String? {
        var current = id
        var seen: Set<String> = []
        while let person = people[current], let next = person.mergedInto, seen.insert(current).inserted {
            current = next
        }
        return people[current]?.deleted == true ? nil : current
    }

    // MARK: Merging two versions

    /// This version and another one (another device's, read from the server) in one: per person the newer name,
    /// deletion and merge win; faces and rejections of both are kept, a face said both ways keeps the newer word. Nothing
    /// a device wrote is lost: a name is only replaced by a newer one.
    public func merged(with other: DevicePeopleDocument) -> DevicePeopleDocument {
        var result = DevicePeopleDocument(version: max(version, other.version), people: people)
        for (id, theirs) in other.people {
            guard let ours = result.people[id] else {
                result.people[id] = theirs
                continue
            }
            var person = ours.updatedAt >= theirs.updatedAt ? ours : theirs
            person.faces = Self.union(ours.faces, theirs.faces)
            person.rejected = Self.union(ours.rejected, theirs.rejected)
            result.people[id] = person
        }
        return result
    }

    /// Both lists, one entry per face with its newest time.
    static func union(_ a: [FaceRef], _ b: [FaceRef]) -> [FaceRef] {
        var result: [FaceRef] = []
        for ref in (a + b).sorted(by: { ($0.fileId, -$0.at) < ($1.fileId, -$1.at) }) {
            if !result.contains(where: { $0.isSameFace(ref.fileId, ref.box) }) { result.append(ref) }
        }
        return result
    }

    // MARK: Changes the user makes

    /// Names a person (a new id when `id` is nil), with the faces that let other devices find them.
    @discardableResult
    public mutating func name(_ id: String?, _ name: String, anchors: [FaceRef], at time: Double) -> String {
        let key = id ?? UUID().uuidString
        var person = people[key] ?? Person(updatedAt: time)
        person.name = name
        person.updatedAt = time
        person.deleted = false
        person.mergedInto = nil
        person.faces = Self.union(person.faces, anchors)
        people[key] = person
        return key
    }

    /// The user put faces to this person.
    public mutating func assign(_ faces: [FaceRef], to id: String, at time: Double) {
        var person = people[id] ?? Person(updatedAt: time)
        let stamped = faces.map { FaceRef(fileId: $0.fileId, box: $0.box, at: time) }
        person.faces = Self.union(stamped, person.faces)
        // Said again, newer: a face that was rejected before is theirs now.
        person.rejected.removeAll { ref in stamped.contains { $0.isSameFace(ref.fileId, ref.box) } }
        people[id] = person
        for other in people.keys where other != id {
            people[other]?.faces.removeAll { ref in stamped.contains { $0.isSameFace(ref.fileId, ref.box) } }
        }
    }

    /// The user said these faces are not this person.
    public mutating func reject(_ faces: [FaceRef], from id: String, at time: Double) {
        guard var person = people[id] else { return }
        let stamped = faces.map { FaceRef(fileId: $0.fileId, box: $0.box, at: time) }
        person.rejected = Self.union(stamped, person.rejected)
        person.faces.removeAll { ref in stamped.contains { $0.isSameFace(ref.fileId, ref.box) } }
        people[id] = person
    }

    public mutating func merge(_ id: String, into target: String, at time: Double) {
        guard id != target, var person = people[id], var into = people[target] else { return }
        into.faces = Self.union(into.faces, person.faces)
        into.rejected = Self.union(into.rejected, person.rejected)
        people[target] = into
        person.mergedInto = target
        person.updatedAt = time
        people[id] = person
    }

    public mutating func delete(_ id: String, at time: Double) {
        guard var person = people[id] else { return }
        person.deleted = true
        person.updatedAt = time
        people[id] = person
    }
}

/// Where the names and assignments of People on this device are kept and shared (SPEC §22.3, §22.5).
///
/// The app shares them through `.nextcloud-photos/people.json`, one record per person merged with
/// `DevicePeopleDocument.merged` (`SyncedDevicePeopleNames` in PhotosCore, SPEC §22.5); `LocalDevicePeopleNames` keeps
/// them on this device only.
public protocol DevicePeopleNames: Sendable {
    /// The current document (the shared one merged with this device's changes).
    func load() async throws -> DevicePeopleDocument
    /// Applies a change and stores it (and shares it); returns the document after the change.
    @discardableResult
    func update(_ change: @Sendable (inout DevicePeopleDocument) -> Void) async throws -> DevicePeopleDocument
}

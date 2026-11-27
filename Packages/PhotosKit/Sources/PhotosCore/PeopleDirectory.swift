// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore

/// Where the People screens get people from (SPEC §7.9, §22.3): Recognize on the server when it has it, else the people
/// found on this device. Both speak Recognize's language: a person is their name (an unnamed one a number), a photo of
/// them is a face with a child name, and the same actions work on both.
public protocol PeopleDirectory: Sendable {
    /// The people are found on this device (and nothing goes to the server).
    var isOnDevice: Bool { get }
    func people() async throws -> [Person]
    /// The faces of a person, or the faces of no one (`nil`: "Unassigned faces").
    func photos(of person: String?) async throws -> [PersonPhoto]
    func rename(_ person: String, to name: String) async throws
    func create(_ name: String) async throws
    func delete(_ person: String) async throws
    /// "Not this person".
    func remove(_ childNames: [String], from person: String) async throws
    /// To another person; `from == nil` assigns faces of no one.
    func move(_ childNames: [String], from person: String?, to target: String) async throws
    func merge(_ person: String, into target: String) async throws
    /// The named people in a photo, left to right (info panel, VoiceOver).
    func faces(in item: MediaItem) async throws -> [FaceDetection]
}

extension PeopleDirectory {
    /// The files a person is in (search).
    public func fileIds(of person: String) async throws -> [FileID] {
        try await photos(of: person).map(\.item.fileId)
    }
}

/// Recognize's people on the server.
public struct RecognizePeopleDirectory: PeopleDirectory {
    let api: PhotosAPI
    /// The Recognize API key, fetched when needed.
    let key: @Sendable () async -> String?

    public init(api: PhotosAPI, key: @escaping @Sendable () async -> String?) {
        self.api = api
        self.key = key
    }

    public var isOnDevice: Bool { false }
    public func people() async throws -> [Person] { try await api.people(key: await key()) }
    public func photos(of person: String?) async throws -> [PersonPhoto] { try await api.personPhotos(person, key: await key()) }
    public func rename(_ person: String, to name: String) async throws { try await api.renamePerson(person, to: name, key: await key()) }
    public func create(_ name: String) async throws { try await api.createPerson(name, key: await key()) }
    public func delete(_ person: String) async throws { try await api.deletePerson(person, key: await key()) }

    public func remove(_ childNames: [String], from person: String) async throws {
        let key = await key()
        for child in childNames { try await api.removeFromPerson(person, childName: child, key: key) }
    }

    public func move(_ childNames: [String], from person: String?, to target: String) async throws {
        try await api.moveFaces(childNames, from: person, to: target, key: await key())
    }

    public func merge(_ person: String, into target: String) async throws {
        try await api.mergePerson(person, into: target, key: await key())
    }

    public func faces(in item: MediaItem) async throws -> [FaceDetection] { try await api.faceDetections(userPath: item.path) }
}

/// The people found on this device (`DevicePeopleEngine`, SPEC §22.3).
public struct DevicePeopleDirectory: PeopleDirectory {
    let store: DeviceFaceStore
    let engine: DevicePeopleEngine
    /// After a change: named people go to search and memories (`mirrorNamedPeople`).
    let changed: @Sendable () async -> Void

    init(store: DeviceFaceStore, engine: DevicePeopleEngine, changed: @escaping @Sendable () async -> Void) {
        self.store = store
        self.engine = engine
        self.changed = changed
    }

    public var isOnDevice: Bool { true }

    /// The name a person goes by in the People screens: their name, or their number when unnamed.
    static func name(_ person: DeviceFaceStore.PersonSummary) -> String { person.name ?? String(person.id) }

    static let childPrefix = "device-"

    static func faceId(_ childName: String) -> Int64? {
        childName.hasPrefix(childPrefix) ? Int64(childName.dropFirst(childPrefix.count)) : nil
    }

    /// The person's id from what the screens call them.
    func id(of person: String) throws -> Int64 {
        if let id = try store.personId(named: person) { return id }
        if let id = Int64(person), try store.person(id) != nil { return id }
        throw DevicePeopleError.unknownPerson
    }

    public func people() async throws -> [Person] {
        try store.people().map { person in
            Person(name: Self.name(person), itemCount: person.photoCount, coverFileId: person.coverFileId, coverBox: person.coverBox)
        }
    }

    public func photos(of person: String?) async throws -> [PersonPhoto] {
        let faces = try person.map { try store.faces(ofPerson: try id(of: $0)) } ?? store.unassignedFaces()
        return faces.map { face, item in
            PersonPhoto(detectionId: Int(face.id), childName: Self.childPrefix + String(face.id), item: item, box: face.box)
        }
    }

    public func rename(_ person: String, to name: String) async throws {
        try await engine.rename(try id(of: person), to: name)
        await changed()
    }

    public func create(_ name: String) async throws {
        _ = try await engine.create(named: name)
    }

    public func delete(_ person: String) async throws {
        try await engine.delete(try id(of: person))
        await changed()
    }

    public func remove(_ childNames: [String], from person: String) async throws {
        try await engine.reject(childNames.compactMap(Self.faceId), from: try id(of: person))
        await changed()
    }

    public func move(_ childNames: [String], from person: String?, to target: String) async throws {
        try await engine.move(childNames.compactMap(Self.faceId), from: try person.map(id(of:)), to: try id(of: target))
        await changed()
    }

    public func merge(_ person: String, into target: String) async throws {
        try await engine.merge(try id(of: person), into: try id(of: target))
        await changed()
    }

    public func faces(in item: MediaItem) async throws -> [FaceDetection] {
        let names = Dictionary(
            try store.allPeople().compactMap { person in person.name.map { (person.id, $0) } }, uniquingKeysWith: { first, _ in first })
        return try store.faces(inFile: item.fileId).compactMap { face in
            guard let person = face.personId, let name = names[person] else { return nil }
            return FaceDetection(id: Int(face.id), fileId: item.fileId, clusterId: Int(person), title: name, box: face.box)
        }
    }
}

enum DevicePeopleError: LocalizedError {
    case unknownPerson

    var errorDescription: String? {
        String(
            localized: "This person is no longer there.", bundle: .module,
            comment: "People on this device: a person that was merged or removed meanwhile.")
    }
}

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import PhotosModel
import PhotosNetworking
import SwiftUI

// Managing people (SPEC PE-3, PE-4) with what Recognize's DAV API offers: rename (MOVE), merge, remove a photo,
// move photos to another person, assign unassigned faces, create a person (MKCOL), delete a person. Recognize has no
// way to hide a person: "Hide" is kept on this device only, per account, and says so.

/// People hidden from the People screen on this device. Kept in the account's own folder, so logging out removes it.
struct HiddenPeople: Equatable {
    var names: Set<String> = []

    /// A renamed person stays hidden under the new name.
    func renamed(_ old: String, to new: String) -> HiddenPeople {
        guard names.contains(old) else { return self }
        var copy = self
        copy.names.remove(old)
        copy.names.insert(new)
        return copy
    }

    static func file(in accountDirectory: URL) -> URL { accountDirectory.appending(path: "hidden-people.json") }

    static func load(from file: URL) -> HiddenPeople {
        guard let data = try? Data(contentsOf: file), let names = try? JSONDecoder().decode([String].self, from: data) else {
            return HiddenPeople()
        }
        return HiddenPeople(names: Set(names))
    }

    func save(to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(names.sorted()) { try? data.write(to: file, options: .atomic) }
    }
}

/// Checks a person's new name before it is sent: Recognize refuses an empty name, a name of digits only (that is how
/// unnamed people are called) and a name another person already has.
enum PersonName {
    enum Problem: Equatable {
        case empty, numeric, taken
    }

    static func problem(_ name: String, existing: [String], current: String? = nil) -> Problem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if Int(trimmed) != nil { return .numeric }
        if trimmed != current, existing.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { return .taken }
        return nil
    }

    static func message(_ problem: Problem) -> String {
        switch problem {
        case .empty: String(localized: "Enter a name.", bundle: .module)
        case .numeric:
            String(localized: "A name can't be only digits.", bundle: .module)
        case .taken:
            String(localized: "Another person already has this name. Use Merge to put them together.", bundle: .module)
        }
    }
}

extension SessionModel {
    /// Where this account keeps the people hidden on this device.
    var hiddenPeopleFile: URL? {
        services.map { HiddenPeople.file(in: $0.layout.accountDirectory($0.account.id)) }
    }
}

/// Picks the person to move photos or faces to, or creates a new one.
struct PersonPickerSheet: View {
    let title: String
    /// The person the photos come from; not offered.
    var excluding: String?
    /// Moves the photos; the sheet closes when it returns.
    let pick: @MainActor (String) async throws -> Void
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var people: [Person] = []
    @State private var creating = false
    @State private var newName = ""
    @State private var working = false
    @State private var error: String?

    var candidates: [Person] { people.filter { $0.name != excluding && !$0.isUnnamed } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newName = ""
                        creating = true
                    } label: {
                        Label(Self.newPersonTitle, systemImage: "person.crop.circle.badge.plus")
                    }
                }
                Section {
                    ForEach(candidates) { person in
                        Button {
                            run(person.name)
                        } label: {
                            LabeledContent(person.name) { Text(AccessibilityText.photos(person.itemCount)) }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .disabled(working)
            .overlay { if working { ProgressView() } }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .module)) { dismiss() } }
            }
            .alert(Self.newPersonTitle, isPresented: $creating) {
                TextField(String(localized: "Name", bundle: .module), text: $newName)
                Button(String(localized: "Create", bundle: .module)) {
                    createAndRun()
                }
                Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
            }
            .task { people = (try? await session.services?.api.people(key: await session.recognizeKey())) ?? [] }
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    func run(_ name: String) {
        working = true
        Task {
            defer { working = false }
            do {
                try await pick(name)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func createAndRun() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = PersonName.problem(name, existing: people.map(\.name)) {
            error = PersonName.message(problem)
            return
        }
        working = true
        Task {
            defer { working = false }
            do {
                try await session.services?.api.createPerson(name, key: await session.recognizeKey())
                try await pick(name)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    static var newPersonTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("New Person…", bundle: .module),
            other: LocalizedStringResource("New person…", bundle: .module))
    }
}

/// Faces Recognize found but put in no cluster, with "Assign to person…" (SPEC PE-4).
struct UnassignedFacesScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var faces: [PersonPhoto] = []
    @State private var assigning: [MediaItem]?
    /// Counted up to load the faces again after some were assigned.
    @State private var reloads = 0

    var body: some View {
        ItemsScreen(
            title: String(localized: "Unassigned faces", bundle: .module), sectioned: false,
            extraActions: { items in
                [
                    GridMenuAction(id: "assign", title: Self.assignTitle, systemImage: "person.crop.circle.badge.plus") { _ in
                        assigning = items
                    }
                ]
            },
            load: { services in
                faces = try await services.api.personPhotos(nil, key: await session.recognizeKey())
                return faces.map(\.item)
            }
        )
        .id(reloads)
        .sheet(
            isPresented: Binding(get: { assigning != nil }, set: { if !$0 { assigning = nil } })
        ) {
            PersonPickerSheet(title: Self.assignTitle) { name in
                let ids = Set((assigning ?? []).map(\.fileId))
                let children: [String] = faces.filter { ids.contains($0.item.fileId) }.map(\.childName)
                try await session.services?.api.moveFaces(children, from: nil, to: name, key: await session.recognizeKey())
                reloads += 1
            }
        }
    }

    static var assignTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Assign to Person…", bundle: .module),
            other: LocalizedStringResource("Assign to person…", bundle: .module))
    }
}

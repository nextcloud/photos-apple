// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI

/// "Tags…" in menus (the same in title and sentence case).
enum TagWording {
    static var menuTitle: String {
        String(localized: "Tags…", bundle: .module, comment: "Menu item that opens the tags of the selected photos or of the photo shown")
    }
}

/// Whether a tag is on all, some or none of the photos the tag sheet was opened for.
enum TagMark: Equatable {
    case all, some, none

    init(count: Int, of total: Int) {
        self = count <= 0 ? .none : (count >= total ? .all : .some)
    }

    /// Tapping a tag: on all photos it is taken off, otherwise it is given to all.
    var assignsOnTap: Bool { self != .all }

    var systemImage: String {
        switch self {
        case .all: "checkmark.circle.fill"
        case .some: "minus.circle.fill"
        case .none: "circle"
        }
    }
}

/// Tags of one photo (viewer) or of a selection (grid), SPEC §7.10. System tags are shared with Files and the web, so a
/// tag given here shows there too. Changes go through the outbox; a new tag needs the server, which gives it its id.
struct TagEditorSheet: View {
    let items: [MediaItem]
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [SystemTag] = []
    /// How many of `items` have each tag.
    @State private var counts: [Int: Int] = [:]
    @State private var loaded = false
    @State private var isOffline = false
    @State private var newName = ""
    @State private var filter = ""
    @State private var creating = false
    @State private var error: String?

    var shownTags: [SystemTag] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? tags : tags.filter { $0.name.localizedStandardContains(text) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(String(localized: "New tag", bundle: .module), text: $newName)
                            .onSubmit { create() }
                            .disabled(creating)
                        Button(String(localized: "Add", bundle: .module)) { create() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || creating)
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                } footer: {
                    if isOffline {
                        Text("Offline: your changes are saved when the connection is back. New tags need the connection.", bundle: .module)
                    }
                }
                Section {
                    ForEach(shownTags) { tag in row(tag) }
                } footer: {
                    Text("Tags are shared with Files and the other Nextcloud apps.", bundle: .module)
                }
            }
            .overlay {
                if !loaded {
                    ProgressView()
                } else if tags.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No tags yet", bundle: .module), systemImage: "tag",
                        description: Text("Type a name above to create the first one.", bundle: .module))
                }
            }
            .searchable(text: $filter, prompt: Text("Find a tag", bundle: .module))
            .navigationTitle(String(localized: "Tags", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
            .task { await load() }
        }
        .frame(minWidth: 360, minHeight: 440)
    }

    func row(_ tag: SystemTag) -> some View {
        let mark = TagMark(count: counts[tag.id] ?? 0, of: items.count)
        return Button {
            toggle(tag, mark: mark)
        } label: {
            HStack {
                Label(tag.name, systemImage: "tag")
                Spacer()
                Image(systemName: mark.systemImage)
                    .foregroundStyle(mark == .none ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!tag.canAssign)
        .accessibilityValue(accessibilityValue(mark))
        .accessibilityAddTraits(mark == .all ? .isSelected : [])
    }

    func accessibilityValue(_ mark: TagMark) -> String {
        switch mark {
        case .all: String(localized: "On", bundle: .module)
        case .some: String(localized: "On some of the selected items", bundle: .module)
        case .none: String(localized: "Off", bundle: .module)
        }
    }

    func load() async {
        let (all, offline) = await session.assignableTags()
        let current = await session.tagCounts(of: items)
        tags = all
        counts = current
        isOffline = offline
        loaded = true
    }

    func toggle(_ tag: SystemTag, mark: TagMark) {
        let assign = mark.assignsOnTap
        counts[tag.id] = assign ? items.count : 0
        Task { await session.setTag(tag, on: items, assigned: assign) }
    }

    func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !creating else { return }
        // A tag of that name is there already: use it.
        if let existing = tags.first(where: { $0.name.lowercased() == name.lowercased() }) {
            newName = ""
            toggle(existing, mark: .none)
            return
        }
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let tag = try await session.createTag(named: name)
                if !tags.contains(where: { $0.id == tag.id }) {
                    tags.append(tag)
                    tags.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }
                newName = ""
                toggle(tag, mark: .none)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

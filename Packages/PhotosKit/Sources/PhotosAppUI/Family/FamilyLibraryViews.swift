// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosNetworking
import PhotosStore
import SwiftUI

enum FamilyWording {
    static var title: String { String(localized: "Family Library", bundle: .module, comment: "Name of the family library feature.") }

    static func headline(_ suggestion: FamilySuggestion) -> String {
        let count = suggestion.fileIds.count
        switch suggestion.reason {
        case .people:
            return String(
                localized: "These \(count) photos show your family", bundle: .module,
                comment: "Family library suggestion: photos the family members are in. Plural variations in the catalog.")
        case .sharedDay(let day, let place):
            let date = day.formatted(.dateTime.day().month(.wide))
            if let place {
                return String(
                    localized: "\(count) photos from \(place) on \(date)", bundle: .module,
                    comment:
                        "Family library suggestion: photos of a day the family shared. Arguments: count, place, day. Plural variations in the catalog."
                )
            }
            return String(
                localized: "\(count) photos from \(date)", bundle: .module,
                comment:
                    "Family library suggestion: photos of a day the family shared, without a place. Arguments: count, day. Plural variations in the catalog."
            )
        }
    }

    static func detail(_ suggestion: FamilySuggestion) -> String {
        switch suggestion.reason {
        case .people(let names, let month):
            let monthText = month.formatted(.dateTime.month(.wide).year())
            return "\(names.formatted(.list(type: .and))) · \(monthText)"
        case .sharedDay:
            return String(
                localized: "The family folder has photos from that day too.", bundle: .module,
                comment: "Family library suggestion: why photos of a day are suggested.")
        }
    }

    static func question(folder: String, copies: Bool) -> String {
        copies
            ? String(
                localized: "Copy them to \(folder)?", bundle: .module,
                comment: "Family library card: the argument is the family folder's name.")
            : String(
                localized: "Move them to \(folder)?", bundle: .module,
                comment: "Family library card: the argument is the family folder's name.")
    }

    static func action(count: Int, copies: Bool) -> String {
        copies
            ? String(
                localized: "Copy \(count)", bundle: .module,
                comment: "Button that copies N suggested photos to the family folder. Plural variations in the catalog.")
            : String(
                localized: "Move \(count)", bundle: .module,
                comment: "Button that moves N suggested photos to the family folder. Plural variations in the catalog.")
    }

    static func folderDetail(_ folder: SharedFolder) -> String {
        switch folder.kind {
        case .received:
            folder.ownerDisplayName.isEmpty
                ? String(localized: "Shared with you", bundle: .module)
                : String(
                    localized: "Shared by \(folder.ownerDisplayName)", bundle: .module, comment: "A folder someone shared with the user.")
        case .groupFolder:
            String(localized: "Team folder", bundle: .module, comment: "A group folder (Team folder) of the Nextcloud admin.")
        case .own:
            folder.sharedWith.isEmpty
                ? String(localized: "Shared by you", bundle: .module, comment: "The user's own folder that is shared with others.")
                : String(
                    localized: "Shared with \(folder.sharedWith.formatted(.list(type: .and)))", bundle: .module,
                    comment: "The user's own folder; the argument lists who it is shared with.")
        }
    }
}

// MARK: - Card in Memories

/// "These 14 photos show your family — move them to the family folder?" in Memories, when there is a suggestion.
struct FamilySuggestionCard: View {
    @Environment(SessionModel.self) private var session
    @State private var working = false
    @State private var reviewing = false

    var body: some View {
        // In a stack that is always there: a task on the card alone would not run while there is no suggestion yet.
        VStack(spacing: 0) { card }
            // Suggestions are looked for when Memories opens too, not only after a sync (at most every 30 minutes).
            .task {
                if session.family?.settings.isSetUp == true { await session.family?.refresh() }
            }
            // A sheet, not a push: the card is replaced whenever the suggestions change, which would pop a pushed screen.
            .sheet(isPresented: $reviewing) {
                NavigationStack {
                    FamilySuggestionsScreen()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "Done", bundle: .module)) { reviewing = false }
                            }
                        }
                }
                #if os(macOS)
                    .frame(minWidth: 560, minHeight: 600)
                #endif
            }
    }

    @ViewBuilder var card: some View {
        if let family = session.family, let folder = family.settings.folder, let suggestion = family.topSuggestion {
            let items = family.items(of: suggestion)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(FamilyWording.title, systemImage: "figure.2.and.child.holdinghands").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        family.dismiss(suggestion.fileIds)
                    } label: {
                        // A target of 44 points around the small cross (SPEC §20.3).
                        Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(-10)
                    .accessibilityLabel(
                        Text(
                            "Don't suggest these photos again", bundle: .module, comment: "Dismisses a family library suggestion for good.")
                    )
                }
                HStack(spacing: 4) {
                    ForEach(items.prefix(4)) { (item: MediaItem) in
                        PreviewImage(item: item, bucket: 256).aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 6))
                    }
                }
                .accessibilityHidden(true)
                Text(FamilyWording.headline(suggestion)).font(.headline)
                Text(FamilyWording.question(folder: folder.name, copies: family.settings.copies)).font(.subheadline).foregroundStyle(
                    .secondary)
                HStack {
                    Button {
                        working = true
                        Task {
                            await family.apply(family.settings.copies ? .copy : .move, to: items)
                            working = false
                        }
                    } label: {
                        if working, let progress = family.progress {
                            Text(verbatim: "\(progress.done)/\(progress.total)").monospacedDigit()
                        } else {
                            Text(FamilyWording.action(count: items.count, copies: family.settings.copies))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || items.isEmpty)
                    Button {
                        reviewing = true
                    } label: {
                        Text("Review", bundle: .module, comment: "Opens all family library suggestions.")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(.background.secondary, in: .rect(cornerRadius: 16))
        }
    }
}

// MARK: - All suggestions

struct FamilySuggestionsScreen: View {
    @Environment(SessionModel.self) private var session
    /// Photos left out of a suggestion by the user.
    @State private var deselected: Set<FileID> = []
    @State private var failed = 0

    var body: some View {
        Group {
            if let family = session.family {
                List {
                    if family.suggestions.isEmpty && !family.isLoading {
                        ContentUnavailableView(
                            String(localized: "No Suggestions", bundle: .module, comment: "Family library: nothing to suggest."),
                            systemImage: "figure.2.and.child.holdinghands",
                            description: Text(
                                "New photos of your family and of days you spent together will appear here.", bundle: .module,
                                comment: "Family library: empty state."))
                    }
                    ForEach(family.suggestions) { (suggestion: FamilySuggestion) in
                        section(suggestion, family: family)
                    }
                    if failed > 0 {
                        Text(
                            "\(failed) photos could not be added. They are suggested again later.", bundle: .module,
                            comment: "Family library: some moves failed. Plural variations in the catalog."
                        )
                        .foregroundStyle(.red)
                    }
                }
                .overlay {
                    if family.isLoading && family.suggestions.isEmpty { ProgressView() }
                }
                .refreshable { await family.refresh(force: true) }
                .task { await family.refresh() }
            }
        }
        .navigationTitle(FamilyWording.title)
        .toolbar {
            NavigationLink {
                FamilyLibrarySetupScreen()
            } label: {
                Label(String(localized: "Options", bundle: .module, comment: "Opens the family library options."), systemImage: "gearshape")
            }
        }
    }

    func section(_ suggestion: FamilySuggestion, family: FamilyLibraryModel) -> some View {
        let items = family.items(of: suggestion)
        let chosen = items.filter { !deselected.contains($0.fileId) }
        return Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 120), spacing: 3)], spacing: 3) {
                ForEach(items) { (item: MediaItem) in
                    let selected = !deselected.contains(item.fileId)
                    Button {
                        if selected { deselected.insert(item.fileId) } else { deselected.remove(item.fileId) }
                    } label: {
                        PreviewImage(item: item, bucket: 256)
                            .aspectRatio(1, contentMode: .fit)
                            .opacity(selected ? 1 : 0.4)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, selected ? Color.accentColor : .black.opacity(0.3))
                                    .font(.title3).padding(4)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        AccessibilityText.media(
                            isVideo: item.kind == .video, isLivePhoto: item.isLivePhoto, date: item.timestamp, duration: item.duration,
                            place: item.place)
                    )
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            HStack {
                Button(FamilyWording.action(count: chosen.count, copies: false)) {
                    Task { failed = await family.apply(.move, to: chosen) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty || family.progress != nil)
                Button(FamilyWording.action(count: chosen.count, copies: true)) {
                    Task { failed = await family.apply(.copy, to: chosen) }
                }
                .buttonStyle(.bordered)
                .disabled(chosen.isEmpty || family.progress != nil)
                Spacer()
                Button(
                    String(
                        localized: "Not These", bundle: .module,
                        comment: "Dismisses the selected photos of a family library suggestion for good."), role: .destructive
                ) {
                    family.dismiss(chosen.map(\.fileId))
                }
                .buttonStyle(.borderless)
                .disabled(chosen.isEmpty)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(FamilyWording.headline(suggestion)).font(.headline).foregroundStyle(.primary).textCase(nil)
                Text(FamilyWording.detail(suggestion)).font(.subheadline).foregroundStyle(.secondary).textCase(nil)
            }
        }
    }
}

// MARK: - Setup

/// Settings › Family Library: the shared folder, the family members, move or copy.
struct FamilyLibrarySetupScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var people: [Person] = []
    @State private var confirmOff = false

    var body: some View {
        Form {
            if let family = session.family {
                folderSection(family)
                membersSection(family)
                Section {
                    Picker(
                        String(
                            localized: "Add photos by", bundle: .module,
                            comment: "Family library: whether suggested photos are moved or copied."),
                        selection: Binding(get: { family.settings.copies }, set: { value in family.update { $0.copies = value } })
                    ) {
                        Text("Moving", bundle: .module, comment: "Family library: suggested photos are moved to the family folder.").tag(
                            false)
                        Text("Copying", bundle: .module, comment: "Family library: suggested photos are copied to the family folder.").tag(
                            true)
                    }
                } footer: {
                    Text(
                        "Moved photos are in the family folder only; copies stay in your folders too and take space twice. Nothing is moved or copied until you say so.",
                        bundle: .module, comment: "Family library options: footer of move or copy.")
                }
                if family.settings.isSetUp {
                    Section {
                        if family.dismissedCount > 0 {
                            Button(String(localized: "Suggest Dismissed Photos Again", bundle: .module, comment: "Family library option."))
                            {
                                family.showDismissedAgain()
                            }
                        }
                        Button(
                            String(localized: "Turn Off Family Library", bundle: .module, comment: "Family library option."),
                            role: .destructive
                        ) {
                            confirmOff = true
                        }
                    } footer: {
                        Text(
                            "Turning it off changes nothing in the family folder.", bundle: .module,
                            comment: "Family library options: footer.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(FamilyWording.title)
        .confirmationDialog(
            String(localized: "Turn off the family library?", bundle: .module, comment: "Family library: confirmation of turning it off."),
            isPresented: $confirmOff, titleVisibility: .visible
        ) {
            Button(String(localized: "Turn Off", bundle: .module, comment: "Confirms turning a feature off."), role: .destructive) {
                session.family?.turnOff()
            }
        }
        .task {
            people = session.family?.namedPeople() ?? []
            await session.family?.loadFolders()
        }
    }

    @ViewBuilder func folderSection(_ family: FamilyLibraryModel) -> some View {
        Section {
            if !family.foldersLoaded {
                HStack {
                    ProgressView()
                    Text("Looking for shared folders…", bundle: .module, comment: "Family library setup while folders load.")
                        .foregroundStyle(.secondary)
                }
            } else if family.folders.isEmpty {
                Text(
                    "No shared folder you can add to. Share a folder with your family in Nextcloud, or ask them to share one with you.",
                    bundle: .module, comment: "Family library setup: no shared folders."
                )
                .foregroundStyle(.secondary)
            }
            ForEach(family.folders) { (folder: SharedFolder) in
                Button {
                    family.update { $0.folder = folder }
                } label: {
                    HStack {
                        Image(systemName: folder.kind == .groupFolder ? "person.3" : "folder.badge.person.crop")
                            .foregroundStyle(Color.accentColor).frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(folder.name).foregroundStyle(.primary)
                            Text(FamilyWording.folderDetail(folder)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if family.settings.folder?.path == folder.path {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(family.settings.folder?.path == folder.path ? .isSelected : [])
            }
            if let error = family.error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Family folder", bundle: .module, comment: "Family library setup: section of the shared folder.")
        } footer: {
            if let folder = family.settings.folder, !isInLibrary(folder.path) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "This folder is not one of your timeline folders: photos moved there leave your Library.", bundle: .module,
                        comment: "Family library setup: the family folder is not shown in the timeline.")
                    Button(
                        String(
                            localized: "Show Family Folder in Library", bundle: .module,
                            comment: "Adds the family folder to the timeline folders.")
                    ) {
                        Task { try? await session.setUserConfig(.photosSourceFolders) { $0.photosSourceFolders.append(folder.path) } }
                    }
                }
            } else {
                Text(
                    "Shared folders and Team folders you can add files to. Photos from your own library that show your family, or were taken on days the family folder has photos of, are suggested.",
                    bundle: .module, comment: "Family library setup: footer of the folder section.")
            }
        }
    }

    @ViewBuilder func membersSection(_ family: FamilyLibraryModel) -> some View {
        Section {
            if people.isEmpty {
                Text(
                    "No named people yet. Name people in People to have photos of them suggested.", bundle: .module,
                    comment: "Family library setup: Recognize found no named people."
                )
                .foregroundStyle(.secondary)
            }
            ForEach(people) { (person: Person) in
                Toggle(
                    isOn: Binding(
                        get: { family.settings.members.contains(person.name) },
                        set: { (on: Bool) in
                            family.update { settings in
                                settings.members.removeAll { $0 == person.name }
                                if on { settings.members.append(person.name) }
                            }
                        })
                ) {
                    HStack {
                        Group {
                            if let cover = person.coverFileId {
                                PreviewImage(fileId: cover, etag: "", bucket: 64)
                            } else {
                                Image(systemName: "person.crop.circle").resizable()
                            }
                        }
                        .frame(width: 32, height: 32).clipShape(.circle)
                        Text(person.name)
                    }
                }
            }
        } header: {
            Text("Family members", bundle: .module, comment: "Family library setup: section of the people who are family.")
        }
    }

    func isInLibrary(_ path: String) -> Bool {
        session.features.userConfig.photosSourceFolders.contains { folder in
            folder == "/" || path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
    }
}

/// Settings › Family Library row.
struct FamilyLibrarySettingsSection: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        if let family = session.family {
            Section {
                SettingsPageLink {
                    FamilyLibrarySetupScreen()
                } label: {
                    LabeledContent {
                        Text(family.settings.folder?.name ?? String(localized: "Off", bundle: .module))
                    } label: {
                        Label(FamilyWording.title, systemImage: "figure.2.and.child.holdinghands")
                    }
                }
            } footer: {
                Text(
                    "Suggests your photos of family members and of days you spent together for a shared family folder.", bundle: .module,
                    comment: "Settings: footer of the family library row.")
            }
        }
    }
}

/// A link to a page of its own from Settings: pushed where Settings has a navigation stack, a sheet in the Mac's Settings
/// window (whose General tab has none).
struct SettingsPageLink<Destination: View, Label: View>: View {
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label
    @State private var presented = false

    var body: some View {
        #if os(macOS)
            Button {
                presented = true
            } label: {
                label().contentShape(.rect)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $presented) {
                NavigationStack {
                    destination()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "Done", bundle: .module)) { presented = false }
                            }
                        }
                }
                .frame(minWidth: 480, minHeight: 520)
            }
        #else
            NavigationLink(destination: destination, label: label)
        #endif
    }
}

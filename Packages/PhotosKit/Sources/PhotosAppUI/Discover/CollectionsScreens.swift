// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosNetworking
import PhotosStore
import SwiftUI

let tileColumns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

// MARK: - Places (SPEC PL-1)

struct PlacesScreen: View {
    /// A Map button in the toolbar; not when the list is a mode of Places next to its map (`PlacesHome`).
    var showsMapButton = true
    @Environment(SessionModel.self) private var session
    @State private var places: [Place] = []
    @State private var error: String?
    /// The travel globe's history and stats (SPEC §15.6).
    @State private var travel = TravelModel()
    /// A place's photos zoom out of its tile, the map out of its button (SPEC §17.4).
    @Namespace private var zoom

    var grouped: [(country: String, places: [Place])] {
        guard session.features.has(.placeCountry) else { return [("", places)] }
        let groups = Dictionary(grouping: places) { $0.countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? "" }
        return groups.map { ($0.key, $0.value.sorted { $0.itemCount > $1.itemCount }) }
            .sorted { ($0.country.isEmpty ? 1 : 0, $0.country) < ($1.country.isEmpty ? 1 : 0, $1.country) }
    }

    var body: some View {
        ScrollView {
            // Travel and "Then and now" (SPEC §15.6) above the places.
            VStack(alignment: .leading, spacing: 24) {
                TravelSummaryCard(model: travel)
                ThenAndNowRow()
            }
            .padding([.horizontal, .top])
            LazyVStack(alignment: .leading, spacing: 24, pinnedViews: .sectionHeaders) {
                ForEach(grouped, id: \.country) { group in
                    Section {
                        LazyVGrid(columns: tileColumns, spacing: 20) {
                            ForEach(group.places) { place in
                                NavigationLink {
                                    ItemsScreen(title: place.name) { services in
                                        try await services.api.placeContent(place.name).map(\.item)
                                    }
                                    .cardTransitionDestination(id: "place-" + place.name, in: zoom)
                                } label: {
                                    CollectionTile(
                                        title: place.name, subtitle: AccessibilityText.photos(place.itemCount),
                                        coverFileId: place.coverFileId, kind: String(localized: "place", bundle: .module),
                                        transition: CollectionTile.Transition(id: "place-" + place.name, namespace: zoom))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        if grouped.count > 1 {
                            // A glass label that floats over the places scrolling under it, not a solid band (SPEC §17.3).
                            Text(group.country.isEmpty ? String(localized: "Other", bundle: .module) : group.country)
                                .font(.title3.bold())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .chromeGlass(in: .capsule)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
            }
            .padding()
            if let error { Text(error).foregroundStyle(.red).padding() }
        }
        .navigationTitle(String(localized: "Places", bundle: .module))
        .toolbar {
            if showsMapButton {
                ToolbarItem {
                    NavigationLink {
                        MapScreen().cardTransitionDestination(id: "map", in: zoom)
                    } label: {
                        Label(String(localized: "Map", bundle: .module), systemImage: "map")
                    }
                }
                #if os(iOS)
                    .matchedTransitionSource(id: AnyHashable("map"), in: zoom)
                #endif
            }
        }
        .task {
            guard let services = session.services else { return }
            Task {
                do { try await services.sync.refreshPlaces() } catch { self.error = error.localizedDescription }
            }
            Task { await travel.load(services) }
            do {
                for try await value in services.collections.observePlaces() { places = value }
            } catch {}
        }
    }
}

// MARK: - People (SPEC §7.9)

struct PeopleScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var people: [Person] = []
    @State private var loading = true
    @State private var error: String?
    /// Hidden on this device (Recognize has no way to hide a person on the server).
    @State private var hidden = HiddenPeople()
    @State private var showsHidden = false
    @State private var renaming: Person?
    @State private var newName = ""
    @State private var actionError: String?
    /// A person's page zooms out of their face (SPEC §17.4).
    @Namespace private var zoom

    var shown: [Person] {
        showsHidden ? people : people.filter { !hidden.names.contains($0.name) }
    }

    var hiddenCount: Int { people.filter { hidden.names.contains($0.name) }.count }

    var body: some View {
        ScrollView {
            if let error {
                ContentUnavailableView(
                    String(localized: "People are not available", bundle: .module), systemImage: "person.2.slash", description: Text(error))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)], spacing: 20) {
                ForEach(shown) { person in
                    NavigationLink {
                        PersonScreen(person: person) { Task { await load() } }
                            .cardTransitionDestination(id: "person-" + person.name, in: zoom)
                    } label: {
                        CollectionTile(
                            title: person.isUnnamed ? String(localized: "Add name", bundle: .module) : person.name,
                            subtitle: AccessibilityText.photos(person.itemCount), coverFileId: person.coverFileId,
                            faceBox: person.coverBox, circular: true, kind: String(localized: "person", bundle: .module),
                            transition: CollectionTile.Transition(id: "person-" + person.name, namespace: zoom)
                        )
                        .opacity(hidden.names.contains(person.name) ? 0.45 : 1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { personMenu(person) }
                }
            }
            .padding()
            if hiddenCount > 0 { hiddenNote }
        }
        .overlay {
            if loading && people.isEmpty && error == nil {
                SkeletonCovers(minimum: 100, circular: true).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationTitle(String(localized: "People", bundle: .module))
        .toolbar {
            NavigationLink {
                UnassignedFacesScreen()
            } label: {
                Label(String(localized: "Unassigned faces", bundle: .module), systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .alert(String(localized: "Name", bundle: .module), isPresented: isRenaming) {
            TextField(String(localized: "Name", bundle: .module), text: $newName)
            Button(String(localized: "Save", bundle: .module)) { if let person = renaming { rename(person, to: newName) } }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        }
        .alert(
            String(localized: "Something went wrong", bundle: .module),
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    @ViewBuilder func personMenu(_ person: Person) -> some View {
        Button {
            newName = person.isUnnamed ? "" : person.name
            renaming = person
        } label: {
            Label(PeopleActions.renameTitle, systemImage: "pencil")
        }
        Button {
            setHidden(person, !hidden.names.contains(person.name))
        } label: {
            if hidden.names.contains(person.name) {
                Label(PeopleActions.showTitle, systemImage: "eye")
            } else {
                Label(PeopleActions.hideTitle, systemImage: "eye.slash")
            }
        }
    }

    /// Says how many people are hidden and that it is this device only, with a way to see them.
    var hiddenNote: some View {
        VStack(spacing: 8) {
            Text(PeopleActions.hiddenNote(count: hiddenCount)).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(showsHidden ? PeopleActions.hideHiddenTitle : PeopleActions.showHiddenTitle) { showsHidden.toggle() }
                .font(.footnote)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    func setHidden(_ person: Person, _ value: Bool) {
        if value { hidden.names.insert(person.name) } else { hidden.names.remove(person.name) }
        if let file = session.hiddenPeopleFile { hidden.save(to: file) }
        // A hidden person leaves Spotlight and Shortcuts at once.
        Task { await session.updateSpotlight(force: true) }
    }

    func rename(_ person: Person, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = PersonName.problem(trimmed, existing: people.map(\.name), current: person.name) {
            actionError = PersonName.message(problem)
            return
        }
        guard trimmed != person.name else { return }
        Task {
            do {
                try await session.services?.api.renamePerson(person.name, to: trimmed, key: await session.recognizeKey())
                hidden = hidden.renamed(person.name, to: trimmed)
                if let file = session.hiddenPeopleFile { hidden.save(to: file) }
                await load()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        if let file = session.hiddenPeopleFile { hidden = HiddenPeople.load(from: file) }
        guard let services = session.services else { return }
        do {
            let key = await session.recognizeKey()
            people = try await services.api.people(key: key)
            error = nil
        } catch NetworkError.forbidden {
            error = String(
                localized: "Your server doesn't allow apps to access people yet. An administrator can enable it for apps.", bundle: .module)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Titles of the people actions: title case on the Mac, sentence case elsewhere.
enum PeopleActions {
    static var renameTitle: String { String(localized: "Rename…", bundle: .module) }

    static var hideTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Hide Person", bundle: .module),
            other: LocalizedStringResource("Hide person", bundle: .module))
    }

    static var showTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Show Person", bundle: .module),
            other: LocalizedStringResource("Show person", bundle: .module))
    }

    static var moveTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Move to Another Person…", bundle: .module),
            other: LocalizedStringResource("Move to another person…", bundle: .module))
    }

    static var showHiddenTitle: String {
        String(localized: "Show hidden people", bundle: .module)
    }

    static var hideHiddenTitle: String {
        String(localized: "Don't show hidden people", bundle: .module)
    }

    /// Hiding is kept on this device: the server has no way to hide a person.
    static func hiddenNote(count: Int) -> String {
        String(
            localized: "\(count) people are hidden on this device. Nextcloud can't hide people on all your devices yet.", bundle: .module)
    }
}

struct PersonScreen: View {
    let person: Person
    /// Called after the person was renamed, merged, emptied or deleted, so the People screen loads again.
    var changed: () -> Void = {}
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var merging = false
    @State private var confirmRemove = false
    @State private var error: String?
    @State private var photos: [PersonPhoto] = []
    @State private var moving: [MediaItem]?
    @State private var hidden = HiddenPeople()
    /// Counted up to load the photos again after some were moved away.
    @State private var reloads = 0
    /// "Make Sticker Pack" (SPEC §15.8.2).
    @State private var makingStickers = false
    /// "Through the Years" (SPEC §16.6).
    @State private var years: YearsPerson?
    @State private var needsName = false

    var isHidden: Bool { hidden.names.contains(person.name) }

    var body: some View {
        ItemsScreen(
            title: person.isUnnamed ? String(localized: "Unnamed person", bundle: .module) : person.name, sectioned: false,
            extraActions: { items in
                [
                    GridMenuAction(
                        id: "notPerson", title: String(localized: "Not this person", bundle: .module),
                        systemImage: "person.crop.circle.badge.xmark"
                    ) {
                        _ in
                        Task {
                            let key = await session.recognizeKey()
                            for item in items {
                                if let photo = photos.first(where: { $0.item.fileId == item.fileId }) {
                                    try? await session.services?.api.removeFromPerson(person.name, childName: photo.childName, key: key)
                                }
                            }
                            reloads += 1
                            changed()
                        }
                    },
                    GridMenuAction(id: "movePerson", title: PeopleActions.moveTitle, systemImage: "person.2.crop.square.stack") { _ in
                        moving = items
                    },
                ]
            },
            hero: hero,
            load: { services in
                photos = try await services.api.personPhotos(person.name, key: await session.recognizeKey())
                return photos.map(\.item)
            }
        ) {
            Menu {
                Button(String(localized: "Rename…", bundle: .module)) {
                    newName = person.isUnnamed ? "" : person.name
                    renaming = true
                }
                Button(String(localized: "Merge with…", bundle: .module)) { merging = true }
                Button(isHidden ? PeopleActions.showTitle : PeopleActions.hideTitle) { toggleHidden() }
                if !person.isUnnamed {
                    Button(StickerWording.packTitle, systemImage: "face.smiling") { makingStickers = true }
                }
                Button(YearsText.title, systemImage: "person.crop.rectangle.stack") {
                    if person.isUnnamed { needsName = true } else { years = YearsPerson(name: person.name) }
                }
                Button(String(localized: "Remove person…", bundle: .module), role: .destructive) { confirmRemove = true }
            } label: {
                Label(String(localized: "Person", bundle: .module), systemImage: "ellipsis.circle")
            }
        }
        .id(reloads)
        .sheet(isPresented: $makingStickers) { StickerPackSheet(person: person.name) }
        .throughTheYears($years)
        .alert(YearsText.title, isPresented: $needsName) {
            Button(String(localized: "Add Name…", bundle: .module, comment: "Through the years of an unnamed person: names them first.")) {
                newName = ""
                renaming = true
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: {
            Text(
                "Name this person first: Through the years follows a named person across all their photos.", bundle: .module,
                comment: "Through the years of a person Recognize has not been given a name for.")
        }
        .task { if let file = session.hiddenPeopleFile { hidden = HiddenPeople.load(from: file) } }
        .alert(String(localized: "Name", bundle: .module), isPresented: $renaming) {
            TextField(String(localized: "Name", bundle: .module), text: $newName)
            Button(String(localized: "Save", bundle: .module)) { rename() }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        }
        .sheet(isPresented: $merging) {
            MergePersonSheet(person: person) {
                changed()
                dismiss()
            }
        }
        .sheet(isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
            PersonPickerSheet(title: PeopleActions.moveTitle, excluding: person.name) { name in
                let ids = Set((moving ?? []).map(\.fileId))
                let children: [String] = photos.filter { ids.contains($0.item.fileId) }.map(\.childName)
                try await session.services?.api.moveFaces(children, from: person.name, to: name, key: await session.recognizeKey())
                reloads += 1
                changed()
            }
        }
        .confirmationDialog(
            String(localized: "Remove this person?", bundle: .module), isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button(String(localized: "Remove person", bundle: .module), role: .destructive) {
                Task {
                    do {
                        try await session.services?.api.deletePerson(person.name, key: await session.recognizeKey())
                        changed()
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("The person and the assignment of their photos are removed. The photos stay in your library.", bundle: .module)
        }
        .alert(
            String(localized: "Something went wrong", bundle: .module),
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
        } message: {
            Text(error ?? "")
        }
    }

    /// The person's photo at the top, their face and name over it (iPhone, iPad; SPEC §17.4).
    var hero: GridHero {
        let person = person
        let title = person.isUnnamed ? String(localized: "Unnamed person", bundle: .module) : person.name
        return GridHero {
            HeroHeaderView(title: title, subtitle: AccessibilityText.photos(person.itemCount)) {
                if let cover = person.coverFileId {
                    PreviewImage(fileId: cover, etag: "", bucket: 1024)
                } else {
                    AlbumGradientView(name: person.name)
                }
            } badge: {
                if let cover = person.coverFileId {
                    FaceCroppedPreview(fileId: cover, box: person.coverBox)
                        .frame(width: 64, height: 64)
                        .clipShape(.circle)
                        .overlay { Circle().strokeBorder(.white.opacity(0.8), lineWidth: 2) }
                }
            }
        }
    }

    func toggleHidden() {
        if isHidden { hidden.names.remove(person.name) } else { hidden.names.insert(person.name) }
        if let file = session.hiddenPeopleFile { hidden.save(to: file) }
        Task { await session.updateSpotlight(force: true) }
        changed()
    }

    func rename() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != person.name else { return }
        Task {
            do {
                let key = await session.recognizeKey()
                let others: [String] = ((try? await session.services?.api.people(key: key)) ?? []).map(\.name)
                if let problem = PersonName.problem(name, existing: others, current: person.name) {
                    error = PersonName.message(problem)
                    return
                }
                try await session.services?.api.renamePerson(person.name, to: name, key: key)
                if let file = session.hiddenPeopleFile { HiddenPeople.load(from: file).renamed(person.name, to: name).save(to: file) }
                changed()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MergePersonSheet: View {
    let person: Person
    let done: () -> Void
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var people: [Person] = []

    var body: some View {
        NavigationStack {
            List(people.filter { $0.name != person.name && !$0.isUnnamed }) { other in
                Button(other.name) {
                    Task {
                        try? await session.services?.api.mergePerson(person.name, into: other.name, key: await session.recognizeKey())
                        dismiss()
                        done()
                    }
                }
            }
            .navigationTitle(String(localized: "Merge into", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .module)) { dismiss() } }
            }
            .task { people = (try? await session.services?.api.people(key: await session.recognizeKey())) ?? [] }
        }
        .frame(minWidth: 360, minHeight: 420)
    }
}

// MARK: - Tags (SPEC §7.10)

struct TagsScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var tags: [SystemTag] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: tileColumns, spacing: 20) {
                ForEach(tags) { tag in
                    NavigationLink {
                        TagScreen(tag: tag)
                    } label: {
                        CollectionTile(
                            title: tag.name, subtitle: AccessibilityText.photos(tag.itemCount),
                            coverFileId: tag.coverFileId, kind: String(localized: "tag", bundle: .module))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(String(localized: "Tags", bundle: .module))
        .task {
            do {
                tags = try await session.services?.api.tagsInUse() ?? []
            } catch {
                // Offline: the tags known from the last refresh, with their photos in the library.
                let local = session.services.flatMap { try? LabelStore(database: $0.database).tags() } ?? []
                tags = local.filter { $0.itemCount != 0 }
                if tags.isEmpty { self.error = error.localizedDescription }
            }
        }
    }
}

/// The photos of one tag, with "Remove tag" for a selection.
struct TagScreen: View {
    let tag: SystemTag
    @Environment(SessionModel.self) private var session

    var body: some View {
        ItemsScreen(
            title: tag.name,
            extraActions: { items in
                [
                    GridMenuAction(id: "untag", title: String(localized: "Remove tag", bundle: .module), systemImage: "tag.slash") { _ in
                        Task { await session.setTag(tag, on: items, assigned: false) }
                    }
                ]
            }
        ) { _ in
            try await session.tagItems(tag.id)
        }
    }
}

// MARK: - Folders (SPEC §7.11)

struct FoldersScreen: View {
    var path = "/"
    var sharedWithYou = false
    @Environment(SessionModel.self) private var session
    @State private var folders: [FolderEntry] = []
    /// The folder's own photos, shown by the grid the rest of the app uses: selection, context menu, share,
    /// favourite, delete, keyboard and the viewer come with it.
    @State private var feed = GridFeed()
    @State private var previews: [String: [FileID]] = [:]
    @State private var error: String?
    @State private var loaded = false
    @AppStorage("gridColumns") private var columns = GridColumns.default
    @State private var sharing: SharingTarget?

    var title: String {
        if path == "/" {
            return sharedWithYou ? String(localized: "Shared with you", bundle: .module) : String(localized: "Folders", bundle: .module)
        }
        return (path as NSString).lastPathComponent
    }

    var body: some View {
        Group {
            if feed.items.isEmpty {
                // Only subfolders (or nothing yet): large tiles, as on the other collection screens.
                ScrollView {
                    LazyVGrid(columns: tileColumns, spacing: 20) {
                        ForEach(folders) { folder in folderLink(folder) }
                    }
                    .padding()
                    if let error, !folders.isEmpty { Text(error).foregroundStyle(.red).padding() }
                }
                .overlay { status }
                .navigationTitle(title)
            } else {
                // Subfolders above the photos. The grid scrolls by itself, so they are a strip that stays in place.
                VStack(spacing: 0) {
                    if !folders.isEmpty {
                        FolderStrip(folders: folders) { folder in folderLink(folder, compact: true) }
                        Divider()
                    }
                    MediaGridScreen(
                        feed: feed, title: title, showsHeaders: false,
                        emptyTitle: String(localized: "No photos in this folder", bundle: .module), emptyMessage: "", columns: $columns
                    ) {
                        EmptyView()
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        // File ▸ Import from iPhone or iPad (Continuity Camera, Mac; SPEC §16.5.3): into this folder.
        .continuityCameraImport(folder: path, isEnabled: path != "/")
        .toolbar {
            if path != "/" {
                ToolbarItem(placement: .automatic) {
                    Button {
                        sharing = SharingTarget(path: path, isFolder: true)
                    } label: {
                        Label(String(localized: "Share via Nextcloud…", bundle: .module), systemImage: "person.badge.plus")
                    }
                    .help(String(localized: "Share via Nextcloud…", bundle: .module))
                }
            }
        }
        .sheet(item: $sharing) { target in
            if let services = session.services { FileSharingSheet(target: target, api: services.api.sharing) }
        }
    }

    func folderLink(_ folder: FolderEntry, compact: Bool = false) -> some View {
        NavigationLink {
            FoldersScreen(path: folder.path)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                FolderMosaic(fileIds: folder.previews.isEmpty ? previews[folder.path] ?? [] : folder.previews)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: Design.coverCornerRadius))
                if compact {
                    // Narrow tiles: the name may take two lines instead of ending after a few letters.
                    Text(folder.name).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                } else {
                    Label(folder.name, systemImage: "folder").font(.headline).lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                AccessibilityText.collection(
                    title: folder.name, kind: String(localized: "folder", bundle: .module), detail: nil))
        }
        .buttonStyle(.plain)
        .task { await loadPreviews(folder) }
    }

    /// Progress while loading, and a centred empty or error state instead of a blank screen.
    @ViewBuilder var status: some View {
        if !folders.isEmpty {
            EmptyView()
        } else if !loaded {
            SkeletonCovers().frame(maxHeight: .infinity, alignment: .top)
        } else if let error {
            ContentUnavailableView {
                Label(String(localized: "Couldn't load folders", bundle: .module), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(String(localized: "Try again", bundle: .module)) { Task { await load() } }
            }
        } else if sharedWithYou && path == "/" {
            ContentUnavailableView(
                String(localized: "Nothing shared with you", bundle: .module), systemImage: "person.2",
                description: Text("Folders with photos that others share with you appear here.", bundle: .module))
        } else {
            ContentUnavailableView(
                String(localized: "No photos in this folder", bundle: .module), systemImage: "folder",
                description: Text("Folders that contain photos or videos appear here.", bundle: .module))
        }
    }

    func load() async {
        guard let services = session.services else { return }
        defer { loaded = true }
        do {
            error = nil
            if sharedWithYou && path == "/" {
                folders = try await services.api.sharedWithYou().filter(\.isFolder)
            } else {
                let result = try await services.api.folder(path, mimeTypes: session.features.allMimeTypes, nomedia: session.excludedFolders)
                folders = result.folders
                // Stored for the viewer and the grid's actions; newest first like everywhere else.
                let items: [MediaItem] = result.items.filter { !$0.isLivePhotoVideo }
                feed.apply(await ItemsPreparation.prepare(items, library: services.library), flat: true)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadPreviews(_ folder: FolderEntry) async {
        guard folder.previews.isEmpty, previews[folder.path] == nil, let services = session.services else { return }
        previews[folder.path] = (try? await services.api.folderPreviews(folder.path, mimeTypes: session.features.imageMimeTypes)) ?? []
    }
}

/// Subfolders in one row above a folder's photos.
struct FolderStrip<Tile: View>: View {
    let folders: [FolderEntry]
    @ViewBuilder var tile: (FolderEntry) -> Tile
    /// The tiles grow with the text size, which their labels follow.
    @ScaledMetric(relativeTo: .subheadline) private var side = 104.0

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(folders) { folder in
                    tile(folder).frame(width: side)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Folders", bundle: .module))
    }
}

/// 2×2 mosaic of up to four photos.
struct FolderMosaic: View {
    let fileIds: [FileID]

    var body: some View {
        if fileIds.isEmpty {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.secondary)
            }
        } else if fileIds.count < 4 {
            PreviewImage(fileId: fileIds[0], etag: "", bucket: 256)
        } else {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    PreviewImage(fileId: fileIds[0], etag: "", bucket: 256)
                    PreviewImage(fileId: fileIds[1], etag: "", bucket: 256)
                }
                GridRow {
                    PreviewImage(fileId: fileIds[2], etag: "", bucket: 256)
                    PreviewImage(fileId: fileIds[3], etag: "", bucket: 256)
                }
            }
        }
    }
}

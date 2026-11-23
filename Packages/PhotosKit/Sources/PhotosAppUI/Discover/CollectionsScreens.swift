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
    @Environment(SessionModel.self) private var session
    @State private var places: [Place] = []
    @State private var error: String?

    var grouped: [(country: String, places: [Place])] {
        guard session.features.has(.placeCountry) else { return [("", places)] }
        let groups = Dictionary(grouping: places) { $0.countryCode.flatMap { Locale.current.localizedString(forRegionCode: $0) } ?? "" }
        return groups.map { ($0.key, $0.value.sorted { $0.itemCount > $1.itemCount }) }
            .sorted { ($0.country.isEmpty ? 1 : 0, $0.country) < ($1.country.isEmpty ? 1 : 0, $1.country) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24, pinnedViews: .sectionHeaders) {
                ForEach(grouped, id: \.country) { group in
                    Section {
                        LazyVGrid(columns: tileColumns, spacing: 20) {
                            ForEach(group.places) { place in
                                NavigationLink {
                                    ItemsScreen(title: place.name) { services in
                                        try await services.api.placeContent(place.name).map(\.item)
                                    }
                                } label: {
                                    CollectionTile(
                                        title: place.name, subtitle: AccessibilityText.photos(place.itemCount),
                                        coverFileId: place.coverFileId, kind: String(localized: "place", bundle: .module))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        if grouped.count > 1 {
                            Text(group.country.isEmpty ? String(localized: "Other", bundle: .module) : group.country)
                                .font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).background(.bar)
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
            NavigationLink {
                MapScreen()
            } label: {
                Label(String(localized: "Map", bundle: .module), systemImage: "map")
            }
        }
        .task {
            guard let services = session.services else { return }
            Task {
                do { try await services.sync.refreshPlaces() } catch { self.error = error.localizedDescription }
            }
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

    var body: some View {
        ScrollView {
            if let error {
                ContentUnavailableView(
                    String(localized: "People are not available", bundle: .module), systemImage: "person.2.slash", description: Text(error))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)], spacing: 20) {
                ForEach(people) { person in
                    NavigationLink {
                        PersonScreen(person: person)
                    } label: {
                        CollectionTile(
                            title: person.isUnnamed ? String(localized: "Add name", bundle: .module) : person.name,
                            subtitle: AccessibilityText.photos(person.itemCount), coverFileId: person.coverFileId,
                            faceBox: person.coverBox, circular: true, kind: String(localized: "person", bundle: .module))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay { if loading && people.isEmpty && error == nil { ProgressView() } }
        .navigationTitle(String(localized: "People", bundle: .module))
        .toolbar {
            NavigationLink {
                ItemsScreen(title: String(localized: "Unassigned faces", bundle: .module), sectioned: false) { services in
                    try await services.api.personPhotos(nil, key: await session.recognizeKey()).map(\.item)
                }
            } label: {
                Label(String(localized: "Unassigned faces", bundle: .module), systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    func load() async {
        loading = true
        defer { loading = false }
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

struct PersonScreen: View {
    let person: Person
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var merging = false
    @State private var confirmRemove = false
    @State private var error: String?
    @State private var photos: [PersonPhoto] = []

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
                        }
                    }
                ]
            },
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
                Button(String(localized: "Remove person…", bundle: .module), role: .destructive) { confirmRemove = true }
            } label: {
                Label(String(localized: "Person", bundle: .module), systemImage: "ellipsis.circle")
            }
        }
        .alert(String(localized: "Name", bundle: .module), isPresented: $renaming) {
            TextField(String(localized: "Name", bundle: .module), text: $newName)
            Button(String(localized: "Save", bundle: .module)) {
                Task {
                    do {
                        try await session.services?.api.renamePerson(person.name, to: newName, key: await session.recognizeKey())
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        }
        .sheet(isPresented: $merging) { MergePersonSheet(person: person) { dismiss() } }
        .confirmationDialog(
            String(localized: "Remove this person?", bundle: .module), isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button(String(localized: "Remove person", bundle: .module), role: .destructive) {
                Task {
                    do {
                        try await session.services?.api.deletePerson(person.name, key: await session.recognizeKey())
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
                        ItemsScreen(title: tag.name) { services in try await services.api.tagContent(tag.id) }
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
            do { tags = try await session.services?.api.tagsInUse() ?? [] } catch { self.error = error.localizedDescription }
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
            ProgressView()
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

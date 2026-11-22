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
                                        title: place.name, subtitle: String(localized: "\(place.itemCount) photos", bundle: .module),
                                        coverFileId: place.coverFileId)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        if grouped.count > 1 {
                            Text(group.country.isEmpty ? String(localized: "Other", bundle: .module) : group.country)
                                .font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).background(.bar)
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
                            subtitle: String(localized: "\(person.itemCount) photos", bundle: .module), coverFileId: person.coverFileId,
                            faceBox: person.coverBox, circular: true)
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
                Button(String(localized: "Remove person", bundle: .module), role: .destructive) {
                    Task {
                        try? await session.services?.api.deletePerson(person.name, key: await session.recognizeKey())
                        dismiss()
                    }
                }
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
                            title: tag.name, subtitle: String(localized: "\(tag.itemCount) photos", bundle: .module),
                            coverFileId: tag.coverFileId)
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
    @State private var items: [MediaItem] = []
    @State private var previews: [String: [FileID]] = [:]
    @State private var error: String?
    @State private var viewer: ViewerStart?

    var title: String {
        if path == "/" {
            return sharedWithYou ? String(localized: "Shared with you", bundle: .module) : String(localized: "Folders", bundle: .module)
        }
        return (path as NSString).lastPathComponent
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: tileColumns, spacing: 20) {
                ForEach(folders) { folder in
                    NavigationLink {
                        FoldersScreen(path: folder.path)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            FolderMosaic(fileIds: folder.previews.isEmpty ? previews[folder.path] ?? [] : folder.previews)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: Design.coverCornerRadius))
                            Label(folder.name, systemImage: "folder").font(.headline).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .task { await loadPreviews(folder) }
                }
            }
            .padding()
            if !items.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
                    ForEach(items) { item in
                        PreviewImage(item: item, bucket: 256)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .contentShape(.rect)
                            .onTapGesture { viewer = ViewerStart(ids: items.map(\.fileId), startId: item.fileId) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).padding() }
        }
        .navigationTitle(title)
        .task { await load() }
        .refreshable { await load() }
        #if os(iOS)
            .fullScreenCover(item: $viewer) { start in MediaViewer(ids: start.ids, startId: start.startId).environment(session) }
        #else
            .navigationDestination(item: $viewer) { start in MediaViewer(ids: start.ids, startId: start.startId) }
        #endif
    }

    func load() async {
        guard let services = session.services else { return }
        do {
            if sharedWithYou && path == "/" {
                folders = try await services.api.sharedWithYou().filter(\.isFolder)
            } else {
                let result = try await services.api.folder(path, mimeTypes: session.features.allMimeTypes, nomedia: session.excludedFolders)
                folders = result.folders
                items = result.items
                try? services.library.storeCollectionMedia(items)
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

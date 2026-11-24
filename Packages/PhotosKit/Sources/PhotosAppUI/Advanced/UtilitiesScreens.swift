// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import FoundationModels
import LocalAuthentication
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
import PhotosStore
import SwiftUI
import Vision

// MARK: - Recently deleted (SPEC §7.14)

struct RecentlyDeletedScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var items: [TrashedItem] = []
    @State private var unlocked = false
    @State private var confirmEmpty = false
    /// The item waiting for the confirmation of its permanent deletion.
    @State private var confirmDelete: TrashedItem?
    @State private var error: String?

    var body: some View {
        Group {
            if !unlocked {
                ContentUnavailableView {
                    Label(String(localized: "Recently deleted is locked", bundle: .module), systemImage: "lock")
                } actions: {
                    Button(String(localized: "Unlock", bundle: .module)) { Task { await unlock() } }.buttonStyle(.borderedProminent)
                }
            } else if items.isEmpty {
                ContentUnavailableView(String(localized: "No recently deleted photos", bundle: .module), systemImage: "trash")
            } else {
                List(items) { item in
                    HStack {
                        TrashPreview(item: item).frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 6))
                        VStack(alignment: .leading) {
                            Text(item.originalName).lineLimit(1)
                            if let date = item.deletedAt {
                                Text("Deleted \(date.formatted(.relative(presentation: .named)))", bundle: .module).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(String(localized: "Restore", bundle: .module)) { Task { await run { try await $0.restore(item) } } }
                            .buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button(String(localized: "Delete", bundle: .module), role: .destructive) { confirmDelete = item }
                    }
                    .contextMenu {
                        Button(String(localized: "Restore", bundle: .module)) { Task { await run { try await $0.restore(item) } } }
                        Button(String(localized: "Delete permanently…", bundle: .module), role: .destructive) { confirmDelete = item }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Recently deleted", bundle: .module))
        .toolbar {
            if unlocked && !items.isEmpty {
                Button(String(localized: "Empty", bundle: .module), role: .destructive) { confirmEmpty = true }
            }
        }
        .confirmationDialog(
            String(localized: "Delete all items permanently?", bundle: .module), isPresented: $confirmEmpty, titleVisibility: .visible
        ) {
            Button(String(localized: "Delete all", bundle: .module), role: .destructive) {
                Task { await run { try await $0.emptyTrash() } }
            }
        }
        .confirmationDialog(
            String(localized: "Delete “\(confirmDelete?.originalName ?? "")” permanently?", bundle: .module),
            isPresented: Binding(get: { confirmDelete != nil }, set: { shown in if !shown { confirmDelete = nil } }),
            titleVisibility: .visible, presenting: confirmDelete
        ) { (item: TrashedItem) in
            Button(String(localized: "Delete permanently", bundle: .module), role: .destructive) {
                Task { await run { try await $0.deletePermanently(item) } }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: { _ in
            Text("It is removed from the trash bin of your Nextcloud and cannot be restored.", bundle: .module)
        }
        .alert(
            String(localized: "Something went wrong", bundle: .module),
            isPresented: Binding(get: { error != nil }, set: { shown in if !shown { error = nil } })
        ) {
        } message: {
            Text(error ?? "")
        }
        .task { await unlock() }
        .refreshable { await load() }
    }

    func unlock() async {
        let context = LAContext()
        unlocked =
            (try? await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: String(localized: "Show recently deleted photos", bundle: .module)))
            ?? false
        if unlocked { await load() }
    }

    func load() async {
        guard let services = session.services else { return }
        // The types the timeline indexes, TIFF and RAW included.
        items = (try? await services.api.trash(mimeTypes: session.features.allMimeTypes + MimeTypes.appleExtras)) ?? []
    }

    func run(_ action: @escaping (PhotosAPI) async throws -> Void) async {
        guard let services = session.services else { return }
        do {
            try await action(services.api)
            await load()
            await session.syncNow()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TrashPreview: View {
    let item: TrashedItem
    @Environment(SessionModel.self) private var session
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
        }
        .task {
            guard let services = session.services,
                let data = try? await services.dav.get(services.api.trashPreviewURL(fileId: item.fileId, size: 256)).data
            else { return }
            image = ImageDecoding.decode(data: data, maxPixelSize: 256)
        }
    }
}

// MARK: - Deleting from the server

/// Wording of the confirmation shown before Duplicates and Free up space delete files. Both delete on the Nextcloud
/// server, not just in this app, so the dialog always says so and says whether the trash bin catches the files.
enum ServerDeleteWording {
    static func title(count: Int) -> String {
        String(localized: "Delete \(count) items from your Nextcloud?", bundle: .module)
    }

    static func message(trashbin: Bool, bytes: Int64) -> String {
        let size = Formatters.bytes(bytes)
        return trashbin
            ? String(
                localized:
                    "Deleting here deletes on your Nextcloud server (\(size)) and so on all your devices and the web. Deleted items go to the server's trash bin and can be restored from “Recently deleted” until the server empties it.",
                bundle: .module)
            : String(
                localized:
                    "Deleting here deletes on your Nextcloud server (\(size)) and so on all your devices and the web. The trash bin is disabled on this server: deleted items are gone permanently and cannot be restored.",
                bundle: .module)
    }

    /// Duplicates whose copies are in albums: the kept copy is added to those albums first.
    static func keepInAlbumsButton(count: Int, trashbin: Bool) -> String {
        trashbin
            ? String(
                localized: "Keep in albums and move \(count) items to the trash bin", bundle: .module,
                comment: "Duplicates: add the kept copy to the deleted copies' albums, then delete them.")
            : String(
                localized: "Keep in albums and delete \(count) items permanently", bundle: .module,
                comment: "Duplicates: add the kept copy to the deleted copies' albums, then delete them.")
    }

    static func button(count: Int, trashbin: Bool) -> String {
        trashbin
            ? String(localized: "Move \(count) items to the trash bin", bundle: .module)
            : String(localized: "Delete \(count) items permanently", bundle: .module)
    }
}

/// Files waiting for the user's confirmation, and what to do in the list once they are queued for deletion.
struct PendingServerDeletion {
    var items: [MediaItem]
    /// Duplicates: the albums the deleted copies are in (SPEC §7.15).
    var albums: DuplicateAlbumNote? = nil
    var done: @MainActor () -> Void
}

/// Deleting duplicates takes them out of their albums: the albums they are in and the kept copy is not, so it can be
/// added to them before the others go (SPEC §7.15). Only what the app knows: the content of albums opened on this device.
struct DuplicateAlbumNote {
    var kept: MediaItem
    var albums: [Album]
    /// Albums with photos whose content the app has not read yet: they could not be checked.
    var unchecked: Int

    /// The kept copy can be put into the albums (only the user's own files can be added to albums).
    var canKeepMemberships: Bool { kept.isOwnStorage && !albums.isEmpty }

    @MainActor static func make(deleting items: [MediaItem], kept: MediaItem, services: AccountServices) -> DuplicateAlbumNote {
        let ids = items.map(\.fileId) + [kept.fileId]
        let placements: [Duplicates.AlbumPlacement] = ((try? services.collections.memberships(of: ids)) ?? []).map {
            Duplicates.AlbumPlacement(albumId: $0.albumId, fileId: $0.fileId, byFilter: $0.origin == "filters")
        }
        let losing = Duplicates.albumsLosingPhoto(deleted: items.map(\.fileId), kept: kept.fileId, placements: placements)
        let albums: [Album] = losing.compactMap { try? services.collections.album(id: $0) }
            .filter { $0.kind != .publicLink }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let all: [Album] = (((try? services.collections.albums(.own)) ?? []) + ((try? services.collections.albums(.shared)) ?? []))
        let unchecked = all.filter { album in
            album.itemCount > 0 && (try? services.collections.albumContentFetchedAt(albumId: album.id)) == nil
        }.count
        return DuplicateAlbumNote(kept: kept, albums: albums, unchecked: unchecked)
    }

    /// What the confirmation adds about albums; nil when there is nothing to say.
    var message: String? {
        var parts: [String] = []
        if !albums.isEmpty {
            let names = albums.map { "“\($0.title)”" }.formatted(.list(type: .and))
            parts.append(
                String(
                    localized:
                        "The copies to be deleted are in albums the kept copy is not in: \(names). Deleting them takes the photo out of these albums.",
                    bundle: .module, comment: "Duplicates: warning in the delete confirmation. The names are album titles in quotes."))
            if !kept.isOwnStorage {
                parts.append(
                    String(
                        localized: "The kept copy is shared with you, so it can't be added to the albums instead.", bundle: .module,
                        comment: "Duplicates: the kept copy is not the user's own file."))
            }
        }
        if unchecked > 0 {
            parts.append(
                String(
                    localized:
                        "\(unchecked) albums haven't been opened on this device yet; whether the copies are in them couldn't be checked.",
                    bundle: .module, comment: "Duplicates: albums whose content is not known to the app."))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

extension View {
    /// The confirmation for deleting files from the server (count, size, trash bin or permanent; destructive button).
    func serverDeleteConfirmation(_ pending: Binding<PendingServerDeletion?>, session: SessionModel) -> some View {
        let items: [MediaItem] = pending.wrappedValue?.items ?? []
        let trashbin = session.features.has(.trashbin)
        let presented = Binding<Bool>(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } })
        let note: DuplicateAlbumNote? = pending.wrappedValue?.albums
        let base: String = ServerDeleteWording.message(trashbin: trashbin, bytes: items.reduce(0) { $0 + $1.size })
        let message: String = note?.message.map { "\($0)\n\n\(base)" } ?? base
        return confirmationDialog(ServerDeleteWording.title(count: items.count), isPresented: presented, titleVisibility: .visible) {
            if let note, note.canKeepMemberships {
                // First the kept copy goes into the albums (queued before the deletes), then the copies are deleted.
                Button(ServerDeleteWording.keepInAlbumsButton(count: items.count, trashbin: trashbin), role: .destructive) {
                    guard let request = pending.wrappedValue else { return }
                    Task {
                        for album in note.albums { await session.addToAlbum([note.kept], album: album) }
                        await session.delete(request.items)
                        request.done()
                    }
                }
            }
            Button(ServerDeleteWording.button(count: items.count, trashbin: trashbin), role: .destructive) {
                guard let request = pending.wrappedValue else { return }
                Task {
                    await session.delete(request.items)
                    request.done()
                }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

/// File name with its folder underneath, instead of a raw server path.
struct FileNameLabel: View {
    let item: MediaItem

    var folder: String {
        let directory = item.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return directory.isEmpty ? String(localized: "Top folder", bundle: .module) : directory.replacingOccurrences(of: "/", with: " › ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Label(folder, systemImage: "folder").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.head)
        }
    }
}

// MARK: - Duplicates and Free up space (SPEC §7.15)

/// One set of identical files, with the copy suggested to keep.
struct DuplicateSet: Identifiable, Sendable {
    var id: String
    var copies: [MediaItem]
    var suggested: Duplicates.Keeper

    /// Reads the possible duplicates (a store query, not the whole index) and groups them, off the main actor.
    nonisolated static func load(_ library: LibraryStore) async -> [DuplicateSet] {
        let all = (try? await library.duplicateCandidates()) ?? []
        let byId = Dictionary(all.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
        return Duplicates.groups(all).compactMap { group in
            let copies = group.items.compactMap { byId[$0] }
            guard copies.count >= 2, let keeper = Duplicates.keeper(of: copies) else { return nil }
            return DuplicateSet(id: group.id, copies: copies, suggested: keeper)
        }
    }
}

struct DuplicatesScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var sets: [DuplicateSet] = []
    /// Copies the user picked to keep instead of the suggested one, by set id.
    @State private var chosen: [String: FileID] = [:]
    @State private var loaded = false
    @State private var pending: PendingServerDeletion?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !sets.isEmpty {
                    Text(
                        "These files are identical copies stored in different folders of your Nextcloud. Choose the copy to keep in each set; the others can be deleted from the server.",
                        bundle: .module
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(sets) { group in
                    DuplicateSetView(
                        group: group, keptId: chosen[group.id] ?? group.suggested.fileId, userChose: chosen[group.id] != nil,
                        keep: { id in chosen[group.id] = id == group.suggested.fileId ? nil : id },
                        delete: { items in
                            let keptId: FileID = chosen[group.id] ?? group.suggested.fileId
                            var note: DuplicateAlbumNote?
                            if let services = session.services, let kept = group.copies.first(where: { $0.fileId == keptId }) {
                                note = DuplicateAlbumNote.make(deleting: items, kept: kept, services: services)
                            }
                            pending = PendingServerDeletion(items: items, albums: note) { sets.removeAll { $0.id == group.id } }
                        })
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if !loaded {
                ProgressView(String(localized: "Looking for duplicates…", bundle: .module))
            } else if sets.isEmpty {
                ContentUnavailableView(
                    String(localized: "No duplicates", bundle: .module), systemImage: "checkmark.seal",
                    description: Text("Identical copies of a photo or video in your Nextcloud appear here.", bundle: .module))
            }
        }
        .navigationTitle(String(localized: "Duplicates", bundle: .module))
        .serverDeleteConfirmation($pending, session: session)
        .task {
            guard let services = session.services else { return }
            sets = await DuplicateSet.load(services.library)
            loaded = true
        }
    }
}

struct DuplicateSetView: View {
    let group: DuplicateSet
    let keptId: FileID
    let userChose: Bool
    let keep: (FileID) -> Void
    let delete: ([MediaItem]) -> Void

    /// The copies that would be deleted: all but the kept one, as far as the user may delete them.
    var deletable: [MediaItem] { group.copies.filter { $0.fileId != keptId && $0.permissions.canDelete } }

    var reason: String {
        if userChose { return String(localized: "You chose which copy to keep.", bundle: .module) }
        switch group.suggested.reason {
        case .favorite: return String(localized: "The favorite is kept.", bundle: .module)
        case .ownFile: return String(localized: "Your own file is kept; the other copies are shared with you.", bundle: .module)
        case .oldest: return String(localized: "The copy that has been on the server the longest is kept.", bundle: .module)
        case .firstByPath: return String(localized: "The copies don't differ; the first one by folder is kept.", bundle: .module)
        }
    }

    var hint: String {
        #if os(macOS)
            String(localized: "Click another copy to keep that one instead.", bundle: .module)
        #else
            String(localized: "Tap another copy to keep that one instead.", bundle: .module)
        #endif
    }

    var body: some View {
        let freed: Int64 = deletable.reduce(0) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 10) {
            Text("\(group.copies.count) identical copies · \(Formatters.bytes(freed)) can be freed", bundle: .module).font(.headline)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(group.copies) { item in
                        DuplicateCopyCard(item: item, kept: item.fileId == keptId) { keep(item.fileId) }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            Text(verbatim: "\(reason) \(hint)").font(.callout).foregroundStyle(.secondary)
            if deletable.isEmpty {
                Text("You don't have permission to delete the other copies.", bundle: .module).font(.callout).foregroundStyle(.secondary)
            } else {
                Button(String(localized: "Delete \(deletable.count) copies…", bundle: .module), role: .destructive) { delete(deletable) }
            }
        }
    }
}

struct DuplicateCopyCard: View {
    let item: MediaItem
    let kept: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                PreviewImage(item: item, bucket: 256)
                    .frame(width: 180, height: 180)
                    .clipShape(.rect(cornerRadius: Design.coverCornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.coverCornerRadius)
                            .strokeBorder(kept ? Color.accentColor : Color.clear, lineWidth: 3)
                    }
                    .overlay(alignment: .topLeading) { badge.padding(8) }
                    .opacity(kept ? 1 : 0.75)
                FileNameLabel(item: item)
                Text(Formatters.bytes(item.size)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 180, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(kept ? .isSelected : [])
    }

    var badge: some View {
        Label(
            kept ? String(localized: "Keep", bundle: .module) : String(localized: "Delete", bundle: .module),
            systemImage: kept ? "checkmark.circle.fill" : "trash"
        )
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(.white)
        .background(kept ? Color.accentColor : Color.black.opacity(0.55), in: .capsule)
    }
}

struct FreeSpaceScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var categories: [Cleanup.Candidates] = []
    @State private var loaded = false
    @State private var pending: PendingServerDeletion?

    /// How many rows of a category are listed; the delete button still covers (and counts) all of them.
    static let listed = 50

    /// Reads the possible candidates (a store query, not the whole index) and classifies them, off the main actor.
    nonisolated static func load(_ library: LibraryStore) async -> [Cleanup.Candidates] {
        Cleanup.candidates((try? await library.cleanupCandidates()) ?? [])
    }

    static func title(_ category: Cleanup.Category) -> String {
        switch category {
        case .screenshots: String(localized: "Screenshots", bundle: .module)
        case .screenRecordings: String(localized: "Screen recordings", bundle: .module)
        case .largeVideos: String(localized: "Large videos", bundle: .module)
        }
    }

    var body: some View {
        List {
            if !categories.isEmpty {
                Text(
                    "Screenshots, screen recordings and large videos that take up storage on your Nextcloud server. Deleting them here removes them from the server and from all your devices.",
                    bundle: .module
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(categories, id: \.category) { category in
                Section {
                    ForEach(category.items.prefix(Self.listed)) { item in
                        HStack(spacing: 12) {
                            PreviewImage(item: item, bucket: 256).frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 6))
                            FileNameLabel(item: item)
                            Spacer()
                            Text(Formatters.bytes(item.size)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .contextMenu {
                            Button(String(localized: "Delete…", bundle: .module), role: .destructive) { ask([item]) }
                        }
                    }
                    if category.items.count > Self.listed {
                        Text("and \(category.items.count - Self.listed) more", bundle: .module).foregroundStyle(.secondary)
                    }
                    Button(String(localized: "Delete \(category.items.count) items…", bundle: .module), role: .destructive) {
                        ask(category.items)
                    }
                } header: {
                    Text("\(Self.title(category.category)) · \(Formatters.bytes(category.totalBytes))", bundle: .module)
                }
            }
        }
        .overlay {
            if !loaded {
                ProgressView(String(localized: "Looking for files to clean up…", bundle: .module))
            } else if categories.isEmpty {
                ContentUnavailableView(
                    String(localized: "Nothing to clean up", bundle: .module), systemImage: "checkmark.seal",
                    description: Text(
                        "Screenshots, screen recordings and large videos that take up storage on your Nextcloud server appear here.",
                        bundle: .module))
            }
        }
        .navigationTitle(String(localized: "Free up server space", bundle: .module))
        .serverDeleteConfirmation($pending, session: session)
        .task {
            guard let services = session.services else { return }
            categories = await Self.load(services.library)
            loaded = true
        }
    }

    func ask(_ items: [MediaItem]) {
        let ids = Set(items.map(\.fileId))
        pending = PendingServerDeletion(items: items) {
            categories = categories.compactMap { category in
                var remaining = category
                remaining.items.removeAll { ids.contains($0.fileId) }
                return remaining.items.isEmpty ? nil : remaining
            }
        }
    }
}

// MARK: - Extract text (SPEC §7.20)

struct ExtractTextSheet: View {
    let item: MediaItem
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let text {
                    Text(text.isEmpty ? String(localized: "No text found.", bundle: .module) : text).textSelection(.enabled).padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let error {
                    Text(error).foregroundStyle(.red).padding()
                } else {
                    ProgressView(String(localized: "Reading text…", bundle: .module)).padding(40)
                }
            }
            .navigationTitle(String(localized: "Text in photo", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done", bundle: .module)) { dismiss() } }
                if let text, !text.isEmpty {
                    ToolbarItem(placement: .primaryAction) { Button(String(localized: "Copy", bundle: .module)) { Clipboard.copy(text) } }
                }
            }
            .task { await extract() }
        }
        .frame(minWidth: 420, minHeight: 400)
    }

    /// Server OCR when available, else Vision on the device.
    func extract() async {
        guard let services = session.services else { return }
        if session.features.has(.taskOCR), let result = try? await services.api.extractText(fileId: item.fileId) {
            text = result
            return
        }
        do {
            let file = try await services.images.originals.original(
                fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            let observations = try await request.perform(on: file)
            text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Ask your photos (SPEC SR-4)

@Generable
struct AskFilters {
    @Guide(description: "Start date YYYY-MM-DD, or empty") var start: String
    @Guide(description: "End date YYYY-MM-DD, or empty") var end: String
    @Guide(description: "Place names from the list, or empty") var places: [String]
    @Guide(description: "Tag names from the list, or empty") var tags: [String]
    @Guide(description: "A word to look for in file names or descriptions, or empty") var name: String
}

enum AskPhotos {
    /// A language model can answer: the server's Assistant, or the one on this device.
    @MainActor static func isAvailable(_ session: SessionModel) -> Bool {
        if session.features.has(.taskText2Text) { return true }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func prompt(question: String, places: [String], tags: [String]) -> String {
        """
        Today is \(Date().formatted(.iso8601.year().month().day())). Turn the question into photo search filters.
        Known places: \(places.prefix(500).joined(separator: ", ")).
        Known tags: \(tags.prefix(500).joined(separator: ", ")).
        Answer only with JSON {"start":"YYYY-MM-DD","end":"YYYY-MM-DD","places":[],"tags":[],"name":""}.
        Question: \(question)
        """
    }

    /// On-device language model when available, else the server's Assistant; returns validated filters.
    @MainActor static func filters(for question: String, session: SessionModel, places: [String], tags: [(id: Int, name: String)])
        async throws
        -> [SearchFilter]
    {
        let text = prompt(question: question, places: places, tags: tags.map(\.name))
        var answer: AskFilters?
        if session.features.has(.taskText2Text), let services = session.services {
            let reply = try await services.api.generateText(text)
            answer = parse(reply)
        } else if case .available = SystemLanguageModel.default.availability {
            let model = LanguageModelSession()
            answer = try await model.respond(to: text, generating: AskFilters.self).content
        }
        guard let answer else {
            throw NetworkError.unsupportedServer(String(localized: "No language model is available.", bundle: .module))
        }
        var filters: [SearchFilter] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        if let start = formatter.date(from: answer.start), let end = formatter.date(from: answer.end.isEmpty ? answer.start : answer.end) {
            filters.append(
                .dateRange(
                    start: start, end: end.addingTimeInterval(86_400),
                    label: (start..<end.addingTimeInterval(86_400)).formatted(.interval.day().month().year())))
        }
        let placeSet = Dictionary(places.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        filters += answer.places.compactMap { placeSet[$0.lowercased()].map { .place($0) } }
        filters += answer.tags.compactMap { name in
            tags.first { $0.name.lowercased() == name.lowercased() }.map { .tag(id: $0.id, name: $0.name) }
        }
        if !answer.name.isEmpty { filters.append(.text(answer.name)) }
        return filters
    }

    /// Parses the server's reply: strips `<think>` blocks and takes the outermost JSON object.
    static func parse(_ reply: String) -> AskFilters? {
        var text = reply
        while let start = text.range(of: "<think>"), let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"),
            let data = String(text[open...close]).data(using: .utf8),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return AskFilters(
            start: json["start"]?.string ?? "", end: json["end"]?.string ?? "", places: json["places"]?.array?.compactMap(\.string) ?? [],
            tags: json["tags"]?.array?.compactMap(\.string) ?? [], name: json["name"]?.string ?? "")
    }
}

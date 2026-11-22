// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import FoundationModels
import LocalAuthentication
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosNetworking
import SwiftUI
import Vision

// MARK: - Recently deleted (SPEC §7.14)

struct RecentlyDeletedScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var items: [TrashedItem] = []
    @State private var unlocked = false
    @State private var confirmEmpty = false
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
                        Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                            Task { await run { try await $0.deletePermanently(item) } }
                        }
                    }
                    .contextMenu {
                        Button(String(localized: "Restore", bundle: .module)) { Task { await run { try await $0.restore(item) } } }
                        Button(String(localized: "Delete permanently", bundle: .module), role: .destructive) {
                            Task { await run { try await $0.deletePermanently(item) } }
                        }
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
        items = (try? await services.api.trash(mimeTypes: session.features.allMimeTypes)) ?? []
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

// MARK: - Duplicates and Free up space (SPEC §7.15)

struct DuplicatesScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var groups: [Duplicates.Group] = []
    @State private var items: [FileID: MediaItem] = [:]
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(Array(group.items.enumerated()), id: \.element) { index, id in
                        if let item = items[id] {
                            HStack {
                                PreviewImage(item: item, bucket: 64).frame(width: 48, height: 48).clipShape(.rect(cornerRadius: 6))
                                VStack(alignment: .leading) {
                                    Text(item.path).lineLimit(1).truncationMode(.middle)
                                    Text(index == 0 ? String(localized: "Kept", bundle: .module) : Formatters.bytes(item.size)).font(
                                        .caption
                                    )
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button(String(localized: "Delete \(group.items.count - 1) copies", bundle: .module), role: .destructive) {
                        Task {
                            await session.delete(group.items.dropFirst().compactMap { items[$0] })
                            groups.removeAll { $0.id == group.id }
                        }
                    }
                } header: {
                    Text("\(Formatters.bytes(group.wastedBytes)) can be freed", bundle: .module)
                }
            }
        }
        .overlay {
            if loaded && groups.isEmpty {
                ContentUnavailableView(String(localized: "No duplicates", bundle: .module), systemImage: "checkmark.seal")
            } else if !loaded {
                ProgressView()
            }
        }
        .navigationTitle(String(localized: "Duplicates", bundle: .module))
        .task {
            guard let services = session.services else { return }
            let all = (try? services.library.allVisibleItems()) ?? []
            items = Dictionary(all.map { ($0.fileId, $0) }, uniquingKeysWith: { a, _ in a })
            groups = Duplicates.groups(all)
            loaded = true
        }
    }
}

struct FreeSpaceScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var categories: [(title: String, items: [MediaItem])] = []
    @State private var confirm: [MediaItem]?

    static let screenshotNames = ["screenshot", "bildschirmfoto", "capture d", "captura de pantalla", "schermafbeelding", "screen shot"]
    static let recordingNames = [
        "screen recording", "bildschirmaufnahme", "enregistrement de l", "grabación de pantalla", "schermopname", "screenrecording",
    ]

    var body: some View {
        List {
            ForEach(categories, id: \.title) { category in
                Section {
                    ForEach(category.items.prefix(50)) { item in
                        HStack {
                            PreviewImage(item: item, bucket: 64).frame(width: 48, height: 48).clipShape(.rect(cornerRadius: 6))
                            Text(item.name).lineLimit(1)
                            Spacer()
                            Text(Formatters.bytes(item.size)).foregroundStyle(.secondary)
                        }
                    }
                    Button(String(localized: "Delete all \(category.items.count)", bundle: .module), role: .destructive) {
                        confirm = category.items
                    }
                } header: {
                    Text("\(category.title) · \(Formatters.bytes(category.items.reduce(0) { $0 + $1.size }))")
                }
            }
        }
        .navigationTitle(String(localized: "Free up space", bundle: .module))
        .confirmationDialog(
            String(localized: "Delete \(confirm?.count ?? 0) items?", bundle: .module),
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible
        ) {
            Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                if let items = confirm { Task { await session.delete(items) } }
            }
        }
        .task {
            let all = ((try? session.services?.library.allVisibleItems()) ?? []).filter(\.permissions.canDelete)
            func named(_ item: MediaItem, _ patterns: [String]) -> Bool {
                let name = item.name.lowercased()
                return patterns.contains { name.contains($0) }
            }
            let screenshots = all.filter { $0.kind == .image && (named($0, Self.screenshotNames) || $0.mimeType == "image/png") }
            let recordings = all.filter { $0.kind == .video && named($0, Self.recordingNames) }
            let recordingIds = Set(recordings.map(\.fileId))
            let large = all.filter { $0.kind == .video && $0.size > 100 * 1024 * 1024 && !recordingIds.contains($0.fileId) }
            categories = [
                (String(localized: "Screenshots", bundle: .module), screenshots.sorted { $0.size > $1.size }),
                (String(localized: "Screen recordings", bundle: .module), recordings.sorted { $0.size > $1.size }),
                (String(localized: "Large videos", bundle: .module), large.sorted { $0.size > $1.size }),
            ].filter { !$0.items.isEmpty }
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

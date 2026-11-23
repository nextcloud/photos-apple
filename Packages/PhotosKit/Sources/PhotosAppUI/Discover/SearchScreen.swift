// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Evaluates search filters on the local index (SPEC SR-2): AND between kinds, OR within a kind.
enum SearchEvaluator {
    @MainActor static func items(for filters: [SearchFilter], session: SessionModel) async throws -> [MediaItem] {
        guard let services = session.services else { return [] }
        var items = try services.library.allVisibleItems()
        let places = filters.compactMap { if case .place(let name) = $0 { name } else { nil } }
        if !places.isEmpty { items = items.filter { $0.place.map(places.contains) ?? false } }
        let ranges = filters.compactMap { if case .dateRange(let start, let end, _) = $0 { (start, end) } else { nil } }
        if !ranges.isEmpty { items = items.filter { item in ranges.contains { item.timestamp >= $0.0 && item.timestamp < $0.1 } } }
        let texts = filters.compactMap { if case .text(let text) = $0 { text } else { nil } }
        for text in texts {
            items = items.filter { item in
                [item.name, item.caption ?? "", item.place ?? "", item.directory].contains {
                    $0.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
        if filters.contains(.favorites) { items = items.filter(\.isFavorite) }
        if filters.contains(.videos) { items = items.filter { $0.kind == .video } }
        let tagIds = filters.compactMap { if case .tag(let id, _) = $0 { id } else { nil } }
        if !tagIds.isEmpty {
            var allowed = Set<FileID>()
            for id in tagIds { allowed.formUnion(try await services.api.tagContent(id).map(\.fileId)) }
            items = items.filter { allowed.contains($0.fileId) }
        }
        let people = filters.compactMap { if case .person(let name) = $0 { name } else { nil } }
        if !people.isEmpty {
            var allowed = Set<FileID>()
            let key = await session.recognizeKey()
            for name in people { allowed.formUnion(try await services.api.personPhotos(name, key: key).map(\.item.fileId)) }
            items = items.filter { allowed.contains($0.fileId) }
        }
        let albums = filters.compactMap { if case .album(let id, _) = $0 { id } else { nil } }
        if !albums.isEmpty {
            var allowed = Set<FileID>()
            for id in albums { allowed.formUnion(try services.collections.albumItems(albumId: id).map(\.fileId)) }
            items = items.filter { allowed.contains($0.fileId) }
        }
        return items
    }

    /// Filters that can be stored in a smart album (`AlbumFilters`: places, dates, names, tags).
    static func albumFilters(_ filters: [SearchFilter]) -> AlbumFilters {
        var result = AlbumFilters()
        for filter in filters {
            switch filter {
            case .place(let name): result.places.append(name)
            case .dateRange(let start, let end, _):
                result.dateRanges.append(AlbumFilters.DateRange(start: start, end: end.addingTimeInterval(-86_400)))
            case .text(let text): result.names.append(text)
            case .tag(_, let name): result.tags.append(name)
            default: break
            }
        }
        return result
    }

    static func searchFilters(_ filters: AlbumFilters) -> [SearchFilter] {
        filters.places.map { .place($0) } + filters.names.map { .text($0) }
            + filters.dateRanges.map {
                .dateRange(
                    start: $0.startDate, end: $0.endDateExclusive,
                    label: DateRangeLabel.string(for: $0.startDate..<$0.endDateExclusive))
            }
    }
}

/// The search tab (iPhone, iPad, Vision Pro) with its own search field. On the Mac the field is in the window toolbar.
struct SearchTab: View {
    @State private var query = ""
    @State private var filters: [SearchFilter] = []

    var body: some View {
        SearchScreen(query: $query, filters: $filters)
            .searchable(text: $query, prompt: Text("Places, people, dates…", bundle: .module))
    }
}

extension SearchFilter {
    var systemImage: String {
        switch self {
        case .place: "mappin"
        case .person: "person"
        case .tag: "tag"
        case .album: "rectangle.stack"
        case .dateRange: "calendar"
        case .text: "textformat"
        case .favorites: "heart"
        case .videos: "video"
        }
    }
}

struct SearchScreen: View {
    @Environment(SessionModel.self) private var session
    /// Text of the search field, which the caller provides.
    @Binding var query: String
    /// The chosen filters. On the Mac they are the tokens of the search field; elsewhere a row of chips above the results.
    @Binding var filters: [SearchFilter]
    @State private var vocabulary = SearchSuggestions.Vocabulary()
    @State private var feed = GridFeed()
    @State private var saving = false
    @State private var smartName = ""
    @AppStorage("gridColumns") private var columns = GridColumns.default
    @State private var asking = false
    @State private var askError: String?

    var suggestions: [SearchFilter] {
        SearchSuggestions.suggestions(for: query, vocabulary: vocabulary).filter { !filters.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if !os(macOS)
                if !filters.isEmpty { filterBar }
            #endif
            if !query.isEmpty {
                if query.split(separator: " ").count >= 3 {
                    Button {
                        ask()
                    } label: {
                        Label(
                            asking
                                ? String(localized: "Thinking…", bundle: .module) : String(localized: "Ask: “\(query)”", bundle: .module),
                            systemImage: "sparkles")
                    }
                    .disabled(asking)
                    .padding(.top, 8)
                }
                if let askError { Text(askError).font(.footnote).foregroundStyle(.red) }
                List(suggestions) { suggestion in
                    Button {
                        filters.append(suggestion)
                        query = ""
                    } label: {
                        // A full-width row: what it is, and what kind of thing it is.
                        HStack {
                            Label(suggestion.label, systemImage: suggestion.systemImage)
                            Spacer()
                            Text(kind(suggestion)).font(.callout).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .overlay {
                    if suggestions.isEmpty {
                        ContentUnavailableView(
                            String(localized: "No suggestions", bundle: .module), systemImage: "magnifyingglass",
                            description: Text("Try a place, an album, a date like “june 2023”, or part of a file name.", bundle: .module))
                    }
                }
            } else if filters.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Search your photos", bundle: .module), systemImage: "magnifyingglass")
                } description: {
                    Text("Places, people, tags, albums, dates like “june 2023”, or file names.", bundle: .module)
                } actions: {
                    HStack {
                        Button(String(localized: "Favorites", bundle: .module)) { filters.append(.favorites) }
                        Button(String(localized: "Videos", bundle: .module)) { filters.append(.videos) }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                MediaGridScreen(
                    feed: feed, title: String(localized: "Search", bundle: .module), showsHeaders: true,
                    emptyTitle: String(localized: "No results", bundle: .module), emptyMessage: "", columns: $columns
                ) {
                    Button {
                        smartName = filters.map(\.label).joined(separator: ", ")
                        saving = true
                    } label: {
                        Label(String(localized: "Save as smart album", bundle: .module), systemImage: "plus.rectangle.on.rectangle")
                    }
                    .help(String(localized: "Save as smart album", bundle: .module))
                }
                #if os(macOS)
                    .navigationSubtitle(feed.loaded ? String(localized: "\(feed.items.count) results", bundle: .module) : "")
                #endif
            }
        }
        .navigationTitle(String(localized: "Search", bundle: .module))
        .task { await loadVocabulary() }
        .task(id: filters) {
            guard !filters.isEmpty, let items = try? await SearchEvaluator.items(for: filters, session: session) else { return }
            feed.apply(items.map(GridMedia.init), flat: false)
        }
        .alert(String(localized: "Save as smart album", bundle: .module), isPresented: $saving) {
            TextField(String(localized: "Name", bundle: .module), text: $smartName)
            Button(String(localized: "Save", bundle: .module)) {
                Task { await session.saveSmartAlbum(SmartAlbum(name: smartName, filters: SearchEvaluator.albumFilters(filters))) }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        }
    }

    /// The active filters (click one to remove it) and the number of results.
    var filterBar: some View {
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(filters) { filter in
                        Button {
                            filters.removeAll { $0 == filter }
                        } label: {
                            Label(filter.label, systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel(Text("Remove filter \(filter.label)", bundle: .module))
                    }
                }
            }
            if query.isEmpty && feed.loaded {
                Text("\(feed.items.count) results", bundle: .module)
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// Natural-language search (SPEC SR-4).
    func ask() {
        asking = true
        askError = nil
        let question = query
        Task {
            defer { asking = false }
            do {
                let result = try await AskPhotos.filters(for: question, session: session, places: vocabulary.places, tags: vocabulary.tags)
                if result.isEmpty {
                    askError = String(localized: "I couldn't turn that into a search.", bundle: .module)
                } else {
                    filters = result
                    query = ""
                }
            } catch {
                askError = error.localizedDescription
            }
        }
    }

    /// What kind of filter a suggestion is, shown at the end of its row.
    func kind(_ filter: SearchFilter) -> String {
        switch filter {
        case .place: String(localized: "Place", bundle: .module)
        case .person: String(localized: "Person", bundle: .module)
        case .tag: String(localized: "Tag", bundle: .module)
        case .album: String(localized: "Album", bundle: .module)
        case .dateRange: String(localized: "Date", bundle: .module)
        case .text: String(localized: "Name or caption", bundle: .module)
        case .favorites: String(localized: "Favorites", bundle: .module)
        case .videos: String(localized: "Videos", bundle: .module)
        }
    }

    func loadVocabulary() async {
        guard let services = session.services else { return }
        let items = (try? services.library.allVisibleItems()) ?? []
        var places = Set(items.compactMap(\.place))
        places.formUnion(((try? services.collections.albums(.own)) ?? []).map(\.location).filter { !$0.isEmpty })
        let albums = (((try? services.collections.albums(.own)) ?? []) + ((try? services.collections.albums(.shared)) ?? [])).map {
            ($0.id, $0.title)
        }
        vocabulary = SearchSuggestions.Vocabulary(places: places.sorted(), albums: albums)
        if session.features.has(.systemtags), let tags = try? await services.api.tagsInUse() {
            vocabulary.tags = tags.map { ($0.id, $0.name) }
        }
        if session.features.has(.recognize), let people = try? await services.api.people(key: await session.recognizeKey()) {
            vocabulary.people = people.filter { !$0.isUnnamed }.map(\.name)
        }
    }
}

/// Saved filters (SPEC SR-5).
struct SmartAlbumsScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var albums: [(SmartAlbum, isLocal: Bool)] = []

    var body: some View {
        List {
            ForEach(albums, id: \.0.id) { album, isLocal in
                NavigationLink {
                    ItemsScreen(title: album.name) { _ in
                        try await SearchEvaluator.items(for: SearchEvaluator.searchFilters(album.filters), session: session)
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(album.name)
                        if isLocal { Text("On this device", bundle: .module).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .swipeActions {
                    Button(String(localized: "Delete", bundle: .module), role: .destructive) {
                        Task {
                            await session.deleteSmartAlbum(album)
                            albums = session.smartAlbums()
                        }
                    }
                }
            }
        }
        .overlay {
            if albums.isEmpty {
                ContentUnavailableView(
                    String(localized: "No smart albums", bundle: .module), systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Search for something and save it as a smart album.", bundle: .module))
            }
        }
        .navigationTitle(String(localized: "Smart albums", bundle: .module))
        .task { albums = session.smartAlbums() }
    }
}

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// Evaluates search filters on the local index (SPEC SR-2): AND between kinds, OR within a kind.
enum SearchEvaluator {
    /// The store query for a set of filter chips. Everything the index knows is answered by one SQL query (full-text
    /// index and indexed columns, SPEC SR-3) on a database queue. Tag and person memberships are asked from the server,
    /// which knows the latest; without a connection the copies stored for search answer (`LabelSync`).
    @MainActor static func search(for filters: [SearchFilter], session: SessionModel) async throws -> LibrarySearch? {
        guard let services = session.services else { return nil }
        var search = LibrarySearch(filters: filters)
        let labels = LabelStore(database: services.database)
        let tagIds = filters.compactMap { if case .tag(let id, _) = $0 { id } else { nil } }
        if !tagIds.isEmpty {
            var allowed = Set<FileID>()
            // A tag of a smart album that no longer exists on the server matches nothing.
            for id in tagIds where id != unknownTagId {
                allowed.formUnion(
                    try await membership(
                        server: { try await services.api.tagContent(id).map(\.fileId) }, local: { try labels.fileIds(withTag: id) }))
            }
            search.memberships.append(allowed)
        }
        let people = filters.compactMap { if case .person(let name) = $0 { name } else { nil } }
        if !people.isEmpty {
            var allowed = Set<FileID>()
            let key = await session.recognizeKey()
            for name in people {
                allowed.formUnion(
                    try await membership(
                        server: { try await services.api.personPhotos(name, key: key).map(\.item.fileId) },
                        local: { try labels.fileIds(ofPerson: name) }))
            }
            search.memberships.append(allowed)
        }
        return search
    }

    /// The server's answer, or the stored copy when the server cannot be asked. Nothing stored: the server's error.
    @MainActor static func membership(
        server: () async throws -> [FileID], local: () throws -> Set<FileID>
    ) async throws -> Set<FileID> {
        do {
            return Set(try await server())
        } catch {
            let stored = (try? local()) ?? []
            if stored.isEmpty { throw error }
            return stored
        }
    }

    /// Search results as grid rows.
    @MainActor static func gridItems(for filters: [SearchFilter], session: SessionModel) async throws -> [GridMedia] {
        guard let services = session.services, let search = try await search(for: filters, session: session) else { return [] }
        return try await services.library.search(search)
    }

    /// Search results as full items (smart albums).
    @MainActor static func items(for filters: [SearchFilter], session: SessionModel) async throws -> [MediaItem] {
        guard let services = session.services, let search = try await search(for: filters, session: session) else { return [] }
        return try await services.library.searchItems(search)
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

    /// Tag id of a smart-album tag whose name the server no longer knows.
    static let unknownTagId = -1

    /// The search filters of a smart album. Smart albums store tags by name (as the web app does), so the server's tags
    /// map them back to ids; a tag that is gone matches nothing rather than being dropped, which would widen the album.
    static func searchFilters(_ filters: AlbumFilters, tags: [SystemTag] = []) -> [SearchFilter] {
        let ids = Dictionary(tags.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let tagFilters: [SearchFilter] = filters.tags.map { .tag(id: ids[$0] ?? unknownTagId, name: $0) }
        let dateFilters: [SearchFilter] = filters.dateRanges.map {
            .dateRange(
                start: $0.startDate, end: $0.endDateExclusive,
                label: DateRangeLabel.string(for: $0.startDate..<$0.endDateExclusive))
        }
        return filters.places.map { .place($0) } + filters.names.map { .text($0) } + dateFilters + tagFilters
    }

    /// The items of a smart album.
    @MainActor static func items(of album: SmartAlbum, session: SessionModel) async throws -> [MediaItem] {
        var tags: [SystemTag] = []
        if !album.filters.tags.isEmpty, session.features.has(.systemtags), let services = session.services {
            tags = try await services.api.tagsInUse()
        }
        return try await items(for: searchFilters(album.filters, tags: tags), session: session)
    }
}

/// The search tab (iPhone, iPad, Vision Pro) with its own search field. On the Mac the field is in the window toolbar.
struct SearchTab: View {
    @Environment(AppModel.self) private var app
    @Environment(\.commandPalette) private var palette
    @State private var query = ""
    @State private var filters: [SearchFilter] = []
    @State private var submissions = 0

    var body: some View {
        SearchScreen(query: $query, filters: $filters, submissions: submissions)
            .searchable(text: $query, prompt: Text("Places, people, dates…", bundle: .module))
            // Return searches: the top suggestion, else the typed text.
            .onSubmit(of: .search) { submissions += 1 }
            // A search link or the "Search photos" intent (SPEC §4.8, §7.23).
            .onChange(of: app.requestedSearch, initial: true) { _, text in
                guard let text else { return }
                app.requestedSearch = nil
                query = text
                filters = []
            }
            // A search chosen in the command palette (SPEC §16.2).
            .onChange(of: palette?.pendingSearch, initial: true) { _, pending in
                guard let pending else { return }
                palette?.pendingSearch = nil
                query = ""
                filters = pending
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { CommandPaletteButton() }
            }
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
        case .photos: "photo"
        case .label: "eye"
        case .rating: "star"
        }
    }
}

struct SearchScreen: View {
    @Environment(SessionModel.self) private var session
    /// Text of the search field, which the caller provides.
    @Binding var query: String
    /// The chosen filters. On the Mac they are the tokens of the search field; elsewhere a row of chips above the results.
    @Binding var filters: [SearchFilter]
    /// Counts Return in the search field. The field belongs to the window (the Mac's toolbar) or the tab, this screen
    /// knows the suggestions: each window or tab passes its own count, so Return searches in that window only.
    var submissions = 0
    @State private var vocabulary = SearchSuggestions.Vocabulary()
    /// Counts the steps in which the vocabulary arrives (it loads off the main thread, tags and people from the server),
    /// so that suggestions for text typed before it was there are computed again.
    @State private var vocabularyRevision = 0
    @State private var feed = GridFeed()
    @State private var saving = false
    @State private var smartName = ""
    @AppStorage("gridColumns") private var columns = GridColumns.default
    @State private var asking = false
    @State private var askError: String?
    /// Suggestions for the typed text, computed after a pause in typing and off the main thread.
    @State private var matches: [SearchFilter] = []
    /// Why the search could not be run (a tag or person filter needs the server).
    @State private var searchError: String?
    /// Counts "Try again", so the same filters are evaluated once more.
    @State private var searchAttempt = 0
    @State private var recents = RecentSearches()
    /// What the typed words say as chips (SPEC §16.2): read on the device at once, then refined by the language model
    /// where there is one.
    @State private var understood: NaturalSearch.Interpretation?
    /// Whether the language model added to `understood`.
    @State private var understoodByModel = false
    /// Words photos are known to show (on-device labels), for reading searches.
    @State private var labels: [String] = []

    var suggestions: [SearchFilter] { matches.filter { !filters.contains($0) } }

    /// How long typing must pause before suggestions are computed.
    static let typingPause: Duration = .milliseconds(120)

    nonisolated static func suggestions(for query: String, vocabulary: SearchSuggestions.Vocabulary) async -> [SearchFilter] {
        SearchSuggestions.suggestions(for: query, vocabulary: vocabulary)
    }

    func updateSuggestions() async {
        let typed = query
        if typed.isEmpty {
            matches = []
            understood = nil
            return
        }
        // The first suggestions come at once; while they are on screen, further typing is debounced.
        if !matches.isEmpty { try? await Task.sleep(for: Self.typingPause) }
        guard !Task.isCancelled else { return }
        let result = await Self.suggestions(for: typed, vocabulary: vocabulary)
        let parsed = await Self.interpret(typed, vocabulary: naturalVocabulary)
        guard !Task.isCancelled else { return }
        matches = result
        understood = parsed
        understoodByModel = false
        await refineWithModel(typed, parsed: parsed)
    }

    var naturalVocabulary: NaturalSearch.Vocabulary { NaturalSearch.Vocabulary(vocabulary, labels: labels) }

    nonisolated static func interpret(_ query: String, vocabulary: NaturalSearch.Vocabulary) async -> NaturalSearch.Interpretation {
        NaturalSearch.interpret(query, vocabulary: vocabulary)
    }

    /// After a longer pause in typing, the language model reads the words too (where Apple Intelligence is available).
    func refineWithModel(_ typed: String, parsed: NaturalSearch.Interpretation) async {
        // Single names are what the suggestions are for.
        guard NaturalSearchModel.isAvailable, FuzzyMatch.words(typed).count >= 2 else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled,
            let model = try? await NaturalSearchModel.filters(for: typed, vocabulary: naturalVocabulary), !Task.isCancelled, query == typed
        else { return }
        let merged = NaturalSearch.merge(parsed, model: model)
        if merged != parsed {
            understood = merged
            understoodByModel = true
        }
    }

    /// Chips worth offering for the typed words as a whole: more than one, or one with words left over.
    var understoodFilters: [SearchFilter]? {
        guard let understood, understood.isStructured else { return nil }
        let chips = understood.filters
        guard chips.count >= 2 || understoodByModel else { return nil }
        return chips
    }

    var body: some View {
        VStack(spacing: 0) {
            if !filters.isEmpty {
                SearchChipBar(
                    filters: $filters, vocabulary: vocabulary, count: query.isEmpty && feed.loaded ? feed.items.count : nil)
            }
            if !query.isEmpty {
                suggestionList
            } else if filters.isEmpty {
                startScreen
            } else if let searchError {
                // The search itself failed (a tag or person filter while offline): say so instead of loading forever.
                ContentUnavailableView {
                    Label(String(localized: "Couldn't search", bundle: .module), systemImage: "exclamationmark.magnifyingglass")
                } description: {
                    Text(searchError)
                } actions: {
                    Button(String(localized: "Try again", bundle: .module)) { searchAttempt += 1 }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                MediaGridScreen(
                    feed: feed, title: String(localized: "Search", bundle: .module), showsHeaders: true,
                    emptyTitle: String(localized: "No results", bundle: .module),
                    emptyMessage: String(localized: "Nothing in your library matches these filters.", bundle: .module), columns: $columns,
                    emptyAction: GridEmptyAction(title: String(localized: "Clear search", bundle: .module)) { filters = [] }
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
        .task {
            guard let services = session.services else { return }
            labels = await Self.knownLabels(services.database)
        }
        .task {
            if let layout = session.services?.layout { recents = RecentSearches.load(account: session.account.id, layout: layout) }
        }
        .task(id: SuggestionInput(query: query, vocabularyRevision: vocabularyRevision)) { await updateSuggestions() }
        .task(id: SearchRun(filters: filters, attempt: searchAttempt)) { await runSearch() }
        .onChange(of: submissions) { _, _ in commit() }
        .alert(String(localized: "Save as smart album", bundle: .module), isPresented: $saving) {
            TextField(String(localized: "Name", bundle: .module), text: $smartName)
            Button(String(localized: "Save", bundle: .module)) {
                Task { await session.saveSmartAlbum(SmartAlbum(name: smartName, filters: SearchEvaluator.albumFilters(filters))) }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        }
    }

    /// The filters and the attempt a search run belongs to.
    struct SearchRun: Hashable {
        var filters: [SearchFilter]
        var attempt: Int
    }

    /// Evaluates the filters. A failure is shown with "Try again"; a search that worked is remembered.
    func runSearch() async {
        guard !filters.isEmpty else {
            searchError = nil
            return
        }
        let searched = filters
        do {
            let items = try await SearchEvaluator.gridItems(for: searched, session: session)
            // A newer set of filters is already being evaluated.
            guard !Task.isCancelled else { return }
            searchError = nil
            feed.apply(items, flat: false)
            remember(searched)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
    }

    func remember(_ searched: [SearchFilter]) {
        recents.add(searched)
        saveRecents()
    }

    func saveRecents() {
        guard let layout = session.services?.layout else { return }
        recents.save(account: session.account.id, layout: layout)
    }

    /// Return in the search field: the top suggestion becomes a filter, else the typed text is searched for.
    func commit() {
        let typed = query
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            // Not the list on screen: it may still belong to what was typed a moment ago.
            let current = await Self.suggestions(for: typed, vocabulary: vocabulary)
            let parsed = await Self.interpret(typed, vocabulary: naturalVocabulary)
            guard query == typed else { return }
            // Words that say several things ("videos of Anna at the beach") become all their chips.
            let whole = understood?.filters ?? parsed.filters
            if parsed.isStructured, whole.count >= 2 {
                apply(whole)
                return
            }
            guard let filter = SearchCommit.filter(for: typed, suggestions: current, active: filters) else { return }
            filters.append(filter)
            query = ""
        }
    }

    /// Adds chips to the search (replacing a chip of the same date or media kind) and clears the field.
    func apply(_ chips: [SearchFilter]) {
        var result = filters
        for chip in chips where !result.contains(chip) {
            switch chip {
            case .dateRange: result.removeAll { if case .dateRange = $0 { true } else { false } }
            case .videos, .photos: result.removeAll { $0 == .videos || $0 == .photos }
            case .rating: result.removeAll { if case .rating = $0 { true } else { false } }
            default: break
            }
            result.append(chip)
        }
        filters = result
        query = ""
    }

    /// Suggestions for the typed text, with "Ask" on top where a language model can answer.
    @ViewBuilder var suggestionList: some View {
        if let chips = understoodFilters {
            understoodRow(chips)
        }
        // The server's Assistant (SPEC SR-4); on devices with Apple Intelligence the words are read as they are typed.
        if !NaturalSearchModel.isAvailable, AskPhotos.isAvailable(session) {
            Button {
                ask()
            } label: {
                Label(
                    asking ? String(localized: "Thinking…", bundle: .module) : String(localized: "Ask: “\(query)”", bundle: .module),
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
    }

    /// "Search for: Videos · Anna · beach · Summer 2026": the typed words as chips, on top of the suggestions.
    func understoodRow(_ chips: [SearchFilter]) -> some View {
        Button {
            apply(chips)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: understoodByModel ? "sparkles" : "text.magnifyingglass")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips) { chip in
                            Label(chip.label, systemImage: chip.systemImage)
                                .font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.tint.opacity(0.14), in: .capsule)
                        }
                    }
                }
                Image(systemName: "return").foregroundStyle(.secondary).font(.caption).accessibilityHidden(true)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text(
                "Search for \(AccessibilityText.join(chips.map(\.label)))", bundle: .module,
                comment: "VoiceOver: the typed words understood as search filters, e.g. Search for Videos, Anna, beach, Summer 2026."))
    }

    /// Before anything is typed: what can be searched for, or the recent searches.
    @ViewBuilder var startScreen: some View {
        if recents.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "Search your photos", bundle: .module), systemImage: "magnifyingglass")
            } description: {
                Text("Places, people, tags, albums, dates like “june 2023”, or file names.", bundle: .module)
            } actions: {
                quickFilters
            }
        } else {
            List {
                Section {
                    ForEach(recents.entries, id: \.self) { (search: [SearchFilter]) in
                        Button {
                            filters = search
                        } label: {
                            Label(RecentSearches.title(search), systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(String(localized: "Remove", bundle: .module), role: .destructive) { forget(search) }
                        }
                        .contextMenu {
                            Button(String(localized: "Remove from recent searches", bundle: .module)) { forget(search) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent searches", bundle: .module)
                        Spacer()
                        Button(String(localized: "Clear", bundle: .module)) {
                            recents.clear()
                            saveRecents()
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .accessibilityLabel(Text("Clear recent searches", bundle: .module))
                    }
                }
                Section {
                    quickFilters
                }
            }
            .listStyle(.inset)
        }
    }

    var quickFilters: some View {
        HStack {
            Button(String(localized: "Favorites", bundle: .module)) { filters.append(.favorites) }
            Button(String(localized: "Videos", bundle: .module)) { filters.append(.videos) }
        }
        .buttonStyle(.bordered)
    }

    func forget(_ search: [SearchFilter]) {
        recents.remove(search)
        saveRecents()
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
        case .text:
            String(
                localized: "Name, caption or tag", bundle: .module,
                comment:
                    "Kind of a search suggestion: the text is searched in file names, captions, places, tags, people and recognised content."
            )
        case .favorites: String(localized: "Favorites", bundle: .module)
        case .videos: String(localized: "Videos", bundle: .module)
        case .photos: String(localized: "Photos", bundle: .module)
        case .label: SearchChipWording.kind(filter)
        case .rating: SearchChipWording.kind(filter)
        }
    }

    /// Words photos are known to show, off the main thread.
    nonisolated static func knownLabels(_ database: AccountDatabase) async -> [String] {
        (try? PhotoDescriptionStore(database: database).knownLabels(limit: 1500)) ?? []
    }

    func loadVocabulary() async {
        guard let services = session.services else { return }
        var places = Set((try? await services.library.placeNames()) ?? [])
        places.formUnion(((try? services.collections.albums(.own)) ?? []).map(\.location).filter { !$0.isEmpty })
        let albums = (((try? services.collections.albums(.own)) ?? []) + ((try? services.collections.albums(.shared)) ?? [])).map {
            ($0.id, $0.title)
        }
        vocabulary = SearchSuggestions.Vocabulary(places: places.sorted(), albums: albums)
        vocabularyRevision += 1
        // Tags and people from the server; offline, the ones stored for search.
        let labels = LabelStore(database: services.database)
        if session.features.has(.systemtags),
            let tags = (try? await services.api.tagsInUse()) ?? (try? labels.tags().filter { $0.itemCount != 0 })
        {
            vocabulary.tags = tags.map { ($0.id, $0.name) }
            vocabularyRevision += 1
        }
        if session.features.has(.recognize) {
            let people = (try? await services.api.people(key: await session.recognizeKey()))?.filter { !$0.isUnnamed }.map(\.name)
            if let names = people ?? (try? labels.personNames()) {
                vocabulary.people = names
                vocabularyRevision += 1
            }
        }
    }

    /// What the suggestions depend on. On the Mac the screen opens with the first typed letters already in the field,
    /// before the vocabulary has loaded.
    struct SuggestionInput: Hashable {
        var query: String
        var vocabularyRevision: Int
    }
}

/// Saved filters (SPEC SR-5).
struct SmartAlbumsScreen: View {
    @Environment(SessionModel.self) private var session
    @State private var albums: [(SmartAlbum, isLocal: Bool)] = []
    /// The smart album waiting for the confirmation of its deletion.
    @State private var deleting: SmartAlbum?

    var body: some View {
        List {
            ForEach(albums, id: \.0.id) { album, isLocal in
                NavigationLink {
                    ItemsScreen(title: album.name) { _ in
                        try await SearchEvaluator.items(of: album, session: session)
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(album.name)
                        if isLocal { Text("On this device", bundle: .module).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .swipeActions {
                    Button(String(localized: "Delete", bundle: .module), role: .destructive) { deleting = album }
                }
                // On the Mac there is no swipe.
                .contextMenu {
                    Button(String(localized: "Delete…", bundle: .module), role: .destructive) { deleting = album }
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
        .confirmationDialog(
            String(localized: "Delete the smart album “\(deleting?.name ?? "")”?", bundle: .module),
            isPresented: Binding(get: { deleting != nil }, set: { shown in if !shown { deleting = nil } }), titleVisibility: .visible,
            presenting: deleting
        ) { (album: SmartAlbum) in
            Button(String(localized: "Delete smart album", bundle: .module), role: .destructive) {
                Task {
                    await session.deleteSmartAlbum(album)
                    albums = session.smartAlbums()
                }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: { _ in
            Text("The saved search is deleted. Your photos are not affected.", bundle: .module)
        }
    }
}

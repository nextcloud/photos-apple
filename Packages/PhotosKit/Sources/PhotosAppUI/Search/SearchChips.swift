// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosDomain
import PhotosModel
import SwiftUI

/// The search's filter chips (SPEC §16.2). A tap on a chip opens what can be changed about it — another person or
/// place, the year before or after, photos instead of videos, more or fewer stars, other words — and Remove. Results
/// follow every change.
struct SearchChipBar: View {
    @Binding var filters: [SearchFilter]
    var vocabulary: SearchSuggestions.Vocabulary
    /// The number of results, when known.
    var count: Int?
    @State private var editing: EditedChip?
    @State private var editedText = ""
    @State private var choosingDates: SearchFilter?

    struct EditedChip: Identifiable {
        var filter: SearchFilter
        var id: String { filter.id }
    }

    var body: some View {
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(filters) { filter in
                        chip(filter)
                    }
                }
                .padding(.vertical, 2)
            }
            if let count {
                Text("\(count) results", bundle: .module)
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .alert(
            String(localized: "Change search words", bundle: .module, comment: "Title of the alert that edits a word chip of the search."),
            isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), presenting: editing
        ) { chip in
            TextField(
                String(localized: "Words", bundle: .module, comment: "Field of the alert that edits a word chip of the search."),
                text: $editedText)
            Button(String(localized: "Done", bundle: .module)) {
                let text = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    remove(chip.filter)
                } else if case .label = chip.filter {
                    replace(chip.filter, with: .label(text))
                } else {
                    replace(chip.filter, with: .text(text))
                }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        }
        .sheet(item: Binding(get: { choosingDates.map(EditedChip.init) }, set: { choosingDates = $0?.filter })) { chip in
            DateRangeChooser(filter: chip.filter) { replacement in replace(chip.filter, with: replacement) }
        }
    }

    func chip(_ filter: SearchFilter) -> some View {
        Menu {
            changes(filter)
            Divider()
            Button(role: .destructive) {
                remove(filter)
            } label: {
                Label(String(localized: "Remove", bundle: .module), systemImage: "xmark.circle")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.systemImage).imageScale(.small)
                Text(filter.label).lineLimit(1)
                Image(systemName: "chevron.down").imageScale(.small).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        // The chip draws its own chevron (the Mac's menu button would add a second one).
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .accessibilityLabel(Text(AccessibilityText.join([SearchChipWording.kind(filter), filter.label])))
        .accessibilityHint(Text("Change or remove this filter", bundle: .module, comment: "VoiceOver hint of a search filter chip."))
    }

    /// What can be changed about a chip.
    @ViewBuilder func changes(_ filter: SearchFilter) -> some View {
        switch filter {
        case .dateRange(let start, let end, let label):
            let context = SearchDates.Context()
            if let earlier = SearchDates.shifted(start..<end, label: label, by: -1, context: context) {
                Button(earlier.label, systemImage: "chevron.backward") { replace(filter, with: earlier) }
            }
            if let later = SearchDates.shifted(start..<end, label: label, by: 1, context: context), later.label != label,
                case .dateRange(let laterStart, _, _) = later, laterStart <= Date()
            {
                Button(later.label, systemImage: "chevron.forward") { replace(filter, with: later) }
            }
            Button(PaletteWording.platform("Choose Dates…", "Choose dates…"), systemImage: "calendar") {
                choosingDates = filter
            }
        case .person(let name):
            alternatives(vocabulary.people.filter { $0 != name }, make: { .person($0) }, replacing: filter)
        case .place(let name):
            alternatives(vocabulary.places.filter { $0 != name }, make: { .place($0) }, replacing: filter)
        case .tag(let id, _):
            let tags = vocabulary.tags.filter { $0.id != id }
            Menu(SearchChipWording.otherTag) {
                ForEach(tags.prefix(40), id: \.id) { tag in
                    Button(tag.name) { replace(filter, with: .tag(id: tag.id, name: tag.name)) }
                }
            }
            .disabled(tags.isEmpty)
        case .album(let id, _):
            let albums = vocabulary.albums.filter { $0.id != id }
            Menu(SearchChipWording.otherAlbum) {
                ForEach(albums.prefix(40), id: \.id) { album in
                    Button(album.title) { replace(filter, with: .album(id: album.id, title: album.title)) }
                }
            }
            .disabled(albums.isEmpty)
        case .videos:
            Button(SearchChipWording.photosInstead, systemImage: "photo") { replace(filter, with: .photos) }
        case .photos:
            Button(SearchChipWording.videosInstead, systemImage: "video") { replace(filter, with: .videos) }
        case .rating(let stars):
            ForEach(1...CullingTags.maxRating, id: \.self) { (value: Int) in
                Button {
                    replace(filter, with: .rating(atLeast: value))
                } label: {
                    if value == stars {
                        Label(SearchFilter.rating(atLeast: value).label, systemImage: "checkmark")
                    } else {
                        Text(SearchFilter.rating(atLeast: value).label)
                    }
                }
            }
        case .text(let text), .label(let text):
            Button(PaletteWording.platform("Change Words…", "Change words…"), systemImage: "pencil") {
                editedText = text
                editing = EditedChip(filter: filter)
            }
        case .favorites:
            EmptyView()
        }
    }

    func alternatives(
        _ names: [String], make: @escaping (String) -> SearchFilter, replacing filter: SearchFilter
    ) -> some View {
        Menu(SearchChipWording.other(filter)) {
            ForEach(names.prefix(60), id: \.self) { name in
                Button(name) { replace(filter, with: make(name)) }
            }
        }
        .disabled(names.isEmpty)
    }

    func replace(_ old: SearchFilter, with new: SearchFilter) {
        guard let index = filters.firstIndex(of: old) else { return }
        if filters.contains(new) {
            filters.remove(at: index)
        } else {
            filters[index] = new
        }
    }

    func remove(_ filter: SearchFilter) {
        filters.removeAll { $0 == filter }
    }
}

/// Picks the first and last day of a date chip.
struct DateRangeChooser: View {
    let filter: SearchFilter
    let apply: (SearchFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var first = Date()
    @State private var last = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    String(localized: "From", bundle: .module, comment: "Date chooser of a search chip: first day."), selection: $first,
                    in: ...Date(), displayedComponents: .date)
                DatePicker(
                    String(localized: "To", bundle: .module, comment: "Date chooser of a search chip: last day."), selection: $last,
                    in: first...Date.distantFuture, displayedComponents: .date)
            }
            .navigationTitle(String(localized: "Choose Dates", bundle: .module, comment: "Title of the date chooser of a search chip."))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) {
                        let calendar = Calendar.current
                        let start = calendar.startOfDay(for: min(first, last))
                        if let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(first, last))) {
                            apply(
                                .dateRange(start: start, end: end, label: SearchDates.describe(start..<end, context: SearchDates.Context()))
                            )
                        }
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 240)
        .onAppear {
            if case .dateRange(let start, let end, _) = filter {
                first = start
                last = max(start, end.addingTimeInterval(-1))
            }
        }
    }
}

enum SearchChipWording {
    static var photosInstead: String {
        PaletteWording.platform("Photos Instead", "Photos instead")
    }

    static var videosInstead: String {
        PaletteWording.platform("Videos Instead", "Videos instead")
    }

    static var otherTag: String { PaletteWording.platform("Other Tag", "Other tag") }

    static var otherAlbum: String {
        PaletteWording.platform("Other Album", "Other album")
    }

    static func other(_ filter: SearchFilter) -> String {
        if case .person = filter {
            return PaletteWording.platform("Other Person", "Other person")
        }
        return PaletteWording.platform("Other Place", "Other place")
    }

    /// What kind of filter a chip is, for VoiceOver ("Person, Anna").
    static func kind(_ filter: SearchFilter) -> String {
        switch filter {
        case .place: String(localized: "Place", bundle: .module)
        case .person: String(localized: "Person", bundle: .module)
        case .tag: String(localized: "Tag", bundle: .module)
        case .album: String(localized: "Album", bundle: .module)
        case .dateRange: String(localized: "Date", bundle: .module)
        case .text: String(localized: "Words", bundle: .module, comment: "Field of the alert that edits a word chip of the search.")
        case .label:
            String(localized: "Shows", bundle: .module, comment: "Kind of a search filter: something the photos show, e.g. Shows: beach.")
        case .favorites, .videos, .photos:
            String(localized: "Filter", bundle: .module, comment: "Kind of a search filter chip for VoiceOver.")
        case .rating: String(localized: "Rating", bundle: .module, comment: "Kind of a search filter: the least star rating.")
        }
    }
}

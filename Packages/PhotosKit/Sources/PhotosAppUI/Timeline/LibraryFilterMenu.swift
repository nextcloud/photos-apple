// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI

/// The Library's filters (SPEC §19.2): what its one filter menu sets and the chips under the title show. Media kind
/// and rating or flag belong to the screen; partner photos are the account's setting (Settings › Partner sharing).
struct LibraryFilters: Equatable {
    var kind: MediaFilter = .all
    var culling: CullingFilter = .all
    /// The photos in partner folders are left out of the Library.
    var hidesPartnerPhotos = false

    /// The kinds the menu offers, in its order.
    static let kinds: [MediaFilter] = [.all, .photos, .videos, .favorites]

    /// One active filter: a chip that clears it.
    enum Chip: Hashable, Identifiable {
        case kind(MediaFilter)
        case culling(CullingFilter)
        case partners

        var id: Self { self }
    }

    /// The active filters, in the menu's order.
    var chips: [Chip] {
        var chips: [Chip] = []
        if kind != .all { chips.append(.kind(kind)) }
        if culling != .all { chips.append(.culling(culling)) }
        if hidesPartnerPhotos { chips.append(.partners) }
        return chips
    }

    var activeCount: Int { chips.count }
    var isActive: Bool { activeCount > 0 }

    /// The filters with `chip` cleared.
    func clearing(_ chip: Chip) -> LibraryFilters {
        var result = self
        switch chip {
        case .kind: result.kind = .all
        case .culling: result.culling = .all
        case .partners: result.hidesPartnerPhotos = false
        }
        return result
    }

    /// Every filter cleared.
    func clearingAll() -> LibraryFilters {
        LibraryFilters()
    }
}

/// What the filter menu and its chips say.
enum LibraryFilterWording {
    static var menuTitle: String {
        String(
            localized: "Filter", bundle: .module,
            comment:
                "Kind of a search filter chip for VoiceOver (Favorites, Videos, Photos); also the Library's filter menu button (media kind, rating or flag, partner photos)."
        )
    }

    /// "Filter, 2 active": the menu button's label for VoiceOver and its tooltip while filters are on.
    static func activeTitle(_ count: Int) -> String {
        String(
            localized: "Filter, \(count) active", bundle: .module,
            comment: "Library filter button while filters are on: the number of active filters. Plural variations in the catalog.")
    }

    static func kindTitle(_ kind: MediaFilter) -> String {
        switch kind {
        case .photos: String(localized: "Photos", bundle: .module)
        case .videos: String(localized: "Videos", bundle: .module)
        case .favorites: String(localized: "Favorites", bundle: .module)
        default: String(localized: "All Items", bundle: .module, comment: "Culling filter: show everything.")
        }
    }

    static func kindSymbol(_ kind: MediaFilter) -> String {
        switch kind {
        case .photos: "photo"
        case .videos: "video"
        case .favorites: "heart"
        default: "photo.on.rectangle"
        }
    }

    static var ratingsMenuTitle: String {
        String(localized: "Ratings and Flags", bundle: .module, comment: "Toolbar menu: filter the library by rating or flag.")
    }

    static var hidePartnersTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Hide Partner Photos", bundle: .module,
                comment: "Library filter menu (Mac, title case): leave out the photos of partner folders."),
            other: LocalizedStringResource(
                "Hide partner photos", bundle: .module,
                comment: "Library filter menu (iPhone, iPad): leave out the photos of partner folders."))
    }

    static var partnersChipTitle: String {
        String(
            localized: "Without partner photos", bundle: .module,
            comment: "Chip under the Library's title while partner photos are left out; tapping it shows them again.")
    }

    static var clearAllTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Clear All Filters", bundle: .module, comment: "Library filter menu: turn every filter off. Mac menu."),
            other: LocalizedStringResource("Clear all filters", bundle: .module, comment: "Library filter menu: turn every filter off."))
    }

    static func chipTitle(_ chip: LibraryFilters.Chip) -> String {
        switch chip {
        case .kind(let kind): kindTitle(kind)
        case .culling(let culling): CullingWording.filterTitle(culling)
        case .partners: partnersChipTitle
        }
    }

    static func chipSymbol(_ chip: LibraryFilters.Chip) -> String {
        switch chip {
        case .kind(let kind): kindSymbol(kind)
        case .culling: "star"
        case .partners: "person.2.slash"
        }
    }

    /// VoiceOver: what tapping a chip does.
    static func removeTitle(_ chip: LibraryFilters.Chip) -> String {
        String(
            localized: "Remove filter \(chipTitle(chip))", bundle: .module,
            comment:
                "VoiceOver label of the button that removes a search filter or a Library filter chip. %@ is the filter's name, e.g. Favorites."
        )
    }
}

/// The Library's one filter menu (SPEC §19.2): media kind, rating or flag, partner photos. While a filter is on, its
/// symbol is filled and the number of active filters is shown on it.
struct LibraryFilterMenu: View {
    @Binding var kind: MediaFilter
    @Binding var culling: CullingFilter
    /// Ratings and flags are system tags; without them on the server there is nothing to filter by.
    var offersCulling: Bool
    var deleteRejected: () -> Void
    @Environment(SessionModel.self) private var session
    @AppStorage(CullingSettings.autoAdvanceKey) private var autoAdvance = true

    static let cullingChoices: [[CullingFilter]] = [
        [.all],
        [.picks, .unflagged, .notRejected, .rejected],
        [.rating(atLeast: 1), .rating(atLeast: 2), .rating(atLeast: 3), .rating(atLeast: 4), .rating(atLeast: 5), .unrated],
    ]

    var filters: LibraryFilters {
        LibraryFilters(kind: kind, culling: culling, hidesPartnerPhotos: LibraryFilterMenu.hidesPartners(session.partners))
    }

    static func hidesPartners(_ partners: PartnerTimelineModel?) -> Bool {
        guard let partners, partners.hasPartners else { return false }
        return !partners.settings.showInTimeline
    }

    var body: some View {
        let filters: LibraryFilters = filters
        let title: String = filters.isActive ? LibraryFilterWording.activeTitle(filters.activeCount) : LibraryFilterWording.menuTitle
        Menu {
            Picker(selection: $kind) {
                ForEach(LibraryFilters.kinds, id: \.self) { (choice: MediaFilter) in
                    Label(LibraryFilterWording.kindTitle(choice), systemImage: LibraryFilterWording.kindSymbol(choice)).tag(choice)
                }
            } label: {
                Text("Show", bundle: .module)
            }
            .pickerStyle(.inline)
            if offersCulling { cullingMenu }
            if let partners = session.partners, partners.hasPartners {
                Toggle(
                    LibraryFilterWording.hidePartnersTitle,
                    isOn: Binding<Bool>(
                        get: { () -> Bool in !partners.settings.showInTimeline },
                        set: { (hide: Bool) in partners.setShownInTimeline(!hide) }))
            }
            if filters.isActive {
                Divider()
                Button {
                    clearAll()
                } label: {
                    Label(LibraryFilterWording.clearAllTitle, systemImage: "xmark.circle")
                }
            }
        } label: {
            Label(title, systemImage: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .badge(filters.activeCount)
        .help(title)
        .accessibilityIdentifier("library-filter")
    }

    /// Picks, rejected, star ratings, with the culling options beside them (SPEC §15.2).
    var cullingMenu: some View {
        Menu {
            Picker(selection: $culling) {
                ForEach(Self.cullingChoices.indices, id: \.self) { (group: Int) in
                    Section {
                        ForEach(Self.cullingChoices[group], id: \.self) { (choice: CullingFilter) in
                            Text(CullingWording.filterTitle(choice)).tag(choice)
                        }
                    }
                }
            } label: {
                Text(LibraryFilterWording.ratingsMenuTitle)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(CullingWording.autoAdvanceTitle, isOn: $autoAdvance)
            Button(role: .destructive) {
                deleteRejected()
            } label: {
                Label(CullingWording.deleteRejectedTitle, systemImage: "trash")
            }
        } label: {
            Label(LibraryFilterWording.ratingsMenuTitle, systemImage: culling == .all ? "star" : "star.fill")
        }
    }

    func clearAll() {
        apply(filters.clearingAll())
    }

    func apply(_ new: LibraryFilters) {
        LibraryFilterMenu.apply(new, kind: $kind, culling: $culling, partners: session.partners)
    }

    /// Writes `new` to the screen's filters and the partner setting.
    static func apply(_ new: LibraryFilters, kind: Binding<MediaFilter>, culling: Binding<CullingFilter>, partners: PartnerTimelineModel?) {
        if kind.wrappedValue != new.kind { kind.wrappedValue = new.kind }
        if culling.wrappedValue != new.culling { culling.wrappedValue = new.culling }
        if let partners, partners.hasPartners, hidesPartners(partners) != new.hidesPartnerPhotos {
            partners.setShownInTimeline(!new.hidesPartnerPhotos)
        }
    }
}

/// The active filters under the Library's title, one chip each; a tap on a chip clears that filter (SPEC §19.2).
struct LibraryFilterChips: View {
    @Binding var kind: MediaFilter
    @Binding var culling: CullingFilter
    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var filters: LibraryFilters {
        LibraryFilters(kind: kind, culling: culling, hidesPartnerPhotos: LibraryFilterMenu.hidesPartners(session.partners))
    }

    var body: some View {
        let chips: [LibraryFilters.Chip] = filters.chips
        if !chips.isEmpty {
            // At most three chips: a row that fits, not a scroll view (one over the grid crashed SwiftUI's scroll
            // target handling on iOS 27.2).
            HStack(spacing: 8) {
                ForEach(chips) { (chip: LibraryFilters.Chip) in
                    chipButton(chip)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    func chipButton(_ chip: LibraryFilters.Chip) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) {
                LibraryFilterMenu.apply(filters.clearing(chip), kind: $kind, culling: $culling, partners: session.partners)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: LibraryFilterWording.chipSymbol(chip))
                Text(LibraryFilterWording.chipTitle(chip))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // A material, not Liquid Glass: in the bar over the photos a glass chip was not drawn (iOS 27.2 simulator).
            .background(.regularMaterial, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LibraryFilterWording.removeTitle(chip))
        .accessibilityAddTraits(.isButton)
        .help(LibraryFilterWording.removeTitle(chip))
    }
}

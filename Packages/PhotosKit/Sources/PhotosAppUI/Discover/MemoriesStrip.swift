// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// The memories at the top of the library (SPEC TL-3): On this day first, then the year in review and recent trips,
/// as a row of small cards. A card opens the memory; its context menu plays it as a slideshow. "All memories" at the
/// end leads to the Memories screen (also in Collections and the sidebar).
struct MemoriesStrip: View {
    /// Loaded by the library screen (`load`), so the strip can come and go (selection) without loading again.
    let memories: [Memory]
    @AppStorage(TimelineDisplay.showsMemoriesKey) private var showsMemories = true
    @Environment(SessionModel.self) private var session
    @State private var slideshow: SlideshowStart?
    /// Around New Year the year in review leads the strip (December: the year ending; January: the one just ended).
    @State private var seasonalYear: Int?

    /// At most this many cards: the strip is a way in, the Memories screen has them all.
    static let limit = 12

    /// Loaded again when a sync has finished and when the day changes.
    struct LoadKey: Hashable {
        var lastSync: Date?
        var day: Date
        /// The strip is switched on (Settings); nothing is loaded while it is off.
        var isShown: Bool
    }

    static func loadKey(_ status: SyncStatus, isShown: Bool) -> LoadKey {
        var lastSync: Date?
        if case .idle(let date) = status { lastSync = date }
        return LoadKey(lastSync: lastSync, day: Calendar.current.startOfDay(for: Date()), isShown: isShown)
    }

    /// Room above and below the cards.
    static let verticalPadding: CGFloat = 8

    /// Card size: small enough to leave the grid most of the screen.
    var cardSize: CGSize {
        #if os(macOS)
            CGSize(width: 176, height: 120)
        #else
            CGSize(width: 140, height: 104)
        #endif
    }

    /// Story cards or this strip (SPEC §16.1).
    @AppStorage(MemoriesStyle.key) private var style = MemoriesStyle.stories
    /// A memory zooms out of its card (SPEC §17.4).
    @Namespace private var zoom

    var body: some View {
        Group {
            if !memories.isEmpty, style == .stories {
                MemoryStories(memories: shown, seasonalYear: seasonalYear, slideshow: $slideshow)
            } else if !memories.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        if let seasonalYear { yearInReviewLink(seasonalYear) }
                        ForEach(shown) { memory in card(memory) }
                        allMemoriesLink
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, Self.verticalPadding)
                }
                .scrollIndicators(.hidden)
                // A horizontal scroll view takes all the height it is offered: in the library's stack it would share
                // the screen with the grid and leave a large empty band above the cards. A fixed height, not
                // `fixedSize()`: measured at its ideal size the lazy stack could stay empty until it was scrolled.
                .frame(height: cardSize.height + 2 * Self.verticalPadding)
                .contextMenu {
                    Button {
                        withAnimation { style = .stories }
                    } label: {
                        Label(Self.storiesTitle, systemImage: "rectangle.stack")
                    }
                    Button {
                        showsMemories = false
                    } label: {
                        Label(Self.hideTitle, systemImage: "eye.slash")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Memories", bundle: .module))
            }
        }
        .memorySlideshow($slideshow)
        .task(id: Calendar.current.startOfDay(for: Date())) {
            guard let year = YearInReview.seasonalYear(), let services = session.services else {
                seasonalYear = nil
                return
            }
            let years = (try? await services.library.reviewYears()) ?? []
            seasonalYear = years.contains(year) ? year : nil
        }
    }

    /// The memories after the year in review card: its year's recap is in the review (Play Film).
    var shown: [Memory] {
        guard let seasonalYear else { return memories }
        return memories.filter { $0.kind != .yearRecap(seasonalYear) }
    }

    func yearInReviewLink(_ year: Int) -> some View {
        NavigationLink {
            YearInReviewScreen(year: year)
                .cardTransitionDestination(id: "year-\(year)", in: zoom)
        } label: {
            YearInReviewCard(year: year, compact: true).frame(width: cardSize.width, height: cardSize.height)
                .cardTransitionSource(id: "year-\(year)", in: zoom, cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }

    func card(_ memory: Memory) -> some View {
        NavigationLink {
            MemoryScreen(memory: memory)
                .cardTransitionDestination(id: memory.id, in: zoom)
        } label: {
            MemoryCard(memory: memory, compact: true)
                .frame(width: cardSize.width, height: cardSize.height)
                .cardTransitionSource(id: memory.id, in: zoom, cornerRadius: 12)
                // The card has a fixed size: at accessibility text sizes its title would be cut to a word or two. The
                // whole title is in the VoiceOver label and on the memory's screen.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                slideshow = SlideshowStart(memory: memory)
            } label: {
                Label(MemoryScreen.playTitle, systemImage: "play.rectangle")
            }
        }
        .accessibilityAction(named: Text(MemoryScreen.playTitle)) { slideshow = SlideshowStart(memory: memory) }
    }

    var allMemoriesLink: some View {
        NavigationLink {
            MemoriesScreen()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack").font(.title2)
                Text("All memories", bundle: .module)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .frame(width: cardSize.height, height: cardSize.height)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// The memories of the strip, computed on a database queue over the whole index.
    static func load(_ services: AccountServices) async -> [Memory]? {
        let snapshot: MemoriesSnapshot = (try? await services.library.memories()) ?? MemoriesSnapshot()
        guard !Task.isCancelled else { return nil }
        let cards = cards(snapshot)
        // SPEC §18.2: memory covers rank higher for the caches.
        Task.detached(priority: .utility) { await services.noteCacheRole(.memoryCover, fileIds: Set(cards.map(\.cover))) }
        return cards
    }

    /// Which memories the strip shows, in this order: On this day, the year in review, then trips (newest first).
    static func cards(_ snapshot: MemoriesSnapshot) -> [Memory] {
        var result: [Memory] = snapshot.onThisDay
        if let recap = snapshot.recap { result.append(recap) }
        result += snapshot.trips
        return Array(result.prefix(limit))
    }

    static var storiesTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Show as Stories", bundle: .module, comment: "Context menu of the memories strip (Mac)."),
            other: LocalizedStringResource("Show as stories", bundle: .module, comment: "Context menu of the memories strip."))
    }

    static var hideTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Hide Memories", bundle: .module),
            other: LocalizedStringResource("Hide memories", bundle: .module))
    }
}

/// One memory's photos, with "Play Slideshow" and the memory's menu (`MemoryActionsMenu`) in the toolbar.
struct MemoryScreen: View {
    let memory: Memory
    @State private var slideshow: SlideshowStart?
    /// Save as album, share as link, slideshow music (SPEC ME-4).
    @State private var actions = MemoryActionsModel()
    /// Guest Mode with the memory's photos (SPEC §16.8.3).
    @State private var guestSheet: AlbumCardSheet?
    @Environment(SessionModel.self) private var session

    var body: some View {
        ItemsScreen(title: memory.title, sectioned: false, hero: hero) { services in
            let map = try await services.library.fetchItems(memory.items)
            return memory.items.compactMap { map[$0] }
        } accessory: {
            Button {
                slideshow = SlideshowStart(memory: memory)
            } label: {
                Label(Self.playTitle, systemImage: "play.rectangle")
            }
            .help(Self.playTitle)
            #if os(visionOS)
                // The photos around the viewer (SPEC §15.4).
                MemoryRoomButton(memory: memory)
            #endif
            MemoryActionsMenu(memory: memory, model: actions) {
                guestSheet = .guest(GuestShows.memory(memory, session: session))
            }
        }
        .memorySlideshow($slideshow)
        .memoryActions(actions)
        .albumCardSheets($guestSheet)
        // A hint of the cover's colour in the header (SPEC §16.8.1); on iPhone and iPad the hero shows the cover itself.
        .photoHeaderTint(GridHero.isSupported ? nil : memory.cover)
    }

    /// The memory's cover at the top with its title and dates (iPhone, iPad; SPEC §17.4).
    var hero: GridHero {
        let memory = memory
        return GridHero {
            HeroHeaderView(title: memory.title, subtitle: Memories.dateLine(for: memory)) {
                PreviewImage(fileId: memory.cover, etag: "", bucket: 1024)
            }
        }
    }

    static var playTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Play Slideshow", bundle: .module),
            other: LocalizedStringResource("Play slideshow", bundle: .module))
    }
}

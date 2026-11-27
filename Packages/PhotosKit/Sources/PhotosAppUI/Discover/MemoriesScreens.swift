// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import LocalAuthentication
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

// MARK: - Memories and On this day (SPEC §7.12)

struct MemoriesScreen: View {
    var onlyOnThisDay = false
    @Environment(SessionModel.self) private var session
    @State private var slideshow: SlideshowStart?
    @State private var onThisDay: [Memory] = []
    @State private var trips: [Memory] = []
    @State private var recap: Memory?
    /// Years with enough photos for a year in review, newest first.
    @State private var years: [Int] = []
    @State private var loaded = false
    /// A memory zooms out of its card (SPEC §17.4).
    @Namespace private var zoom

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !onlyOnThisDay {
                    // This week's photo prompt and the family library's suggestion (SPEC §16.7); nothing when off.
                    // Above the carousels below, whose touch area reaches up beyond what they show.
                    WeeklyPromptCard().zIndex(1)
                    FamilySuggestionCard().zIndex(1)
                }
                if !onThisDay.isEmpty {
                    // The On this day screen is titled so already: no heading that repeats the title.
                    section(onlyOnThisDay ? nil : String(localized: "On this day", bundle: .module), onThisDay)
                }
                if !onlyOnThisDay {
                    if !years.isEmpty {
                        yearsSection
                    } else if let recap {
                        section(String(localized: "Year in review", bundle: .module), [recap])
                    }
                    if !trips.isEmpty { section(String(localized: "Trips", bundle: .module), trips) }
                    // Places photographed in several years (SPEC §15.6); shows nothing when there are none.
                    ThenAndNowRow()
                    // Named people's faces across the years (SPEC §16.6).
                    ThroughTheYearsRow()
                    // Their birthdays from Nextcloud Contacts (SPEC §22.3); nothing without.
                    BirthdaysRow()
                }
                if loaded && onThisDay.isEmpty && (onlyOnThisDay || (trips.isEmpty && recap == nil && years.isEmpty)) {
                    ContentUnavailableView(
                        onlyOnThisDay
                            ? String(localized: "Nothing on this day", bundle: .module)
                            : String(localized: "No memories yet", bundle: .module),
                        systemImage: "sparkles",
                        description: Text("Memories appear as your library grows.", bundle: .module))
                }
            }
            .padding()
        }
        .navigationTitle(onlyOnThisDay ? String(localized: "On this day", bundle: .module) : String(localized: "Memories", bundle: .module))
        .memorySlideshow($slideshow)
        .task {
            guard let services = session.services else { return }
            // Purpose-built queries on a database queue; the library itself never comes into memory.
            let memories = (try? await services.library.memories(onlyOnThisDay: onlyOnThisDay)) ?? MemoriesSnapshot()
            onThisDay = memories.onThisDay
            trips = memories.trips
            recap = memories.recap
            if !onlyOnThisDay { years = (try? await services.library.reviewYears()) ?? [] }
            loaded = true
        }
    }

    /// The year in review of every year with enough photos (SPEC §15.1); each also plays the year's film.
    var yearsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Year in review", bundle: .module).font(Typography.sectionTitle).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(years, id: \.self) { (year: Int) in
                        NavigationLink {
                            YearInReviewScreen(year: year)
                                .cardTransitionDestination(id: "year-\(year)", in: zoom)
                        } label: {
                            YearInReviewCard(year: year).frame(width: 150, height: 200)
                                .cardTransitionSource(id: "year-\(year)", in: zoom, cornerRadius: 16)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    func section(_ title: String?, _ memories: [Memory]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(Typography.sectionTitle).accessibilityAddTraits(.isHeader) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16)], spacing: 16) {
                ForEach(memories) { memory in
                    NavigationLink {
                        MemoryScreen(memory: memory)
                            .cardTransitionDestination(id: memory.id, in: zoom)
                    } label: {
                        MemoryCard(memory: memory)
                            .cardTransitionSource(id: memory.id, in: zoom, cornerRadius: 14)
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
            }
        }
    }
}

struct MemoryCard: View {
    let memory: Memory
    /// Small, for the strip at the top of the library: smaller titles on the picture, which fills the card; at
    /// accessibility text sizes below it.
    var compact = false
    /// A small card's picture height when its titles are below it (accessibility text sizes).
    var pictureHeight: CGFloat = 104
    @Environment(SessionModel.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The date under the title; nil when the title already is the date (a trip without places).
    var dateLine: String? { Memories.dateLine(for: memory) }

    var body: some View {
        Group {
            if compact && dynamicTypeSize.isAccessibilitySize {
                // Large text does not fit on the small picture: below it, wrapped, as on the large cards (SPEC §20.3).
                VStack(alignment: .leading, spacing: 4) {
                    compactPicture.frame(height: pictureHeight).clipShape(.rect(cornerRadius: 12))
                    compactTitles(onPicture: false).fixedSize(horizontal: false, vertical: true)
                }
            } else if compact {
                compactCard
            } else if dynamicTypeSize.isAccessibilitySize {
                // Large text does not fit on the picture: it goes below it, and wraps.
                VStack(alignment: .leading, spacing: 6) {
                    cover.clipShape(.rect(cornerRadius: 14))
                    titles
                }
            } else {
                cover
                    .overlay(alignment: .bottomLeading) {
                        titles
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 3)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Even behind the titles: 4.5:1 on any photo (SPEC §20.3).
                            .background { CaptionScrim(color: scrimColor, increased: increased, fade: 56) }
                    }
                    .clipShape(.rect(cornerRadius: 14))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityText.memory(title: memory.title, dateLine: dateLine, itemCount: memory.items.count))
    }

    var cover: some View {
        Color.clear
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                // A little deeper than the card while the list scrolls (SPEC §17.4).
                PreviewImage(fileId: memory.cover, etag: "", bucket: 1024).scrollParallax()
            }
            .clipped()
    }

    var compactPicture: some View {
        Color.clear
            .overlay { PreviewImage(fileId: memory.cover, etag: "", bucket: 256).scrollParallax(.horizontal) }
            .clipped()
    }

    /// The picture fills the card the strip gives it; the title is on it and may take two lines.
    var compactCard: some View {
        compactPicture
            .overlay(alignment: .bottomLeading) {
                compactTitles(onPicture: true)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Even behind the titles: 4.5:1 on any photo (SPEC §20.3).
                    .background { CaptionScrim(color: scrimColor, increased: increased, fade: 22) }
                    // The card has a fixed size: up to xxLarge on it; larger sizes put the titles below the picture.
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            .clipShape(.rect(cornerRadius: 12))
    }

    func compactTitles(onPicture: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(memory.title).font(.footnote.bold()).lineLimit(onPicture ? 2 : nil)
            if let dateLine { Text(dateLine).font(.caption2).lineLimit(onPicture ? 1 : nil) }
        }
        // UI tests: captions on photos, which the audit measures against the photo under them (SPEC §20.3).
        .accessibilityIdentifier("memory-caption")
    }

    var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            // A little smaller than before, two lines at most (SPEC §17.5).
            Text(memory.title).font(Typography.overlayTitle).lineLimit(2)
            if let dateLine { Text(dateLine).font(Typography.overlaySubtitle).lineLimit(1) }
        }
        // UI tests: captions on photos, which the audit measures against the photo under them (SPEC §20.3).
        .accessibilityIdentifier("memory-caption")
    }

    /// A deep shade of the cover's colour (SPEC §16.8.1); black with Increase Contrast or Reduce Transparency.
    var scrimColor: Color {
        MemoryScrimColor.color(
            cover: memory.cover, services: session.services, contrast: contrast, reduceTransparency: reduceTransparency)
    }

    /// Increase Contrast or Reduce Transparency: a stronger shade under the white titles.
    var increased: Bool { contrast == .increased || reduceTransparency }
}

// MARK: - Archive (SPEC §7.13)

/// Archive needs authentication every time it is opened.
struct ArchiveScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var unlocked = false
    /// The padlock clicks open before the archive replaces it (SPEC §17.3).
    @State private var lockOpen = false
    @State private var error: String?

    var body: some View {
        Group {
            if unlocked {
                TimelineScreenArchived()
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Archive is locked", bundle: .module)
                    } icon: {
                        ChromeLockSymbol(isOpen: lockOpen)
                    }
                } description: {
                    Text(error ?? String(localized: "Archived photos are hidden from your library.", bundle: .module))
                } actions: {
                    Button(String(localized: "Unlock", bundle: .module)) { Task { await unlock() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(String(localized: "Archive", bundle: .module))
        .task { await unlock() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { lock() } }
        .onDisappear { lock() }
    }

    func lock() {
        unlocked = false
        lockOpen = false
    }

    func unlock() async {
        let context = LAContext()
        do {
            let granted: Bool = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: String(localized: "Show archived photos", bundle: .module))
            guard granted else { return }
            lockOpen = true
            if !reduceMotion { try? await Task.sleep(for: ChromeMotion.unlockedLinger) }
            // Left (or sent to the background) while the lock opened: it stays locked.
            guard lockOpen else { return }
            unlocked = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TimelineScreenArchived: View {
    @Environment(SessionModel.self) private var session
    @State private var feed = GridFeed()
    @AppStorage("gridColumns") private var columns = GridColumns.default

    var body: some View {
        MediaGridScreen(
            feed: feed, title: String(localized: "Archive", bundle: .module), showsHeaders: true,
            emptyTitle: String(localized: "The archive is empty", bundle: .module),
            emptyMessage: String(
                localized: "Archived photos are moved to the .archive folder and hidden everywhere else.", bundle: .module),
            columns: $columns
        ) { EmptyView() }
        .task {
            guard let library = session.services?.library else { return }
            feed.observe({ library.observeGrid(.archived) }, flat: false)
        }
    }
}

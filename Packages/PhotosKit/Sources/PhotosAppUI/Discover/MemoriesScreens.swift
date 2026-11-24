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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !onThisDay.isEmpty {
                    section(String(localized: "On this day", bundle: .module), onThisDay)
                }
                if !onlyOnThisDay {
                    if !years.isEmpty {
                        yearsSection
                    } else if let recap {
                        section(String(localized: "Year in review", bundle: .module), [recap])
                    }
                    if !trips.isEmpty { section(String(localized: "Trips", bundle: .module), trips) }
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
            Text("Year in review", bundle: .module).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(years, id: \.self) { (year: Int) in
                        NavigationLink {
                            YearInReviewScreen(year: year)
                        } label: {
                            YearInReviewCard(year: year).frame(width: 150, height: 200)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    func section(_ title: String, _ memories: [Memory]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16)], spacing: 16) {
                ForEach(memories) { memory in
                    NavigationLink {
                        MemoryScreen(memory: memory)
                    } label: {
                        MemoryCard(memory: memory)
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
    /// Small, for the strip at the top of the library: smaller titles, always on the picture, which fills the card.
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The date under the title; nil when the title already is the date (a trip without places).
    var dateLine: String? { Memories.dateLine(for: memory) }

    var body: some View {
        Group {
            if compact {
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
                            .shadow(radius: 4)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                LinearGradient(colors: [.clear, .black.opacity(scrimOpacity)], startPoint: .top, endPoint: .bottom))
                    }
                    .clipShape(.rect(cornerRadius: 14))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityText.memory(title: memory.title, dateLine: dateLine, itemCount: memory.items.count))
    }

    var cover: some View {
        PreviewImage(fileId: memory.cover, etag: "", bucket: 1024)
            .aspectRatio(4 / 3, contentMode: .fit)
    }

    /// The picture fills the card the strip gives it; the title is on it and may take two lines.
    var compactCard: some View {
        Color.clear
            .overlay { PreviewImage(fileId: memory.cover, etag: "", bucket: 256) }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(memory.title).font(.footnote.bold()).lineLimit(2)
                    if let dateLine { Text(dateLine).font(.caption2).lineLimit(1) }
                }
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(scrimOpacity)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(.rect(cornerRadius: 12))
    }

    var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(memory.title).font(.title3.bold())
            if let dateLine { Text(dateLine).font(.caption) }
        }
    }

    /// Stronger with Increase Contrast or Reduce Transparency, so the white titles stay readable on bright photos.
    var scrimOpacity: Double {
        OverlayLegibility.scrimOpacity(base: 0.6, increased: contrast == .increased || reduceTransparency)
    }
}

// MARK: - Archive (SPEC §7.13)

/// Archive needs authentication every time it is opened.
struct ArchiveScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var error: String?

    var body: some View {
        Group {
            if unlocked {
                TimelineScreenArchived()
            } else {
                ContentUnavailableView {
                    Label(String(localized: "Archive is locked", bundle: .module), systemImage: "lock")
                } description: {
                    Text(error ?? String(localized: "Archived photos are hidden from your library.", bundle: .module))
                } actions: {
                    Button(String(localized: "Unlock", bundle: .module)) { Task { await unlock() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(String(localized: "Archive", bundle: .module))
        .task { await unlock() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { unlocked = false } }
        .onDisappear { unlocked = false }
    }

    func unlock() async {
        let context = LAContext()
        do {
            unlocked = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: String(localized: "Show archived photos", bundle: .module))
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

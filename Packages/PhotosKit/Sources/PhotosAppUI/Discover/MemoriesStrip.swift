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
    @State private var slideshow: SlideshowStart?

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

    /// Card size: small enough to leave the grid most of the screen.
    var cardSize: CGSize {
        #if os(macOS)
            CGSize(width: 176, height: 120)
        #else
            CGSize(width: 140, height: 104)
        #endif
    }

    var body: some View {
        Group {
            if !memories.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(memories) { memory in card(memory) }
                        allMemoriesLink
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .contextMenu {
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
    }

    func card(_ memory: Memory) -> some View {
        NavigationLink {
            MemoryScreen(memory: memory)
        } label: {
            MemoryCard(memory: memory, compact: true)
                .frame(width: cardSize.width, height: cardSize.height)
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
        return cards(snapshot)
    }

    /// Which memories the strip shows, in this order: On this day, the year in review, then trips (newest first).
    static func cards(_ snapshot: MemoriesSnapshot) -> [Memory] {
        var result: [Memory] = snapshot.onThisDay
        if let recap = snapshot.recap { result.append(recap) }
        result += snapshot.trips
        return Array(result.prefix(limit))
    }

    static var hideTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Hide Memories", bundle: .module),
            other: LocalizedStringResource("Hide memories", bundle: .module))
    }
}

/// One memory's photos, with "Play Slideshow" in the toolbar.
struct MemoryScreen: View {
    let memory: Memory
    @State private var slideshow: SlideshowStart?

    var body: some View {
        ItemsScreen(title: memory.title, sectioned: false) { services in
            let map = try await services.library.fetchItems(memory.items)
            return memory.items.compactMap { map[$0] }
        } accessory: {
            Button {
                slideshow = SlideshowStart(memory: memory)
            } label: {
                Label(Self.playTitle, systemImage: "play.rectangle")
            }
            .help(Self.playTitle)
        }
        .memorySlideshow($slideshow)
    }

    static var playTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Play Slideshow", bundle: .module),
            other: LocalizedStringResource("Play slideshow", bundle: .module))
    }
}

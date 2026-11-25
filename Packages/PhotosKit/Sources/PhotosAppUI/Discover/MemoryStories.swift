// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// How the memories at the top of the Library are shown (SPEC §16.1): story cards (the default) or the classic strip of
/// small cards. A setting of this device (Settings › On this device, and the cards' context menu).
enum MemoriesStyle: String, CaseIterable, Identifiable {
    case stories
    case strip

    var id: String { rawValue }
    static let key = "memoriesStyle"

    var title: String {
        switch self {
        case .stories:
            String(localized: "Stories", bundle: .module, comment: "Settings: memories at the top of the library as story cards.")
        case .strip:
            String(localized: "Strip", bundle: .module, comment: "Settings: memories at the top of the library as a row of small cards.")
        }
    }
}

/// The rules of a story card: which photos it shows and where a tap goes.
enum MemoryStory {
    /// A card shows a few photos, not the whole memory: the memory's screen and film have them all.
    static let maximumPhotos = 6
    /// Each photo stays this long while the card plays.
    static let interval: Duration = .seconds(4)

    /// The cover first, then photos spread evenly over the memory, in time order.
    static func photos(of memory: Memory, limit: Int = maximumPhotos) -> [FileID] {
        let others = memory.items.filter { $0 != memory.cover }
        let wanted = max(0, min(limit - 1, others.count))
        guard wanted > 0 else { return [memory.cover] }
        let step = Double(others.count) / Double(wanted)
        let picked = (0..<wanted).map { others[min(others.count - 1, Int((Double($0) + 0.5) * step))] }
        return [memory.cover] + picked
    }

    enum Step: Equatable {
        case photo(Int)
        /// Past the last photo: the next card.
        case nextCard
        /// Before the first photo: the card before.
        case previousCard
    }

    static func step(from index: Int, count: Int, forward: Bool) -> Step {
        let next = index + (forward ? 1 : -1)
        if next >= count { return .nextCard }
        if next < 0 { return .previousCard }
        return .photo(next)
    }

    /// A tap on the leading third goes back, elsewhere forward (as in stories everywhere); mirrored right to left.
    static func isForward(x: Double, width: Double, rightToLeft: Bool = false) -> Bool {
        guard width > 0 else { return true }
        let fraction = x / width
        return rightToLeft ? fraction < 2.0 / 3.0 : fraction > 1.0 / 3.0
    }

    /// Height of the band; fixed, so the cards never leave an empty band above the grid (round 4's strip fix).
    @MainActor static func height(compact: Bool) -> CGFloat {
        #if os(macOS)
            210
        #else
            compact ? 184 : 220
        #endif
    }
}

/// The memories as story cards: one large card at a time on iPhone (the next one peeks in), several side by side where
/// there is room. The card in front plays: its photos follow one another, a bar per photo shows how far it is; a tap
/// on the right goes on, on the left back; past its last photo the next card comes. The title opens the memory, the
/// play button its film.
struct MemoryStories: View {
    let memories: [Memory]
    /// The year in review, first around New Year (`MemoriesStrip`).
    var seasonalYear: Int?
    @Binding var slideshow: SlideshowStart?
    @AppStorage(TimelineDisplay.showsMemoriesKey) private var showsMemories = true
    @AppStorage(MemoriesStyle.key) private var style = MemoriesStyle.stories
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var front: String?
    @State private var width: CGFloat = 0
    @State private var opened: Memory?

    var compact: Bool { sizeClass == .compact || width < 500 }
    var height: CGFloat { MemoryStory.height(compact: compact) }
    var cardWidth: CGFloat {
        // iPhone: the whole width but a peek of the next card; wider: cards of a pleasant shape side by side.
        compact ? max(width - 24 - 28, 200) : min(height * 1.6, max(width - 24, 200))
    }

    static let allMemoriesId = "all-memories"
    static let reviewId = "year-in-review"

    var ids: [String] {
        (seasonalYear == nil ? [] : [Self.reviewId]) + memories.map(\.id) + [Self.allMemoriesId]
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                if let seasonalYear {
                    NavigationLink {
                        YearInReviewScreen(year: seasonalYear)
                    } label: {
                        YearInReviewCard(year: seasonalYear, compact: true)
                            .frame(width: cardWidth, height: height)
                            .clipShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .id(Self.reviewId)
                }
                ForEach(memories) { memory in
                    StoryCard(
                        memory: memory, isFront: front == memory.id || (front == nil && memory.id == memories.first?.id),
                        open: { opened = memory }, play: { slideshow = SlideshowStart(memory: memory) },
                        finished: { advance(after: memory.id) }, back: { retreat(before: memory.id) }
                    )
                    .frame(width: cardWidth, height: height)
                    .contextMenu { menu(memory) }
                    .id(memory.id)
                }
                allMemoriesLink.id(Self.allMemoriesId)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            .padding(.vertical, MemoriesStrip.verticalPadding)
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $front, anchor: .leading)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        // Fixed: a horizontal scroll view takes all the height it is offered (see `MemoriesStrip`).
        .frame(height: height + 2 * MemoriesStrip.verticalPadding)
        .navigationDestination(item: $opened) { memory in MemoryScreen(memory: memory) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Memories", bundle: .module))
    }

    @ViewBuilder func menu(_ memory: Memory) -> some View {
        Button {
            slideshow = SlideshowStart(memory: memory)
        } label: {
            Label(MemoryScreen.playTitle, systemImage: "play.rectangle")
        }
        Button {
            withAnimation { style = .strip }
        } label: {
            Label(Self.stripTitle, systemImage: "rectangle.split.3x1")
        }
        Button {
            showsMemories = false
        } label: {
            Label(MemoriesStrip.hideTitle, systemImage: "eye.slash")
        }
    }

    /// The next card comes to the front once a card has shown its last photo.
    func advance(after id: String) {
        guard let index = ids.firstIndex(of: id), index + 1 < ids.count, ids[index + 1] != Self.allMemoriesId else { return }
        withAnimation(.smooth) { front = ids[index + 1] }
    }

    func retreat(before id: String) {
        guard let index = ids.firstIndex(of: id), index > 0, ids[index - 1] != Self.reviewId else { return }
        withAnimation(.smooth) { front = ids[index - 1] }
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
            .frame(width: min(120, height * 0.7), height: height)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    static var stripTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Show as Strip", bundle: .module, comment: "Context menu of a memory story card (Mac)."),
            other: LocalizedStringResource("Show as strip", bundle: .module, comment: "Context menu of a memory story card."))
    }
}

/// One memory as a story: its photos one after the other with a bar per photo, the title at the bottom.
struct StoryCard: View {
    let memory: Memory
    /// The card in front plays; the others show their first photo.
    let isFront: Bool
    let open: () -> Void
    let play: () -> Void
    /// Past the last photo, and before the first one.
    let finished: () -> Void
    let back: () -> Void

    @State private var index = 0
    /// When the photo shown began, for its bar; nil while paused.
    @State private var shownSince: Date?
    /// How far the photo had got when the card was paused.
    @State private var progressAtPause: Double = 0
    @State private var isHovering = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var photos: [FileID] { MemoryStory.photos(of: memory) }

    /// Plays while in front and the app is active, unless VoiceOver reads it (then the photos are stepped through with
    /// swipes up and down).
    var isPlaying: Bool { isFront && scenePhase == .active && !voiceOver && photos.count > 1 }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Pinned to the card: a fill-scaled preview is larger than the card, and its tap area reached the
                // photos below the band (they could not be tapped).
                picture
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .contentShape(.rect)
                    .onTapGesture { location in
                        let forward = MemoryStory.isForward(
                            x: Double(location.x), width: Double(proxy.size.width), rightToLeft: layoutDirection == .rightToLeft)
                        step(forward: forward)
                    }
                VStack(alignment: .leading, spacing: 0) {
                    bars.padding(.horizontal, 10).padding(.top, 8)
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom) {
                        titles
                        Spacer(minLength: 8)
                        playButton
                    }
                    .padding(12)
                    .background(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(scrimOpacity)], startPoint: .top, endPoint: .bottom)
                            .padding(.top, -24)
                            .allowsHitTesting(false)
                    }
                }
                #if os(macOS) || os(iOS)
                    if isHovering, photos.count > 1 { hoverChevrons }
                #endif
            }
        }
        .clipShape(.rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
        .onHover { isHovering = $0 }
        .onChange(of: isPlaying, initial: true) { _, playing in playingChanged(playing) }
        .task(id: TimerKey(index: index, playing: isPlaying)) { await runTimer() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(forward: true)
            case .decrement: step(forward: false)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text(MemoryScreen.playTitle)) { play() }
    }

    var accessibilityLabel: String {
        let base = AccessibilityText.memory(title: memory.title, dateLine: Memories.dateLine(for: memory), itemCount: memory.items.count)
        let position = String(
            localized: "Photo \(index + 1) of \(photos.count)", bundle: .module,
            comment: "VoiceOver: which photo of a memory story card is shown.")
        return base + ", " + position
    }

    var scrimOpacity: Double {
        OverlayLegibility.scrimOpacity(base: 0.55, increased: contrast == .increased || reduceTransparency)
    }

    // MARK: Picture

    var picture: some View {
        ZStack {
            Color.black
            ForEach(Array(photos.enumerated()), id: \.offset) { offset, fileId in
                // The photo shown and the next one (loaded ahead, invisible) are in the hierarchy; the others are not.
                if offset == index || offset == (index + 1) % max(photos.count, 1) {
                    PreviewImage(fileId: fileId, etag: "", bucket: 1024)
                        .scaleEffect(offset == index && isPlaying && !reduceMotion ? 1.06 : 1)
                        .animation(isPlaying && !reduceMotion ? .linear(duration: 4.5) : .default, value: index)
                        .animation(isPlaying && !reduceMotion ? .linear(duration: 4.5) : .default, value: isPlaying)
                        .opacity(offset == index ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.35), value: index)
    }

    // MARK: Bars

    var bars: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { context in
            HStack(spacing: 3) {
                ForEach(0..<photos.count, id: \.self) { offset in
                    Capsule()
                        .fill(.white.opacity(0.35))
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(.white)
                                    .frame(width: proxy.size.width * fill(of: offset, at: context.date))
                            }
                        }
                        .frame(height: 3)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 1)
        }
        .accessibilityHidden(true)
    }

    func fill(of offset: Int, at date: Date) -> CGFloat {
        if offset < index { return 1 }
        if offset > index { return 0 }
        return CGFloat(progress(at: date))
    }

    func progress(at date: Date) -> Double {
        guard let shownSince else { return progressAtPause }
        let seconds = Double(MemoryStory.interval.components.seconds)
        return min(max(progressAtPause + date.timeIntervalSince(shownSince) / seconds, 0), 1)
    }

    // MARK: Titles and buttons

    var titles: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(memory.title).font(.headline).lineLimit(2)
                    Image(systemName: "chevron.forward").font(.caption.weight(.bold)).opacity(0.8)
                }
                if let dateLine = Memories.dateLine(for: memory) {
                    Text(dateLine).font(.caption).lineLimit(1).opacity(0.9)
                }
            }
            .foregroundStyle(.white)
            .shadow(radius: 3)
            .multilineTextAlignment(.leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The card has a fixed height: the whole title is in the VoiceOver label and on the memory's screen.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    var playButton: some View {
        Button(action: play) {
            Image(systemName: "play.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.35), in: .circle)
        }
        .buttonStyle(.plain)
        .help(MemoryScreen.playTitle)
        .accessibilityLabel(Text(MemoryScreen.playTitle))
    }

    var hoverChevrons: some View {
        HStack {
            chevron("chevron.backward") { step(forward: false) }
            Spacer()
            chevron("chevron.forward") { step(forward: true) }
        }
        .padding(.horizontal, 8)
        .transition(.opacity)
    }

    func chevron(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.35), in: .circle)
        }
        .buttonStyle(.plain)
    }

    // MARK: Playing

    struct TimerKey: Hashable {
        var index: Int
        var playing: Bool
    }

    func playingChanged(_ playing: Bool) {
        if playing {
            shownSince = Date()
        } else {
            progressAtPause = progress(at: Date())
            shownSince = nil
        }
    }

    /// Waits for the rest of the photo's time, then goes on.
    func runTimer() async {
        guard isPlaying else { return }
        let seconds = Double(MemoryStory.interval.components.seconds)
        let remaining = max(0, (1 - progress(at: Date())) * seconds)
        try? await Task.sleep(for: .seconds(remaining))
        guard !Task.isCancelled, isPlaying else { return }
        step(forward: true)
    }

    func step(forward: Bool) {
        switch MemoryStory.step(from: index, count: photos.count, forward: forward) {
        case .photo(let next):
            index = next
            progressAtPause = 0
            shownSince = isPlaying ? Date() : nil
        case .nextCard:
            index = 0
            progressAtPause = 0
            shownSince = nil
            finished()
        case .previousCard:
            back()
        }
    }
}

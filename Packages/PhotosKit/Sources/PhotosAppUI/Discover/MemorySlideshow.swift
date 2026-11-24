// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// What a slideshow shows: a memory's title and photos.
struct SlideshowStart: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var ids: [FileID]
    /// Plays the music chosen for memory slideshows (`memorySlideshowMusic`).
    var playsMemoryMusic = false

    init(memory: Memory) {
        id = memory.id
        title = memory.title
        subtitle = Memories.dateLine(for: memory)
        ids = memory.items
        playsMemoryMusic = true
    }
}

extension View {
    /// Plays a slideshow full screen on iPhone and iPad; pushed in the window's stack on the Mac and Vision Pro, like the
    /// viewer ("Back" or Escape ends it).
    func memorySlideshow(_ start: Binding<SlideshowStart?>) -> some View {
        modifier(SlideshowPresenter(start: start))
    }
}

private struct SlideshowPresenter: ViewModifier {
    @Binding var start: SlideshowStart?
    @Environment(SessionModel.self) private var session

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(item: $start) { (start: SlideshowStart) in
                MemorySlideshow(start: start).environment(session)
            }
        #else
            content.navigationDestination(item: $start) { (start: SlideshowStart) in
                MemorySlideshow(start: start)
            }
        #endif
    }
}

/// A memory's photos one after the other, cross-faded (SPEC ME-4): plays by itself, pauses and goes on, steps back and
/// forward, and ends with Close (Escape). With Reduce Motion the photos dissolve without the slow zoom. Videos show
/// their still. It starts over after the last photo.
struct MemorySlideshow: View {
    let start: SlideshowStart
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// The photos in the order they were taken; loaded from the index.
    @State private var items: [MediaItem] = []
    @State private var index = 0
    @State private var playing = true
    @State private var controlsShown = true
    /// The title over the first photo, until the slideshow moves on.
    @State private var showsTitle = true
    @State private var loaded = false
    @FocusState private var focused: Bool

    /// Restarts the timer whenever the photo changes or playback is paused or resumed.
    struct Tick: Hashable {
        var index: Int
        var playing: Bool
        var count: Int
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item = items[safe: index] {
                SlideshowSlide(item: item, drift: Slideshow.drift(reduceMotion: reduceMotion))
                    .id(item.fileId)
                    .transition(.opacity)
                    .accessibilityLabel(description(of: item))
                    .accessibilityAddTraits(.isImage)
                // Loaded ahead, out of sight, so the next photo is there when it fades in.
                if let next = items[safe: Slideshow.next(after: index, count: items.count)], next.fileId != item.fileId {
                    PreviewImage(item: next, bucket: 1024, contentMode: .fit).opacity(0).accessibilityHidden(true)
                }
            } else if loaded {
                ContentUnavailableView(
                    String(localized: "No photos to show", bundle: .module),
                    systemImage: "photo.on.rectangle.angled")
            } else {
                DelayedSpinner(tint: .white)
            }
            if showsTitle && !items.isEmpty { titleCard }
        }
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsShown.toggle() }
        }
        .overlay(alignment: .top) { if controlsShown { topBar } }
        .memorySlideshowMusic(enabled: start.playsMemoryMusic, playing: playing && !items.isEmpty, controlsShown: controlsShown)
        .overlay(alignment: .bottom) { if controlsShown { playbackBar } }
        #if os(iOS)
            .statusBarHidden(!controlsShown)
            .persistentSystemOverlays(controlsShown ? .automatic : .hidden)
        #else
            .navigationTitle(start.title)
        #endif
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .space, .escape]) { press in
            switch press.key {
            case .leftArrow: step(-1)
            case .rightArrow: step(1)
            case .space: togglePlaying()
            default: dismiss()
            }
            return .handled
        }
        .task {
            playing = Slideshow.startsPlaying(voiceOver: voiceOver)
            await load()
        }
        .task(id: Tick(index: index, playing: playing, count: items.count)) {
            guard playing, items.count > 1 else { return }
            try? await Task.sleep(for: Slideshow.interval)
            guard !Task.isCancelled else { return }
            advance(to: Slideshow.next(after: index, count: items.count))
        }
    }

    func load() async {
        guard let services = session.services else { return }
        let map = (try? await services.library.fetchItems(start.ids)) ?? [:]
        items = start.ids.compactMap { map[$0] }.filter { !$0.isLivePhotoVideo }.sorted { $0.timestamp < $1.timestamp }
        loaded = true
    }

    func advance(to next: Int) {
        withAnimation(.easeInOut(duration: Slideshow.crossfade(reduceMotion: reduceMotion))) {
            index = next
            showsTitle = false
        }
    }

    func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        advance(
            to: delta < 0
                ? Slideshow.previous(before: index, count: items.count) : Slideshow.next(after: index, count: items.count))
    }

    func togglePlaying() {
        playing.toggle()
    }

    func description(of item: MediaItem) -> String {
        AccessibilityText.media(
            isVideo: item.kind == .video, isLivePhoto: item.isLivePhoto, date: item.timestamp, duration: item.duration,
            place: item.place, isFavorite: item.isFavorite, caption: item.caption)
    }

    var titleCard: some View {
        VStack(spacing: 6) {
            Text(start.title).font(.largeTitle.bold())
            if let subtitle = start.subtitle { Text(subtitle).font(.title3) }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 8)
        .padding(24)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Label(String(localized: "Close", bundle: .module), systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .help(String(localized: "Close", bundle: .module))
            if !items.isEmpty {
                Text(AccessibilityText.position(index: index, count: items.count))
                    .font(.callout.monospacedDigit())
                    .accessibilityLabel(AccessibilityText.position(index: index, count: items.count))
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    var playbackBar: some View {
        HStack(spacing: 28) {
            controlButton(
                String(localized: "Previous", bundle: .module), systemImage: "backward.fill", disabled: items.count < 2
            ) { step(-1) }
            controlButton(
                playing
                    ? String(localized: "Pause", bundle: .module)
                    : String(localized: "Play", bundle: .module),
                systemImage: playing ? "pause.fill" : "play.fill", disabled: items.count < 2, large: true
            ) { togglePlaying() }
            controlButton(String(localized: "Next", bundle: .module), systemImage: "forward.fill", disabled: items.count < 2) {
                step(1)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45), in: .capsule)
        .padding(.bottom, 24)
    }

    func controlButton(
        _ title: String, systemImage: String, disabled: Bool, large: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(large ? .title.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(title)
    }
}

/// One photo of the slideshow: fitted to the screen, slowly growing while it is shown unless Reduce Motion is on.
private struct SlideshowSlide: View {
    let item: MediaItem
    /// The scale the photo grows to while it is shown (1: it stays still).
    let drift: Double
    @State private var grown = false

    var body: some View {
        PreviewImage(item: item, bucket: 1024, contentMode: .fit)
            .scaleEffect(grown ? drift : 1)
            .ignoresSafeArea()
            .onAppear {
                guard drift != 1 else { return }
                withAnimation(.linear(duration: Double(Slideshow.interval.components.seconds) + 1.5)) { grown = true }
            }
    }
}

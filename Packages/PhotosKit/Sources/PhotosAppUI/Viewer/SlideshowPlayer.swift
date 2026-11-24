// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import AVFoundation
import AVKit
import Combine
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

/// A slideshow of a grid's photos, of a selection or of the viewer's context (SPEC VW-5). Memories have their own player
/// as films (`MemoryFilmPlayer`); both use `Slideshow`.
struct SlideshowRequest: Identifiable, Hashable {
    let id = UUID()
    /// The place it was started from ("Library", an album's name); the Mac's window title.
    var title: String
    /// The photos in the order of the place they come from.
    var ids: [FileID]
    /// The photo to start with (the one the viewer shows, the one a context menu was opened on).
    var startId: FileID?

    /// "Play Slideshow" on the Mac, "Slideshow" elsewhere (as in Apple Photos).
    static var menuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Play Slideshow", bundle: .module), other: LocalizedStringResource("Slideshow", bundle: .module))
    }

    static let systemImage = "play.rectangle"
}

/// The slideshow's options, kept on the device.
enum SlideshowSettings {
    static let intervalKey = "slideshowInterval"
    static let repeatsKey = "slideshowRepeats"
}

extension View {
    /// Plays a slideshow: full screen on iPhone and iPad (with the screen kept on), in a full-screen window of its own on
    /// the Mac, pushed in the window's stack on Vision Pro. `ended` is told the photo shown last.
    func slideshow(_ request: Binding<SlideshowRequest?>, ended: @escaping @MainActor (FileID) -> Void = { _ in }) -> some View {
        modifier(SlideshowPresenter(request: request, ended: ended))
    }
}

private struct SlideshowPresenter: ViewModifier {
    @Binding var request: SlideshowRequest?
    let ended: @MainActor (FileID) -> Void
    @Environment(SessionModel.self) private var session

    func close(last: FileID?) {
        request = nil
        if let last { ended(last) }
    }

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(item: $request) { (request: SlideshowRequest) in
                SlideshowPlayer(request: request) { last in close(last: last) }
                    .environment(session)
            }
        #elseif os(macOS)
            content.onChange(of: request) { _, request in
                guard let request else { return }
                SlideshowWindow.present(request, session: session) { last in close(last: last) }
            }
        #else
            content.navigationDestination(item: $request) { (request: SlideshowRequest) in
                SlideshowPlayer(request: request) { last in close(last: last) }
            }
        #endif
    }
}

/// The photos one after the other, cross-faded, with a slow zoom unless Reduce Motion is on. Videos play to their end
/// (a video that cannot be played shows its still for the interval). Plays by itself (not with VoiceOver), pauses and
/// goes on, steps back and forward; the interval and whether it starts over after the last photo are options. Ends with
/// Close (Escape), and at once when the app locks.
struct SlideshowPlayer: View {
    let request: SlideshowRequest
    let close: @MainActor (_ last: FileID?) -> Void
    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AppStorage(SlideshowSettings.intervalKey) private var storedInterval = SlideshowPlan.defaultInterval
    @AppStorage(SlideshowSettings.repeatsKey) private var repeats = true
    @State private var items: [MediaItem] = []
    @State private var index = 0
    @State private var playing = true
    @State private var controlsShown = true
    @State private var loaded = false
    /// Videos that cannot be played here: they show their still for the interval instead.
    @State private var stills: Set<FileID> = []
    @State private var lock = AppLock.shared
    @FocusState private var focused: Bool

    var interval: Int { SlideshowPlan.interval(seconds: storedInterval) }

    var current: MediaItem? { items[safe: index] }

    /// Restarts the timer whenever the photo changes, playback is paused or resumed, or the interval changes.
    struct Tick: Hashable {
        var index: Int
        var playing: Bool
        var count: Int
        var interval: Int
        var still: Bool
    }

    var tick: Tick {
        let isTimed: Bool = current.map { $0.kind != .video || stills.contains($0.fileId) } ?? false
        return Tick(index: index, playing: playing, count: items.count, interval: interval, still: isTimed)
    }

    var body: some View {
        stage
            .contentShape(.rect)
            .onTapGesture {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsShown.toggle() }
            }
            .overlay(alignment: .top) { if controlsShown { topBar } }
            .overlay(alignment: .bottom) { if controlsShown { playbackBar } }
            #if os(iOS)
                .statusBarHidden(!controlsShown)
                .persistentSystemOverlays(controlsShown ? .automatic : .hidden)
            #elseif os(visionOS)
                .navigationTitle(request.title)
            #endif
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear {
                focused = true
                DisplaySleep.prevent(true)
            }
            .onDisappear { DisplaySleep.prevent(false) }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .space, .escape]) { press in
                switch press.key {
                case .leftArrow: step(-1)
                case .rightArrow: step(1)
                case .space: playing.toggle()
                default: close(current?.fileId)
                }
                return .handled
            }
            .task {
                playing = Slideshow.startsPlaying(voiceOver: voiceOver)
                await load()
            }
            .task(id: tick) {
                guard tick.playing, tick.still, items.count > 0 else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                advance()
            }
            // Nothing of the library stays on screen while the app is locked.
            .onChange(of: lock.requiresUnlock) { _, locked in
                if locked { close(nil) }
            }
    }

    @ViewBuilder var stage: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item = current {
                slide(item)
                    .id(item.fileId)
                    .transition(.opacity)
                    .accessibilityLabel(description(of: item))
                    .accessibilityAddTraits(.isImage)
                // Loaded ahead, out of sight, so the next photo is there when it fades in.
                if let next = SlideshowPlan.next(after: index, count: items.count, repeats: repeats).flatMap({ items[safe: $0] }),
                    next.fileId != item.fileId
                {
                    PreviewImage(item: next, bucket: 1024, contentMode: .fit).opacity(0).accessibilityHidden(true)
                }
            } else if loaded {
                ContentUnavailableView(String(localized: "No photos to show", bundle: .module), systemImage: "photo.on.rectangle.angled")
            } else {
                ProgressView().tint(.white)
            }
        }
    }

    @ViewBuilder func slide(_ item: MediaItem) -> some View {
        if item.kind == .video && !stills.contains(item.fileId) {
            SlideshowVideo(
                item: item, playing: playing,
                finished: { if playing { advance() } },
                unplayable: { stills.insert(item.fileId) })
        } else {
            SlideshowPhoto(item: item, drift: Slideshow.drift(reduceMotion: reduceMotion), interval: interval)
        }
    }

    func load() async {
        guard let services = session.services else { return }
        let map = (try? await services.library.fetchItems(request.ids)) ?? [:]
        // In the order of the place it was started from, beginning with the photo it was started at.
        let ordered: [FileID] = SlideshowPlan.order(request.ids, from: request.startId)
        items = ordered.compactMap { map[$0] }.filter { !$0.isLivePhotoVideo }
        loaded = true
    }

    /// The next photo; after the last one the slideshow starts over, or stops there with its controls shown.
    func advance() {
        guard let next = SlideshowPlan.next(after: index, count: items.count, repeats: repeats) else {
            playing = false
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsShown = true }
            return
        }
        show(next)
    }

    func show(_ next: Int) {
        withAnimation(.easeInOut(duration: Slideshow.crossfade(reduceMotion: reduceMotion))) { index = next }
    }

    func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        show(delta < 0 ? Slideshow.previous(before: index, count: items.count) : Slideshow.next(after: index, count: items.count))
    }

    func description(of item: MediaItem) -> String {
        AccessibilityText.media(
            isVideo: item.kind == .video, isLivePhoto: item.isLivePhoto, date: item.timestamp, duration: item.duration,
            place: item.place, isFavorite: item.isFavorite, caption: item.caption)
    }

    // MARK: Controls

    var topBar: some View {
        HStack(spacing: 12) {
            Button {
                close(current?.fileId)
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
            }
            Spacer(minLength: 0)
            #if os(iOS)
                // Videos go to the AirPlay receiver chosen here; Screen Mirroring shows the whole slideshow there.
                RoutePicker()
                    .frame(width: 44, height: 44)
                    .help(String(localized: "AirPlay", bundle: .module))
            #endif
            optionsMenu
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

    /// How long each photo is shown, and whether the slideshow starts over after the last one.
    var optionsMenu: some View {
        Menu {
            Picker(selection: $storedInterval) {
                ForEach(SlideshowPlan.intervals, id: \.self) { seconds in
                    Text(Self.intervalTitle(seconds)).tag(seconds)
                }
            } label: {
                Text("Show each photo for", bundle: .module)
            }
            .pickerStyle(.inline)
            Toggle(isOn: $repeats) {
                Text("Repeat", bundle: .module)
            }
        } label: {
            Label(String(localized: "Slideshow options", bundle: .module), systemImage: "timer")
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .menuIndicator(.hidden)
        .help(String(localized: "Slideshow options", bundle: .module))
        .onAppear { storedInterval = interval }
    }

    /// "3 seconds".
    static func intervalTitle(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .wide))
    }

    var playbackBar: some View {
        HStack(spacing: 28) {
            controlButton(String(localized: "Previous", bundle: .module), systemImage: "backward.fill", disabled: items.count < 2) {
                step(-1)
            }
            controlButton(
                playing ? String(localized: "Pause", bundle: .module) : String(localized: "Play", bundle: .module),
                systemImage: playing ? "pause.fill" : "play.fill", disabled: items.isEmpty, large: true
            ) {
                // Played to the end without repeating: Play starts again from the first photo.
                if !playing, SlideshowPlan.next(after: index, count: items.count, repeats: repeats) == nil { show(0) }
                playing.toggle()
            }
            controlButton(String(localized: "Next", bundle: .module), systemImage: "forward.fill", disabled: items.count < 2) {
                step(1)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45), in: .capsule)
        .padding(.bottom, 24)
    }

    func controlButton(_ title: String, systemImage: String, disabled: Bool, large: Bool = false, action: @escaping () -> Void)
        -> some View
    {
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
private struct SlideshowPhoto: View {
    let item: MediaItem
    /// The scale the photo grows to while it is shown (1: it stays still).
    let drift: Double
    let interval: Int
    @State private var grown = false

    var body: some View {
        PreviewImage(item: item, bucket: 1024, contentMode: .fit)
            .scaleEffect(grown ? drift : 1)
            .ignoresSafeArea()
            .onAppear {
                guard drift != 1 else { return }
                withAnimation(.linear(duration: SlideshowPlan.driftDuration(interval: interval))) { grown = true }
            }
    }
}

/// A video of the slideshow, played to its end without controls; its still while it loads.
private struct SlideshowVideo: View {
    let item: MediaItem
    let playing: Bool
    /// The video played to its end.
    let finished: @MainActor () -> Void
    /// It cannot be played here: the slideshow shows its still instead.
    let unplayable: @MainActor () -> Void
    @Environment(SessionModel.self) private var session
    @State private var video: PlayableVideo?

    var body: some View {
        ZStack {
            PreviewImage(item: item, bucket: 1024, contentMode: .fit)
            if let player = video?.player {
                PlayerSurface(player: player, showsControls: false)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .task { await load() }
        .task(id: video.map { ObjectIdentifier($0.player) }) { await watch() }
        .onChange(of: playing) { _, playing in
            if playing { video?.player.play() } else { video?.player.pause() }
        }
        .onDisappear {
            video?.release()
            video = nil
        }
    }

    func load() async {
        guard let services = session.services else { return }
        // Formats only the server's conversion can play are left to the viewer: the slideshow does not wait minutes.
        guard !MimeTypes.unplayableVideos.contains(item.mimeType) else {
            unplayable()
            return
        }
        do {
            let loaded: PlayableVideo = try await PlayableVideo.load(
                fileId: item.fileId, etag: item.etag, name: item.name, mimeType: item.mimeType,
                originalURL: services.originalURL(for: item), services: services, offline: session.offline)
            guard !Task.isCancelled else {
                loaded.release()
                return
            }
            video = loaded
            if playing { loaded.player.play() }
        } catch {
            if !Task.isCancelled { unplayable() }
        }
    }

    /// Moves on at the end of the video, or shows the still when it fails while playing.
    func watch() async {
        guard let playerItem = video?.player.currentItem else { return }
        let ended = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem)
            .map { _ in true }
        let failed = playerItem.publisher(for: \.status).filter { $0 == .failed }.map { _ in false }
        for await didEnd in ended.merge(with: failed).first().values {
            guard !Task.isCancelled else { return }
            if didEnd { finished() } else { unplayable() }
        }
    }
}

/// Keeps the screen on while a slideshow plays.
@MainActor
enum DisplaySleep {
    #if os(macOS)
        private static var activity: (any NSObjectProtocol)?
    #endif

    static func prevent(_ prevent: Bool) {
        #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = prevent
        #elseif os(macOS)
            if prevent, activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Slideshow")
            } else if !prevent, let running = activity {
                ProcessInfo.processInfo.endActivity(running)
                activity = nil
            }
        #endif
    }
}

#if os(iOS)
    /// The system's AirPlay button.
    private struct RoutePicker: UIViewRepresentable {
        func makeUIView(context: Context) -> AVRoutePickerView {
            let view = AVRoutePickerView()
            view.tintColor = .white
            view.prioritizesVideoDevices = true
            return view
        }

        func updateUIView(_ view: AVRoutePickerView, context: Context) {}
    }
#endif

#if os(macOS)
    import AppKit

    /// The Mac's slideshow: a window of its own that goes full screen, like Apple Photos' slideshow, so the library's
    /// window keeps its sidebar and place. Escape or Close ends it and closes the window.
    @MainActor
    enum SlideshowWindow {
        /// Open slideshow windows, kept until they close.
        private static var open: [ObjectIdentifier: Controller] = [:]

        @MainActor
        final class Controller: NSObject, NSWindowDelegate {
            let window: NSWindow
            let closed: @MainActor (FileID?) -> Void
            /// Counts as a window in front for the app lock.
            let lockId = UUID()
            var last: FileID?

            init(window: NSWindow, closed: @escaping @MainActor (FileID?) -> Void) {
                self.window = window
                self.closed = closed
            }

            func finish(_ last: FileID?) {
                self.last = last
                // Not from inside the action of the slideshow's own Close button, whose view goes with the window.
                DispatchQueue.main.async { [window] in window.close() }
            }

            func windowWillClose(_ notification: Notification) {
                AppLock.shared.windowDidLeave(lockId)
                closed(last)
                // The window and its views are let go once it is closed, not while it closes.
                DispatchQueue.main.async { [self] in
                    window.contentViewController = nil
                    SlideshowWindow.open[ObjectIdentifier(self)] = nil
                }
            }

            func windowDidMiniaturize(_ notification: Notification) { AppLock.shared.windowDidLeave(lockId) }
            func windowDidDeminiaturize(_ notification: Notification) { AppLock.shared.windowDidBecomeActive(lockId) }
        }

        static func present(_ request: SlideshowRequest, session: SessionModel, closed: @escaping @MainActor (FileID?) -> Void) {
            let screen: NSScreen? = NSApp.keyWindow?.screen ?? NSScreen.main
            let window = NSWindow(
                contentRect: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            let controller = Controller(window: window, closed: closed)
            let player = SlideshowPlayer(request: request) { [weak controller] last in controller?.finish(last) }
                .environment(session)
            window.contentViewController = NSHostingController(rootView: player)
            window.title = request.title
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.delegate = controller
            open[ObjectIdentifier(controller)] = controller
            AppLock.shared.windowDidBecomeActive(controller.lockId)
            window.setFrame(screen?.visibleFrame ?? window.frame, display: false)
            window.makeKeyAndOrderFront(nil)
            if !windowed { window.toggleFullScreen(nil) }
        }

        /// Debug builds: `PHOTOS_DEBUG_SLIDESHOW_WINDOWED=1` keeps the slideshow in a window (UI checks on a Mac in use).
        static var windowed: Bool {
            #if DEBUG
                ProcessInfo.processInfo.environment["PHOTOS_DEBUG_SLIDESHOW_WINDOWED"] == "1"
            #else
                false
            #endif
        }
    }
#endif

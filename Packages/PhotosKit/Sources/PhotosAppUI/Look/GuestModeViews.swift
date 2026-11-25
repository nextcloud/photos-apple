// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

#if os(macOS)
    import AppKit
#endif

// MARK: - Guest Mode (SPEC §16.8.3)

/// Texts of Guest Mode, per platform.
enum GuestWording {
    static var menuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Show to a Guest…", bundle: .module, comment: "Album or memory menu item on the Mac: start Guest Mode with its photos."),
            other: LocalizedStringResource(
                "Show to a guest…", bundle: .module, comment: "Album or memory menu item: start Guest Mode with its photos."))
    }

    static let systemImage = "person.crop.rectangle.badge.lock"

    static var endTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("End Guest Mode", bundle: .module, comment: "Button in Guest Mode on the Mac: leave it."),
            other: LocalizedStringResource(
                "End Guest Mode", bundle: .module, comment: "Button in Guest Mode: leave it (asks for Face ID or the passcode)."))
    }

    /// What the system's authentication prompt says.
    static var reason: String {
        String(localized: "End Guest Mode", bundle: .module, comment: "Reason in the system's authentication prompt when Guest Mode ends.")
    }

    static var subtitle: String {
        String(localized: "Guest Mode", bundle: .module, comment: "Subtitle of the album or memory shown in Guest Mode.")
    }

    /// What the start sheet explains.
    static var explanation: String {
        #if os(macOS)
            String(
                localized:
                    "Only these photos fill the screen. Sharing, deleting, info, your other albums and notifications are not available. Leaving needs Touch ID or your password.",
                bundle: .module, comment: "Guest Mode start sheet on the Mac.")
        #else
            String(
                localized:
                    "Only these photos can be seen. Sharing, deleting, info, your other albums and notifications are not available. Ending Guest Mode needs Face ID, Touch ID or your passcode.",
                bundle: .module, comment: "Guest Mode start sheet on iPhone, iPad and Vision Pro.")
        #endif
    }

    /// The system's own lock, which also keeps the guest in the app.
    static var guidedAccessTip: String? {
        #if os(iOS)
            String(
                localized:
                    "To also keep your guest in this app, turn on Guided Access in Settings › Accessibility and triple-click the side or Home button.",
                bundle: .module, comment: "Guest Mode start sheet: tip about the system's Guided Access.")
        #elseif os(visionOS)
            String(
                localized: "To also keep your guest in this app, turn on Guided Access in Settings › Accessibility.", bundle: .module,
                comment: "Guest Mode start sheet on Vision Pro: tip about the system's Guided Access.")
        #else
            nil
        #endif
    }

    static var unprotected: String {
        #if os(macOS)
            String(
                localized: "This Mac has no login password, so anyone can end Guest Mode.", bundle: .module,
                comment: "Guest Mode start sheet: warning when nothing can protect it.")
        #else
            String(
                localized: "This device has no passcode, so anyone can end Guest Mode.", bundle: .module,
                comment: "Guest Mode start sheet: warning when nothing can protect it.")
        #endif
    }
}

/// What an album card's menu opens (SPEC §16.8.2, §16.8.3).
enum AlbumCardSheet: Identifiable {
    case cover(Album)
    case guest(GuestShow)

    var id: String {
        switch self {
        case .cover(let album): "cover:\(album.id)"
        case .guest(let show): "guest:\(show.title)"
        }
    }
}

/// "Customize Cover…" and "Show to a Guest…" for an album (its card's context menu, the album's options menu).
struct AlbumLookMenuItems: View {
    let album: Album
    @Binding var sheet: AlbumCardSheet?
    @Environment(SessionModel.self) private var session

    var body: some View {
        Button {
            sheet = .cover(album)
        } label: {
            Label(AlbumLookSheet.menuTitle, systemImage: "photo.artframe")
        }
        Button {
            Task { if let show = await GuestShows.album(album, session: session) { sheet = .guest(show) } }
        } label: {
            Label(GuestWording.menuTitle, systemImage: GuestWording.systemImage)
        }
        .disabled(album.itemCount == 0)
    }
}

extension View {
    /// Presents what `AlbumLookMenuItems` asks for.
    func albumCardSheets(_ sheet: Binding<AlbumCardSheet?>) -> some View {
        self.sheet(item: sheet) { (value: AlbumCardSheet) in
            switch value {
            case .cover(let album): AlbumLookSheet(album: album)
            case .guest(let show): GuestStartSheet(show: show)
            }
        }
    }
}

/// The photos a guest may see, read when Guest Mode starts.
@MainActor
enum GuestShows {
    static func album(_ album: Album, session: SessionModel) async -> GuestShow? {
        guard let services = session.services else { return nil }
        func read() async -> [FileID] {
            do {
                for try await value in services.collections.observeAlbumGrid(albumId: album.id) { return value.map(\.fileId) }
            } catch {}
            return []
        }
        var ids = await read()
        if ids.isEmpty {
            // Not read from the server yet (an album not opened before).
            try? await session.refreshAlbumContent(album)
            ids = await read()
        }
        guard !ids.isEmpty else { return nil }
        return GuestShow(
            account: session.account.id.rawValue, kind: .album, title: album.title,
            subtitle: album.dateStart.map { DateRangeLabel.string(from: $0, to: album.dateEnd ?? $0) }, items: ids)
    }

    static func memory(_ memory: Memory, session: SessionModel) -> GuestShow {
        GuestShow(
            account: session.account.id.rawValue, kind: .memory, title: memory.title, subtitle: Memories.dateLine(for: memory),
            items: memory.items)
    }
}

/// Explains Guest Mode and starts it.
struct GuestStartSheet: View {
    let show: GuestShow
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: GuestWording.systemImage)
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(
                        "Show “\(show.title)” to a Guest", bundle: .module,
                        comment: "Guest Mode start sheet title; the argument is the album or memory."
                    )
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    Text(GuestWording.explanation)
                        .multilineTextAlignment(.center)
                    if !GuestMode.isProtected {
                        Label(GuestWording.unprotected, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let tip = GuestWording.guidedAccessTip {
                        Text(tip)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        start()
                    } label: {
                        Text("Start Guest Mode", bundle: .module, comment: "Button: start Guest Mode.")
                            .frame(maxWidth: 320)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 440, minHeight: 360)
        #endif
        .presentationDetents([.medium, .large])
    }

    func start() {
        dismiss()
        GuestMode.shared.start(show)
        #if os(macOS)
            openWindow(id: GuestModeScene.id)
        #endif
    }
}

/// The Mac's presentation window (`Window(id: GuestModeScene.id)` in the app).
public enum GuestModeScene {
    public static let id = "guest-mode"
}

// MARK: The guest's view

/// What a guest sees: the photos of one album or memory, and nothing else (SPEC §16.8.3). Replaces the whole window
/// content on iPhone, iPad and Vision Pro; fills the Mac's presentation window.
public struct GuestModeRoot: View {
    @Environment(AppModel.self) private var app
    @State private var guest = GuestMode.shared
    @State private var viewing: GuestViewerStart?
    #if !os(macOS)
        @State private var slideshow: SlideshowRequest?
    #endif
    @State private var failed = false

    public init() {}

    public var body: some View {
        if let show = guest.show, let session = app.session {
            NavigationStack {
                grid(show: show, session: session)
                    .navigationTitle(show.title)
                    #if !os(visionOS)
                        .navigationSubtitle(show.subtitle.map { "\(GuestWording.subtitle) · \($0)" } ?? GuestWording.subtitle)
                    #endif
                    .toolbar { toolbar(show: show) }
                    .photoHeaderTint(show.items.first)
                    #if os(macOS)
                        .overlay {
                            if let viewing {
                                GuestViewer(ids: show.items, start: viewing.id) { self.viewing = nil }
                                .transition(.opacity)
                            }
                        }
                    #elseif os(iOS)
                        .fullScreenCover(item: $viewing) { start in
                            GuestViewer(ids: show.items, start: start.id) { viewing = nil }
                            .environment(session)
                        }
                        .slideshow($slideshow)
                    #else
                        .navigationDestination(item: $viewing) { start in
                            GuestViewer(ids: show.items, start: start.id) { viewing = nil }
                        }
                        .slideshow($slideshow)
                    #endif
            }
            .environment(session)
            .alert(
                String(
                    localized: "Guest Mode continues", bundle: .module, comment: "Alert when the authentication to end Guest Mode failed."),
                isPresented: $failed
            ) {
                Button(String(localized: "OK", bundle: .module)) {}
            }
        } else {
            Color.clear
        }
    }

    func grid(show: GuestShow, session: SessionModel) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 220), spacing: 2)], spacing: 2) {
                // Only photos of the account shown: never anything of another account.
                ForEach(guest.items(for: session.account.id), id: \.self) { (id: FileID) in
                    Button {
                        viewing = GuestViewerStart(id: id)
                    } label: {
                        GuestTile(fileId: id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ToolbarContentBuilder func toolbar(show: GuestShow) -> some ToolbarContent {
        #if !os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    slideshow = SlideshowRequest(title: show.title, ids: show.items, startId: show.items.first)
                } label: {
                    Label(SlideshowRequest.menuTitle, systemImage: "play.rectangle")
                }
            }
        #endif
        ToolbarItem(placement: .cancellationAction) {
            Button {
                Task { await end() }
            } label: {
                Label(GuestWording.endTitle, systemImage: "lock.open")
            }
            .disabled(guest.isAuthenticating)
            .help(GuestWording.endTitle)
        }
    }

    func end() async {
        let ended = await guest.end(reason: GuestWording.reason)
        guard ended else {
            failed = true
            return
        }
        // What a guest opened from outside meanwhile (a notification, a link) does not open afterwards.
        app.requestedDestination = nil
        app.linkPrompt = nil
        #if os(macOS)
            GuestKiosk.leave()
        #endif
    }
}

struct GuestViewerStart: Identifiable, Hashable {
    let id: FileID
}

/// A square tile of the guest's grid.
private struct GuestTile: View {
    let fileId: FileID
    @Environment(SessionModel.self) private var session
    @State private var item: MediaItem?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let item {
                    PreviewImage(item: item, bucket: 256)
                } else {
                    PreviewImage(fileId: fileId, etag: "", bucket: 256)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item?.kind == .video {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(5)
                }
            }
            .clipped()
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .task(id: fileId) { item = try? session.services?.library.item(fileId) }
    }

    var label: String {
        guard let item else { return "" }
        return AccessibilityText.media(
            isVideo: item.kind == .video, isLivePhoto: item.isLivePhoto, date: item.timestamp, duration: item.duration, place: item.place,
            isFavorite: false, caption: item.caption)
    }
}

/// The guest's viewer: paging, zoom, Live Photos and videos, the photo's colour behind it, and only Close.
private struct GuestViewer: View {
    let ids: [FileID]
    let start: FileID
    let close: () -> Void
    @State private var current: FileID?
    @State private var tint = ViewerTint()
    @State private var zoomCommand: ViewerZoomCommand?
    @FocusState private var focused: Bool

    init(ids: [FileID], start: FileID, close: @escaping () -> Void) {
        self.ids = ids
        self.start = start
        self.close = close
        _current = State(initialValue: start)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(ids, id: \.self) { (id: FileID) in
                    ViewerPage(
                        fileId: id, isCurrent: id == current,
                        position: ids.firstIndex(of: id).map { AccessibilityText.position(index: $0, count: ids.count) } ?? "",
                        offersActions: false
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Double.self) { geometry in
            ViewerTint.pagePosition(offset: geometry.contentOffset.x, width: geometry.containerSize.width)
        } action: { _, position in
            tint.scrollPosition = position
        }
        .background(ViewerBackdrop(tint: tint).ignoresSafeArea())
        .modifier(ViewerTintTracking(tint: tint, pages: ids, current: current))
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding()
            .accessibilityLabel(Text("Close", bundle: .module))
            .keyboardShortcut(.cancelAction)
        }
        .environment(\.isGuestPresentation, true)
        .keyFocusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .hardwareKeys([.leftArrow, .rightArrow]) { key in
            step(key == .rightArrow ? 1 : -1)
        }
        .accessibilityAction(.escape) { close() }
    }

    func step(_ delta: Int) {
        guard let current, let index = ids.firstIndex(of: current) else { return }
        let next = index + delta
        guard ids.indices.contains(next) else { return }
        withAnimation { self.current = ids[next] }
    }
}

extension EnvironmentValues {
    /// Inside Guest Mode: no Live Text (its menu can copy, share and look things up).
    @Entry var isGuestPresentation = false
}

// MARK: While Guest Mode is on

/// Every other window while Guest Mode is on: nothing of the library, and on the Mac a way back to the presentation.
public struct GuestModeCover: View {
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif

    public init() {}

    public var body: some View {
        ContentUnavailableView {
            Label(GuestWording.subtitle, systemImage: GuestWording.systemImage)
        } description: {
            Text("Nothing else is shown while Guest Mode is on.", bundle: .module, comment: "Other windows while Guest Mode is on.")
        } actions: {
            #if os(macOS)
                Button(String(localized: "Show Presentation", bundle: .module, comment: "Mac: bring back the Guest Mode window.")) {
                    openWindow(id: GuestModeScene.id)
                }
            #endif
        }
        #if os(macOS)
            // Opened again after a relaunch in Guest Mode.
            .task { openWindow(id: GuestModeScene.id) }
        #endif
    }
}

#if os(macOS)
    /// The Mac's presentation window: Guest Mode on the whole screen, with the Dock, the menu bar and app switching away,
    /// until the owner ends it with Touch ID or the password. Force Quit stays available (and a relaunch comes back in Guest
    /// Mode).
    public struct GuestModeWindow: View {
        @Environment(AppModel.self) private var app
        @Environment(\.dismissWindow) private var dismissWindow
        @State private var guest = GuestMode.shared

        public init() {}

        public var body: some View {
            Group {
                if guest.isActive {
                    GuestModeRoot()
                        .background { GuestKiosk() }
                } else {
                    Color.clear.task { dismissWindow(id: GuestModeScene.id) }
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            .onChange(of: guest.isActive) { _, active in
                if !active { dismissWindow(id: GuestModeScene.id) }
            }
        }
    }

    /// Makes its window the presentation: the whole screen, not closable, the Dock, menu bar and app switching away.
    struct GuestKiosk: NSViewRepresentable {
        static let options: NSApplication.PresentationOptions = [
            .hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication,
        ]

        func makeNSView(context: Context) -> NSView {
            let view = KioskView()
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {}

        /// Ends the presentation: the Dock, the menu bar and app switching come back.
        @MainActor static func leave() {
            NSApplication.shared.presentationOptions = []
        }

        final class KioskView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window, let screen = window.screen ?? NSScreen.main else { return }
                window.styleMask.remove([.closable, .miniaturizable, .resizable])
                window.collectionBehavior.insert(.fullScreenNone)
                window.setFrame(screen.frame, display: true)
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate()
                NSApplication.shared.presentationOptions = GuestKiosk.options
            }
        }
    }
#endif

/// What a window of the app shows in Guest Mode: the guest's photos on iPhone, iPad and Vision Pro; on the Mac they are in
/// the presentation window, and this window shows nothing of the library.
struct GuestModeContent: View {
    var body: some View {
        #if os(macOS)
            GuestModeCover()
        #else
            GuestModeRoot()
        #endif
    }
}

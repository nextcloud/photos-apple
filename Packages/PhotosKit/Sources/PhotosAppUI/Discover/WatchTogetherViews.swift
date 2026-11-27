// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

#if os(macOS)
    import AppKit
#endif

/// The wording of watching together (SPEC §16.6).
enum WatchTogetherText {
    static var shareTitle: String {
        String(
            localized: "SharePlay", bundle: .module, comment: "Memory film and slideshow: button that watches it together over FaceTime.")
    }

    static var leave: String {
        String(localized: "Leave SharePlay", bundle: .module, comment: "Film shared over SharePlay: closes it on this device only.")
    }

    static var notShared: String {
        String(
            localized: "Not shared with you", bundle: .module,
            comment: "Film watched together: in place of a photo that is not shared with this person on Nextcloud.")
    }

    static var howToStart: String {
        String(
            localized:
                "Start a FaceTime call with the people you want to watch with, then choose SharePlay again. Everyone needs Nextcloud Photos and access to these photos on your Nextcloud: share the album with them there.",
            bundle: .module, comment: "SharePlay could not start: what is needed.")
    }

    /// What everyone needs, said before sharing: nothing but the film's description goes through Apple.
    static var privacy: String {
        String(
            localized:
                "Everyone sees the photos from your Nextcloud with their own account: only photos shared with them there. No photo is sent through Apple.",
            bundle: .module, comment: "SharePlay: how the photos reach the others (and that they are never sent through Apple).")
    }

    static func watching(_ others: Int) -> String {
        if others <= 0 {
            return String(
                localized: "Waiting for others to join…", bundle: .module, comment: "SharePlay banner: nobody else has joined yet.")
        }
        if others == 1 {
            return String(
                localized: "Watching with one other person", bundle: .module,
                comment: "SharePlay banner: one other person watches the film.")
        }
        return String(
            localized: "Watching with \(others) others", bundle: .module,
            comment: "SharePlay banner: how many other people watch the film. The argument is a number.")
    }

    /// For the others: who cannot see some or all of the photos.
    static func audience(_ audience: SharedFilmAudience) -> String? {
        if audience.blind == 1 {
            return String(
                localized:
                    "Someone can't see these photos. Share the album with them on Nextcloud, or ask them to sign in to it.",
                bundle: .module, comment: "SharePlay banner: one participant sees none of the photos.")
        }
        if audience.blind > 1 {
            return String(
                localized:
                    "\(audience.blind) people can't see these photos. Share the album with them on Nextcloud, or ask them to sign in to it.",
                bundle: .module, comment: "SharePlay banner: some participants see none of the photos. The argument is a number.")
        }
        if audience.partial == 1 {
            return String(
                localized: "Someone can't see some photos. Share the album with them on Nextcloud.", bundle: .module,
                comment: "SharePlay banner: one participant sees only part of the photos.")
        }
        if audience.partial > 1 {
            return String(
                localized: "\(audience.partial) people can't see some photos. Share the album with them on Nextcloud.", bundle: .module,
                comment: "SharePlay banner: some participants see only part of the photos. The argument is a number.")
        }
        return nil
    }

    /// For this device, watching someone else's film.
    static func ownView(visible: Int, total: Int) -> String {
        String(
            localized:
                "You can see \(visible) of \(total) photos. The others aren't shared with you on Nextcloud; they show as dark cards.",
            bundle: .module,
            comment: "SharePlay banner of a participant: how many of the film's photos they can see. Arguments are numbers.")
    }
}

/// Under the film's controls while watching together: how many watch, and who cannot see what.
struct WatchTogetherBanner: View {
    let model: MemoryFilmModel
    @State private var watch = WatchTogether.shared

    var lines: [String] {
        var lines = [WatchTogetherText.watching(max(0, watch.participantCount - 1))]
        if model.isGuest, let total = model.making?.items.count, model.checked >= total, !model.unavailable.isEmpty {
            lines.append(WatchTogetherText.ownView(visible: total - model.unavailable.count, total: total))
        }
        if let audience = WatchTogetherText.audience(watch.audience) { lines.append(audience) }
        return lines
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shareplay").font(.headline)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines, id: \.self) { line in Text(line) }
            }
            .font(.footnote)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.black.opacity(0.5), in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

/// In place of a photo of a shared film that this account cannot load.
struct NotSharedCard: View {
    let height: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.12), .black], startPoint: .top, endPoint: .bottom)
            VStack(spacing: height * 0.02) {
                Image(systemName: "lock.fill").font(.system(size: height * 0.06))
                Text(WatchTogetherText.notShared).font(.system(size: height * 0.03, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// When a film comes over SharePlay that this account cannot open: why, and what helps.
struct WatchTogetherProblemView: View {
    let film: SharedFilm
    @Environment(AppModel.self) private var app
    let dismiss: () -> Void

    /// Another account on this device is on the film's Nextcloud.
    var otherAccount: Account? { app.accounts.first { film.isOn($0.serverURL) } }

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(film.title, systemImage: "shareplay")
            } description: {
                if let otherAccount {
                    Text(
                        "This film is on \(film.serverName). Switch to your account \(otherAccount.userId) there to watch it together.",
                        bundle: .module,
                        comment: "SharePlay: the film is on a Nextcloud where the user has another account. Arguments: server, user name.")
                } else {
                    Text(
                        "This film is on \(film.serverName), and you're not signed in to it in Nextcloud Photos. Sign in with an account the photos are shared with, then join again.",
                        bundle: .module,
                        comment: "SharePlay: the film is on a Nextcloud the user is not signed in to. The argument is the server.")
                }
            } actions: {
                if let otherAccount {
                    Button(
                        String(
                            localized: "Switch Account", bundle: .module,
                            comment: "SharePlay: switches to the account on the film's server.")
                    ) {
                        app.switchTo(otherAccount.id)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(WatchTogetherText.leave) {
                    WatchTogether.shared.leave()
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close", bundle: .module)) { dismiss() }
                }
            }
        }
        .sheetMinimumSize(width: 420, height: 320)
        .onAppear {
            WatchTogether.shared.report(SharedFilmReport(visible: 0, total: film.pictures.count, problem: .noAccount))
        }
    }
}

extension View {
    /// Joins SharePlay sessions of the app and shows the film someone shares (SPEC §16.6), when no film player is open
    /// (an open one takes the shared film over): full screen on iPhone, iPad and Vision Pro, in a window of its own on the
    /// Mac. Inside the app lock: nothing is shown while the app is locked.
    func watchTogether() -> some View {
        modifier(WatchTogetherReceiver())
    }
}

private struct WatchTogetherReceiver: ViewModifier {
    @Environment(SessionModel.self) private var session
    @Environment(AppModel.self) private var app
    @State private var watch = WatchTogether.shared
    @State private var lock = AppLock.shared
    @State private var presented: SharedFilm?
    @State private var problem: SharedFilm?

    func body(content: Content) -> some View {
        content
            .task { watch.listen() }
            .onChange(of: watch.film?.id, initial: true) { _, _ in present() }
            .onChange(of: lock.requiresUnlock) { _, locked in
                if locked {
                    presented = nil
                    #if os(macOS)
                        SharedFilmWindow.closeAll()
                    #endif
                } else {
                    present()
                }
            }
            #if os(macOS)
                .onChange(of: presented?.id) { _, _ in
                    guard let film = presented else { return }
                    SharedFilmWindow.present(film, session: session) { presented = nil }
                }
            #else
                .fullScreenCover(item: $presented) { (film: SharedFilm) in
                    MemoryFilmPlayer(shared: film).environment(session)
                }
            #endif
            .sheet(item: $problem) { (film: SharedFilm) in
                WatchTogetherProblemView(film: film) { problem = nil }.environment(app)
            }
    }

    func present() {
        guard let film = watch.film, !lock.requiresUnlock else { return }
        // An open film player takes the shared film over (it may be this device's own); a slideshow shared from here
        // opens like anyone else's.
        guard FilmPlayers.open == 0, presented?.id != film.id else { return }
        if film.isOn(session.account.serverURL) {
            presented = film
        } else {
            problem = film
        }
    }
}

#if os(macOS)
    /// The Mac shows a film shared over SharePlay in a window of its own, like a slideshow.
    @MainActor enum SharedFilmWindow {
        private static var open: [ObjectIdentifier: Controller] = [:]

        final class Controller: NSObject, NSWindowDelegate {
            let window: NSWindow
            let closed: @MainActor () -> Void
            let lockId = UUID()

            init(window: NSWindow, closed: @escaping @MainActor () -> Void) {
                self.window = window
                self.closed = closed
            }

            func windowWillClose(_ notification: Notification) {
                AppLock.shared.windowDidLeave(lockId)
                closed()
                DispatchQueue.main.async { [self] in
                    window.contentViewController = nil
                    SharedFilmWindow.open[ObjectIdentifier(self)] = nil
                }
            }
        }

        static func present(_ film: SharedFilm, session: SessionModel, closed: @escaping @MainActor () -> Void) {
            closeAll()
            let screen: NSScreen? = NSApp.keyWindow?.screen ?? NSScreen.main
            let frame = screen?.visibleFrame.insetBy(dx: 80, dy: 60) ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let window = NSWindow(
                contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            let controller = Controller(window: window, closed: closed)
            let player = MemoryFilmPlayer(shared: film) { [weak window] in
                DispatchQueue.main.async { window?.close() }
            }
            .environment(session)
            window.contentViewController = NSHostingController(rootView: player)
            window.title = film.title
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.delegate = controller
            open[ObjectIdentifier(controller)] = controller
            AppLock.shared.windowDidBecomeActive(controller.lockId)
            window.setFrame(frame, display: false)
            window.makeKeyAndOrderFront(nil)
        }

        static func closeAll() {
            for controller in open.values { controller.window.close() }
        }
    }
#endif

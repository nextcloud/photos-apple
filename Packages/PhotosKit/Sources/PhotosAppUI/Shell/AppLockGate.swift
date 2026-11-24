// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import SwiftUI

#if os(iOS)
    import UIKit
#endif

// MARK: - App lock (SPEC §8)

/// Keeps the account out of sight while the app is locked, and covers it in the app switcher.
///
/// - Locked: the content is not shown at all. Removing it also closes everything it presented (the viewer, sheets) and
///   takes its menu commands and keyboard shortcuts away; scene storage brings the window back to its place after unlocking.
/// - iPhone and iPad: the cover is a window of its own above the app's window, so it is also above a full-screen viewer,
///   sheets and alerts, and is what the app switcher's snapshot shows whenever the app is not active.
/// - Mac and Vision Pro: the cover is drawn over the window's content.
struct AppLockGate<Content: View>: View {
    /// The share extension offers to cancel instead of unlocking.
    var cancel: (@MainActor () -> Void)?
    /// Draw the cover over the content also on iPhone and iPad (the share extension, which has no scene of its own to add a
    /// window to and no app switcher snapshot).
    var inPlace = false
    @ViewBuilder var content: () -> Content
    @AppStorage(AppLockSettings.enabledKey, store: AppLockSettings.defaults) private var enabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var lock = AppLock.shared
    /// This window, for the Mac's count of windows in front (`AppLock.windowDidBecomeActive`).
    @State private var windowId = UUID()

    init(cancel: (@MainActor () -> Void)? = nil, inPlace: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.cancel = cancel
        self.inPlace = inPlace
        self.content = content
    }

    var coversInPlace: Bool {
        #if os(iOS)
            inPlace
        #else
            true
        #endif
    }

    var locked: Bool { enabled && lock.isLocked }

    /// The privacy cover: while locked, and whenever the window is not active (app switcher, Control Centre). An extension's
    /// view does not get the scene phases of an app window: there only the lock counts.
    var covered: Bool { enabled && (lock.isLocked || (!inPlace && scenePhase != .active)) }

    var body: some View {
        ZStack {
            if !locked { content() }
            if covered && coversInPlace { cover }
        }
        #if os(iOS)
            .background { if !inPlace { PrivacyCoverWindow(isShown: covered) { cover } } }
        #endif
        .onChange(of: scenePhase) { _, phase in
            #if os(macOS)
                switch phase {
                case .background: lock.windowDidLeave(windowId)
                case .active: lock.windowDidBecomeActive(windowId)
                default: break
                }
            #endif
            if phase == .active { askIfLocked() }
        }
        .onChange(of: lock.isLocked) { _, _ in askIfLocked() }
        .onChange(of: enabled) { _, _ in lock.settingChanged() }
        .task {
            #if os(macOS)
                if scenePhase == .active { lock.windowDidBecomeActive(windowId) }
            #endif
            askIfLocked()
        }
        #if os(macOS)
            // A closed window is not "away": only when no window is left in front does the lock clock start.
            .onDisappear { lock.windowDidLeave(windowId) }
        #endif
    }

    var cover: some View {
        AppLockCover(locked: locked, cancel: cancel) { Task { await unlock() } }
    }

    /// Asks for authentication right away when the window shows and the app is locked.
    func askIfLocked() {
        guard locked, inPlace || scenePhase == .active, !lock.isAuthenticating else { return }
        Task { await unlock() }
    }

    func unlock() async {
        await lock.unlock(reason: String(localized: "Unlock Nextcloud Photos", bundle: .module))
    }
}

/// What the lock shows: the logo, and while locked the Unlock button.
struct AppLockCover: View {
    let locked: Bool
    let cancel: (@MainActor () -> Void)?
    let unlock: @MainActor () -> Void

    var body: some View {
        ZStack {
            // Opaque: on iPhone and iPad it is a window of its own, which a material could not blur the app through.
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                NextcloudLogo().frame(width: 120, height: 60)
                if locked {
                    Button(String(localized: "Unlock Nextcloud Photos", bundle: .module)) { unlock() }
                        .buttonStyle(.borderedProminent)
                    if let cancel {
                        Button(String(localized: "Cancel", bundle: .module), role: .cancel) { cancel() }
                    }
                }
            }
        }
        // VoiceOver stays on the lock and doesn't wander into the window below.
        .accessibilityAddTraits(.isModal)
        #if os(macOS)
            // The Settings window takes the size of what it shows.
            .frame(minWidth: 360, minHeight: 240)
        #endif
    }
}

#if os(iOS)
    /// Shows `cover` in a window of its own above the scene's other windows while `isShown` (privacy cover and lock screen).
    struct PrivacyCoverWindow<Cover: View>: UIViewRepresentable {
        var isShown: Bool
        @ViewBuilder var cover: () -> Cover

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> AnchorView {
            let view = AnchorView()
            view.coordinator = context.coordinator
            view.isUserInteractionEnabled = false
            return view
        }

        func updateUIView(_ view: AnchorView, context: Context) {
            context.coordinator.cover = AnyView(cover())
            context.coordinator.isShown = isShown
            context.coordinator.update(scene: view.window?.windowScene)
        }

        static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
            coordinator.tearDown()
        }

        /// Reports the scene once the anchor is in a window.
        final class AnchorView: UIView {
            weak var coordinator: Coordinator?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                coordinator?.update(scene: window?.windowScene)
            }
        }

        @MainActor final class Coordinator {
            var cover = AnyView(EmptyView())
            var isShown = false
            private var window: UIWindow?
            private var host: UIHostingController<AnyView>?

            func update(scene: UIWindowScene?) {
                guard let scene else { return }
                if window == nil || window?.windowScene !== scene {
                    window?.isHidden = true
                    let host = UIHostingController(rootView: cover)
                    host.view.backgroundColor = .systemBackground
                    host.view.accessibilityViewIsModal = true
                    let window = UIWindow(windowScene: scene)
                    // Above alerts and sheets of the app's window.
                    window.windowLevel = .alert + 1
                    window.rootViewController = host
                    window.isHidden = true
                    self.window = window
                    self.host = host
                }
                host?.rootView = cover
                guard let window else { return }
                if isShown, window.isHidden {
                    window.makeKeyAndVisible()
                } else if !isShown, !window.isHidden {
                    window.isHidden = true
                    // Keyboard and menu commands go back to the app's window.
                    scene.windows.first { $0 !== window && !$0.isHidden }?.makeKey()
                }
            }

            func tearDown() {
                window?.isHidden = true
                window = nil
                host = nil
            }
        }
    }
#endif

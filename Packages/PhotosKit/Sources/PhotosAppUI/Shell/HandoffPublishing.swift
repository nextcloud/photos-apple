// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// What the screens of one window show, for Handoff (SPEC §22.2). A screen registers its content when it appears and takes
/// it back when it goes away; the one that appeared last wins — the photo in the viewer over the album under it, an album
/// over the Albums list. Screens that a navigation stack covers may stay registered (UIKit and AppKit differ in whether
/// they disappear); they are older, so they lose.
@MainActor
@Observable
final class HandoffRegistry {
    private struct Entry {
        var order: Int
        var content: HandoffContent
    }

    private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var counter = 0

    /// What the window advertises now.
    var current: HandoffContent? {
        entries.values.max { $0.order < $1.order }?.content
    }

    /// A screen appeared (or appeared again): its content is the newest.
    func register(_ id: UUID, _ content: HandoffContent) {
        counter += 1
        entries[id] = Entry(order: counter, content: content)
    }

    /// The content of a screen that stays on screen changed (the viewer paged, the Library scrolled): it keeps its place.
    func update(_ id: UUID, _ content: HandoffContent?) {
        guard let content else {
            entries[id] = nil
            return
        }
        if let entry = entries[id] {
            entries[id] = Entry(order: entry.order, content: content)
        } else {
            register(id, content)
        }
    }

    func remove(_ id: UUID) {
        entries[id] = nil
    }
}

extension EnvironmentValues {
    /// The window's Handoff registry (`MainView`); nil outside the main windows (album windows, Guest Mode, the TV).
    @Entry var handoffRegistry: HandoffRegistry?
}

extension View {
    /// Advertises `content` for Handoff while this view is on screen (nil: nothing from this view).
    func handoff(_ content: HandoffContent?) -> some View {
        modifier(HandoffSource(content: content))
    }

    /// Advertises `link` for Handoff while this view is on screen.
    func handoff(_ link: DeepLink?, title: String? = nil) -> some View {
        modifier(HandoffSource(content: link.map { HandoffContent($0, title: title) }))
    }

    /// The window's activity: what its registry holds, for the account shown, while nothing hides it (app lock, Guest
    /// Mode). SwiftUI makes it the current activity while the window is the active one.
    func handoffActivity(_ registry: HandoffRegistry, account: Account, isHidden: Bool) -> some View {
        let published: HandoffContent? = isHidden ? nil : registry.current
        return userActivity(HandoffActivity.type, element: published) { (content: HandoffContent, activity: NSUserActivity) in
            HandoffActivity.configure(activity, content: content, account: account)
        }
    }
}

private struct HandoffSource: ViewModifier {
    let content: HandoffContent?
    @Environment(\.handoffRegistry) private var registry
    @State private var id = UUID()

    func body(content view: Content) -> some View {
        view
            .onAppear { if let content { registry?.register(id, content) } }
            .onChange(of: content) { _, new in registry?.update(id, new) }
            .onDisappear { registry?.remove(id) }
    }
}

extension HandoffActivity {
    /// Fills the window's activity. Not for search or prediction: Spotlight has its own index of albums, people and
    /// places (`SpotlightIndexer`), and a photo the user looked at is not a suggestion for Siri.
    @MainActor static func configure(_ activity: NSUserActivity, content: HandoffContent, account: Account) {
        guard let info = userInfo(for: content, account: account) else {
            activity.invalidate()
            return
        }
        activity.title = content.title
        activity.userInfo = info
        activity.requiredUserInfoKeys = [linkKey, versionKey]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        #if !os(macOS)
            activity.isEligibleForPrediction = false
        #endif
        activity.isEligibleForPublicIndexing = false
        activity.webpageURL = webpageURL(for: content.link, serverURL: account.serverURL)
        #if !os(macOS)
            // On iPad and Vision Pro the window that shows links takes it (`handlesExternalEvents` of the main window).
            activity.targetContentIdentifier = info[linkKey] as? String
        #endif
        activity.needsSave = true
    }
}

/// Activities from another device: opened like links, or — for an account that is not logged in here — a question that
/// offers the same place on the server's web page (SPEC §22.2).
@MainActor
@Observable
public final class HandoffCenter {
    public static let shared = HandoffCenter()

    /// An activity of an account that is not logged in on this device, waiting for the user's answer.
    var otherAccount: OtherAccount?

    struct OtherAccount: Identifiable, Equatable {
        var name: String
        var webpage: URL?
        var id: String { name }
    }

    /// Handles an activity the system continued in this app (`onContinueUserActivity(HandoffActivity.type)`).
    public func `continue`(_ activity: NSUserActivity, app: AppModel) {
        // Guest Mode: nothing leads out of the album or memory shown (SPEC §16.8.3).
        guard !GuestMode.shared.isActive else { return }
        let arrival = HandoffArrival.resolve(
            link: HandoffActivity.link(in: activity.userInfo), webpage: activity.webpageURL, accounts: app.accounts,
            active: app.activeAccount?.id)
        switch arrival {
        case .open(let link):
            // Locks first when the app was away long enough: the link waits for the unlock (`MainView.openRequested`).
            AppLock.shared.refresh()
            app.open(link)
        case .otherAccount(let name, let webpage):
            otherAccount = OtherAccount(name: name, webpage: webpage)
        case .ignore:
            break
        }
    }
}

extension View {
    /// The question for an activity of another account (Open in Browser / Cancel). Not while the app is locked: it names
    /// an account.
    public func handoffPrompts(isLocked: Bool) -> some View {
        modifier(HandoffPrompts(isLocked: isLocked))
    }
}

private struct HandoffPrompts: ViewModifier {
    let isLocked: Bool
    @State private var center = HandoffCenter.shared
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        let shown: Binding<Bool> = Binding(
            get: { !isLocked && center.otherAccount != nil }, set: { if !$0 { center.otherAccount = nil } })
        content.alert(HandoffWording.otherAccountTitle, isPresented: shown, presenting: center.otherAccount) { prompt in
            if let webpage = prompt.webpage {
                Button(HandoffWording.openInBrowser) {
                    center.otherAccount = nil
                    openURL(webpage)
                }
            }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) { center.otherAccount = nil }
        } message: { prompt in
            Text(HandoffWording.otherAccountMessage(prompt.name, hasWebpage: prompt.webpage != nil))
        }
    }
}

enum HandoffWording {
    static var otherAccountTitle: String {
        String(
            localized: "Continue in Another Account?", bundle: .module,
            comment: "Title: Handoff from another device that shows an account which is not logged in on this device.")
    }

    static var openInBrowser: String {
        String(
            localized: "Open in Browser", bundle: .module,
            comment: "Button: open what the other device shows on the server's web page (Handoff of another account).")
    }

    static func otherAccountMessage(_ name: String, hasWebpage: Bool) -> String {
        hasWebpage
            ? String(
                localized:
                    "The other device shows photos of \(name), which is not logged in here. You can open the same place on the web, or add the account under Settings › Accounts.",
                bundle: .module, comment: "Handoff of an account that is not logged in on this device. Placeholder: user@server.")
            : String(
                localized:
                    "The other device shows photos of \(name), which is not logged in here. Add the account under Settings › Accounts to continue.",
                bundle: .module, comment: "Handoff of an account that is not logged in; no web page to offer. Placeholder: user@server.")
    }
}

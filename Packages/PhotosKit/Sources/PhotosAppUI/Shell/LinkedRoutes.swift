// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI

// Screens that a link opens by name (SPEC §4.8: `places/<name>`, `faces/<name>`, `tags/<name>`), and the questions a link
// for another account or a public album asks first.

/// The photos of a place, as the Places screen opens them.
struct PlaceRouteScreen: View {
    let name: String

    var body: some View {
        ItemsScreen(title: name) { services in
            try await services.api.placeContent(name).map(\.item)
        }
    }
}

/// A person's photos, as the People screen opens them; the screen loads them by name.
struct PersonRouteScreen: View {
    let name: String

    var body: some View {
        PersonScreen(person: Person(name: name))
    }
}

/// A tag's photos. The tag is looked up by name: what the device knows first, else the server.
struct TagRouteScreen: View {
    let name: String
    @Environment(SessionModel.self) private var session
    @State private var tag: SystemTag?
    @State private var missing = false

    var body: some View {
        Group {
            if let tag {
                TagScreen(tag: tag)
            } else if missing {
                ContentUnavailableView(
                    String(localized: "Tag not found", bundle: .module), systemImage: "tag.slash",
                    description: Text("It may have been renamed or deleted.", bundle: .module))
            } else {
                ProgressView()
            }
        }
        .task(id: name) {
            guard tag == nil, let services = session.services else { return }
            let local = (try? LabelStore(database: services.database).tags()) ?? []
            if let found = Self.tag(named: name, in: local) {
                tag = found
                return
            }
            tag = Self.tag(named: name, in: (try? await services.api.tagsInUse()) ?? [])
            missing = tag == nil
        }
    }

    /// The tag with this name; the exact name wins over one that differs in case.
    static func tag(named name: String, in tags: [SystemTag]) -> SystemTag? {
        tags.first { $0.name == name } ?? tags.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

extension View {
    /// Asks what to do with a link that cannot open at once (`AppModel.linkPrompt`). Nothing is asked while the app is
    /// locked: the question names accounts.
    func linkPrompts(isLocked: Bool) -> some View {
        modifier(LinkPromptModifier(isLocked: isLocked))
    }
}

struct LinkPromptModifier: ViewModifier {
    let isLocked: Bool
    @Environment(AppModel.self) private var app

    var prompt: LinkPrompt? { isLocked ? nil : app.linkPrompt }

    var switching: Binding<Bool> {
        Binding(
            get: { if case .switchAccount = prompt { true } else { false } },
            set: { shown in if !shown { app.linkPrompt = nil } })
    }

    var unknown: Binding<Bool> {
        Binding(
            get: { if case .unknownAccount = prompt { true } else { false } },
            set: { shown in if !shown { app.linkPrompt = nil } })
    }

    var publicLink: Binding<PublicLinkRequest?> {
        Binding(
            get: { if case .publicAlbum(let link) = prompt { PublicLinkRequest(link: link) } else { nil } },
            set: { link in if link == nil { app.linkPrompt = nil } })
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                LinkPromptWording.switchTitle, isPresented: switching, titleVisibility: .visible, presenting: prompt
            ) { prompt in
                if case .switchAccount(let accounts, let link) = prompt {
                    ForEach(accounts) { account in
                        Button(LinkPromptWording.switchButton(account, onlyOne: accounts.count == 1)) {
                            app.openLink(link, in: account.id)
                        }
                    }
                }
                Button(String(localized: "Cancel", bundle: .module), role: .cancel) { app.linkPrompt = nil }
            } message: { prompt in
                if case .switchAccount(let accounts, _) = prompt {
                    Text(LinkPromptWording.switchMessage(accounts))
                }
            }
            .alert(LinkPromptWording.unknownTitle, isPresented: unknown, presenting: prompt) { _ in
                Button(String(localized: "OK", bundle: .module), role: .cancel) { app.linkPrompt = nil }
            } message: { prompt in
                if case .unknownAccount(let name) = prompt {
                    Text(LinkPromptWording.unknownMessage(name))
                }
            }
            // The public album sheet shows the link and opens it with Open, after its own question for http://.
            .sheet(item: publicLink) { request in OpenPublicLinkSheet(link: request.link) }
    }
}

/// A public album link waiting in its sheet.
struct PublicLinkRequest: Identifiable {
    var id: String { link }
    var link: String
}

/// What the link questions say.
enum LinkPromptWording {
    static var switchTitle: String {
        String(
            localized: "Open the link in another account?", bundle: .module,
            comment: "Title of the question when a link opens a photo, album or person of another logged-in account.")
    }

    static func switchMessage(_ accounts: [Account]) -> String {
        if accounts.count == 1, let account = accounts.first {
            return String(
                localized:
                    "The link is for \(account.displayName) on \(account.hostDisplayName). The app switches to that account to open it.",
                bundle: .module, comment: "A link for another account. First: the account's name; second: the server.")
        }
        return String(
            localized: "The link is for an account on another server. Choose the account to open it with.", bundle: .module,
            comment: "A web link of a server with several accounts on this device.")
    }

    static func switchButton(_ account: Account, onlyOne: Bool) -> String {
        if onlyOne {
            return String(localized: "Switch Account", bundle: .module, comment: "Button: switch to the account a link is for and open it.")
        }
        // A name and a server: nothing to translate.
        return "\(account.displayName) – \(account.hostDisplayName)"
    }

    static var unknownTitle: String {
        String(
            localized: "This link is for another account", bundle: .module,
            comment: "Title: a link names an account that is not logged in on this device.")
    }

    static func unknownMessage(_ name: String) -> String {
        String(
            localized:
                "\(name) is not logged in on this device. To open the link, add the account under Settings › Accounts, then open the link again.",
            bundle: .module, comment: "A link names an account that is not logged in. The placeholder is user@server or the server.")
    }
}

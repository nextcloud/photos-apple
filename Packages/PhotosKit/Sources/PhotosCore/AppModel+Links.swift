// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosDomain
import PhotosModel

/// A link from outside that waits for the user's answer (SPEC §4.8).
public enum LinkPrompt: Equatable, Identifiable, Sendable {
    /// The link belongs to another logged-in account (one, or several when a web link names a server with more than one
    /// account): the app switches only when the user says so.
    case switchAccount([Account], DeepLink)
    /// No account on this device matches; `name` is the user and server, or the server, the link asks for.
    case unknownAccount(name: String)
    /// A public album link: it opens without an account, after the user saw where it leads.
    case publicAlbum(link: String)

    public var id: String {
        switch self {
        case .switchAccount(let accounts, let link): "switch:\(accounts.map(\.id.rawValue))|\(link.request)"
        case .unknownAccount(let name): "unknown:\(name)"
        case .publicAlbum(let link): "public:\(link)"
        }
    }
}

extension AppModel {
    /// Handles a link from outside: `nextcloudphotos://…` (widgets, notifications, other apps, Spotlight) or a web link of
    /// an account's server. Returns false when the link is not one of the app's.
    ///
    /// A link for the account shown opens at once (after the unlock when the app is locked, `MainView`); one for another
    /// account, for an account that is not logged in, or a public album waits in `linkPrompt` for the user.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        guard let incoming = IncomingLink.resolve(url, accounts: accounts, active: activeAccount?.id) else { return false }
        switch incoming {
        case .open(let link):
            linkPrompt = nil
            requestedDestination = link.request
        case .switchAccount(let ids, let link):
            let candidates = ids.compactMap { id in accounts.first { $0.id == id } }
            linkPrompt = candidates.isEmpty ? nil : .switchAccount(candidates, link)
        case .unknownAccount(let name):
            linkPrompt = .unknownAccount(name: name)
        case .publicAlbum:
            linkPrompt = .publicAlbum(link: url.absoluteString)
        }
        return true
    }

    /// The user agreed to open a link in another account: switches to it and opens the link there.
    public func openLink(_ link: DeepLink, in account: AccountID) {
        linkPrompt = nil
        guard accounts.contains(where: { $0.id == account }) else { return }
        switchTo(account)
        requestedDestination = link.request
    }

    /// Opens the search with this text (the "Search photos" intent).
    public func requestSearch(_ text: String) {
        requestedDestination = DeepLink.search(text).request
    }
}

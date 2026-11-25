// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosDomain
import PhotosModel
import PhotosNetworking

/// A postcard that was sent: where its two sides are in the user's files and the public link to them.
public struct SentPostcard: Hashable, Sendable {
    /// The folder with the two sides (`/Postcards/2026-11-25 Lisbon`).
    public var folder: String
    /// The public link of the folder; nil when the server allows no public links (the card is still shared as images).
    public var link: URL?
}

/// Sending a photo as a postcard (SPEC §16.7.1). The two rendered sides go into a folder of their own below `/Postcards`
/// (which holds a `.nomedia` file, so the cards don't show up in the timeline), and that folder gets an ordinary public
/// link: the recipient sees Nextcloud's own public page with the front and the back. The message is the link's note as
/// well, so it can be read as text there. Nothing on the server is new.
extension SessionModel {
    public func sendPostcard(front: Data, back: Data, content: PostcardContent) async throws -> SentPostcard {
        guard let services else { throw NetworkError.unauthorized }
        return try await PostcardSender.send(front: front, back: back, content: content, services: services)
    }
}

enum PostcardSender {
    static func send(front: Data, back: Data, content: PostcardContent, services: AccountServices, now: Date = Date()) async throws
        -> SentPostcard
    {
        let dav = services.dav
        let connection = services.connection
        try await dav.mkcolRecursive(userPath: PostcardFiles.rootFolder)
        let marker = PostcardFiles.rootFolder + "/.nomedia"
        if (try? await dav.head(connection.filesURL(marker))) == nil {
            _ = try await dav.put(connection.filesURL(marker), data: Data())
        }
        var folder = ""
        for attempt in 1...50 {
            let candidate = PostcardFiles.rootFolder + "/" + PostcardFiles.folderName(date: now, place: content.place, attempt: attempt)
            do {
                try await dav.mkcol(connection.filesURL(candidate))
                folder = candidate
                break
            } catch NetworkError.conflict {
                continue  // taken: the next number
            }
        }
        guard !folder.isEmpty else { throw NetworkError.conflict }
        do {
            _ = try await dav.put(connection.filesURL(folder + "/" + PostcardFiles.frontFileName), data: front)
            _ = try await dav.put(connection.filesURL(folder + "/" + PostcardFiles.backFileName), data: back)
        } catch {
            // No half card is left behind.
            try? await dav.delete(connection.filesURL(folder))
            throw error
        }
        var link: URL?
        do {
            let message = PostcardContent.printedMessage(content.message)
            let share = try await services.api.sharing.createShare(
                path: folder, kind: .link, permissions: .viewOnly, label: PostcardFiles.linkLabel(recipient: content.recipient),
                note: message.isEmpty ? nil : message)
            link = share.url
        } catch {
            // No public links on this server (or for this user): the card goes out as pictures only.
            Logger(subsystem: "com.nextcloud.photos", category: "postcard").info(
                "no link for postcard: \(error.localizedDescription, privacy: .public)")
        }
        return SentPostcard(folder: folder, link: link)
    }
}

extension PostcardFiles {
    /// The label of the public link, as the Sharing tab of the web app shows it: "Postcard to Grandma".
    static func linkLabel(recipient: String) -> String {
        let name = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? String(localized: "Postcard", bundle: .module, comment: "Label of the public link of a sent postcard.")
            : String(
                localized: "Postcard to \(name)", bundle: .module,
                comment: "Label of the public link of a sent postcard; the argument is the name the card is addressed to.")
    }
}

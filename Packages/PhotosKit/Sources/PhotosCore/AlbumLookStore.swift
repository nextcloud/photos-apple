// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosDomain
import PhotosModel
import PhotosNetworking

/// Where the album cover choices are kept on the server: a small JSON file in the user's own files.
public struct AlbumLookRemote: Sendable {
    /// The file and its ETag; nil when there is none yet.
    public var fetch: @Sendable () async throws -> (data: Data, etag: String?)?
    /// Writes the file, only over the version with `ifMatch` when given (`NetworkError.preconditionFailed` otherwise);
    /// returns the new ETag when the server tells it.
    public var store: @Sendable (_ data: Data, _ ifMatch: String?) async throws -> String?

    public init(
        fetch: @escaping @Sendable () async throws -> (data: Data, etag: String?)?,
        store: @escaping @Sendable (_ data: Data, _ ifMatch: String?) async throws -> String?
    ) {
        self.fetch = fetch
        self.store = store
    }

    /// `/.nextcloud-photos/album-covers.json` in the user's files, over WebDAV. The folder is made when it is missing.
    public static func dav(_ dav: DAVClient) -> AlbumLookRemote {
        let url = dav.connection.filesURL(AlbumLookBook.userPath)
        return AlbumLookRemote(
            fetch: {
                do {
                    let response = try await dav.get(url)
                    return (response.data, Self.etag(response))
                } catch NetworkError.notFound {
                    return nil
                }
            },
            store: { data, ifMatch in
                var headers = ["Content-Type": "application/json"]
                // "*": only when a file exists; no header and no file: only when there is none (two devices writing the
                // first version at once must not overwrite each other).
                headers[ifMatch == nil ? "If-None-Match" : "If-Match"] = ifMatch.map { "\"\($0)\"" } ?? "*"
                do {
                    return Self.etag(try await dav.put(url, data: data, headers: headers))
                } catch NetworkError.conflict {
                    // 409: the folder is missing.
                    try await dav.mkcolRecursive(userPath: "/\(AlbumLookBook.folder)")
                    return Self.etag(try await dav.put(url, data: data, headers: headers))
                }
            })
    }

    static func etag(_ response: HTTPResponse) -> String? {
        (response.headers["oc-etag"] ?? response.headers["etag"]).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }
}

/// The album cover choices of one account (SPEC §16.8.2): read from a copy on the device at once, kept in step with
/// `.nextcloud-photos/album-covers.json` in the user's Nextcloud so the user's other devices show the same covers.
@MainActor
@Observable
public final class AlbumLookStore {
    public private(set) var book: AlbumLookBook
    @ObservationIgnored let localFile: URL
    @ObservationIgnored let remote: AlbumLookRemote
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.nextcloud.photos", category: "album-looks")
    /// How long a fetched copy is fresh.
    static let refreshInterval: TimeInterval = 300

    public init(localFile: URL, remote: AlbumLookRemote) {
        self.localFile = localFile
        self.remote = remote
        book = (try? Data(contentsOf: localFile)).flatMap { try? AlbumLookBook.decode($0) } ?? AlbumLookBook()
    }

    // MARK: One store per account

    private static var stores: [AccountID: AlbumLookStore] = [:]

    /// The store of the account of `services`, made on first use.
    public static func store(for services: AccountServices) -> AlbumLookStore {
        if let store = stores[services.account.id] { return store }
        let store = AlbumLookStore(
            localFile: services.layout.accountDirectory(services.account.id).appending(path: "album-covers.json"),
            remote: .dav(services.dav))
        stores[services.account.id] = store
        return store
    }

    /// Forgets the store of a removed account (its folder goes with the account).
    public static func forget(_ account: AccountID) { stores[account] = nil }

    // MARK: Reading

    public func look(for album: Album) -> AlbumLook? { book.look(for: album.id) }

    /// The cover to show: the one chosen here, else the album's own.
    public func coverFileId(for album: Album) -> FileID? {
        look(for: album)?.coverFileId ?? album.displayCoverFileId
    }

    public func effect(for album: Album) -> AlbumCoverEffect { look(for: album)?.effect ?? .automatic }

    // MARK: Changing

    /// Chooses the cover and effect of an album; `cover` nil keeps the album's own cover. Saved on the device at once and
    /// then in the user's Nextcloud.
    public func set(cover: FileID?, effect: AlbumCoverEffect, for album: Album, now: Date = Date()) async {
        book.set(AlbumLook(coverFileId: cover, effect: effect, updatedAt: now), for: album.id)
        saveLocally()
        await push()
    }

    /// An album was renamed: its choice follows it.
    public func renamed(_ album: Album, to newName: String) async {
        var renamed = album
        renamed.name = newName
        guard book.albums[album.id] != nil else { return }
        book.rename(from: album.id, to: renamed.id)
        saveLocally()
        await push()
    }

    // MARK: Server

    /// Takes in what the other devices chose; at most every few minutes unless forced.
    public func refresh(force: Bool = false, now: Date = Date()) async {
        if !force, let fetchedAt, now.timeIntervalSince(fetchedAt) < Self.refreshInterval { return }
        if let refreshing { return await refreshing.value }
        let task = Task { await self.pull(now: now) }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func pull(now: Date) async {
        do {
            guard let (data, etag) = try await remote.fetch() else {
                fetchedAt = now
                // No file yet: what was chosen here before (offline, or on a server without the file) goes up.
                if !book.albums.isEmpty { await push() }
                return
            }
            fetchedAt = now
            self.etag = etag
            let theirs = (try? AlbumLookBook.decode(data)) ?? AlbumLookBook()
            let merged = book.merged(with: theirs)
            let changedHere = merged != theirs
            if merged != book {
                book = merged
                saveLocally()
            }
            if changedHere { await push() }
        } catch {
            logger.error("could not read album covers: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the book over the version last read; when another device wrote in between, reads theirs, merges and tries
    /// again (twice at most).
    private func push() async {
        for _ in 0..<3 {
            do {
                let data = try book.encoded()
                etag = try await remote.store(data, etag)
                return
            } catch NetworkError.preconditionFailed {
                do {
                    if let (data, etag) = try await remote.fetch() {
                        self.etag = etag
                        book = book.merged(with: (try? AlbumLookBook.decode(data)) ?? AlbumLookBook())
                    } else {
                        etag = nil
                    }
                    saveLocally()
                } catch {
                    return
                }
            } catch {
                // Offline or refused: the choice is kept here and goes up with the next refresh.
                fetchedAt = nil
                logger.error("could not save album covers: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    private func saveLocally() {
        do {
            try FileManager.default.createDirectory(at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try book.encoded().write(to: localFile, options: .atomic)
        } catch {
            logger.error("could not store album covers: \(error.localizedDescription, privacy: .public)")
        }
    }
}

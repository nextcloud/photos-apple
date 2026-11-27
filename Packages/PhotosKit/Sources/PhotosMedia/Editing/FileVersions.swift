// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel
import PhotosNetworking

/// Nextcloud's file versions (`files_versions`, WebDAV `/remote.php/dav/versions/<user>/versions/<fileId>`), as far as
/// "Apply edits to the file" needs them (SPEC §21.6.6): the original is kept as a **named** version before the edited
/// picture replaces it — Nextcloud never expires a named version, neither by age nor when the user's space runs low — and
/// "Restore Original" restores that version.
///
/// Since Nextcloud 26 the listing also has the current version (its id is the file's modification time), and a name given
/// to it stays when a new upload turns it into an older version: the original is named before it is replaced.
public struct FileVersions: Sendable {
    /// The name the app gives the original. Found again by this name (on every device, whatever its language).
    public static let originalLabel = "Original (Nextcloud Photos)"
    static let label = QName(XMLNamespace.nc, "version-label")

    public struct Version: Sendable, Equatable {
        /// The version's id (a Unix time) as the server names it.
        public var id: String
        public var label: String?
        public var size: Int64?
        public var lastModified: Date?
    }

    public enum Failure: LocalizedError, Equatable {
        /// The server keeps no versions (the Versions app is disabled) or cannot name them: the original could not be
        /// kept, so the file is not replaced.
        case unavailable
        /// No version of the file has the original's name.
        case noOriginal
    }

    let dav: DAVClient

    public init(dav: DAVClient) {
        self.dav = dav
    }

    func collection(_ fileId: FileID) -> URL {
        dav.connection.davURL("versions/\(dav.connection.userId)/versions/\(fileId)")
    }

    func versionURL(_ fileId: FileID, _ id: String) -> URL {
        collection(fileId).appending(path: id)
    }

    /// Every version of the file, the current one included, newest first.
    public func versions(of fileId: FileID) async throws -> [Version] {
        let resources = try await dav.propfind(
            collection(fileId), depth: 1, properties: [DAVProp.etag, DAVProp.contentLength, DAVProp.lastModified, Self.label])
        let base = collection(fileId).path(percentEncoded: false)
        return
            resources
            .filter { !$0.href.hasSuffix("/") && $0.href.trimmingCharacters(in: ["/"]) != base.trimmingCharacters(in: ["/"]) }
            .map { resource in
                let label = resource.string(Self.label)
                return Version(
                    id: (resource.href as NSString).lastPathComponent, label: (label?.isEmpty ?? true) ? nil : label,
                    size: resource.int64(DAVProp.contentLength), lastModified: resource.string(DAVProp.lastModified).flatMap(Self.httpDate))
            }
            .sorted { (Int($0.id) ?? 0) > (Int($1.id) ?? 0) }
    }

    /// A version label the app gave: `originalLabel`, or `originalLabel: <the user's own label>`.
    public static func isOriginal(_ label: String?) -> Bool {
        label == originalLabel || label?.hasPrefix(originalLabel + ": ") == true
    }

    /// The version the app named as the original, if any.
    public func original(of fileId: FileID) async throws -> Version? {
        try await versions(of: fileId).first { Self.isOriginal($0.label) }
    }

    /// Makes sure the original is kept for good before the file is replaced: the current version is named
    /// `originalLabel`, unless a version has that name already (the photo was edited into its file before: the first
    /// original is the one to keep). A name the user gave the current version stays in it
    /// (`Original (Nextcloud Photos): <their name>`). Throws `unavailable` when the server lists no version or refuses the
    /// name: then nothing may be overwritten.
    @discardableResult
    public func keepOriginal(of fileId: FileID) async throws -> Version {
        let all: [Version]
        do {
            all = try await versions(of: fileId)
        } catch NetworkError.notFound {
            throw Failure.unavailable
        } catch NetworkError.http(let status, _) where status == 405 || status == 501 {
            throw Failure.unavailable
        }
        if let original = all.first(where: { Self.isOriginal($0.label) }) { return original }
        guard let current = all.first else { throw Failure.unavailable }
        let label = current.label.map { "\(Self.originalLabel): \($0)" } ?? Self.originalLabel
        do {
            try await dav.proppatch(versionURL(fileId, current.id), set: [(Self.label, .text(label))])
        } catch {
            throw Failure.unavailable
        }
        // Read back: only a name the server keeps protects the original.
        guard let named = try await versions(of: fileId).first(where: { $0.id == current.id }), named.label == label else {
            throw Failure.unavailable
        }
        return named
    }

    /// The bytes of a version.
    public func download(_ fileId: FileID, version id: String) async throws -> Data {
        try await dav.get(versionURL(fileId, id)).data
    }

    /// Puts the original back as the file's content (the edited picture becomes an older version, nothing is lost).
    public func restoreOriginal(of fileId: FileID) async throws {
        guard let original = try await original(of: fileId) else { throw Failure.noOriginal }
        let target = dav.connection.davURL("versions/\(dav.connection.userId)/restore/target")
        // Nextcloud answers 412 to a restore without `Overwrite: T` (the target is a fixed name).
        try await dav.move(versionURL(fileId, original.id), to: target, overwrite: true)
    }

    static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}

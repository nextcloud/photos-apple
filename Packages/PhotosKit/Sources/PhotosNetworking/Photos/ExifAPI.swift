// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// The EXIF of many photos at once, for Insights (SPEC §16.5.1). Stock servers have it: `nc:metadata-photos-exif` and
/// `-ifd0` are filled by the server's own metadata extraction (Nextcloud 28+), and WebDAV SEARCH returns them like any
/// property.
extension PhotosAPI {
    /// The EXIF tags of one file as read from a search result, and the ETag they belong to.
    public struct ExifRecord: Sendable, Hashable {
        public var fileId: FileID
        public var etag: String
        /// The capture time (`nc:metadata-photos-original_date_time`), the cursor of `exifPage`.
        public var capturedAt: Double?
        public var tags: [String: String]
    }

    static let exifProperties: [QName] = [
        DAVProp.fileId, DAVProp.etag, DAVProp.metadataOriginalDateTime, DAVProp.metadataExif, DAVProp.metadataIFD0,
    ]

    /// The tags of a search or PROPFIND result: IFD0 (camera) and the EXIF IFD (exposure), the latter winning where
    /// both have a tag. A tag the server wrote as a list (`ISOSpeedRatings` of some cameras) gives its first value.
    public static func exifRecord(from resource: DAVResource) -> ExifRecord? {
        guard !resource.isCollection, let fileId = resource.int64(DAVProp.fileId) else { return nil }
        var tags: [String: String] = [:]
        for name in [DAVProp.metadataIFD0, DAVProp.metadataExif] {
            for child in resource.node(name)?.children ?? [] {
                let value = child.value.isEmpty ? (child.children.first?.value ?? "") : child.value
                if !value.isEmpty { tags[child.name.name] = value }
            }
        }
        let etag = (resource.string(DAVProp.etag) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return ExifRecord(fileId: fileId, etag: etag, capturedAt: resource.double(DAVProp.metadataOriginalDateTime), tags: tags)
    }

    /// The EXIF of these files (50 per request, as `items(fileIds:)`).
    public func exifRecords(fileIds: [FileID]) async throws -> [ExifRecord] {
        guard !fileIds.isEmpty else { return [] }
        var result: [ExifRecord] = []
        for start in stride(from: 0, to: fileIds.count, by: 50) {
            let chunk = Array(fileIds[start..<min(start + 50, fileIds.count)])
            let search = DAVSearch(
                select: Self.exifProperties,
                scopes: [DAVSearch.Scope(href: connection.filesHref("/"))],
                condition: .or(chunk.map { .eq(DAVProp.fileId, String($0)) })
            )
            result += try await dav.search(search).compactMap(Self.exifRecord(from:))
        }
        return result
    }

    /// One page of the photos of the timeline folders with their EXIF, newest first, taken at `before` or earlier
    /// (unix seconds; nil: from the newest). For a large library whose camera data is read for the first time: a few
    /// hundred photos per request instead of 50. The caller skips what it saw already (the page boundary is
    /// inclusive, so photos sharing a second are not lost) and stops at an empty page.
    public func exifPage(sourceFolders: [String], mimeTypes: [String], before: Double?, limit: Int = 500) async throws
        -> [ExifRecord]
    {
        var conditions: [DAVSearch.Condition] = [Self.mimeCondition(mimeTypes)]
        if let before { conditions.append(.lte(DAVProp.metadataOriginalDateTime, Self.number(before))) }
        let search = DAVSearch(
            select: Self.exifProperties,
            scopes: sourceFolders.map { DAVSearch.Scope(href: connection.filesHref($0)) },
            condition: .and(conditions),
            orderBy: [DAVSearch.Order(DAVProp.metadataOriginalDateTime)],
            limit: limit
        )
        return try await dav.search(search, timeout: 300).compactMap(Self.exifRecord(from:))
    }
}

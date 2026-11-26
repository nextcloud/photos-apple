// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Photos the server has no preview for, and when to ask again (SPEC §20.1).
///
/// A file without a preview (a broken or truncated JPEG, a format no preview provider reads) answers 404, and the original
/// cannot be thumbnailed on the device either (`DevicePreview`). Without this log every tile that shows it, every scroll
/// past it and every viewer page asked the server again. A failed file is asked for again only after the library synced
/// since and its backoff passed (2 min, 10 min, 1 h, 6 h, then once a day); a new version (another ETag) is asked for at
/// once, and one that waited for the end of Low Data Mode as soon as it ended. Network errors are not failures in this
/// sense: they are retried as before.
public struct PreviewFailureLog: Sendable, Equatable {
    struct Key: Hashable, Sendable {
        var fileId: FileID
        var etag: String
    }

    struct Entry: Equatable, Sendable {
        var attempts: Int
        var retryAfter: Date
        /// `syncs` when it failed: it is asked for again only after a later sync.
        var syncs: Int
        var reason: NoPreviewReason
    }

    private var entries: [Key: Entry] = [:]
    /// Library syncs seen.
    private var syncs = 0

    /// Entries kept at most; the oldest retry dates go first (a library full of broken files must not grow it forever).
    static let capacity = 5000

    public init() {}

    /// How long after the `attempts`-th failure the file is not asked for.
    public static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        let steps: [TimeInterval] = [2 * 60, 10 * 60, 60 * 60, 6 * 60 * 60, 24 * 60 * 60]
        return steps[min(max(attempts, 1), steps.count) - 1]
    }

    /// The server had no preview of this version of the file, and none could be made on the device.
    public mutating func recordFailure(fileId: FileID, etag: String, reason: NoPreviewReason = .unreadable, at now: Date = Date()) {
        let key = Key(fileId: fileId, etag: etag)
        let attempts = (entries[key]?.attempts ?? 0) + 1
        entries[key] = Entry(
            attempts: attempts, retryAfter: now.addingTimeInterval(Self.backoff(afterAttempts: attempts)), syncs: syncs, reason: reason)
        if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.retryAfter < $1.value.retryAfter })?.key {
            entries[oldest] = nil
        }
    }

    /// A preview was had after all.
    public mutating func recordSuccess(fileId: FileID, etag: String) {
        entries[Key(fileId: fileId, etag: etag)] = nil
    }

    /// The library synced: failed files whose backoff has passed may be asked for again.
    public mutating func librarySynced() {
        syncs += 1
    }

    /// Whether the server may be asked for a preview of this version of the file now. A file that waited for the end of
    /// Low Data Mode is asked for as soon as it ended.
    public func allowsRequest(fileId: FileID, etag: String, isConstrained: Bool = false, at now: Date = Date()) -> Bool {
        guard let entry = entries[Key(fileId: fileId, etag: etag)] else { return true }
        if entry.reason == .lowDataMode && !isConstrained { return true }
        return syncs > entry.syncs && now >= entry.retryAfter
    }

    /// The file is known to have no preview (the tile and the viewer say so instead of showing a grey square).
    public func hasNoPreview(fileId: FileID, etag: String) -> Bool {
        entries[Key(fileId: fileId, etag: etag)] != nil
    }

    /// Why the file has no preview; nil when it is not known to have none.
    public func reason(fileId: FileID, etag: String) -> NoPreviewReason? {
        entries[Key(fileId: fileId, etag: etag)]?.reason
    }

    var count: Int { entries.count }
}

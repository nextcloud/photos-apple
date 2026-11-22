// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// A device resource that may be uploaded.
public struct LocalResource: Hashable, Sendable {
    public var localIdentifier: String
    public var kind: MediaKind
    /// Capture time (PhotoKit creation date).
    public var createdAt: Date
    public var originalName: String
    /// Size of the data that would be uploaded, when known.
    public var byteSize: Int64?
    /// Pixel size with orientation applied.
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(
        localIdentifier: String, kind: MediaKind, createdAt: Date, originalName: String, byteSize: Int64? = nil, pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.kind = kind
        self.createdAt = createdAt
        self.originalName = originalName
        self.byteSize = byteSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// A media file on the server found by the reconciliation SEARCH.
public struct RemoteCandidate: Hashable, Sendable {
    public var fileId: FileID
    public var path: String
    public var kind: MediaKind
    public var size: Int64
    public var capturedAt: Date?
    public var modifiedAt: Date
    public var width: Int?
    public var height: Int?

    public init(
        fileId: FileID, path: String, kind: MediaKind, size: Int64, capturedAt: Date?, modifiedAt: Date, width: Int? = nil,
        height: Int? = nil
    ) {
        self.fileId = fileId
        self.path = path
        self.kind = kind
        self.size = size
        self.capturedAt = capturedAt
        self.modifiedAt = modifiedAt
        self.width = width
        self.height = height
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Why a resource was considered already on the server (SPEC §7.18.3 `matchedBy`).
public enum MatchReason: String, Codable, Sendable {
    case ownUpload, filesLedger, serverHash, serverTimeSize, serverTimeName, serverDestination, user
}

/// Server reconciliation by time (SPEC §7.18.4, layer 4). Pure, so the rules are unit-tested.
public enum BackupMatcher {
    /// Seconds of tolerance when comparing capture times.
    static let tolerance: TimeInterval = 1.5

    /// Returns the matching server file and the reason, or nil when the resource must be uploaded.
    ///
    /// Rules, in order:
    /// 1. same kind, capture second equal (capture time or mtime), same byte size → exact copy.
    /// 2. same kind, capture second equal, the original's number (`IMG_1234` → `1234`) appears in the server name → Files-app naming.
    /// 3. same kind, capture second equal, same pixel size, and it is the only candidate on both sides → converted copy (not bursts).
    /// 4. capture times differ by whole hours (≤ 14 h), minutes and seconds equal, and the number matches → EXIF read without offset.
    public static func match(_ resource: LocalResource, candidates: [RemoteCandidate], localSiblings: [LocalResource]) -> (
        RemoteCandidate, MatchReason
    )? {
        let sameKind = candidates.filter { $0.kind == resource.kind }
        let atSameSecond = sameKind.filter { sameSecond($0, resource.createdAt) }
        let number = BackupNaming.number(in: resource.originalName)

        if let size = resource.byteSize, let exact = atSameSecond.first(where: { $0.size == size }) {
            return (exact, .serverTimeSize)
        }
        if let number, let named = atSameSecond.first(where: { containsNumber($0.name, number) }) {
            return (named, .serverTimeName)
        }
        if let width = resource.pixelWidth, let height = resource.pixelHeight {
            let sameSize = atSameSecond.filter { candidate in
                guard let w = candidate.width, let h = candidate.height else { return false }
                return (w == width && h == height) || (w == height && h == width)
            }
            let localAtSameSecond = localSiblings.filter {
                $0.kind == resource.kind && abs($0.createdAt.timeIntervalSince(resource.createdAt)) < tolerance
            }
            if sameSize.count == 1, atSameSecond.count == 1, localAtSameSecond.count <= 1 {
                return (sameSize[0], .serverTimeSize)
            }
        }
        if let number {
            for candidate in sameKind {
                guard let captured = candidate.capturedAt, containsNumber(candidate.name, number) else { continue }
                let difference = captured.timeIntervalSince(resource.createdAt)
                let hours = (difference / 3600).rounded()
                if hours != 0, abs(hours) <= 14, abs(difference - hours * 3600) < tolerance {
                    return (candidate, .serverTimeName)
                }
            }
        }
        return nil
    }

    static func sameSecond(_ candidate: RemoteCandidate, _ date: Date) -> Bool {
        if let captured = candidate.capturedAt, abs(captured.timeIntervalSince(date)) < tolerance { return true }
        return abs(candidate.modifiedAt.timeIntervalSince(date)) < tolerance
    }

    /// The number must appear as a whole digit run (so `123` does not match `1234`).
    static func containsNumber(_ name: String, _ number: String) -> Bool {
        let base = (name as NSString).deletingPathExtension
        var start = base.startIndex
        while let range = base.range(of: number, range: start..<base.endIndex) {
            let before = range.lowerBound == base.startIndex ? nil : base[base.index(before: range.lowerBound)]
            let after = range.upperBound == base.endIndex ? nil : base[range.upperBound]
            if !(before?.isNumber ?? false) && !(after?.isNumber ?? false) { return true }
            start = range.upperBound
        }
        return false
    }
}

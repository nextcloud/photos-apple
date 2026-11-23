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
    /// Which rendition of the asset this is; an edit or a RAW is never "the same file" as the plain original.
    public var rendition: Rendition

    /// The rendition of an asset a resource holds.
    public enum Rendition: String, Hashable, Sendable {
        /// The unedited photo or video (including the motion part of a Live Photo).
        case original
        /// The edited version (`IMG_E1234`).
        case edited
        /// The RAW file next to a JPEG/HEIC.
        case raw
    }

    public init(
        localIdentifier: String, kind: MediaKind, createdAt: Date, originalName: String, byteSize: Int64? = nil, pixelWidth: Int? = nil,
        pixelHeight: Int? = nil, rendition: Rendition = .original
    ) {
        self.rendition = rendition
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
    /// A candidate is only considered when it can be the same rendition (see `isCompatible`): an edit is not matched by the
    /// original's file, a RAW not by a JPEG/HEIC, and the other way round.
    ///
    /// Rules, in order:
    /// 1. same kind, capture second equal (capture time or mtime), same byte size → exact copy (whatever the name says,
    ///    except across RAW / non-RAW).
    /// 2. same kind, capture second equal, and the names agree (`namesAgree`): the same name, or every number of the
    ///    original's name (`IMG_1234` → `1234`) appears in the server name → Files-app naming. Not when another device
    ///    resource of that second has the same numbers (`isAmbiguousName`): the name cannot tell those apart.
    /// 3. same kind, capture second equal, same pixel size, and it is the only candidate on both sides → converted copy (not bursts).
    /// 4. capture times differ by whole hours (≤ 14 h), minutes and seconds equal, and the names agree → EXIF read without offset.
    public static func match(_ resource: LocalResource, candidates: [RemoteCandidate], localSiblings: [LocalResource]) -> (
        RemoteCandidate, MatchReason
    )? {
        let localIsRaw = isRaw(resource)
        let sameKind = candidates.filter { $0.kind == resource.kind && isRawName($0.name) == localIsRaw }
        // Names only say something when no other device resource of that second would fit the same server file.
        let byName = !isAmbiguousName(resource, among: localSiblings)

        if let size = resource.byteSize, size > 0,
            let exact = sameKind.first(where: { $0.size == size && sameSecond($0, resource.createdAt) })
        {
            return (exact, .serverTimeSize)
        }
        let compatible = sameKind.filter { isCompatible(resource, candidateName: $0.name) }
        let atSameSecond = compatible.filter { sameSecond($0, resource.createdAt) }
        if byName, let named = atSameSecond.first(where: { namesAgree(local: resource.originalName, server: $0.name) }) {
            return (named, .serverTimeName)
        }
        if let width = resource.pixelWidth, let height = resource.pixelHeight {
            let sameSize = atSameSecond.filter { candidate in
                guard let w = candidate.width, let h = candidate.height else { return false }
                return (w == width && h == height) || (w == height && h == width)
            }
            // The other renditions of the same asset share its second; they are not burst siblings.
            let localAtSameSecond = localSiblings.filter {
                $0.kind == resource.kind && $0.rendition == resource.rendition && isRaw($0) == localIsRaw
                    && abs($0.createdAt.timeIntervalSince(resource.createdAt)) < tolerance
            }
            if sameSize.count == 1, atSameSecond.count == 1, localAtSameSecond.count <= 1 {
                return (sameSize[0], .serverTimeSize)
            }
        }
        if byName {
            for candidate in compatible {
                guard let captured = candidate.capturedAt, namesAgree(local: resource.originalName, server: candidate.name) else {
                    continue
                }
                let difference = captured.timeIntervalSince(resource.createdAt)
                let hours = (difference / 3600).rounded()
                if hours != 0, abs(hours) <= 14, abs(difference - hours * 3600) < tolerance {
                    return (candidate, .serverTimeName)
                }
            }
        }
        return nil
    }

    // MARK: Renditions

    /// File extensions of camera RAW formats (lowercase).
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "raw", "rwl", "pef", "srw", "x3f", "3fr",
        "erf", "kdc", "dcr", "mos", "mrw", "iiq", "gpr",
    ]

    static func isRawName(_ name: String) -> Bool {
        rawExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A ProRAW photo is the asset's original and a RAW file at the same time, so the name counts too.
    static func isRaw(_ resource: LocalResource) -> Bool {
        resource.rendition == .raw || isRawName(resource.originalName)
    }

    /// Whether a server file name says "edited version": Apple's `IMG_E1234`, or the ` (edited)` suffix this app uses otherwise
    /// (`BackupNaming.editedSuffix`), with any " (2)" conflict counter behind it.
    static func isEditedName(_ name: String) -> Bool {
        let base = (name as NSString).deletingPathExtension
        if base.range(of: BackupNaming.editedSuffix, options: .caseInsensitive) != nil { return true }
        return base.range(of: #"(^|[^A-Za-z])[A-Za-z]{3}_E\d+"#, options: .regularExpression) != nil
    }

    /// Whether a server file with this name can hold the same rendition as the device resource (rules 2–4).
    ///
    /// - edited: only names that say "edited";
    /// - original and RAW: only names that do not.
    ///
    /// RAW against non-RAW is excluded for every rule before this is asked.
    static func isCompatible(_ resource: LocalResource, candidateName: String) -> Bool {
        isEditedName(candidateName) == (resource.rendition == .edited)
    }

    static func sameSecond(_ candidate: RemoteCandidate, _ date: Date) -> Bool {
        if let captured = candidate.capturedAt, abs(captured.timeIntervalSince(date)) < tolerance { return true }
        return abs(candidate.modifiedAt.timeIntervalSince(date)) < tolerance
    }

    // MARK: Names

    /// The digit runs of a file name without its extension: `PXL_20240501_123045123.jpg` → `20240501`, `123045123`.
    static func numbers(in name: String) -> [String] {
        (name as NSString).deletingPathExtension.matches(of: /\d+/).map { String($0.output) }
    }

    /// The name without extension, case and the marker of an edited version, for "is this the same name".
    static func stem(_ name: String) -> String {
        var base = (name as NSString).deletingPathExtension
        if let range = base.range(of: BackupNaming.editedSuffix, options: .caseInsensitive) { base.removeSubrange(range) }
        return base.lowercased()
    }

    /// Whether a server file's name can stand for the device resource: the same name, or a name that has every number
    /// of the original name as a whole digit run. The Files app's scheme (`24-05-01 12-30-45 1234.jpg` for `IMG_1234`)
    /// keeps the number; a name with several numbers (`PXL_20240501_123045123`, `20240501_123045_001`, a UUID) is only
    /// found when all of them are there, so the next photo of the same day or second is not taken for this one.
    static func namesAgree(local: String, server: String) -> Bool {
        if stem(local) == stem(server) { return true }
        let numbers = numbers(in: local)
        guard !numbers.isEmpty else { return false }
        return numbers.allSatisfy { containsNumber(server, $0) }
    }

    /// Whether another device resource of the same second (another asset, same kind and rendition) has a name that the
    /// same server file would agree with: the same name, or the same numbers.
    static func isAmbiguousName(_ resource: LocalResource, among siblings: [LocalResource]) -> Bool {
        let numbers = numbers(in: resource.originalName)
        let stem = stem(resource.originalName)
        let raw = isRaw(resource)
        return siblings.contains { other in
            guard other.localIdentifier != resource.localIdentifier, other.kind == resource.kind,
                other.rendition == resource.rendition, isRaw(other) == raw,
                abs(other.createdAt.timeIntervalSince(resource.createdAt)) < tolerance
            else { return false }
            return Self.stem(other.originalName) == stem || Self.numbers(in: other.originalName) == numbers
        }
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

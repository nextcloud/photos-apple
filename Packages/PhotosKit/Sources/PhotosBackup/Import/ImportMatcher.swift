// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// Whether a photo of an export is already on the server (SPEC §15.7 "Nothing twice"). The backup's rules first
/// (`BackupMatcher`: capture second and size, or capture second and name), then what exports need beyond them:
///
/// 1. the same name and size: the file itself, whatever its time says;
/// 2. a capture time to the minute only (Apple's export): the same kind within the minute, with the same size or the
///    same name (also whole hours apart with the same name, for times read without an offset);
/// 3. a reduced copy (Facebook, Instagram keep smaller, re-encoded copies without most metadata): the capture time the
///    service kept is the second of exactly one photo of that kind on the server, and its proportions agree when the
///    export knows the original's size. Only for a capture time, never for a posting time.
enum ImportMatcher {
    enum Rule: String, Codable, Sendable {
        case backupRules, nameAndSize, sameMinute, reducedCopy
    }

    /// The window around a capture time in which server files are looked for.
    static func margin(for metadata: ImportMetadata) -> TimeInterval {
        metadata.timeSource == .captureMinute ? 90 : 2
    }

    /// A photo of an export as the backup matcher sees a device file.
    static func resource(for item: ImportItem) -> LocalResource {
        let base = (item.name as NSString).deletingPathExtension
        let edited = GoogleTakeoutSidecars.editedSuffixes.contains { base.hasSuffix($0) } || BackupMatcher.isEditedName(item.name)
        let rendition: LocalResource.Rendition
        if case .asset(let resource) = item.origin {
            rendition = resource.rendition
        } else {
            rendition = edited ? .edited : .original
        }
        return LocalResource(
            localIdentifier: item.id, kind: item.kind, createdAt: item.takenAt ?? .distantPast, originalName: item.name,
            byteSize: item.size > 0 ? Int64(item.size) : nil, rendition: rendition)
    }

    /// The name without extension, case and the ` (2)` the server adds to a name that was taken.
    static func stem(_ name: String) -> String {
        var base = (name as NSString).deletingPathExtension.lowercased()
        if let match = base.wholeMatch(of: /(.+) \(\d+\)/) { base = String(match.1) }
        return base
    }

    static func match(_ item: ImportItem, index: inout BackupMatcher.Index, candidates: [RemoteCandidate]) -> (RemoteCandidate, Rule)? {
        guard let time = item.takenAt, item.metadata.isCaptureTime else { return nil }
        if item.metadata.timeSource == .capture, let (candidate, _) = index.match(resource(for: item)) {
            return (candidate, .backupRules)
        }
        let sameKind = candidates.filter { $0.kind == item.kind }
        let itemStem = stem(item.name)
        if item.size > 0, let candidate = sameKind.first(where: { $0.size == Int64(item.size) && stem($0.name) == itemStem }) {
            return (candidate, .nameAndSize)
        }
        func captured(_ candidate: RemoteCandidate) -> Date { candidate.capturedAt ?? candidate.modifiedAt }
        if item.metadata.timeSource == .captureMinute {
            let minute = Int64(time.timeIntervalSince1970) / 60
            for candidate in sameKind {
                let seconds = Int64(captured(candidate).timeIntervalSince1970)
                let sameName = BackupMatcher.namesAgree(local: item.name, server: candidate.name)
                if seconds / 60 == minute, sameName || candidate.size == Int64(item.size) { return (candidate, .sameMinute) }
                // An EXIF time read without its offset: whole hours apart, the same minute of the hour.
                let difference = seconds - minute * 60
                let hours = (Double(difference) / 3600).rounded()
                if sameName, hours != 0, abs(hours) <= 14, abs(difference - Int64(hours) * 3600) < 60 { return (candidate, .sameMinute) }
            }
            return nil
        }
        if item.source.keepsReducedCopies {
            let atSecond = sameKind.filter { abs(captured($0).timeIntervalSince(time)) < BackupMatcher.tolerance }
            guard atSecond.count == 1, let candidate = atSecond.first else { return nil }
            if let width = item.metadata.originalWidth, let height = item.metadata.originalHeight, let w = candidate.width,
                let h = candidate.height, width > 0, height > 0, w > 0, h > 0
            {
                let ratio = Double(max(width, height)) / Double(min(width, height))
                let other = Double(max(w, h)) / Double(min(w, h))
                guard abs(ratio - other) / other < 0.02 else { return nil }
            }
            return (candidate, .reducedCopy)
        }
        return nil
    }
}

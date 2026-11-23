// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// File and folder names for backed-up resources (SPEC §7.18.2, Files app scheme in docs/reference §4.2).
public enum BackupNaming {
    /// Target folder including the date subfolders.
    public static func folder(base: String, subfolders: BackupSettings.Subfolders, date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        let day = String(format: "%02d", parts.day ?? 0)
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        switch subfolders {
        case .none: return trimmed.isEmpty ? "/" : trimmed
        case .year: return "\(trimmed)/\(year)"
        case .yearMonth: return "\(trimmed)/\(year)/\(month)"
        case .yearMonthDay: return "\(trimmed)/\(year)/\(month)/\(day)"
        }
    }

    /// The first run of digits in an original file name (`IMG_1234.HEIC` → `1234`), used by the Files app's naming and for matching.
    public static func number(in originalName: String) -> String? {
        let base = (originalName as NSString).deletingPathExtension
        guard let range = base.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return String(base[range])
    }

    /// Marks an edited version where the name has no `IMG_E1234` form; `BackupMatcher.isEditedName` recognises it.
    public static let editedSuffix = " (edited)"

    /// Apple's name of an edited rendition: `IMG_E1234`.
    static func isAppleEditedName(_ originalName: String) -> Bool {
        (originalName as NSString).deletingPathExtension.wholeMatch(of: /[A-Za-z]{3}_E\d+/) != nil
    }

    /// Name of the uploaded file.
    ///
    /// - Parameters:
    ///   - originalName: the PhotoKit resource's original file name, e.g. `IMG_1234.HEIC` or `IMG_E1234.HEIC` for edits.
    ///   - fileExtension: the extension of the data actually uploaded (`jpg` after conversion).
    public static func fileName(
        originalName: String, fileExtension: String, isVideo: Bool, date: Date, naming: BackupSettings.Naming, counter: Int = 0,
        timeZone: TimeZone = .current
    ) -> String {
        let ext = fileExtension.lowercased()
        switch naming {
        case .original:
            return (originalName as NSString).deletingPathExtension + "." + ext
        case .filesApp(let typePrefix, let mask):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            let number = Self.number(in: originalName) ?? String(format: "%04d", counter % 10_000)
            var name: String
            if let mask, !mask.isEmpty {
                name = Self.applyMask(mask, date: date, formatter: formatter) + " " + number
            } else {
                formatter.dateFormat = "yy-MM-dd HH-mm-ss"
                name = formatter.string(from: date) + " " + number
            }
            // The Files-app scheme drops the `E` of `IMG_E1234`; without a marker the edit would get the original's name
            // and could never be told apart from it again.
            if Self.isAppleEditedName(originalName) || originalName.localizedCaseInsensitiveContains(Self.editedSuffix) {
                name += Self.editedSuffix
            }
            if typePrefix {
                name = (isVideo ? String(localized: "Video") : String(localized: "Photo")) + " " + name
            }
            return name + "." + ext
        }
    }

    /// Files app mask tokens: DD, MMM, MM, YYYY, YY, HH, hh, mm, ss, ampm.
    static func applyMask(_ mask: String, date: Date, formatter: DateFormatter) -> String {
        func format(_ pattern: String) -> String {
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
        var result = ""
        var rest = Substring(mask)
        let tokens: [(String, String)] = [
            ("YYYY", "yyyy"), ("MMM", "MMM"), ("ampm", "a"), ("YY", "yy"), ("MM", "MM"), ("DD", "dd"), ("HH", "HH"), ("hh", "hh"),
            ("mm", "mm"),
            ("ss", "ss"),
        ]
        outer: while !rest.isEmpty {
            for (token, pattern) in tokens where rest.hasPrefix(token) {
                result += format(pattern)
                rest = rest.dropFirst(token.count)
                continue outer
            }
            result.append(rest.removeFirst())
        }
        return result
    }
}

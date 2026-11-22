// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Capture time in the photo's own time zone (web: capture-local-time, dateUtils.ts).
public enum CaptureTime {
    /// Parses EXIF `OffsetTimeOriginal` (`+09:00`, `-0530`) into seconds. Valid: |offset| ≤ 14 h, minutes < 60.
    public static func parseOffset(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.wholeMatch(of: /([+-])(\d{2}):?(\d{2})/) else { return nil }
        let sign = match.1 == "-" ? -1 : 1
        guard let hours = Int(match.2), let minutes = Int(match.3), minutes < 60 else { return nil }
        let total = hours * 3600 + minutes * 60
        guard total <= 14 * 3600 else { return nil }
        return sign * total
    }

    /// Formats a capture date in the given UTC offset, e.g. "14 June 2024 at 09:12 (UTC+9)".
    public static func format(_ date: Date, offset: Int?, locale: Locale = .current) -> String {
        guard let offset, let zone = TimeZone(secondsFromGMT: offset) else {
            return date.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: locale))
        }
        var style = Date.FormatStyle(date: .long, time: .shortened, locale: locale)
        style.timeZone = zone
        let hours = offset / 3600
        let minutes = abs(offset % 3600) / 60
        let suffix =
            minutes == 0
            ? "UTC\(hours >= 0 ? "+" : "")\(hours)" : String(format: "UTC%@%d:%02d", offset >= 0 ? "+" : "-", abs(hours), minutes)
        return "\(date.formatted(style)) (\(suffix))"
    }
}

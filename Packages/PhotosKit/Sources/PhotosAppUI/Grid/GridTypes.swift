// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore

/// A section of the grid (one local calendar day, or one flat section for albums).
struct GridSection: Hashable, Sendable, Identifiable {
    var id: Int
    var title: String
    /// Month title shown above the first day of a month.
    var monthTitle: String?
    var year: Int?
    var items: [FileID]
}

enum GridSectioning {
    /// Day sections with month titles (timeline).
    static func byDay(_ items: [GridMedia], now: Date = Date()) -> [GridSection] {
        let months = TimelineSections.group(timestamps: items.map(\.timestamp))
        var sections: [GridSection] = []
        for month in months {
            for (index, day) in month.days.enumerated() {
                sections.append(
                    GridSection(
                        id: day.id,
                        title: DayLabel.label(for: day.date, now: now),
                        monthTitle: index == 0 ? DayLabel.monthLabel(for: month.date, now: now) : nil,
                        year: month.year,
                        items: items[day.range].map(\.fileId)))
            }
        }
        return sections
    }

    /// One section without headers (albums, places, search results).
    static func flat(_ items: [GridMedia]) -> [GridSection] {
        items.isEmpty ? [] : [GridSection(id: 0, title: "", monthTitle: nil, year: nil, items: items.map(\.fileId))]
    }
}

/// An action offered in context menus and the selection toolbar.
struct GridMenuAction: Identifiable {
    var id: String
    var title: String
    var systemImage: String
    var isDestructive = false
    var handler: @MainActor ([FileID]) -> Void
}

/// Callbacks from the platform grid to SwiftUI.
struct GridCallbacks {
    var open: @MainActor (FileID) -> Void
    var menu: @MainActor ([FileID]) -> [GridMenuAction]
    var selectionChanged: @MainActor (Set<FileID>) -> Void
    var columnsChanged: @MainActor (Int) -> Void
}

enum GridColumns {
    #if os(macOS)
        static let options = [3, 4, 5, 6, 8, 10, 12, 16]
        static let `default` = 6
    #elseif os(visionOS)
        static let options = [3, 4, 5, 6, 8, 10]
        static let `default` = 5
    #else
        static let options = [1, 3, 5, 7, 9, 13]
        static let `default` = 5
    #endif

    static func step(_ current: Int, zoomIn: Bool) -> Int {
        let index = options.firstIndex(of: current) ?? options.firstIndex(where: { $0 >= current }) ?? options.count - 1
        return options[max(0, min(options.count - 1, index + (zoomIn ? -1 : 1)))]
    }
}

/// Builds preview requests for grid tiles.
extension AccountServices {
    func previewRequest(for item: GridMedia, pixels: Double, path: String? = nil) -> ImagePipeline.Request {
        ImagePipeline.Request(
            fileId: item.fileId, etag: item.etag, bucket: PhotosAPIBucket.bucket(pixels), hasPreview: item.hasPreview,
            mimeType: item.mimeType,
            originalURL: connection.filesURL(item.directory == "/" ? "/\(item.name)" : "\(item.directory)/\(item.name)"))
    }
}

enum PhotosAPIBucket {
    static func bucket(_ pixels: Double) -> Int {
        [64, 256, 1024, 4096].first { Double($0) >= pixels * 0.8 } ?? 4096
    }
}

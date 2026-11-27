// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosCore
import PhotosDomain
import PhotosMedia
import PhotosModel
import PhotosStore

/// How the app words the best shot's reasons (SPEC §21.4): "Sharpest, eyes open".
enum BestShotWording {
    static func phrase(_ reason: BestShot.Reason) -> String {
        switch reason {
        case .favorite:
            String(localized: "your favorite", bundle: .module, comment: "Best shot: why it was chosen. Lower case, joined with commas.")
        case .picked:
            String(
                localized: "flagged Pick", bundle: .module,
                comment: "Best shot: why it was chosen (the culling flag Pick). Lower case, joined with commas.")
        case .eyesOpen:
            String(localized: "eyes open", bundle: .module, comment: "Best shot: why it was chosen. Lower case, joined with commas.")
        case .everyoneInFrame:
            String(
                localized: "everyone in the picture", bundle: .module,
                comment: "Best shot: why it was chosen (no face missing). Lower case, joined with commas.")
        case .smiling:
            String(localized: "smiling", bundle: .module, comment: "Best shot: why it was chosen. Lower case, joined with commas.")
        case .sharpest:
            String(localized: "sharpest", bundle: .module, comment: "Best shot: why it was chosen. Lower case, joined with commas.")
        case .lookingAtCamera:
            String(
                localized: "looking at the camera", bundle: .module,
                comment: "Best shot: why it was chosen. Lower case, joined with commas.")
        case .wellExposed:
            String(
                localized: "well exposed", bundle: .module,
                comment: "Best shot: why it was chosen (not too dark or bright). Lower case, joined with commas.")
        case .bestComposed:
            String(
                localized: "best composed", bundle: .module,
                comment: "Best shot: why it was chosen (Vision's aesthetics score). Lower case, joined with commas.")
        }
    }

    /// "Sharpest, eyes open"; for no reasons the balance of everything.
    static func summary(_ reasons: [BestShot.Reason]) -> String {
        guard !reasons.isEmpty else {
            return String(
                localized: "Best balance of sharpness, faces and composition", bundle: .module,
                comment: "Best shot: chosen on the whole, nothing in particular stands out.")
        }
        let separator = String(
            localized: ", ", bundle: .module, comment: "Best shot: separator between reasons, as in sharpest, eyes open.")
        let joined = reasons.map(phrase).joined(separator: separator)
        guard let first = joined.first else { return joined }
        return String(first).uppercased(with: .current) + joined.dropFirst()
    }

    /// The command that flags the best shot of each series Pick (SPEC §21.4).
    static var pickBestTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Pick Best Shots", bundle: .module,
                comment: "Flag menu: flags the best shot of each series of similar photos among the selected ones Pick. Mac menu."),
            other: LocalizedStringResource(
                "Pick best shots", bundle: .module,
                comment: "Flag menu: flags the best shot of each series of similar photos among the selected ones Pick."))
    }

    /// Pick Best Shots found no series among the photos.
    static var noSeries: String {
        String(
            localized:
                "None of these photos were taken in a series of similar shots. Select the shots of a burst or several tries at one scene.",
            bundle: .module, comment: "Pick Best Shots found no series among the selected photos.")
    }

    /// VoiceOver after Pick Best Shots: "Picked the best of 3 series".
    static func picked(_ count: Int, of series: Int) -> String {
        String(
            localized: "Picked the best shot of \(series) series", bundle: .module,
            comment: "VoiceOver after Pick Best Shots. Plural variations in the catalog.")
    }

    /// While the photos of a group are not all analysed yet.
    static var preliminary: String {
        String(
            localized: "Not all shots are analysed yet; the suggestion may change.", bundle: .module,
            comment: "Best shot: the on-device analysis of the series is still incomplete.")
    }
}

/// The best shot of photos of one account (SPEC §21.4): what this device stored, and the missing analyses done now from
/// the 1024 px previews (loaded from the server when they are not on the device and `fetch` allows it).
struct BestShotService: Sendable {
    let services: AccountServices

    var analyzer: BestShotAnalyzer { BestShotAnalyzer(database: services.database, cache: services.images.cache) }

    /// The signals of `ids`, analysing the missing ones.
    func signals(
        of ids: [FileID], fetch: Bool, shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async -> [FileID: BestShot.Signals] {
        let services = services
        @Sendable func preview(_ id: FileID) async -> CGImage? {
            guard let item = try? services.library.items([id])[id] else { return nil }
            let request = ImagePipeline.Request(
                fileId: item.fileId, etag: item.etag, bucket: BestShotAnalysis.bucket, hasPreview: item.hasPreview,
                mimeType: item.mimeType, originalURL: services.connection.originalURL(path: item.path),
                maxPixelSize: BestShotAnalysis.longEdge)
            return await services.images.preview(request)
        }
        let load: (@Sendable (FileID) async -> CGImage?)? = fetch ? preview : nil
        return await analyzer.signals(of: ids, load: load, shouldContinue: shouldContinue)
    }

    /// The best of `items` (one group, in time order), with the user's favourites and Pick/Reject flags.
    func choose(_ items: [MediaItem], fetch: Bool) async -> BestShot.Choice? {
        let ids = items.map(\.fileId)
        let signals = await signals(of: ids, fetch: fetch)
        return choose(items, signals: signals)
    }

    /// The same with signals at hand.
    func choose(_ items: [MediaItem], signals: [FileID: BestShot.Signals]) -> BestShot.Choice? {
        let ids = items.map(\.fileId)
        let tags = (try? CullingStore(database: services.database).cullingTagNames(of: ids)) ?? [:]
        let quality = (try? SimilarityStore(database: services.database).qualities(of: ids)) ?? [:]
        return BestShot.choose(
            items.map { item in
                BestShot.Candidate(
                    id: item.fileId, signals: signals[item.fileId], isFavorite: item.isFavorite,
                    flag: CullingTags.mark(fromTagNames: tags[item.fileId] ?? []).flag, quality: quality[item.fileId])
            })
    }

    /// `items` cut into series of shots of one scene (alike and taken in a chain no more than ten minutes apart,
    /// `SimilarSeries`), in time order; photos that are in no series are left out. Photos "Show Similar" has not
    /// compared yet are compared now (from their 256 px previews).
    func series(of items: [MediaItem]) async -> [[MediaItem]] {
        let photos = items.filter { $0.kind == .image }
        let index = services.similarity
        try? await index.refresh()
        let images = services.images
        let connection = services.connection
        for item in photos {
            guard !Task.isCancelled else { return [] }
            let request = ImagePipeline.Request(
                fileId: item.fileId, etag: item.etag, bucket: 256, hasPreview: item.hasPreview, mimeType: item.mimeType,
                originalURL: connection.originalURL(path: item.path))
            _ = try? await index.featurePrint(of: .init(fileId: item.fileId, etag: item.etag), image: { await images.preview(request) })
        }
        let vectors = await index.vectors(of: photos.map(\.fileId))
        let members = photos.compactMap { item in
            vectors[item.fileId].map {
                SimilarSeries.Member(id: item.fileId, date: item.timestamp, vector: $0, quality: nil, isFavorite: item.isFavorite)
            }
        }
        let byId = Dictionary(photos.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
        return SimilarSeries.series(members).reversed().map { series in series.ids.compactMap { byId[$0] } }
    }
}

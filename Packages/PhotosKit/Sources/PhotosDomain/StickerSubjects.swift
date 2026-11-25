// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import PhotosModel

/// One subject the on-device segmentation found in a photo (a person, a pet, an object in front).
public struct StickerSubject: Sendable, Hashable {
    /// The instance's number in the segmentation result.
    public var instance: Int
    /// Its bounding box in the picture's unit coordinates (origin top left).
    public var box: CGRect
    /// The share of the picture's pixels it covers (0…1).
    public var coverage: Double

    public init(instance: Int, box: CGRect, coverage: Double) {
        self.instance = instance
        self.box = box
        self.coverage = coverage
    }
}

/// Which subjects become the sticker, and which photos make a person's sticker pack (SPEC §15.8.2). Pure, so it is
/// unit-tested; the segmentation itself is Vision's (`StickerMaker`).
public enum StickerSubjects {
    /// Subjects smaller than this share of the picture are specks in the background, not what the photo is of.
    public static let minimumCoverage = 0.01

    /// The subjects to lift.
    ///
    /// - With a face (a person's sticker): the subject that contains the face's centre, else the one that overlaps the face
    ///   most; none when no subject touches the face (the person is not cut out well in this photo).
    /// - Without: every subject that is not a speck, as Photos lifts all of them together; the largest when all are small.
    public static func choose(_ subjects: [StickerSubject], face: CGRect? = nil) -> [Int] {
        guard !subjects.isEmpty else { return [] }
        if let face {
            let centre = CGPoint(x: face.midX, y: face.midY)
            if let holder = subjects.filter({ $0.box.contains(centre) }).max(by: { $0.coverage < $1.coverage }) {
                return [holder.instance]
            }
            let overlaps = subjects.map { ($0, area($0.box.intersection(face))) }.filter { $0.1 > 0 }
            guard let best = overlaps.max(by: { $0.1 < $1.1 }) else { return [] }
            return [best.0.instance]
        }
        let visible = subjects.filter { $0.coverage >= minimumCoverage }
        if !visible.isEmpty { return visible.map(\.instance).sorted() }
        return subjects.max { $0.coverage < $1.coverage }.map { [$0.instance] } ?? []
    }

    static func area(_ rect: CGRect) -> Double {
        rect.isNull || rect.isEmpty ? 0 : Double(rect.width * rect.height)
    }

    /// How many stickers a person's pack has at most.
    public static let packSize = 8
    /// A face smaller than this (share of the picture's width) gives a sticker of a crowd, not of the person.
    public static let minimumFaceWidth = 0.06

    /// The photos for a person's sticker pack: those where the face is large enough, favourites first, the rest spread over
    /// time (a pack of eight photos of the same afternoon is dull). Returns at most `count` file ids, best first.
    ///
    /// - Parameter faces: the person's face box in each photo (unit coordinates).
    public static func packPhotos(_ items: [MediaItem], faces: [FileID: CGRect], count: Int = packSize) -> [FileID] {
        let usable =
            items
            .filter { $0.kind == .image && !$0.isLivePhotoVideo && !$0.isArchived }
            .filter { item in (faces[item.fileId]?.width ?? 0) >= minimumFaceWidth }
            .sorted { $0.timestamp < $1.timestamp }
        guard count > 0, !usable.isEmpty else { return [] }
        let favorites = usable.filter(\.isFavorite)
        var chosen = CollagePicker.spread(favorites, count: min(favorites.count, count / 2))
        let taken = Set(chosen.map(\.fileId))
        chosen += CollagePicker.spread(usable.filter { !taken.contains($0.fileId) }, count: count - chosen.count)
        // Larger faces first: they make the clearest stickers.
        return chosen.sorted { (faces[$0.fileId]?.width ?? 0) > (faces[$1.fileId]?.width ?? 0) }.map(\.fileId)
    }
}

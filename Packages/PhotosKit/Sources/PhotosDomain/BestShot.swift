// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosModel

/// The best shot of a burst or a series of similar photos, and why (SPEC §21.4).
///
/// Each photo of a group is analysed on this device (`BestShotAnalysis` in PhotosMedia: sharpness of the picture and of
/// its subject, exposure, the faces with their eyes, smile and gaze, Vision's aesthetics score). The photos are then
/// compared *with each other*: a burst's frames are all of one scene, so what matters is which frame is sharper, whose
/// eyes are open, who looks at the camera — not how a frame compares with the rest of the library. What the user said
/// comes first: a favourite, else a photo flagged Pick, is kept over any score, and a rejected photo is never suggested
/// while there is another.
public enum BestShot {
    /// What the analysis of one picture found. Stored per version of the file (`BestShotStore`), never uploaded.
    public struct Signals: Codable, Sendable, Equatable {
        /// Bumped when the analysis changes; older rows are analysed again.
        public static let currentVersion = 1

        public var version: Int
        /// Detail of the whole picture: log2(1 + 1024 × variance of the Laplacian / variance of the tones) of the grey
        /// image at the analysis size (`BestShotAnalysis.longEdge`), so brightness and contrast do not count. Only compared
        /// within a group, where every photo was measured the same way.
        public var sharpness: Float
        /// The same for the subject: the largest face, else the most salient object; nil when there is neither.
        public var subjectSharpness: Float?
        /// 1: nothing clipped and the mid-tones where they belong; 0: mostly blown out or black.
        public var exposure: Float
        /// Share of pixels that are blown out (near white) and crushed (near black).
        public var highlights: Float
        public var shadows: Float
        /// The faces, largest first.
        public var faces: [Face]
        /// Vision's overall aesthetics score, −1 … 1.
        public var aesthetics: Float?
        /// Vision says the picture is a document, a receipt, a screenshot… rather than a memorable photo.
        public var isUtility: Bool

        public init(
            version: Int = Signals.currentVersion, sharpness: Float, subjectSharpness: Float? = nil, exposure: Float, highlights: Float = 0,
            shadows: Float = 0, faces: [Face] = [], aesthetics: Float? = nil, isUtility: Bool = false
        ) {
            self.version = version
            self.sharpness = sharpness
            self.subjectSharpness = subjectSharpness
            self.exposure = exposure
            self.highlights = highlights
            self.shadows = shadows
            self.faces = faces
            self.aesthetics = aesthetics
            self.isUtility = isUtility
        }

        /// The faces large enough to judge (eyes and smile of a face a few pixels wide mean nothing) whose eyes were found.
        public var prominentFaces: [Face] { faces.filter(\.isProminent) }

        /// What sharpness means for this photo: mostly its subject's, where it has one.
        var detail: Float {
            guard let subjectSharpness else { return sharpness }
            return 0.65 * subjectSharpness + 0.35 * sharpness
        }
    }

    /// One face of a picture. The box is in normalised coordinates (0 … 1, origin bottom left, as Vision gives it).
    public struct Face: Codable, Sendable, Equatable {
        public var x: Float
        public var y: Float
        public var width: Float
        public var height: Float
        /// 0: both eyes closed … 1: wide open; nil when the eyes could not be found.
        public var eyesOpen: Float?
        public var isSmiling: Bool?
        /// Degrees; 0 is straight at the camera.
        public var yaw: Float?
        public var pitch: Float?
        /// Vision's face capture quality, 0 … 1 (sharp, well lit, facing the camera, a neutral or happy expression).
        public var quality: Float?

        public init(
            x: Float, y: Float, width: Float, height: Float, eyesOpen: Float? = nil, isSmiling: Bool? = nil, yaw: Float? = nil,
            pitch: Float? = nil, quality: Float? = nil
        ) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.eyesOpen = eyesOpen
            self.isSmiling = isSmiling
            self.yaw = yaw
            self.pitch = pitch
            self.quality = quality
        }

        /// Faces narrower than this share of the picture's width are passers-by in the background.
        public static let prominentWidth: Float = 0.05
        /// Eyes below this openness are taken as closed (a blink).
        public static let closedEyes: Float = 0.35
        /// Turned further than this (degrees) is not looking at the camera.
        public static let lookingAngle: Float = 20

        /// Large enough, and a face for sure: its eyes were found (a false detection in a pattern has none).
        public var isProminent: Bool { width >= Self.prominentWidth && eyesOpen != nil }
        public var eyesClosed: Bool { (eyesOpen ?? 1) < Self.closedEyes }
        public var isLooking: Bool { abs(yaw ?? 0) <= Self.lookingAngle && abs(pitch ?? 0) <= Self.lookingAngle }
    }

    /// One photo of a group.
    public struct Candidate: Sendable, Equatable {
        public var id: FileID
        public var signals: Signals?
        public var isFavorite: Bool
        public var flag: CullingFlag
        /// Vision's aesthetics score from "Show Similar" (`SimilarityStore`), used while the photo is not analysed here.
        public var quality: Float?

        public init(id: FileID, signals: Signals? = nil, isFavorite: Bool = false, flag: CullingFlag = .none, quality: Float? = nil) {
            self.id = id
            self.signals = signals
            self.isFavorite = isFavorite
            self.flag = flag
            self.quality = quality
        }
    }

    /// Why a shot was chosen, as the app words it ("Sharpest, eyes open"). Only what sets it apart from the others of
    /// its group is said.
    public enum Reason: String, Codable, Sendable, CaseIterable {
        case favorite, picked, eyesOpen, everyoneInFrame, smiling, sharpest, lookingAtCamera, wellExposed, bestComposed
    }

    /// The best shot of a group.
    public struct Choice: Sendable, Equatable {
        public var best: FileID
        /// Most telling first; at most `maximumReasons`. Empty: the best balance of everything, nothing stands out.
        public var reasons: [Reason]
        /// 0 … 1 for each analysed photo of the group (higher is better).
        public var scores: [FileID: Float]

        public init(best: FileID, reasons: [Reason], scores: [FileID: Float] = [:]) {
            self.best = best
            self.reasons = reasons
            self.scores = scores
        }

        /// The group's photos from best to worst: the analysed ones by score, then the others in their order.
        public func ranking(of ids: [FileID]) -> [FileID] {
            let scored = ids.filter { scores[$0] != nil && $0 != best }.sorted { (scores[$0] ?? 0) > (scores[$1] ?? 0) }
            let rest = ids.filter { scores[$0] == nil && $0 != best }
            return (ids.contains(best) ? [best] : []) + scored + rest
        }
    }

    public static let maximumReasons = 3

    /// The best of `candidates` (in time order). Nil for an empty group.
    public static func choose(_ candidates: [Candidate]) -> Choice? {
        guard !candidates.isEmpty else { return nil }
        // What the user said first: favourites, else picks; rejected photos only when everything is rejected.
        let favorites = candidates.filter(\.isFavorite)
        let picks = candidates.filter { $0.flag == .pick }
        let notRejected = candidates.filter { $0.flag != .reject }
        let pool: [Candidate]
        var lead: [Reason] = []
        if !favorites.isEmpty {
            pool = favorites
            if favorites.count < candidates.count { lead = [.favorite] }
        } else if !picks.isEmpty {
            pool = picks
            if picks.count < candidates.count { lead = [.picked] }
        } else {
            pool = notRejected.isEmpty ? candidates : notRejected
        }
        let scores = Self.scores(candidates)
        let analysed = pool.filter { scores[$0.id] != nil }
        if let best = analysed.max(by: {
            (scores[$0.id] ?? 0, -position($0.id, in: pool)) < (scores[$1.id] ?? 0, -position($1.id, in: pool))
        }) {
            let reasons = lead + Self.reasons(for: best, among: candidates.filter { $0.id != best.id && $0.signals != nil })
            return Choice(best: best.id, reasons: Array(reasons.prefix(maximumReasons)), scores: scores)
        }
        // Nothing analysed yet: as "Show Similar" always did, the best aesthetics score, else the middle shot (often the
        // steadiest of a burst).
        let rated = pool.filter { $0.quality != nil }
        let fallback = rated.max { ($0.quality ?? 0) < ($1.quality ?? 0) } ?? pool[pool.count / 2]
        return Choice(best: fallback.id, reasons: lead, scores: scores)
    }

    private static func position(_ id: FileID, in pool: [Candidate]) -> Int {
        pool.firstIndex { $0.id == id } ?? 0
    }

    // MARK: Scores

    /// What each part weighs. Faces matter most where there are people: a blink spoils a shot more than a little blur.
    struct Weights: Equatable {
        var detail: Float
        var exposure: Float
        var aesthetics: Float
        var eyes: Float = 0
        var smile: Float = 0
        var looking: Float = 0
        var faceQuality: Float = 0
        var everyone: Float = 0

        static let people = Weights(
            detail: 0.22, exposure: 0.08, aesthetics: 0.12, eyes: 0.26, smile: 0.1, looking: 0.07, faceQuality: 0.07, everyone: 0.08)
        static let scenery = Weights(detail: 0.45, exposure: 0.2, aesthetics: 0.35)
        /// Documents, receipts, screenshots: legible beats pretty.
        static let utility = Weights(detail: 0.6, exposure: 0.3, aesthetics: 0.1)
    }

    /// A frame this many doublings of Laplacian variance less detailed than the sharpest gets nothing for detail. Camera
    /// shake of a few pixels costs about two (measured with Core Image's motion blur on a 768 px picture).
    static let detailRange: Float = 3

    /// 0 … 1 for each analysed candidate, compared with the others of the group.
    public static func scores(_ candidates: [Candidate]) -> [FileID: Float] {
        let analysed = candidates.compactMap { candidate in candidate.signals.map { (candidate.id, $0) } }
        guard !analysed.isEmpty else { return [:] }
        let sharpest = analysed.map { $0.1.detail }.max() ?? 0
        let mostFaces = analysed.map { $0.1.prominentFaces.count }.max() ?? 0
        let utilityCount = analysed.filter { $0.1.isUtility }.count
        let weights: Weights =
            utilityCount * 2 > analysed.count ? .utility : mostFaces > 0 ? .people : .scenery
        var result: [FileID: Float] = [:]
        for (id, signals) in analysed {
            var score: Float = 0
            score += weights.detail * max(0, min(1, 1 - (sharpest - signals.detail) / detailRange))
            score += weights.exposure * max(0, min(1, signals.exposure))
            score += weights.aesthetics * max(0, min(1, ((signals.aesthetics ?? 0) + 1) / 2))
            if mostFaces > 0 {
                let faces = signals.prominentFaces
                let count = Float(mostFaces)
                score += weights.eyes * Float(faces.filter { !$0.eyesClosed }.count) / count
                score += weights.smile * Float(faces.filter { $0.isSmiling == true }.count) / count
                score += weights.looking * Float(faces.filter(\.isLooking).count) / count
                let qualities = faces.compactMap(\.quality)
                if !qualities.isEmpty {
                    score += weights.faceQuality * qualities.reduce(0, +) / Float(qualities.count) * Float(faces.count) / count
                }
                score += weights.everyone * Float(faces.count) / count
            }
            result[id] = score
        }
        return result
    }

    // MARK: Reasons

    /// What sets `best` apart from `others` (the analysed photos of its group), most telling first.
    static func reasons(for best: Candidate, among others: [Candidate]) -> [Reason] {
        guard let mine = best.signals, !others.isEmpty else { return [] }
        let theirs = others.compactMap(\.signals)
        var reasons: [Reason] = []
        let myFaces = mine.prominentFaces
        if !myFaces.isEmpty, !myFaces.contains(where: \.eyesClosed),
            theirs.contains(where: { $0.prominentFaces.contains(where: \.eyesClosed) })
        {
            reasons.append(.eyesOpen)
        }
        if !myFaces.isEmpty, theirs.contains(where: { $0.prominentFaces.count < myFaces.count }),
            !theirs.contains(where: { $0.prominentFaces.count > myFaces.count })
        {
            reasons.append(.everyoneInFrame)
        }
        let mySmiles = myFaces.filter { $0.isSmiling == true }.count
        if !myFaces.isEmpty, mySmiles == myFaces.count,
            theirs.contains(where: { $0.prominentFaces.filter { $0.isSmiling == true }.count < mySmiles })
        {
            reasons.append(.smiling)
        }
        let otherDetail = theirs.map(\.detail)
        if let most = otherDetail.max(), mine.detail >= most,
            mine.detail - otherDetail.reduce(0, +) / Float(otherDetail.count) >= sharperBy
        {
            reasons.append(.sharpest)
        }
        let myLooking = myFaces.filter(\.isLooking).count
        if !myFaces.isEmpty, myLooking == myFaces.count, theirs.contains(where: { $0.prominentFaces.filter(\.isLooking).count < myLooking })
        {
            reasons.append(.lookingAtCamera)
        }
        if mine.exposure >= 0.75, theirs.contains(where: { $0.exposure <= mine.exposure - 0.2 }) {
            reasons.append(.wellExposed)
        }
        let otherAesthetics = theirs.compactMap(\.aesthetics)
        if let myAesthetics = mine.aesthetics, let most = otherAesthetics.max(), myAesthetics >= most,
            myAesthetics - otherAesthetics.reduce(0, +) / Float(otherAesthetics.count) >= 0.1
        {
            reasons.append(.bestComposed)
        }
        return reasons
    }

    /// "Sharpest" is only said when the shot has clearly more detail than the others on average (log2 units: 0.35 is
    /// about a quarter more Laplacian variance), not for a difference nobody would see.
    static let sharperBy: Float = 0.35

    // MARK: Covers

    /// A bonus for a cover photo (memories, key photos) from its faces: open eyes and smiles help, a blink spoils it.
    /// 0 without signals or faces.
    public static func coverBonus(_ signals: Signals?) -> Float {
        guard let faces = signals?.prominentFaces, !faces.isEmpty else { return 0 }
        let count = Float(faces.count)
        let open = Float(faces.filter { !$0.eyesClosed }.count) / count
        let smiling = Float(faces.filter { $0.isSmiling == true }.count) / count
        // All eyes open: +0.15; one face of two blinking: −0.15; everyone blinking: −0.45.
        return 0.6 * open - 0.45 + 0.25 * smiling
    }
}

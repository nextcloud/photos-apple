// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosDomain
@testable import PhotosModel

/// The best shot of a burst or series and why (SPEC §21.4).
@Suite struct BestShotTests {
    func signals(
        sharp: Float = 8, subject: Float? = nil, exposure: Float = 0.9, aesthetics: Float? = 0.2, faces: [BestShot.Face] = [],
        utility: Bool = false
    ) -> BestShot.Signals {
        BestShot.Signals(
            sharpness: sharp, subjectSharpness: subject, exposure: exposure, faces: faces, aesthetics: aesthetics, isUtility: utility)
    }

    func face(open: Float = 0.9, smiling: Bool = false, yaw: Float = 0, width: Float = 0.2, x: Float = 0.3) -> BestShot.Face {
        BestShot.Face(x: x, y: 0.4, width: width, height: width, eyesOpen: open, isSmiling: smiling, yaw: yaw, pitch: 0, quality: 0.6)
    }

    @Test func theSharpestFrameOfASceneWinsAndSaysSo() throws {
        let choice = try #require(
            BestShot.choose([
                .init(id: 1, signals: signals(sharp: 7)),
                .init(id: 2, signals: signals(sharp: 8.5)),
                .init(id: 3, signals: signals(sharp: 7.2)),
            ]))
        #expect(choice.best == 2)
        #expect(choice.reasons == [.sharpest])
        #expect(choice.ranking(of: [1, 2, 3]) == [2, 3, 1])
    }

    @Test func aDifferenceNobodySeesIsNotCalledSharpest() throws {
        let choice = try #require(
            BestShot.choose([.init(id: 1, signals: signals(sharp: 8.0)), .init(id: 2, signals: signals(sharp: 8.1))]))
        #expect(choice.best == 2)
        #expect(!choice.reasons.contains(.sharpest))
    }

    @Test func aBlinkLosesAgainstASlightlySofterFrameWithOpenEyes() throws {
        let choice = try #require(
            BestShot.choose([
                .init(id: 1, signals: signals(sharp: 8.6, subject: 8.6, faces: [face(open: 0.1)])),
                .init(id: 2, signals: signals(sharp: 8.2, subject: 8.2, faces: [face(open: 0.95)])),
            ]))
        #expect(choice.best == 2)
        #expect(choice.reasons.first == .eyesOpen)
        #expect(!choice.reasons.contains(.sharpest))
    }

    @Test func everyoneInTheFrameSmilingAndLooking() throws {
        let group = [
            // Someone turned away (and so is not found as a face).
            BestShot.Candidate(id: 1, signals: signals(faces: [face(), face(x: 0.6)])),
            BestShot.Candidate(
                id: 2, signals: signals(faces: [face(smiling: true), face(smiling: true, x: 0.6), face(smiling: true, x: 0.1)])),
            BestShot.Candidate(id: 3, signals: signals(faces: [face(smiling: true, yaw: 40), face(x: 0.6), face(x: 0.1)])),
        ]
        let choice = try #require(BestShot.choose(group))
        #expect(choice.best == 2)
        #expect(choice.reasons == [.everyoneInFrame, .smiling, .lookingAtCamera])
    }

    @Test func faceTooSmallToJudgeDoesNotCount() throws {
        // A passer-by blinking far away does not spoil the shot.
        let choice = try #require(
            BestShot.choose([
                .init(id: 1, signals: signals(sharp: 9, faces: [face(open: 0.05, width: 0.02)])),
                .init(id: 2, signals: signals(sharp: 7, faces: [])),
            ]))
        #expect(choice.best == 1)
        #expect(choice.reasons == [.sharpest])
    }

    @Test func theUsersChoiceComesFirst() throws {
        let group = [
            BestShot.Candidate(id: 1, signals: signals(sharp: 9)),
            BestShot.Candidate(id: 2, signals: signals(sharp: 6), isFavorite: true),
            BestShot.Candidate(id: 3, signals: signals(sharp: 7), flag: .pick),
        ]
        #expect(BestShot.choose(group)?.best == 2)
        #expect(BestShot.choose(group)?.reasons.first == .favorite)
        var noFavorite = group
        noFavorite[1].isFavorite = false
        #expect(BestShot.choose(noFavorite)?.best == 3)
        #expect(BestShot.choose(noFavorite)?.reasons.first == .picked)
        // Two favourites: the better of them.
        var twoFavorites = group
        twoFavorites[0].isFavorite = true
        #expect(BestShot.choose(twoFavorites)?.best == 1)
    }

    @Test func aRejectedShotIsNeverSuggestedWhileThereIsAnother() throws {
        let group = [
            BestShot.Candidate(id: 1, signals: signals(sharp: 9), flag: .reject),
            BestShot.Candidate(id: 2, signals: signals(sharp: 6)),
        ]
        #expect(BestShot.choose(group)?.best == 2)
        let allRejected = group.map { candidate -> BestShot.Candidate in
            var rejected = candidate
            rejected.flag = .reject
            return rejected
        }
        #expect(BestShot.choose(allRejected)?.best == 1)
    }

    @Test func withoutAnalysisTheOldRuleHolds() throws {
        // The best aesthetics score from "Show Similar", else the middle shot.
        #expect(BestShot.choose([.init(id: 1, quality: 0.1), .init(id: 2, quality: 0.4), .init(id: 3)])?.best == 2)
        #expect(BestShot.choose([.init(id: 1), .init(id: 2), .init(id: 3)])?.best == 2)
        #expect(BestShot.choose([.init(id: 1), .init(id: 2), .init(id: 3)])?.reasons == [])
        #expect(BestShot.choose([]) == nil)
    }

    @Test func analysedShotsBeatOnesNotAnalysedYet() throws {
        let choice = try #require(BestShot.choose([.init(id: 1, quality: 0.9), .init(id: 2, signals: signals())]))
        #expect(choice.best == 2)
        #expect(choice.scores[1] == nil)
        #expect(choice.ranking(of: [1, 2]) == [2, 1])
    }

    @Test func documentsAreChosenForBeingLegible() throws {
        // A receipt photographed three times: the sharp one, even if the blurry one "looks nicer".
        let choice = try #require(
            BestShot.choose([
                .init(id: 1, signals: signals(sharp: 6, aesthetics: 0.6, utility: true)),
                .init(id: 2, signals: signals(sharp: 9, aesthetics: -0.4, utility: true)),
                .init(id: 3, signals: signals(sharp: 7, aesthetics: 0.1, utility: true)),
            ]))
        #expect(choice.best == 2)
    }

    @Test func exposureAndCompositionAreReasonsToo() throws {
        let choice = try #require(
            BestShot.choose([
                .init(id: 1, signals: signals(exposure: 0.4, aesthetics: 0.0)),
                .init(id: 2, signals: signals(exposure: 0.95, aesthetics: 0.4)),
            ]))
        #expect(choice.best == 2)
        #expect(choice.reasons == [.wellExposed, .bestComposed])
    }

    @Test func theSubjectsSharpnessCountsMoreThanTheBackgrounds() throws {
        // Frame 1: the background in focus, the face soft (missed focus); frame 2 the other way round.
        let choice = try #require(
            BestShot.choose([
                .init(id: 1, signals: signals(sharp: 9, subject: 6, faces: [face()])),
                .init(id: 2, signals: signals(sharp: 7.5, subject: 8.5, faces: [face()])),
            ]))
        #expect(choice.best == 2)
        #expect(choice.reasons == [.sharpest])
    }

    @Test func atMostThreeReasons() throws {
        let choice = try #require(
            BestShot.choose([
                .init(id: 1, signals: signals(sharp: 6, exposure: 0.3, aesthetics: -0.3, faces: [face(open: 0.1, yaw: 40)])),
                .init(id: 2, signals: signals(sharp: 9, exposure: 0.95, aesthetics: 0.5, faces: [face(smiling: true), face(x: 0.6)])),
            ]))
        #expect(choice.reasons.count == BestShot.maximumReasons)
        #expect(choice.reasons.first == .eyesOpen)
    }

    @Test func coverBonusLikesOpenEyesAndSmiles() {
        #expect(BestShot.coverBonus(nil) == 0)
        #expect(BestShot.coverBonus(signals()) == 0)
        let smiling = BestShot.coverBonus(signals(faces: [face(smiling: true)]))
        let open = BestShot.coverBonus(signals(faces: [face()]))
        let blinking = BestShot.coverBonus(signals(faces: [face(open: 0.1)]))
        #expect(smiling > open)
        #expect(open > 0)
        #expect(blinking < 0)
    }

    @Test func signalsSurviveStorage() throws {
        let original = signals(subject: 7.5, faces: [face(smiling: true)])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(BestShot.Signals.self, from: data) == original)
    }
}

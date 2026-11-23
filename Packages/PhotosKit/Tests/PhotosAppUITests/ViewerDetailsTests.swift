// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import PhotosNetworking
import Testing

@testable import PhotosAppUI

/// The camera line of the info panel (SPEC §7.4).
@Suite struct CameraNameTests {
    @Test func makerIsNotRepeatedWhenTheModelStartsWithIt() {
        #expect(InfoPanel.cameraName(make: "Canon", model: "Canon EOS 6D") == "Canon EOS 6D")
        #expect(InfoPanel.cameraName(make: "NIKON", model: "NIKON D750") == "NIKON D750")
        // Different case, padded with spaces as some cameras write it.
        #expect(InfoPanel.cameraName(make: "SONY ", model: "Sony DSC-RX100") == "Sony DSC-RX100")
    }

    @Test func makerWithCompanySuffix() {
        #expect(InfoPanel.cameraName(make: "NIKON CORPORATION", model: "NIKON D750") == "NIKON D750")
        #expect(InfoPanel.cameraName(make: "OLYMPUS IMAGING CORP.", model: "E-M10") == "OLYMPUS IMAGING CORP. E-M10")
    }

    @Test func makerIsKeptWhereTheModelDoesNotSayIt() {
        #expect(InfoPanel.cameraName(make: "Apple", model: "iPhone 16 Pro") == "Apple iPhone 16 Pro")
        #expect(InfoPanel.cameraName(make: "SONY", model: "ILCE-7M3") == "SONY ILCE-7M3")
    }

    @Test func oneOfThemMissing() {
        #expect(InfoPanel.cameraName(make: nil, model: "Pixel 9") == "Pixel 9")
        #expect(InfoPanel.cameraName(make: "Leica", model: nil) == "Leica")
        #expect(InfoPanel.cameraName(make: nil, model: nil) == "")
        #expect(InfoPanel.cameraName(make: " ", model: "") == "")
    }
}

/// What a video page says when the video does not play.
@Suite struct VideoFailureTests {
    @Test func aConversionInProgressIsNotAFailure() {
        // The server answers 404 until the converted video is there.
        #expect(VideoFailure.isStillConverting(NetworkError.notFound))
        #expect(!VideoFailure.isStillConverting(NetworkError.offline))
        #expect(!VideoFailure.isStillConverting(NetworkError.forbidden(message: nil)))
        #expect(!VideoFailure.isStillConverting(URLError(.timedOut)))
    }

    @Test func failuresSayWhatHappenedAndOfferToTryAgain() {
        let offline = VideoFailure.loading(NetworkError.offline)
        #expect(offline.message == "This video couldn't be loaded.")
        #expect(offline.detail == "You are offline.")
        #expect(offline.canRetry)
        #expect(VideoFailure.conversionTakesLong.canRetry)
        #expect(VideoFailure.conversionTakesLong.detail == "Try again in a few minutes.")
    }

    @Test func aFormatThatCannotBePlayedIsNotRetried() {
        #expect(!VideoFailure.unsupportedFormat.canRetry)
        #expect(VideoFailure.unsupportedFormat.detail == nil)
    }

    @Test func noReasonIsBetterThanAnEmptyOrTechnicalOne() {
        #expect(VideoFailure.loading(nil).detail == nil)
        #expect(VideoFailure.loading(CancellationError()).detail == nil)
        #expect(VideoFailure.loading(NetworkError.cancelled).detail == nil)
    }

    @Test func preparingAndFailedAreDifferentStates() {
        #expect(VideoLoadPhase.preparing != VideoLoadPhase.loading)
        #expect(VideoLoadPhase.failed(.conversionTakesLong) != VideoLoadPhase.preparing)
    }
}

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing

@testable import PhotosDomain

/// The morph between the Library's zoom levels (SPEC §17.5): which photos travel, from where to where.
@Suite struct LibraryZoomMorphTests {
    let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)

    @Test func thePhotosOnBothLevelsTravel() {
        let source: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 400, height: 300),
            2: CGRect(x: 0, y: 320, width: 400, height: 300),
        ]
        let destination: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 190, height: 190),
            3: CGRect(x: 200, y: 0, width: 190, height: 190),
        ]
        let flights = LibraryZoomMorph.flights(from: source, to: destination, viewport: viewport, anchor: .zero)
        #expect(flights == [.init(source: 1, destination: 1, from: source[1]!, to: destination[1]!)])
        #expect(!flights[0].crossFades)
    }

    @Test func photosOffScreenOnEitherSideDoNotTravel() {
        let source: [Int: CGRect] = [
            1: CGRect(x: 0, y: 900, width: 100, height: 100),  // below the screen
            2: CGRect(x: 0, y: 100, width: 100, height: 100),
            3: CGRect(x: 0, y: 200, width: 100, height: 100),
            4: CGRect(x: 0, y: 300, width: 0, height: 0),  // collapsed
        ]
        let destination: [Int: CGRect] = [
            1: CGRect(x: 0, y: 100, width: 50, height: 50),
            2: CGRect(x: 0, y: -400, width: 50, height: 50),  // above the screen
            3: CGRect(x: 0, y: 300, width: 50, height: 50),
            4: CGRect(x: 0, y: 400, width: 50, height: 50),
        ]
        let flights = LibraryZoomMorph.flights(from: source, to: destination, viewport: viewport, anchor: .zero)
        #expect(flights.map(\.source) == [3])
    }

    @Test func theClosestToTheFingersAreKeptWhenThereAreTooMany() {
        var source: [Int: CGRect] = [:]
        var destination: [Int: CGRect] = [:]
        for id in 0..<40 {
            source[id] = CGRect(x: 0, y: CGFloat(id) * 20, width: 20, height: 20)
            destination[id] = CGRect(x: 100, y: CGFloat(id) * 20, width: 20, height: 20)
        }
        let flights = LibraryZoomMorph.flights(
            from: source, to: destination, viewport: viewport, anchor: CGPoint(x: 10, y: 410), limit: 5)
        #expect(flights.count == 5)
        #expect(Set(flights.map(\.source)) == [18, 19, 20, 21, 22])
        #expect(flights.first?.source == 20)
    }

    @Test func theHeroTravelsEvenWhenItsPhotoIsNotOnTheNewLevel() {
        // A year whose key photo is in a month off screen: it flies to the month the zoom arrives at, cross-fading.
        let source: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 400, height: 300)]
        let destination: [Int: CGRect] = [7: CGRect(x: 0, y: 0, width: 190, height: 190)]
        let flights = LibraryZoomMorph.flights(
            from: source, to: destination, hero: (source: 1, destination: 7), viewport: viewport, anchor: .zero)
        #expect(flights.count == 1)
        #expect(flights[0].source == 1 && flights[0].destination == 7)
        #expect(flights[0].crossFades)
    }

    @Test func theHeroIsLeftOutWhenItsPhotoTravelsAnyway() {
        let source: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 400, height: 300)]
        let destination: [Int: CGRect] = [
            1: CGRect(x: 200, y: 200, width: 190, height: 190), 7: CGRect(x: 0, y: 0, width: 190, height: 190),
        ]
        let flights = LibraryZoomMorph.flights(
            from: source, to: destination, hero: (source: 1, destination: 7), viewport: viewport, anchor: .zero)
        #expect(flights.map(\.destination) == [1])
    }

    @Test func theHeroKeepsItsPlaceAtTheLimit() {
        let source: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 10, height: 10), 2: CGRect(x: 0, y: 20, width: 10, height: 10),
            9: CGRect(x: 0, y: 700, width: 10, height: 10),
        ]
        let destination: [Int: CGRect] = [
            1: CGRect(x: 50, y: 0, width: 10, height: 10), 2: CGRect(x: 50, y: 20, width: 10, height: 10),
            8: CGRect(x: 50, y: 700, width: 10, height: 10),
        ]
        let flights = LibraryZoomMorph.flights(
            from: source, to: destination, hero: (source: 9, destination: 8), viewport: viewport, anchor: .zero, limit: 2)
        #expect(flights.map(\.source) == [9, 1])
    }

    @Test func noFlightsWithoutRoom() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(LibraryZoomMorph.flights(from: [1: rect], to: [1: rect], viewport: viewport, anchor: .zero, limit: 0).isEmpty)
        #expect(LibraryZoomMorph.flights(from: [Int: CGRect](), to: [1: rect], viewport: viewport, anchor: .zero).isEmpty)
    }

    @Test func aPinchedLevelIsScaledAroundTheFingers() {
        let rect = CGRect(x: 100, y: 100, width: 100, height: 50)
        let anchor = CGPoint(x: 100, y: 100)
        #expect(LibraryZoomMorph.scaled(rect, by: 2, around: anchor) == CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(
            LibraryZoomMorph.scaled(rect, by: 0.5, around: CGPoint(x: 0, y: 0)) == CGRect(x: 50, y: 50, width: 50, height: 25))
        #expect(LibraryZoomMorph.scaled(rect, by: 1, around: .zero) == rect)
        #expect(LibraryZoomMorph.scaled(rect, by: .nan, around: .zero) == rect)
    }

    @Test func reduceMotionCrossFades() {
        #expect(LibraryZoomMorph.style(reduceMotion: true) == .crossFade)
        #expect(LibraryZoomMorph.style(reduceMotion: false) == .flights)
    }

    @Test func cardsAreRoundedAndTilesSquare() {
        #expect(LibraryZoomMorph.cornerRadius(on: .years) > LibraryZoomMorph.cornerRadius(on: .months))
        #expect(LibraryZoomMorph.cornerRadius(on: .all) == 0)
    }
}

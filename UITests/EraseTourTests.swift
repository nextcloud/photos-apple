// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

/// The editor's Erase tool on iPhone (SPEC §21.5): brush over the photo, the stroke is filled in (Restore All appears),
/// Undo takes it back, Cancel leaves the photo as it was. Same requirements as `SmokeTests` (`PHOTOS_UITEST_LOGIN`);
/// screenshots are attached and, with `PHOTOS_UITEST_SHOTS=<folder>`, also written there. Nothing is saved.
@MainActor
final class EraseTourTests: XCTestCase {
    /// Generous: the simulator's first launch and the editor's first picture can be slow.
    static let wait: TimeInterval = 90
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
            throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
        }
        #if !os(iOS)
            throw XCTSkip("The tour is written for iPhone.")
        #endif
        app = XCUIApplication()
        app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    #if os(iOS)
        func testBrushEraseUndo() {
            app.launch()
            let library = app.tabBars.buttons["Library"].firstMatch
            _ = library.waitForExistence(timeout: 20)
            pause(2)
            if library.exists { library.tap() }
            let tiles = app.collectionViews.cells
            XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline")
            pause(3)
            // The first photo the viewer can edit (another test's video or a read-only share may come first).
            let edit = app.buttons["Edit"].firstMatch
            var found = false
            for index in 0..<4 where !found {
                tiles.element(boundBy: index).tap()
                found = edit.waitForExistence(timeout: 15)
                if !found, app.buttons["Close"].firstMatch.exists {
                    app.buttons["Close"].firstMatch.tap()
                    pause(2)
                }
            }
            XCTAssertTrue(found, "None of the first photos has an Edit button")
            shot("r11-erase-00-viewer")
            pause(2)
            edit.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: Self.wait), "The editor did not open")
            pause(4)
            app.buttons["Erase"].firstMatch.tap()
            let picture = app.images["Edited photo"].firstMatch
            XCTAssertTrue(picture.waitForExistence(timeout: Self.wait), "The Erase tool shows no picture to brush on")
            XCTAssertTrue(app.staticTexts["Tap an object to erase it, or brush over it."].firstMatch.exists)
            // The basic fill is how Erase works: nothing about installing or downloading a model.
            XCTAssertTrue(app.staticTexts["Works best on spots and small things."].firstMatch.exists)
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'model'")).firstMatch.exists)
            pause(2)
            shot("r11-erase-01-tool")
            let start = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            let end = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.55))
            start.press(forDuration: 0.2, thenDragTo: end)
            let restore = app.buttons["Restore All"].firstMatch
            XCTAssertTrue(restore.waitForExistence(timeout: Self.wait), "The brushed stroke was not erased")
            pause(1)
            shot("r11-erase-02-brushed")
            app.buttons["Undo"].firstMatch.tap()
            pause(2)
            XCTAssertFalse(restore.exists, "Undo did not take the stroke back")
            shot("r11-erase-03-undone")
            cancel.tap()
        }

        /// One photo to erase something on (`PHOTOS_UITEST_ERASE_EVIDENCE`): the brush size (fraction of the shorter side,
        /// `RemoveTool.brushSizes`) and straight strokes from point to point, in fractions of the photo.
        struct EvidencePhoto: Decodable {
            var file: String
            var name: String
            var brush: Double
            var strokes: [[[Double]]]
        }

        /// Before/after pictures of the basic fill (SPEC §21.5), opt-in: `PHOTOS_UITEST_ERASE_EVIDENCE=<folder>` holds JPEGs
        /// and `erase-evidence.json` (`[EvidencePhoto]`, photos of different aspect ratios: that is how the test tells
        /// them apart in the grid). They are uploaded into a folder of their own (dated now, so they are the newest of
        /// the library), brushed in the Erase tool, photographed before and after (`<name>-before/-after.png` and the
        /// picture's frame in points, `<name>-frame.txt`, in `PHOTOS_UITEST_SHOTS`), and left with Cancel: nothing is
        /// saved, and the folder is removed at the end. Never the shared test library.
        func testEraseEvidence() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard let source = environment["PHOTOS_UITEST_ERASE_EVIDENCE"], !source.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_ERASE_EVIDENCE to a folder with erase-evidence.json and its photos.")
            }
            let folderURL = URL(fileURLWithPath: source, isDirectory: true)
            let photos = try JSONDecoder().decode(
                [EvidencePhoto].self, from: Data(contentsOf: folderURL.appendingPathComponent("erase-evidence.json")))
            var aspects: [String: Double] = [:]
            let login = environment["PHOTOS_UITEST_LOGIN"] ?? ""
            let folder = "Photos/erase-evidence-\(Int(Date().timeIntervalSince1970))"
            let server = try XCTUnwrap(TestServer(login: login, folder: folder), "PHOTOS_UITEST_LOGIN is not a login link")
            addTeardownBlock { try? await server.removeFolder() }
            for (index, photo) in photos.enumerated() {
                let data = try Data(contentsOf: folderURL.appendingPathComponent(photo.file))
                let image = try XCTUnwrap(UIImage(data: data), "\(photo.file) is not a picture")
                aspects[photo.name] = Double(image.size.width / image.size.height)
                try await server.upload(data, name: photo.file, contentType: "image/jpeg", age: index * 60)
            }
            app.launch()
            let library = app.tabBars.buttons["Library"].firstMatch
            _ = library.waitForExistence(timeout: 20)
            if library.exists { library.tap() }
            XCTAssertTrue(app.staticTexts["Today"].firstMatch.waitForExistence(timeout: Self.wait), "The uploaded photos did not arrive")
            pause(3)
            let tiles = app.collectionViews.cells.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'"))
            var done: Set<String> = []
            for index in 0..<photos.count {
                tiles.element(boundBy: index).tap()
                let edit = app.buttons["Edit"].firstMatch
                XCTAssertTrue(edit.waitForExistence(timeout: Self.wait), "Tile \(index) has no Edit button")
                pause(2)
                edit.tap()
                let cancel = app.buttons["Cancel"].firstMatch
                XCTAssertTrue(cancel.waitForExistence(timeout: Self.wait), "The editor did not open")
                pause(3)
                app.buttons["Erase"].firstMatch.tap()
                let picture = app.images["Edited photo"].firstMatch
                XCTAssertTrue(picture.waitForExistence(timeout: Self.wait), "The Erase tool shows no picture to brush on")
                pause(2)
                let frame = picture.frame
                // Which of the uploaded photos this is, by its shape; anything else is left alone.
                let shape = Double(frame.width / max(frame.height, 1))
                guard
                    let photo = photos.first(where: { !done.contains($0.name) && abs((aspects[$0.name] ?? 0) - shape) / shape < 0.02 })
                else {
                    XCTFail("Tile \(index) is none of the uploaded photos (aspect \(shape))")
                    cancel.tap()
                    return
                }
                done.insert(photo.name)
                let slider = app.sliders["Brush Size"].firstMatch
                if slider.exists {
                    // `RemoveTool.brushSizes`.
                    let range = 0.01...0.08
                    let position = (photo.brush - range.lowerBound) / (range.upperBound - range.lowerBound)
                    slider.adjust(toNormalizedSliderPosition: CGFloat(position))
                    pause(1)
                }
                shot("\(photo.name)-before")
                if let shots = environment["PHOTOS_UITEST_SHOTS"], !shots.isEmpty {
                    let text = "\(frame.minX) \(frame.minY) \(frame.width) \(frame.height)\n"
                    try? Data(text.utf8).write(to: URL(fileURLWithPath: shots).appendingPathComponent("\(photo.name)-frame.txt"))
                }
                let restore = app.buttons["Restore All"].firstMatch
                for stroke in photo.strokes where stroke.count >= 2 {
                    let points = stroke.map { picture.coordinate(withNormalizedOffset: CGVector(dx: $0[0], dy: $0[1])) }
                    for (from, to) in zip(points, points.dropFirst()) {
                        from.press(forDuration: 0.2, thenDragTo: to)
                        // Each drag is a stroke of its own; the next waits until it is filled in.
                        XCTAssertTrue(restore.waitForExistence(timeout: Self.wait), "\(photo.name): the stroke was not erased")
                        _ = app.activityIndicators.firstMatch.waitForNonExistence(timeout: Self.wait)
                        pause(1)
                    }
                }
                pause(2)
                shot("\(photo.name)-after")
                // Nothing is saved.
                cancel.tap()
                pause(2)
                let close = app.buttons["Close"].firstMatch
                if close.waitForExistence(timeout: 10) { close.tap() }
                pause(2)
            }
            XCTAssertEqual(done.count, photos.count, "Not every photo was erased on")
        }
    #endif
}

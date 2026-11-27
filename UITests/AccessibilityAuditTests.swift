// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

#if os(iOS)
    import UIKit

    /// Xcode's accessibility audit of every main screen on iPhone and iPad (SPEC §20.3): Library, viewer, Collections
    /// (the iPad's sidebar), Albums, Settings, Search, Clean up and Memories, at the default text size and at the
    /// largest accessibility size.
    ///
    /// Same requirements as `SmokeTests` (`PHOTOS_UITEST_LOGIN`, a Debug build with a bundle id of your own). They only
    /// look and navigate; nothing on the server changes.
    ///
    /// - `PHOTOS_UITEST_SHOTS=<folder>`: each screen's screenshot, accessibility tree and audit findings are written
    ///   there (`<prefix>iphone-a11y-library.png/.txt/-audit.txt`).
    /// - `PHOTOS_UITEST_A11Y_SURVEY=1`: every finding is written down and none fails the test (to look at a new screen).
    /// - `PHOTOS_UITEST_LANGUAGE=de`: runs the screens in German with a German region (SPEC §20.3, the locale pass);
    ///   `double`: English with every text doubled (`NSDoubleLocalizedStrings`), to find what longer words would cut off.
    ///
    /// A finding fails the test unless `AccessibilityAuditPolicy.accepts` names it with its reason: findings in what the
    /// system draws (bars, the keyboard, the map) and photos, whose contrast is not ours to change.
    @MainActor
    final class AccessibilityAuditTests: XCTestCase {
        static let wait: TimeInterval = 60

        var app: XCUIApplication!
        private var shots: URL?
        private var prefix = ""
        private var survey = false

        override func setUp() async throws {
            continueAfterFailure = true
            let environment = ProcessInfo.processInfo.environment
            guard let login = environment["PHOTOS_UITEST_LOGIN"], !login.isEmpty else {
                throw XCTSkip("Set PHOTOS_UITEST_LOGIN to a login link of a test server to run the UI tests.")
            }
            let runner = Bundle.main.bundleIdentifier ?? ""
            try XCTSkipIf(
                runner.hasPrefix(SmokeTests.officialBundleId + ".uitests"),
                "Build the UI tests with a bundle id of your own (PHOTOS_BUNDLE_ID), not \(SmokeTests.officialBundleId).")
            if let folder = environment["PHOTOS_UITEST_SHOTS"], !folder.isEmpty {
                let url = URL(fileURLWithPath: folder, isDirectory: true)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                shots = url
            }
            survey = environment["PHOTOS_UITEST_A11Y_SURVEY"] == "1"
            let language = environment["PHOTOS_UITEST_LANGUAGE"] ?? "en"
            let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            prefix = (environment["PHOTOS_UITEST_SHOT_PREFIX"] ?? "") + (language == "en" ? "" : "\(language)-") + "\(idiom)-a11y-"
            XCUIDevice.shared.orientation = .portrait
            app = XCUIApplication()
            app.launchEnvironment["PHOTOS_DEBUG_LOGIN"] = login
            switch language {
            case "de":
                app.launchArguments += ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
            case "double":
                // Every text twice as long: where longer languages (German) would be cut off, until there are translations.
                app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "de_DE", "-NSDoubleLocalizedStrings", "YES"]
            default:
                app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            }
        }

        override func tearDown() async throws {
            app?.terminate()
            app = nil
        }

        // MARK: Screens

        func testLibrary() throws {
            launch()
            waitForTiles()
            pause(3)
            try audit("library")
        }

        func testViewer() throws {
            launch()
            waitForTiles()
            tiles.element(boundBy: 2).tap()
            XCTAssertTrue(app.buttons["Info"].firstMatch.waitForExistence(timeout: Self.wait), "The viewer did not open")
            pause(3)
            try audit("viewer")
            app.buttons["Info"].firstMatch.tap()
            pause(2)
            try audit("viewer-info")
        }

        /// iPhone: the Collections tab. iPad: the sidebar, which has the same places.
        func testCollections() throws {
            launch(at: isPad ? "library" : "collections")
            if isPad {
                waitForTiles()
                showSidebar()
                pause(2)
                try audit("sidebar")
            } else {
                XCTAssertTrue(app.navigationBars["Collections"].waitForExistence(timeout: Self.wait), "Collections did not open")
                pause(3)
                try audit("collections")
            }
        }

        func testAlbums() throws {
            launch(at: "albums")
            pause(8)
            try audit("albums")
        }

        func testSettings() throws {
            launch()
            waitForTiles()
            app.openSettings()
            pause(2)
            try audit("settings")
        }

        func testSearch() throws {
            launch(at: "search")
            pause(6)
            try audit("search")
        }

        func testCleanUp() throws {
            launch(at: "cleanUp")
            pause(8)
            try audit("cleanup")
        }

        func testMemories() throws {
            launch(at: "memories")
            pause(8)
            try audit("memories")
        }

        /// People without Recognize (SPEC §22.3): what People shows while this device looks for people.
        func testPeople() throws {
            launch(at: "people")
            pause(8)
            try audit("people")
        }

        /// The largest accessibility text size: nothing clipped, nothing that does not grow.
        func testLargestTextSize() throws {
            app.launchArguments += Self.largestText
            launch()
            waitForTiles()
            pause(3)
            try audit("xxxl-library")
            app.openSettings()
            pause(2)
            try audit("xxxl-settings")
            app.buttons["settings-done"].firstMatch.tap()
            pause(1)
            if isPad {
                showSidebar()
                pause(2)
                try audit("xxxl-sidebar")
            } else {
                app.tabBars.buttons["Collections"].firstMatch.tap()
                pause(3)
                try audit("xxxl-collections")
            }
            let search = app.tabBars.buttons["Search"].firstMatch
            if search.exists {
                search.tap()
                pause(3)
                try audit("xxxl-search")
            }
        }

        func testLargestTextSizeViewer() throws {
            app.launchArguments += Self.largestText
            launch()
            waitForTiles()
            tiles.element(boundBy: 2).tap()
            XCTAssertTrue(app.buttons["Info"].firstMatch.waitForExistence(timeout: Self.wait), "The viewer did not open")
            pause(3)
            try audit("xxxl-viewer")
            app.buttons["Info"].firstMatch.tap()
            pause(2)
            try audit("xxxl-viewer-info")
        }

        func testLargestTextSizeAlbums() throws {
            app.launchArguments += Self.largestText
            launch(at: "albums")
            pause(8)
            try audit("xxxl-albums")
        }

        func testLargestTextSizeCleanUp() throws {
            app.launchArguments += Self.largestText
            launch(at: "cleanUp")
            pause(8)
            try audit("xxxl-cleanup")
        }

        func testLargestTextSizeMemories() throws {
            app.launchArguments += Self.largestText
            launch(at: "memories")
            pause(8)
            try audit("xxxl-memories")
        }

        // MARK: Helpers

        static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

        private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

        /// Photo tiles of the grid (not the sidebar's rows, which are cells too).
        private var tiles: XCUIElementQuery {
            app.collectionViews.cells.matching(NSPredicate(format: "NOT (label IN %@)", ["Library", "Search", "Settings"]))
        }

        /// Always at a destination: without one the app reopens the place of the previous test.
        private func launch(at destination: String = "library") {
            app.launchEnvironment["PHOTOS_DEBUG_DESTINATION"] = destination
            app.launch()
            // A fresh installation syncs first, with pulsing placeholders that the audit would measure.
            let loading = app.staticTexts["Loading your library…"].firstMatch
            if loading.waitForExistence(timeout: 3) { _ = loading.waitForNonExistence(timeout: 180) }
        }

        private func waitForTiles(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(
                tiles.firstMatch.waitForExistence(timeout: Self.wait), "No photo appeared in the timeline", file: file, line: line)
        }

        private func pause(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        /// The iPad's sidebar ("Show Sidebar" in landscape, "Toggle sidebar" with the tab bar in portrait).
        private func showSidebar() {
            let show = app.buttons["Show Sidebar"].firstMatch
            let toggle = app.buttons["Toggle sidebar"].firstMatch
            if show.exists && show.isHittable {
                show.tap()
            } else if toggle.exists && toggle.isHittable && !app.cells["Library"].exists {
                toggle.tap()
            }
        }

        /// Runs the audit, writes screenshot, tree and findings, and fails on findings the policy does not accept.
        private func audit(_ screen: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let name = prefix + screen
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let shots {
                try? screenshot.pngRepresentation.write(to: shots.appending(path: "\(name).png"))
                try? Data(app.debugDescription.utf8).write(to: shots.appending(path: "\(name).txt"))
            }
            // The system's bars: what is behind their glass, and their own items, are the system's.
            // (The iPad has several navigation bars: the sidebar's and the detail's.)
            let bars = AccessibilityAuditPolicy.Bars(
                tabBar: app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame : nil,
                navigationBars: app.navigationBars.allElementsBoundByIndex.map(\.frame),
                sidebarEdge: screen.hasSuffix("sidebar") && app.cells["Library"].exists ? app.cells["Library"].frame.maxX : nil,
                scrollAreas: (app.collectionViews.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
                    + app.tables.allElementsBoundByIndex).map(\.frame),
                screenshot: ScreenshotSampler(screenshot.image))
            // The handler reads the elements (they are gone afterwards) and nothing else: every query costs time of the
            // audit's own limit ("failed to complete in time"); the policy looks at the findings afterwards.
            var findings: [AccessibilityAuditPolicy.Finding] = []
            // In three parts, each with a time limit of its own (on a busy Mac one audit of everything runs out of time);
            // a part that still runs out is tried twice more after a pause.
            let parts: [XCUIAccessibilityAuditType] = [
                .contrast, [.elementDetection, .hitRegion, .sufficientElementDescription, .trait], [.dynamicType, .textClipped],
            ]
            for part in parts {
                for attempt in 1...3 {
                    var found: [AccessibilityAuditPolicy.Finding] = []
                    do {
                        try app.performAccessibilityAudit(for: part) { issue in
                            found.append(AccessibilityAuditPolicy.Finding(issue))
                            // true: handled here, not reported by XCTest; failures are reported below, all together.
                            return true
                        }
                        findings += found
                        break
                    } catch let error as NSError
                        // -56: the audit's own time limit; XCTFuture 1000: XCTest's limit for the whole audit call.
                        where (error.code == -56 || (error.domain == "com.apple.dt.XCTest.XCTFuture" && error.code == 1000))
                        && attempt < 3
                    {
                        pause(15)
                    }
                }
            }
            var report: [String] = []
            var failures: [String] = []
            for finding in findings {
                let reason = AccessibilityAuditPolicy.accepts(finding, screen: screen, bars: bars)
                report.append((reason.map { "accepted (\($0))" } ?? "FAIL") + " — " + finding.summary)
                if reason == nil { failures.append(finding.summary) }
            }
            if let shots {
                let text = report.isEmpty ? "no findings\n" : report.joined(separator: "\n") + "\n"
                try? Data(text.utf8).write(to: shots.appending(path: "\(name)-audit.txt"))
            }
            guard !survey else { return }
            for failure in failures {
                XCTFail("\(screen): \(failure)", file: file, line: line)
            }
        }
    }

    /// Which audit findings are accepted, and why. Everything else is a bug to fix.
    @MainActor enum AccessibilityAuditPolicy {
        struct Finding {
            var type: XCUIAccessibilityAuditType
            var description: String
            var detail: String
            var elementType: XCUIElement.ElementType?
            var label: String
            var identifier: String
            var frame: CGRect?

            @MainActor init(_ issue: XCUIAccessibilityAuditIssue) {
                type = issue.auditType
                description = issue.compactDescription
                detail = issue.detailedDescription
                let element = issue.element
                elementType = element?.elementType
                label = element?.label ?? ""
                identifier = element?.identifier ?? ""
                frame = element?.frame
            }

            var typeName: String {
                switch type {
                case .contrast: "contrast"
                case .elementDetection: "elementDetection"
                case .hitRegion: "hitRegion"
                case .sufficientElementDescription: "sufficientElementDescription"
                case .dynamicType: "dynamicType"
                case .textClipped: "textClipped"
                case .trait: "trait"
                default: "other(\(type.rawValue))"
                }
            }

            var summary: String {
                let kind = elementType.map { "\($0.rawValue)" } ?? "-"
                let place = frame.map { " at \(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? ""
                return "\(typeName): \(description) [type \(kind), label \"\(label)\", id \"\(identifier)\"\(place)] \(detail)"
            }
        }

        /// Where the system's bars are.
        struct Bars {
            var tabBar: CGRect?
            var navigationBars: [CGRect]
            /// The trailing edge of the iPad's sidebar while it overlays the dimmed Library (portrait).
            var sidebarEdge: CGFloat?
            /// The scrolling areas: a row at their edge is cut off until it is scrolled into view.
            var scrollAreas: [CGRect]
            /// The screen as it was audited, to measure contrast where the audit cannot (glass, materials).
            var screenshot: ScreenshotSampler?
        }

        /// The reason a finding is accepted, or nil when it is a bug.
        static func accepts(_ finding: Finding, screen: String, bars: Bars) -> String? {
            // Photo tiles and the viewer's photo: the pictures are the content; their colours are not ours.
            let isPhoto =
                finding.label.hasPrefix("Photo,") || finding.label.hasPrefix("Video,") || finding.label.hasPrefix("Live Photo,")
            if isPhoto && (finding.type == .contrast || finding.type == .elementDetection) {
                return "a photo's own colours"
            }
            // The audit measured something it cannot name (no element): nothing to look at or fix; it stays in the report.
            if finding.elementType == nil && finding.label.isEmpty {
                return "no element named by the audit"
            }
            // "Nearly passed": 3:1 or more, the system's secondary text colours (section headers, footers, subtitles)
            // as Apple's own apps use them. AA for large text; the app follows Increase Contrast for more. Not memory
            // captions: they are white on a shade of their own (`CaptionScrim`) and must pass.
            if finding.type == .contrast && finding.description.contains("nearly passed") && finding.identifier != "memory-caption" {
                return "system secondary colour, at least 3:1"
            }
            if let frame = finding.frame {
                // Content scrolled under the tab bar's glass is measured against the glass.
                if finding.type == .contrast, let tabBar = bars.tabBar, frame.intersects(tabBar), !tabBar.contains(frame) {
                    return "under the tab bar's glass"
                }
                // A row at the edge of a scroll area (a sheet's last row at the largest size) is cut off until it is
                // scrolled into view: the audit measures its hidden part against what is outside the scroll area.
                if finding.type == .textClipped || finding.type == .contrast,
                    bars.scrollAreas.contains(where: { $0.intersects(frame) && !$0.contains(frame) })
                {
                    return "at the edge of its scroll area"
                }
                // Partly off the screen: the audit measures what is not drawn yet.
                if let screen = bars.screenshot?.bounds, !screen.contains(frame) {
                    return "partly off the screen"
                }
                // Behind the sidebar that overlays it (iPad portrait), the Library is dimmed on purpose.
                if finding.type == .contrast, let edge = bars.sidebarEdge, frame.minX > edge + 8 {
                    return "dimmed behind the sidebar"
                }
                // The Library's memory captions under the sidebar itself (portrait), covered by its glass.
                if finding.type == .contrast, finding.identifier == "memory-caption", let edge = bars.sidebarEdge, frame.minX < edge {
                    return "under the sidebar that overlays the Library"
                }
                let inBar = ([bars.tabBar].compactMap { $0 } + bars.navigationBars).contains(where: {
                    $0.insetBy(dx: -4, dy: -4).contains(frame)
                })
                // Bar buttons keep their size; the system shows them enlarged (Large Content Viewer) instead.
                if finding.type == .dynamicType && inBar {
                    return "bar item, Large Content Viewer"
                }
                // Bar buttons are drawn by the system on its glass; the audit measures their text against the glass
                // around them (the avatar's initials, white on the accent, are measured against the bar). The accent
                // itself is checked in AccentPaletteTests.
                if finding.type == .contrast && inBar {
                    return "bar item on the system's glass"
                }
            }
            // Memory captions on photos (story cards, memory cards, `memory-caption`) are not excused: they stand on an
            // even shade dark enough for 4.5:1 on any photo (`CaptionScrim`), and below the picture at accessibility sizes.
            // Text on a caption plate's glass: the audit measures it against the cover behind the glass (black on the
            // plate measured 15.7:1 in the iPad's screenshot).
            if finding.identifier == "caption-plate", finding.type == .contrast {
                return "on a caption plate's glass, measured in the screenshot"
            }
            // The account row in the sidebar's bottom bar (iPad, Vision Pro; `sidebar-account`). Its name and server are in
            // the text colour and must pass; the badge's initials are white on the accent (6.1:1, AccentPaletteTests), which
            // the audit measures against the glass around the circle, and keep the circle's size (hidden from VoiceOver, the
            // row's label says whose account it is). The system's bottom bar lets its text grow only a little (the rows above
            // reach the largest size): the full name and server are in the row's label and in its menu.
            if finding.identifier == "sidebar-account" {
                if finding.label.count <= 2, finding.type == .contrast || finding.type == .dynamicType {
                    return "the account badge's initials, white on the accent"
                }
                if finding.type == .dynamicType {
                    return "the sidebar's bottom bar, whose text size the system caps"
                }
            }
            // At the default size the audit only guesses what larger sizes would do ("partially unsupported", "may be
            // clipped"); every screen is audited again at the largest size (testLargestTextSize…), where it counts.
            if !screen.hasPrefix("xxxl-"), finding.type == .textClipped || finding.description.contains("partially unsupported") {
                return "checked at the largest text size"
            }
            // The viewer's date pill stops growing at accessibility2 on purpose: it shares the top with the close button;
            // the info panel shows date and time at full size.
            if screen.hasPrefix("xxxl-viewer"), finding.type == .dynamicType, let frame = finding.frame, frame.maxY < 160 {
                return "the viewer's date pill, capped at accessibility2"
            }
            // On glass and materials the audit measures against what is behind them (the photo under the iPad's info
            // inspector). Where the element's own pixels are text on an even background, their contrast is measured in
            // the screenshot instead; a background that varies (text on a photo) is never accepted this way.
            if finding.type == .contrast, let frame = finding.frame, let measured = bars.screenshot?.textContrast(in: frame),
                measured >= 7
            {
                return "measured \(String(format: "%.1f", measured)):1 in the screenshot"
            }
            // Search's start screen stands on the animated living wash, which the audit cannot sample: it reports even
            // the black title. Measured in the screenshot instead: title 18.8:1, the accent buttons 5.3:1.
            if screen.hasSuffix("search"), finding.type == .contrast {
                return "on the living wash, measured in the screenshot"
            }
            // The system's search field cuts its prompt short at large sizes; the prompt is not needed to search.
            if finding.type == .textClipped && finding.elementType == .searchField {
                return "the system search field's prompt"
            }
            return nil
        }
    }

    /// Pixels of a screenshot, to measure the contrast of text on an even background (WCAG 2 luminance).
    struct ScreenshotSampler {
        let width: Int
        let height: Int
        let scale: CGFloat
        let pixels: [UInt8]

        init?(_ image: UIImage) {
            guard let cgImage = image.cgImage else { return nil }
            // Locals: the closure below must not capture `self` before every property is set.
            let width = cgImage.width
            let height = cgImage.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            let drawn: Bool = buffer.withUnsafeMutableBytes { bytes in
                guard
                    let context = CGContext(
                        data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            scale = image.scale
            pixels = buffer
        }

        /// The screen in points.
        var bounds: CGRect { CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale) }

        static func luminance(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Double {
            func linear(_ value: UInt8) -> Double {
                let v = Double(value) / 255
                return v <= 0.040_45 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        /// The contrast of the darkest and lightest pixels in `rect` (points), or nil when the background is not even:
        /// fewer than 60 % of the pixels near the most common luminance.
        func textContrast(in rect: CGRect) -> Double? {
            let x0 = max(0, Int(rect.minX * scale))
            let y0 = max(0, Int(rect.minY * scale))
            let x1 = min(width, Int(rect.maxX * scale))
            let y1 = min(height, Int(rect.maxY * scale))
            guard x1 > x0, y1 > y0 else { return nil }
            var values: [Double] = []
            values.reserveCapacity((x1 - x0) * (y1 - y0))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * width + x) * 4
                    values.append(Self.luminance(pixels[i], pixels[i + 1], pixels[i + 2]))
                }
            }
            values.sort()
            let median = values[values.count / 2]
            let even = values.filter { abs($0 - median) < 0.05 }.count
            guard Double(even) >= 0.6 * Double(values.count) else { return nil }
            // A short word in a wide frame is only a few per cent of its pixels: the 0.5 % at either end, which still
            // ignores single stray pixels.
            let dark = values[values.count / 200]
            let light = values[values.count - 1 - values.count / 200]
            return (light + 0.05) / (dark + 0.05)
        }
    }
#endif

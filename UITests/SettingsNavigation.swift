// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import XCTest

extension XCUIApplication {
    /// The account button in the Library's top bar (SPEC §19.2).
    var accountMenu: XCUIElement { buttons["account-menu"].firstMatch }

    /// Opens Settings, a sheet from the account button since there is no Settings tab (SPEC §19.2). Goes to the
    /// Library's root first (a tap on its tab), where the button is.
    @MainActor func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        let library = tabBars.buttons["Library"].firstMatch
        if library.exists && library.isHittable { library.tap() }
        XCTAssertTrue(accountMenu.waitForExistence(timeout: 20), "No account button", file: file, line: line)
        accountMenu.tap()
        let settings = buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "No Settings in the account menu", file: file, line: line)
        // Until the menu has finished opening: a tap during its animation can miss the item.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        settings.tap()
        XCTAssertTrue(
            buttons["settings-done"].firstMatch.waitForExistence(timeout: 10), "Settings did not open", file: file, line: line)
    }
}

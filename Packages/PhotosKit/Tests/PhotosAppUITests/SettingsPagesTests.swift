// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import PhotosAppUI

/// Settings in pages with a search (SPEC §20.4) and the Advanced features switch.
@Suite struct SettingsPagesTests {
    @Test func everyPageIsListedOnTheFirstScreenOrIsAMacTab() {
        let listed = Set(SettingsPage.listed.flatMap { $0 })
        #expect(listed == [.accounts, .library, .notifications, .backup, .storage, .privacy, .advanced, .about])
        #if os(macOS)
            // General (the Mac's Library and Notifications) and Desktop are Mac tabs (`MacSettingsPage` is Mac only).
            let mac = Set(MacSettingsPage.allCases.map(\.page))
            #expect(mac == [.general, .accounts, .backup, .storage, .privacy, .desktop, .advanced, .about])
            for page in SettingsPage.allCases where page != .all {
                #expect(listed.contains(page) || mac.contains(page), "\(page) cannot be opened")
            }
        #endif
    }

    #if os(macOS)
        @Test func theMacTabsKeepTheirOldNames() {
            // Stored by the Settings window and by the command palette of earlier versions.
            #expect(MacSettingsPage(stored: "general") == .general)
            #expect(MacSettingsPage(stored: "desktop") == .desktop)
            #expect(MacSettingsPage(stored: "about") == .about)
            // Server is part of Accounts now; something unknown opens General.
            #expect(MacSettingsPage(stored: "server") == .accounts)
            #expect(MacSettingsPage(stored: "") == .general)
            #expect(MacSettingsPage(stored: "nonsense") == .general)
            #expect(SettingsPage.notifications.macTab == .general)
            #expect(SettingsPage.library.macTab == .general)
            #expect(SettingsPage.storage.macTab == .storage)
        }
    #endif

    @Test func theSearchFindsSettingsByTitleAndOtherWords() {
        let index = SettingsIndex(entries: SettingsIndex.entries(isMac: false))
        #expect(index.search("cache").contains { $0.page == .storage })
        #expect(index.search("Timeline").contains { $0.page == .library })
        // Words people type that are not in the title.
        #expect(index.search("face id").contains { $0.page == .privacy })
        #expect(index.search("log out").allSatisfy { $0.page == .accounts })
        #expect(!index.search("log out").isEmpty)
        #expect(index.search("stickers").contains { $0.page == .advanced })
        #expect(index.search("google takeout").contains { $0.page == .library })
        // Every word must match; case and accents do not matter.
        #expect(index.search("PREVIEW cáche").count == 1)
        #expect(index.search("cache nonsense").isEmpty)
        #expect(index.search("   ").isEmpty)
    }

    @Test func theSearchListsResultsInPageOrder() {
        let index = SettingsIndex(entries: SettingsIndex.entries(isMac: false))
        let pages = index.search("on").map(\.page)
        let order = SettingsPage.allCases
        #expect(pages == pages.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
    }

    @Test func everyPageOfTheFirstScreenHasSearchableSettings() {
        for isMac in [false, true] {
            let entries = SettingsIndex.entries(isMac: isMac)
            let pages = Set(entries.map(\.page))
            let expected: [SettingsPage] =
                isMac
                ? [.general, .accounts, .backup, .storage, .privacy, .desktop, .advanced, .about]
                : SettingsPage.listed.flatMap { $0 }
            for page in expected { #expect(pages.contains(page), "Nothing on \(page) can be found (Mac: \(isMac))") }
            #expect(Set(entries.map(\.id)).count == entries.count, "An entry is listed twice")
        }
        // The Mac has no Lock Screen album or import from other services in Settings; the menu bar extra is its own.
        #expect(!SettingsIndex.entries(isMac: true).contains { $0.keywords.contains("takeout") })
        #expect(SettingsIndex.entries(isMac: true).contains { $0.keywords.contains("menu bar") })
        #expect(!SettingsIndex.entries(isMac: false).contains { $0.keywords.contains("menu bar") })
    }

    // MARK: Advanced features

    @Test func advancedFeaturesAreOffByDefaultAndHideOnlyTheirRows() {
        #expect(AdvancedFeatures.defaultValue == false)
        #expect(!AdvancedFeatures.lists(.stickers, isOn: false))
        #expect(!AdvancedFeatures.lists(.insights, isOn: false))
        #expect(AdvancedFeatures.lists(.stickers, isOn: true))
        for destination in AppDestination.allCases where destination != .stickers && destination != .insights {
            #expect(AdvancedFeatures.lists(destination, isOn: false), "\(destination) lost its row")
        }
        for feature in AdvancedFeature.allCases {
            #expect(AdvancedFeatures.shows(feature, isOn: true))
            #expect(!AdvancedFeatures.shows(feature, isOn: false))
        }
    }

    @Test func theSwitchIsReadFromTheDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "SettingsPagesTests.\(UUID().uuidString)"))
        #expect(!AdvancedFeatures.isOn(defaults))
        #expect(!AdvancedFeatures.shows(.culling, defaults: defaults))
        defaults.set(true, forKey: AdvancedFeatures.storageKey)
        #expect(AdvancedFeatures.isOn(defaults))
        #expect(AdvancedFeatures.shows(.culling, defaults: defaults))
    }

    @Test func advancedRowsStillOpenFromLinks() {
        // The sidebar's row list is filtered, the destination is not: `SidebarLayout.entry` still leads there.
        let entry = SidebarLayout.entry(for: .stickers, visible: { _ in true })
        #expect(entry.destination == .stickers)
        let customization = SidebarCustomization.standard
        let shown = customization.shownUtilities(visible: { AdvancedFeatures.lists($0, isOn: false) })
        #expect(!shown.contains(.stickers) && !shown.contains(.insights))
        #expect(shown.contains(.cleanUp))
    }
}

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import SwiftUI

/// The features whose entry points only show with Settings › Advanced › "Advanced features" on (SPEC §20.4).
///
/// Nothing is removed: the screens stay destinations, so links, widgets, Shortcuts, the command palette and the Mac's menu
/// bar and keyboard shortcuts open them as before. Only the rows of the sidebar and the Collections list and the items of
/// the menus listed here step back, so the everyday screens stay short. The owner decides what is niche: move a case in
/// or out of `hiddenByDefault` (SPEC §20.4 has the audit with every entry point).
enum AdvancedFeature: String, CaseIterable, Sendable {
    /// The sticker book (sidebar and Collections row) and "Make Sticker" in the viewer (SPEC §15.8.2).
    case stickers
    /// The photographer's statistics (sidebar and Collections row; SPEC §16.5.1).
    case insights
    /// "Make Collage" (album, selection) and "Make Card" (memory; SPEC §15.8.3).
    case collages
    /// "Send as Postcard" in the viewer (SPEC §16.7.1).
    case postcards
    /// Flag and rate in the viewer and the selection, Compare, Loupe, and the Library's Ratings filter (SPEC §15.2, §16.5).
    case culling

    /// Every case today. A feature taken out of this set is always shown, whatever the switch says.
    static let hiddenByDefault: Set<AdvancedFeature> = Set(allCases)

    /// The places whose rows (sidebar, Collections list, iPad sidebar) need the switch.
    var destinations: [AppDestination] {
        switch self {
        case .stickers: [.stickers]
        case .insights: [.insights]
        case .collages, .postcards, .culling: []
        }
    }

    /// Its name in the list under the switch.
    var title: String {
        switch self {
        case .stickers: String(localized: "Stickers", bundle: .module, comment: "Settings › Advanced: a feature the switch shows.")
        case .insights: String(localized: "Insights", bundle: .module, comment: "Settings › Advanced: a feature the switch shows.")
        case .collages:
            String(localized: "Collages and cards", bundle: .module, comment: "Settings › Advanced: a feature the switch shows.")
        case .postcards: String(localized: "Postcards", bundle: .module, comment: "Settings › Advanced: a feature the switch shows.")
        case .culling:
            String(
                localized: "Flags, ratings, Compare and Loupe", bundle: .module,
                comment: "Settings › Advanced: the culling tools the switch shows.")
        }
    }

    var systemImage: String {
        switch self {
        case .stickers: AppDestination.stickers.systemImage
        case .insights: AppDestination.insights.systemImage
        case .collages: "rectangle.3.group"
        case .postcards: "envelope"
        case .culling: "flag"
        }
    }
}

/// The "Advanced features" switch: off by default (SPEC §20.4), on this device.
enum AdvancedFeatures {
    /// `@AppStorage` key; `-advancedFeatures YES` turns it on for a launch (UI tests, screenshots).
    static let storageKey = "advancedFeatures"
    static let defaultValue = false

    /// Whether `feature`'s entry points are shown with the switch at `isOn`.
    static func shows(_ feature: AdvancedFeature, isOn: Bool) -> Bool {
        isOn || !AdvancedFeature.hiddenByDefault.contains(feature)
    }

    /// Whether `destination` has a row in the sidebar and the Collections list with the switch at `isOn`. Places that are
    /// not niche always have one (if the server offers them).
    static func lists(_ destination: AppDestination, isOn: Bool) -> Bool {
        AdvancedFeature.allCases.allSatisfy { feature in !feature.destinations.contains(destination) || shows(feature, isOn: isOn) }
    }

    /// The switch as it is now, for code that builds a list of actions instead of a view (the grid's selection menu).
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? defaultValue
    }

    static func shows(_ feature: AdvancedFeature, defaults: UserDefaults = .standard) -> Bool {
        shows(feature, isOn: isOn(defaults))
    }
}

/// Shows its content only while `feature`'s entry points are shown: a menu item, a toolbar button.
struct AdvancedFeatureGate<Content: View>: View {
    let feature: AdvancedFeature
    @ViewBuilder let content: () -> Content
    @AppStorage(AdvancedFeatures.storageKey) private var isOn = AdvancedFeatures.defaultValue

    init(_ feature: AdvancedFeature, @ViewBuilder content: @escaping () -> Content) {
        self.feature = feature
        self.content = content
    }

    var body: some View {
        if AdvancedFeatures.shows(feature, isOn: isOn) { content() }
    }
}

/// Settings › Advanced: the switch, with what it shows.
struct AdvancedFeaturesSection: View {
    @AppStorage(AdvancedFeatures.storageKey) private var isOn = AdvancedFeatures.defaultValue

    var body: some View {
        Section {
            Toggle(AdvancedFeaturesWording.toggleTitle, isOn: $isOn)
                .accessibilityIdentifier("advanced-features")
            ForEach(AdvancedFeature.allCases.filter(AdvancedFeature.hiddenByDefault.contains), id: \.self) { feature in
                Label(feature.title, systemImage: feature.systemImage)
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
        } header: {
            Text("Advanced features", bundle: .module, comment: "Settings › Advanced: section title.")
        } footer: {
            Text(AdvancedFeaturesWording.footer)
        }
    }
}

enum AdvancedFeaturesWording {
    static var toggleTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Show Advanced Features", bundle: .module, comment: "Settings › Advanced: the switch for the niche features (Mac)."),
            other: LocalizedStringResource(
                "Show advanced features", bundle: .module, comment: "Settings › Advanced: the switch for the niche features."))
    }

    static var footer: String {
        String(
            localized:
                "Adds these tools to the sidebar, the Collections list and the menus. Nothing is removed while it is off: links and Shortcuts still open them.",
            bundle: .module, comment: "Settings › Advanced: footer of the Advanced features switch.")
    }
}

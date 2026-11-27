// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import SwiftUI
import TipKit
import UserNotifications

// Contextual tips (SPEC §22.2): what the first run no longer asks or shows — notifications, backup on the Mac or after
// "Not now", imports, Clean up, Advanced features, the Mac's menu bar extra — comes as a small tip at the top of the
// Library when it helps. Apple's TipKit: each tip is shown until it is closed or used, then never again; at most one new
// tip a day, never on the first launch; Settings › Show Tips turns them all off.

/// The tips, the facts their rules read, and the switch.
public enum AppTips {
    /// `UserDefaults` key of Settings › Show Tips (default on).
    static let showsTipsKey = "tips.shown"

    // Facts the rules read, kept current by the Library (`LibraryTips`) and the switch.
    @Parameter static var showsTips: Bool = true
    @Parameter static var notificationsUndetermined: Bool = false
    @Parameter static var backupOffered: Bool = false
    @Parameter static var menuBarShown: Bool = true
    @Parameter static var advancedFeaturesOn: Bool = true
    @Parameter static var libraryCount: Int = 0

    /// How many times the app was launched on this device: tips wait for the second launch or later (`TipPlan`).
    @Parameter static var launches: Int = 0
    /// `UserDefaults` key of the launch count.
    static let launchesKey = "tips.launches"

    /// Counts this launch and returns the count.
    static func countLaunch(_ defaults: UserDefaults) -> Int {
        let count = defaults.integer(forKey: launchesKey) + 1
        defaults.set(count, forKey: launchesKey)
        return count
    }

    /// Called once at launch. Debug builds signed in by `PHOTOS_DEBUG_LOGIN` (UI tests) show no tips, so a tour does not
    /// depend on which tips are due; `PHOTOS_DEBUG_TIPS=show` shows all of them at once (screenshots, the tips' own tour).
    @MainActor public static func configure() {
        do {
            try Tips.configure([.displayFrequency(TipPlan.frequency)])
        } catch {
            return
        }
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["PHOTOS_DEBUG_TIPS"] == "show" {
                Tips.showAllTipsForTesting()
            } else if environment["PHOTOS_DEBUG_LOGIN"] != nil {
                Tips.hideAllTipsForTesting()
            }
        #endif
        showsTips = UserDefaults.standard.object(forKey: showsTipsKey) as? Bool ?? true
        launches = countLaunch(.standard)
    }

    /// Settings › Show Tips.
    @MainActor static func setShowsTips(_ shown: Bool) {
        UserDefaults.standard.set(shown, forKey: showsTipsKey)
        showsTips = shown
    }
}

/// When each tip may come: which platforms, and from which launch on (testable without TipKit).
public enum TipPlan {
    public enum Kind: String, CaseIterable, Sendable {
        case backup, notifications, menuBar, importLibrary, cleanUp, advancedFeatures
    }

    public enum Platform: Sendable {
        case phone, pad, mac, vision
    }

    /// At most one new tip a day.
    static let frequency: Tips.ConfigurationOption.DisplayFrequency = .daily

    /// The order in the Library: the first that is due is shown.
    public static let order: [Kind] = [.backup, .notifications, .menuBar, .importLibrary, .cleanUp, .advancedFeatures]

    /// The launch from which a tip may come (1 is the first launch: none comes then).
    public static func fromLaunch(_ kind: Kind) -> Int {
        switch kind {
        case .backup, .notifications: 2
        case .menuBar, .importLibrary: 3
        case .cleanUp: 4
        case .advancedFeatures: 6
        }
    }

    /// Clean up is worth it from this many photos and videos on.
    public static let cleanUpMinimumLibrary = 500

    public static func isOffered(_ kind: Kind, on platform: Platform) -> Bool {
        switch kind {
        // Backup reads the device's photo library: not on Vision Pro.
        case .backup: platform != .vision
        case .menuBar: platform == .mac
        case .notifications, .importLibrary, .cleanUp, .advancedFeatures: true
        }
    }

    @MainActor static var platform: Platform {
        #if os(macOS)
            .mac
        #elseif os(visionOS)
            .vision
        #else
            UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        #endif
    }
}

// MARK: - The tips

struct BackupTip: Tip {
    var id: String { "tip-backup" }
    var title: Text {
        #if os(macOS)
            Text("Back up this Mac's photos", bundle: .module, comment: "Tip title (Mac): backup of the Photos library.")
        #else
            Text("Back up this device's photos", bundle: .module, comment: "Tip title: backup was not turned on in the first run.")
        #endif
    }
    var message: Text? {
        Text(
            "New photos and videos go to your Nextcloud by themselves; those already there are not uploaded again.", bundle: .module,
            comment: "Tip message: what backup does.")
    }
    var image: Image? { Image(systemName: "icloud.and.arrow.up") }
    var actions: [Action] {
        [Action(id: "open", title: String(localized: "Set Up Backup", bundle: .module, comment: "Tip button: opens the backup set-up."))]
    }
    var rules: [Rule] {
        let launches = TipPlan.fromLaunch(.backup)
        return [
            #Rule(AppTips.$showsTips) { $0 },
            #Rule(AppTips.$backupOffered) { $0 },
            #Rule(AppTips.$launches) { $0 >= launches },
        ]
    }
}

struct NotificationsTip: Tip {
    var id: String { "tip-notifications" }
    var title: Text { Text("Know when there's something new", bundle: .module, comment: "Tip title: turn on notifications.") }
    var message: Text? {
        Text(
            "Get a notification for the memories of the day and for photos added to your shared albums.", bundle: .module,
            comment: "Tip message: what notifications the app sends.")
    }
    var image: Image? { Image(systemName: "bell.badge") }
    var actions: [Action] {
        [
            Action(
                id: "turn-on",
                title: String(
                    localized: "Turn On Notifications", bundle: .module, comment: "Tip button: asks for the notification permission."))
        ]
    }
    var rules: [Rule] {
        let launches = TipPlan.fromLaunch(.notifications)
        return [
            #Rule(AppTips.$showsTips) { $0 },
            #Rule(AppTips.$notificationsUndetermined) { $0 },
            #Rule(AppTips.$launches) { $0 >= launches },
        ]
    }
}

struct MenuBarTip: Tip {
    var id: String { "tip-menu-bar" }
    var title: Text { Text("Keep Photos in the menu bar", bundle: .module, comment: "Tip title (Mac): the menu bar extra.") }
    var message: Text? {
        Text(
            "Drop photos on it to upload them, and see the backup and today's memory at a glance.", bundle: .module,
            comment: "Tip message (Mac): what the menu bar extra does.")
    }
    var image: Image? { Image(systemName: "menubar.arrow.up.rectangle") }
    var actions: [Action] {
        [
            Action(
                id: "show",
                title: String(localized: "Show in Menu Bar", bundle: .module, comment: "Tip button (Mac): turns the menu bar extra on."))
        ]
    }
    var rules: [Rule] {
        let launches = TipPlan.fromLaunch(.menuBar)
        return [
            #Rule(AppTips.$showsTips) { $0 },
            #Rule(AppTips.$menuBarShown) { !$0 },
            #Rule(AppTips.$launches) { $0 >= launches },
        ]
    }
}

struct ImportLibraryTip: Tip {
    var id: String { "tip-import" }
    var title: Text { Text("Bring your photos home", bundle: .module, comment: "Tip title: import from other services.") }
    var message: Text? {
        Text(
            "Import your exports from Google Photos, iCloud, Facebook or Instagram into your Nextcloud.", bundle: .module,
            comment: "Tip message: what Import Library does.")
    }
    var image: Image? { Image(systemName: "square.and.arrow.down.on.square") }
    var actions: [Action] {
        [Action(id: "import", title: String(localized: "Import Library…", bundle: .module, comment: "Tip button: opens Import Library."))]
    }
    var rules: [Rule] {
        let launches = TipPlan.fromLaunch(.importLibrary)
        return [
            #Rule(AppTips.$showsTips) { $0 },
            #Rule(AppTips.$launches) { $0 >= launches },
        ]
    }
}

struct CleanUpTip: Tip {
    var id: String { "tip-clean-up" }
    var title: Text { Text("Make room on your Nextcloud", bundle: .module, comment: "Tip title: the Clean up screen.") }
    var message: Text? {
        Text(
            "Clean up finds duplicates, similar shots and large videos you may not need.", bundle: .module,
            comment: "Tip message: what Clean up does.")
    }
    var image: Image? { Image(systemName: "sparkles") }
    var actions: [Action] {
        [Action(id: "open", title: String(localized: "Open Clean Up", bundle: .module, comment: "Tip button: opens Clean up."))]
    }
    var rules: [Rule] {
        let launches = TipPlan.fromLaunch(.cleanUp)
        let minimum = TipPlan.cleanUpMinimumLibrary
        return [
            #Rule(AppTips.$showsTips) { $0 },
            #Rule(AppTips.$libraryCount) { $0 >= minimum },
            #Rule(AppTips.$launches) { $0 >= launches },
        ]
    }
}

struct AdvancedFeaturesTip: Tip {
    var id: String { "tip-advanced" }
    var title: Text { Text("More tools when you want them", bundle: .module, comment: "Tip title: Advanced features.") }
    var message: Text? {
        Text(
            "Turn on Advanced features in Settings for Insights, stickers, collages, postcards, flags and ratings.", bundle: .module,
            comment: "Tip message: what Settings › Advanced features shows.")
    }
    var image: Image? { Image(systemName: "slider.horizontal.3") }
    var actions: [Action] {
        [Action(id: "settings", title: String(localized: "Open Settings", bundle: .module, comment: "Tip button: opens Settings."))]
    }
    var rules: [Rule] {
        let launches = TipPlan.fromLaunch(.advancedFeatures)
        return [
            #Rule(AppTips.$showsTips) { $0 },
            #Rule(AppTips.$advancedFeaturesOn) { !$0 },
            #Rule(AppTips.$launches) { $0 >= launches },
        ]
    }
}

// MARK: - In the Library

extension EnvironmentValues {
    /// What a tip's button does that only the window can (`MainView`).
    @Entry var tipActions: TipActions? = nil
}

struct TipActions {
    var importLibrary: @MainActor () -> Void
}

/// The tip that is due, at the top of the Library (above the memories). Nothing when none is.
struct LibraryTips: View {
    let group: TipGroup
    @Environment(AppModel.self) private var app
    @Environment(SessionModel.self) private var session
    @Environment(\.tipActions) private var tipActions
    @Environment(\.showSettings) private var showSettings
    #if os(macOS)
        @Environment(\.openSettings) private var openSettings
    #endif

    /// The tips this platform has, in the order of `TipPlan.order`.
    static func makeGroup() -> TipGroup {
        let platform = TipPlan.platform
        let tips: [any Tip] = TipPlan.order.filter { TipPlan.isOffered($0, on: platform) }.map(tip)
        return TipGroup(.firstAvailable) { tips }
    }

    static func tip(_ kind: TipPlan.Kind) -> any Tip {
        switch kind {
        case .backup: BackupTip()
        case .notifications: NotificationsTip()
        case .menuBar: MenuBarTip()
        case .importLibrary: ImportLibraryTip()
        case .cleanUp: CleanUpTip()
        case .advancedFeatures: AdvancedFeaturesTip()
        }
    }

    var body: some View {
        TipView(group.currentTip) { action in perform(action) }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .task(id: session.account.id) { await updateFacts() }
    }

    /// The facts the rules read, from this device and account.
    func updateFacts() async {
        let backup = session.backup
        AppTips.backupOffered = backup.isAvailable && !backup.settings.isEnabled && backup.settings.filesAppMode != .keepFiles
        AppTips.menuBarShown = UserDefaults.standard.bool(forKey: MenuBarExtraSettings.isShownKey)
        AppTips.advancedFeaturesOn = AdvancedFeatures.isOn()
        AppTips.libraryCount = (try? session.services?.library.count()) ?? 0
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        AppTips.notificationsUndetermined = settings.authorizationStatus == .notDetermined
    }

    func perform(_ action: Tips.Action) {
        let current = group.currentTip
        switch current {
        case is BackupTip:
            BackupSummaryNavigation.openBackup(app: app, openSettings: settingsOpener)
        case is NotificationsTip:
            Task {
                if app.pushEnabled { _ = await PushNotifications.requestAuthorization() } else { await app.setPushEnabled(true) }
            }
        case is MenuBarTip:
            UserDefaults.standard.set(true, forKey: MenuBarExtraSettings.isShownKey)
        case is ImportLibraryTip:
            tipActions?.importLibrary()
        case is CleanUpTip:
            app.requestedDestination = AppDestination.cleanUp.rawValue
        case is AdvancedFeaturesTip:
            #if os(macOS)
                UserDefaults.standard.set(MacSettingsPage.advanced.rawValue, forKey: MacSettingsPage.storageKey)
                openSettings()
            #else
                showSettings?()
            #endif
        default:
            break
        }
        current?.invalidate(reason: .actionPerformed)
    }

    var settingsOpener: (() -> Void)? {
        #if os(macOS)
            { openSettings() }
        #else
            nil
        #endif
    }
}

/// Settings › Show Tips (SPEC §22.2).
struct TipsSettingsSection: View {
    @AppStorage(AppTips.showsTipsKey) private var shown = true

    var body: some View {
        Section {
            Toggle(
                String(localized: "Show Tips", bundle: .module, comment: "Settings switch: the small tips in the Library."), isOn: $shown
            )
            .onChange(of: shown) { _, value in AppTips.setShowsTips(value) }
        } footer: {
            Text(
                "Small tips about backup, notifications, imports and other features appear in the Library when they help, each once.",
                bundle: .module, comment: "Footer of Settings › Show Tips.")
        }
    }
}

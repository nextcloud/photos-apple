// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

// The intents of the Control Center controls and the backup's Live Activity (SPEC §15.4). This file is compiled into the app
// and into the widget extension (`WIDGET_EXTENSION`): the extension needs the types for its controls, the app runs them.
// Each is a `LiveActivityIntent`, which the system performs in the app's process — launched in the background when needed
// — where the backup is, and which may start the Live Activity from there.

#if os(iOS)
    import AppIntents
    import Foundation
    #if !WIDGET_EXTENSION
        import PhotosCore
    #endif

    /// "Back Up Now": a backup pass, with the Live Activity for its progress.
    struct BackUpNowControlIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "Back Up Now"
        static let description = IntentDescription("Uploads new photos of this device to your Nextcloud.")
        /// Shortcuts and Siri have "Back up photos to Nextcloud" (`BackUpNowIntent`), which also says how it went.
        static let isDiscoverable = false
        static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

        @MainActor func perform() async throws -> some IntentResult {
            #if !WIDGET_EXTENSION
                if await BackupPresence.shared.backUpNow(AppHost.model.backup) == .needsSetup {
                    try await continueInForeground(IntentDialog("Turn on backup in Nextcloud Photos first."))
                    AppHost.model.requestedDestination = "backup"
                }
            #endif
            return .result()
        }
    }

    /// The backup's switch in Control Center, on the Lock Screen and on the Action button; also "Turn backup on or off" in
    /// Shortcuts. Turning it on needs a backup that was set up in the app: otherwise the app opens at Backup.
    struct SetBackupIntent: SetValueIntent, LiveActivityIntent {
        static let title: LocalizedStringResource = "Turn Backup On or Off"
        static let description = IntentDescription("Turns the backup of this device's photos to your Nextcloud on or off.")
        static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

        @Parameter(title: "Backup") var value: Bool

        init() {}

        @MainActor func perform() async throws -> some IntentResult {
            #if !WIDGET_EXTENSION
                if await BackupPresence.shared.setBackup(AppHost.model.backup, enabled: value) == .needsSetup {
                    try await continueInForeground(IntentDialog("Set up backup in Nextcloud Photos first."))
                    AppHost.model.requestedDestination = "backup"
                }
            #endif
            return .result()
        }
    }

    /// The Live Activity's "Pause": the user's pause of the running pass; "Back Up Now" goes on.
    struct PauseBackupIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "Pause Backup"
        static let isDiscoverable = false

        @MainActor func perform() async throws -> some IntentResult {
            #if !WIDGET_EXTENSION
                AppHost.model.backup.cancel()
            #endif
            return .result()
        }
    }

    /// "Nextcloud Photos" in Control Center: opens the library.
    struct OpenLibraryControlIntent: AppIntent {
        static let title: LocalizedStringResource = "Open Nextcloud Photos"
        static let isDiscoverable = false
        static let supportedModes: IntentModes = .foreground(.immediate)

        @MainActor func perform() async throws -> some IntentResult {
            #if !WIDGET_EXTENSION
                AppHost.model.requestedDestination = "library"
            #endif
            return .result()
        }
    }
#endif

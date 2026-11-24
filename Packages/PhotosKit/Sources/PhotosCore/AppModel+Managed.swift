// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

// The organisation's device management (MDM, AppConfig; SPEC §5.1.9): applied at launch and whenever the system delivers a
// new configuration while the app runs.

extension AppModel {
    /// Whether "Add account" is offered.
    public var canAddAccount: Bool { managed.allowsAddingAccount(existing: accounts) }

    /// Why a login to this server is not allowed (checked before the browser opens; `addAccount` checks again).
    public func loginRefusal(serverURL: URL) -> LoginRefusal? {
        managed.loginRefusal(serverURL: serverURL)
    }

    /// Follows changes of the managed configuration: the system writes it into the app's defaults, which posts
    /// `UserDefaults.didChangeNotification` (also for every other change of the defaults, so the configuration is compared).
    func observeManagedConfiguration() {
        guard managedObserver == nil else { return }
        managedObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.managedConfigurationChanged() }
        }
    }

    /// Reads the configuration again and applies it when it changed.
    func managedConfigurationChanged() {
        let current = ManagedConfiguration.current(defaults)
        guard current != managed else { return }
        managed = current
        applyManagedConfiguration()
    }

    /// Makes the app follow the configuration: app lock on, no kept log, backup off. Turning a restriction off again changes
    /// nothing by itself (app lock stays on until the user turns it off).
    ///
    /// - Parameter lockDefaults: where the app lock setting is kept (the App Group, so widgets and extensions follow it).
    func applyManagedConfiguration(lockDefaults: UserDefaults = AppLockSettings.defaults) {
        if managed.enforcesAppLock && !lockDefaults.bool(forKey: AppLockSettings.enabledKey) {
            lockDefaults.set(true, forKey: AppLockSettings.enabledKey)
            AppLock.shared.settingChanged()
            // Widgets show a placeholder while app lock is on, and Spotlight has nothing of the app.
            system.reloadWidgets()
            if let session { Task { await session.updateSpotlight(force: true) } }
        }
        if managed.disablesLog {
            let removeLog = system.removeLog
            Task { await removeLog() }
        }
        if managed.disablesBackup && backup.settings.isEnabled {
            backup.disable()
        }
    }
}

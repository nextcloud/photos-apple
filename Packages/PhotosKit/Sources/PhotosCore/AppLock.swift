// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation

#if !os(tvOS)
    import LocalAuthentication
#endif

/// The app lock setting (SPEC §8). It lives in the App Group's defaults, so the widgets and the share extension follow it.
public enum AppLockSettings {
    public static let enabledKey = "appLockEnabled"
    public static let timeoutKey = "appLockTimeout"
    /// "Lock after" when it was never chosen: one minute.
    public static let defaultTimeout: TimeInterval = 60

    /// The App Group's defaults; the app's own where there is no App Group (unsigned development builds, which have no
    /// widgets or extensions that could read it). Settings of earlier versions are moved here once.
    public static var defaults: UserDefaults {
        _ = moved
        return AppPaths.sharedDefaults
    }

    private static let moved: Bool = {
        if AppPaths.usesAppGroup { moveSettings(from: .standard, to: AppPaths.sharedDefaults) }
        return true
    }()

    /// Moves the lock settings written by versions that kept them in the app's own defaults.
    static func moveSettings(from old: UserDefaults, to new: UserDefaults) {
        for key in [enabledKey, timeoutKey] {
            guard let value = old.object(forKey: key) else { continue }
            if new.object(forKey: key) == nil { new.set(value, forKey: key) }
            old.removeObject(forKey: key)
        }
    }

    /// On when the user turned it on, or when the organisation requires it (managed `enforce_passcode_lock`, SPEC §5.1.9;
    /// the app also writes it into the setting, so the widgets and extensions follow).
    public static func isEnabled(_ defaults: UserDefaults = defaults) -> Bool {
        defaults.bool(forKey: enabledKey) || ManagedConfiguration.current().enforcesAppLock
    }

    public static func timeout(_ defaults: UserDefaults = defaults) -> TimeInterval {
        defaults.object(forKey: timeoutKey) as? Double ?? defaultTimeout
    }
}

/// Whether the app is locked. One state for the whole process: every window, the Mac's Settings window and links opened
/// from outside follow it.
///
/// The app locks when it starts with app lock on, and when it comes back after having been away for at least the chosen
/// time ("Immediately": every time). "Away" is the app as a whole in the background on iPhone, iPad and Vision Pro (not a
/// single window), and a window in the background (minimised, app hidden) on the Mac, as before. The system's own
/// authentication prompt is not "away": on the Mac it takes the focus from the app.
@MainActor
@Observable
public final class AppLock {
    public static let shared = AppLock()

    public private(set) var isLocked: Bool
    /// An authentication is on screen; another window asking at the same time would stack a second prompt.
    public private(set) var isAuthenticating = false
    @ObservationIgnored private var awaySince: Date?
    @ObservationIgnored private let settings: () -> (enabled: Bool, timeout: TimeInterval)
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Mac: the windows that are in front. The app is away when none is (all minimised, or the app hidden); the Settings
    /// window closing, or one of two windows being minimised, is not.
    @ObservationIgnored private var activeWindows: Set<UUID> = []

    /// - Parameter settings: the setting; tests pass their own.
    init(settings: @escaping () -> (enabled: Bool, timeout: TimeInterval)) {
        self.settings = settings
        self.isLocked = settings().enabled
    }

    convenience init() {
        self.init(settings: { (AppLockSettings.isEnabled(), AppLockSettings.timeout()) })
    }

    public var isEnabled: Bool { settings().enabled }

    /// The app is locked and app lock is on: nothing of the account may be shown, and links wait.
    public var requiresUnlock: Bool { isLocked && isEnabled }

    /// The app went away (background, or another app became active on the Mac).
    public func didGoAway(now: Date = Date()) {
        let (enabled, timeout) = settings()
        guard enabled, !isAuthenticating else { return }
        if awaySince == nil { awaySince = now }
        if timeout <= 0 { isLocked = true }
    }

    /// Locks when the app has been away for the chosen time. Called when it comes back, and before a link from outside is
    /// handled: that can arrive before the window is active again.
    public func refresh(now: Date = Date()) {
        let (enabled, timeout) = settings()
        guard enabled, let awaySince, now.timeIntervalSince(awaySince) >= timeout else { return }
        isLocked = true
    }

    /// The app is back in front.
    public func didComeBack(now: Date = Date()) {
        refresh(now: now)
        awaySince = nil
    }

    /// Mac: a window became active.
    public func windowDidBecomeActive(_ id: UUID, now: Date = Date()) {
        let wasAway = activeWindows.isEmpty
        activeWindows.insert(id)
        if wasAway { didComeBack(now: now) }
    }

    /// Mac: a window went to the background (minimised, app hidden) or was closed.
    public func windowDidLeave(_ id: UUID, now: Date = Date()) {
        guard activeWindows.remove(id) != nil, activeWindows.isEmpty else { return }
        didGoAway(now: now)
    }

    /// The setting was switched. Switching it on doesn't lock at once (the user is looking at the app); off ends a lock.
    public func settingChanged() {
        if !isEnabled {
            isLocked = false
            awaySince = nil
        }
    }

    /// Asks for Face ID, Touch ID, Optic ID or the device passcode / login password; unlocks when it is given.
    /// - Parameter reason: what the system's prompt says.
    @discardableResult
    public func unlock(reason: String) async -> Bool {
        guard requiresUnlock else { return true }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        #if !os(tvOS)
            let context = LAContext()
            let granted = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
        #else
            // Apple TV has no device owner authentication; its app has no lock (SPEC §15.3).
            let granted = true
        #endif
        if granted {
            isLocked = false
            awaySince = nil
        }
        return granted
    }

    /// Unlocks without asking (tests).
    func unlockForTesting() { isLocked = false }

    /// Follows the app going to the background and coming back (iPhone, iPad, Vision Pro; the Mac's windows report it
    /// themselves). Called once by the app at launch.
    public func observeApplication() {
        #if !os(macOS)
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            let away = NSNotification.Name("UIApplicationDidEnterBackgroundNotification")
            let back = NSNotification.Name("UIApplicationWillEnterForegroundNotification")
            observers.append(
                center.addObserver(forName: away, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.didGoAway() }
                })
            observers.append(
                center.addObserver(forName: back, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.didComeBack() }
                })
        #endif
    }
}

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import Observation
import PhotosBackup

#if canImport(WidgetKit)
    import WidgetKit
#endif
#if os(iOS)
    import ActivityKit
    import UIKit
#endif

/// The kinds of the widgets and controls outside the app (SPEC §15.4); the app reloads them by these names.
public enum AmbientKinds {
    public static let photoFrame = "photoFrame"
    public static let backupStatus = "backupStatus"
    public static let backupToggle = "backupToggle"
    public static let backUpNow = "backUpNow"
    public static let openLibrary = "openLibrary"
}

/// Keeps the backup visible outside the app (SPEC §15.4): the snapshot the backup widget and the Control Center toggle
/// read, and the Live Activity while a larger pass runs (iPhone and iPad).
@MainActor public final class BackupPresence {
    public static let shared = BackupPresence()

    private var observation: Task<Void, Never>?
    private var lastSnapshot: BackupWidgetSnapshot?
    private var lastWidgetReload: Date?
    private let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")
    let snapshotFile: URL
    /// The widget reloads; tests count them instead.
    var reload: @MainActor (_ switched: Bool) -> Void = BackupPresence.systemReload
    #if os(iOS)
        public let liveActivity = BackupLiveActivity()
    #endif

    init(snapshotFile: URL = BackupWidgetSnapshot.file()) {
        self.snapshotFile = snapshotFile
    }

    /// Starts following the app's backup. Called once at launch, also for a launch in the background.
    public func start(_ backup: BackupModel) {
        // No backup on Vision Pro.
        guard !Self.isVisionOS, observation == nil else { return }
        #if os(iOS)
            liveActivity.attach(defaults: backup.app?.defaults ?? .standard)
        #endif
        observation = Task { [weak self, weak backup] in
            guard let backup else { return }
            let changes = Observations { () -> Change in
                Change(status: backup.status, settings: backup.settings, inContinuedTask: backup.isInContinuedTask)
            }
            for await change in changes {
                guard let self else { return }
                self.changed(change)
            }
        }
    }

    static var isVisionOS: Bool {
        #if os(visionOS)
            true
        #else
            false
        #endif
    }

    struct Change: Sendable, Equatable {
        var status: BackupStatus
        var settings: BackupSettings
        var inContinuedTask: Bool
    }

    private func changed(_ change: Change) {
        let snapshot = BackupWidgetSnapshot(settings: change.settings, status: change.status)
        writeSnapshot(snapshot)
        #if os(iOS)
            liveActivity.statusChanged(change.status, inContinuedTask: change.inContinuedTask)
        #endif
    }

    /// Writes the snapshot when what it shows changed, and asks the widget and the controls to read it again: at once
    /// for a new phase or switch, otherwise at most once a minute (WidgetKit limits reloads in the background).
    func writeSnapshot(_ snapshot: BackupWidgetSnapshot, now: Date = Date()) {
        if let last = lastSnapshot, last.sameContent(as: snapshot) { return }
        let important = BackupPresencePolicy.isImportantChange(from: lastSnapshot, to: snapshot)
        if !important, let last = lastSnapshot, now.timeIntervalSince(last.written) < BackupPresencePolicy.snapshotInterval { return }
        do {
            try snapshot.save(to: snapshotFile)
        } catch {
            logger.notice("backup: the status for widgets could not be written")
            return
        }
        let switched = lastSnapshot?.isEnabled != snapshot.isEnabled || lastSnapshot?.isSetUp != snapshot.isSetUp
        lastSnapshot = snapshot
        guard important || lastWidgetReload.map({ now.timeIntervalSince($0) >= BackupPresencePolicy.reloadInterval }) ?? true else {
            return
        }
        lastWidgetReload = now
        reload(switched)
    }

    /// Asks WidgetKit to read the snapshot again: the backup widget, and the backup switch when it changed.
    static func systemReload(_ switched: Bool) {
        #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: AmbientKinds.backupStatus)
            #if os(iOS)
                if switched { ControlCenter.shared.reloadControls(ofKind: AmbientKinds.backupToggle) }
            #endif
        #endif
    }
}

/// When the backup snapshot is rewritten and the widgets reloaded.
public enum BackupPresencePolicy {
    /// Progress within a phase is written at most this often.
    public static let snapshotInterval: TimeInterval = 30
    /// … and the widget is reloaded at most this often for it.
    public static let reloadInterval: TimeInterval = 60

    /// A new phase, the backup switched on or off, or set up: shown at once.
    public static func isImportantChange(from old: BackupWidgetSnapshot?, to new: BackupWidgetSnapshot) -> Bool {
        guard let old else { return true }
        return old.isEnabled != new.isEnabled || old.isSetUp != new.isSetUp || old.state?.phase != new.state?.phase
    }
}

// MARK: - Actions of the controls and intents

extension BackupPresence {
    /// What a "Back up now" from a control, the Action button or Siri found.
    public enum BackUpNowResult: Sendable, Equatable {
        case started
        /// Backup is not set up or switched off: the app has to be opened.
        case needsSetup
        case unavailable
    }

    /// Starts a pass the user asked for outside the app and waits a little, so that the Live Activity can be started
    /// while the intent runs (the system allows it then, with the app in the background). The pass goes on afterwards.
    public func backUpNow(_ backup: BackupModel, wait: Duration = .seconds(20)) async -> BackUpNowResult {
        guard backup.isAvailable else { return .unavailable }
        guard backup.settings.isEnabled else { return .needsSetup }
        #if os(iOS)
            liveActivity.noteUserRequest()
        #endif
        let pass = Task { await backup.startBackup() }
        #if os(iOS)
            // Until the Live Activity shows, the pass is over, or the time is up; the pass itself goes on.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await pass.value }
                group.addTask { try? await Task.sleep(for: wait) }
                group.addTask { await self.waitForLiveActivity() }
                await group.next()
                group.cancelAll()
            }
        #else
            _ = pass
        #endif
        return .started
    }

    #if os(iOS)
        private func waitForLiveActivity() async {
            while !Task.isCancelled, !liveActivity.isShowing { try? await Task.sleep(for: .milliseconds(250)) }
        }
    #endif

    /// Turns backup on or off from the Control Center toggle. Turning it on needs a backup that was set up in the app.
    public func setBackup(_ backup: BackupModel, enabled: Bool) async -> BackUpNowResult {
        guard backup.isAvailable else { return .unavailable }
        if !enabled {
            backup.disable()
            return .started
        }
        guard backup.settings.accountId != nil, backup.settings.filesAppMode != .keepFiles else { return .needsSetup }
        backup.update { $0.isEnabled = true }
        return await backUpNow(backup)
    }
}

#if os(iOS)
    /// The backup's Live Activity: what the Lock Screen and the Dynamic Island show while a pass runs (SPEC §15.4).
    public struct BackupActivityAttributes: ActivityAttributes {
        public typealias ContentState = BackupActivityState

        public init() {}
    }

    /// An activity, for the task that updates or ends it.
    ///
    /// `@unchecked Sendable`: ActivityKit does not declare `Activity` Sendable, but its calls may be made from any thread;
    /// the handle only carries it to a detached task that makes one call.
    struct ActivityHandle: @unchecked Sendable {
        let activity: Activity<BackupActivityAttributes>
    }

    /// Starts, updates and ends the backup's Live Activity from the engine's status.
    ///
    /// It starts for a pass that uploads at least `BackupActivityPolicy.minimumItems` (or one the user started outside
    /// the app), never while a continued processing task shows the system's own progress, never after the user swiped it
    /// away during the same pass, and not when the user switched it off (here or in Settings › Nextcloud Photos).
    @MainActor public final class BackupLiveActivity {
        public static let settingKey = "backup.liveActivity"

        private var activity: Activity<BackupActivityAttributes>?
        private var lastState: BackupActivityState?
        private var lastUpdate: Date?
        private var wasRunning = false
        private var dismissedThisPass = false
        private var userRequested = false
        private var defaults: UserDefaults = .standard
        private var dismissWatch: Task<Void, Never>?
        private let logger = Logger(subsystem: "com.nextcloud.photos", category: "backup")

        /// The in-app switch (Backup › Show on Lock Screen); on by default.
        public var isEnabled: Bool {
            get { defaults.object(forKey: Self.settingKey) as? Bool ?? true }
            set {
                defaults.set(newValue, forKey: Self.settingKey)
                if !newValue { end(immediately: true) }
            }
        }

        /// The system allows Live Activities for the app.
        public var isAllowedBySystem: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

        var isShowing: Bool { activity != nil }

        func attach(defaults: UserDefaults) {
            self.defaults = defaults
            // Activities of an earlier run of the app: their pass is over (or continues as a new one).
            for old in Activity<BackupActivityAttributes>.activities {
                let handle = ActivityHandle(activity: old)
                Task.detached { await handle.activity.end(nil, dismissalPolicy: .immediate) }
            }
        }

        /// The next pass was started by the user outside the app: it gets an activity even when it is small.
        func noteUserRequest() { userRequested = true }

        func statusChanged(_ status: BackupStatus, inContinuedTask: Bool) {
            let running = status.isRunning
            if running, !wasRunning { dismissedThisPass = false }
            wasRunning = running
            guard let state = BackupActivityState(status: status) else {
                end(immediately: true)
                return
            }
            // The continued processing task shows the system's own progress for the same pass.
            if inContinuedTask {
                end(immediately: true)
                return
            }
            if activity != nil {
                if state.isFinal {
                    end(with: state)
                    userRequested = false
                } else if BackupActivityPolicy.shouldUpdate(from: lastState, to: state, last: lastUpdate, now: Date()) {
                    update(state)
                }
                return
            }
            if state.isFinal { userRequested = false }
            // The system only allows a start while the app is in front, or from the intent the user ran.
            guard isEnabled, !dismissedThisPass, isAllowedBySystem,
                userRequested || UIApplication.shared.applicationState == .active,
                BackupActivityPolicy.shouldStart(state, userRequested: userRequested)
            else { return }
            request(state)
        }

        private func content(_ state: BackupActivityState) -> ActivityContent<BackupActivityState> {
            ActivityContent(state: state, staleDate: state.isFinal ? nil : Date().addingTimeInterval(BackupActivityPolicy.staleAfter))
        }

        private func request(_ state: BackupActivityState) {
            do {
                let activity = try Activity.request(attributes: BackupActivityAttributes(), content: content(state), pushType: nil)
                self.activity = activity
                lastState = state
                lastUpdate = Date()
                logger.notice("backup: Live Activity started")
                watchDismissal(activity)
            } catch {
                // Not in front and not from an intent, too many activities, or switched off in Settings.
                logger.notice("backup: no Live Activity: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// A swipe on the Lock Screen ends the activity for this pass.
        private func watchDismissal(_ activity: Activity<BackupActivityAttributes>) {
            dismissWatch?.cancel()
            dismissWatch = Task { [weak self] in
                for await state in activity.activityStateUpdates {
                    guard state == .dismissed || state == .ended else { continue }
                    guard let self, self.activity?.id == activity.id else { return }
                    if state == .dismissed { self.dismissedThisPass = true }
                    self.activity = nil
                    self.lastState = nil
                    return
                }
            }
        }

        private func update(_ state: BackupActivityState) {
            guard let activity else { return }
            lastState = state
            lastUpdate = Date()
            let content = content(state)
            let handle = ActivityHandle(activity: activity)
            Task.detached { await handle.activity.update(content) }
        }

        private func end(with state: BackupActivityState) {
            guard let activity else { return }
            self.activity = nil
            lastState = nil
            dismissWatch?.cancel()
            let policy: ActivityUIDismissalPolicy
            switch BackupActivityPolicy.dismissalDelay(state) {
            case .none: policy = .default
            case .some(let delay) where delay <= 0: policy = .immediate
            case .some(let delay): policy = .after(Date().addingTimeInterval(delay))
            }
            let content = content(state)
            let handle = ActivityHandle(activity: activity)
            Task.detached { await handle.activity.end(content, dismissalPolicy: policy) }
            logger.notice("backup: Live Activity ended")
        }

        private func end(immediately: Bool) {
            guard let activity else { return }
            self.activity = nil
            lastState = nil
            dismissWatch?.cancel()
            let handle = ActivityHandle(activity: activity)
            Task.detached { await handle.activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
#endif

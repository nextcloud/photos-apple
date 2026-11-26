// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(iOS)
    import BackgroundTasks
    import OSLog
    import PhotosCore
    import UIKit

    /// Background refresh and processing (SPEC §4.4, §7.18.6).
    enum BackgroundTasks {
        static let refresh = "com.nextcloud.photos.refresh"
        static let processing = "com.nextcloud.photos.processing"
        static let logger = Logger(subsystem: "com.nextcloud.photos", category: "background")

        /// The work of both background tasks: a sync, then a backup pass.
        ///
        /// When the system takes the time away, the task this runs in is cancelled (by the expiration handler of the
        /// processing task; SwiftUI does it for the refresh task). The sync stops with its task. The backup pass is
        /// interrupted, which is not the user's pause: it stays due and goes on with the next task or in the foreground.
        ///
        /// - Parameter sync: false when only the backup is to go on (the short time after finished uploads).
        @MainActor static func run(sync: Bool = true) async {
            let app = AppHost.model
            await withTaskCancellationHandler {
                if sync { await app.session?.syncNow() }
                guard !Task.isCancelled else { return }
                await app.backup.runInBackground()
            } onCancel: {
                Task { @MainActor in await interruptBackup() }
            }
        }

        @MainActor static func runRefresh() async {
            schedule()
            await run()
            // With what the sync brought: the first screens, today's memories and recent albums (SPEC §18.3.2).
            await SmartOfflineScheduling.prepareForNextOpen(model: AppHost.model)
            // A new day: the watch gets its photos without the app being opened.
            await WatchBridge.shared.update()
        }

        /// Stops the backup pass because the background time is over. Not while the app is in front: there the pass may go on.
        /// Not while the pass runs in a continued processing task either: that task has time of its own and ends it.
        @MainActor static func interruptBackup() async {
            let backup = AppHost.model.backup
            guard UIApplication.shared.applicationState != .active, !backup.isInContinuedTask else { return }
            await backup.interrupt()
        }

        /// Uses the short time the system grants outside the foreground (after it reported finished uploads, or when the
        /// app has just left the screen) for a backup pass: it records what arrived and hands the next files to the
        /// system. When the time is over the pass is interrupted; what it handed over goes on.
        @MainActor static func continueBackup(_ application: UIApplication) {
            guard application.applicationState != .active, AppHost.model.backup.settings.isEnabled else { return }
            let work = Task { @MainActor in await run(sync: false) }
            let identifier = application.beginBackgroundTask(withName: "Backup") { work.cancel() }
            Task { @MainActor in
                await work.value
                application.endBackgroundTask(identifier)
            }
        }

        /// Requests the next refresh and a longer processing window (network required) for backup and reconciliation.
        static func schedule() {
            let refreshRequest = BGAppRefreshTaskRequest(identifier: refresh)
            refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            BGTaskScheduler.shared.submitLoggingErrors(refreshRequest, logger: logger)
            let processingRequest = BGProcessingTaskRequest(identifier: processing)
            processingRequest.requiresNetworkConnectivity = true
            processingRequest.requiresExternalPower = false
            BGTaskScheduler.shared.submitLoggingErrors(processingRequest, logger: logger)
        }
    }

    /// A completion handler of UIKit, which is not declared Sendable.
    ///
    /// `@unchecked Sendable`: it is only passed along and then called on the main actor, where UIKit expects it.
    struct SystemCompletion: @unchecked Sendable {
        let call: () -> Void
    }

    final class AppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
        )
            -> Bool
        {
            // Creates the app model now: a launch in the background shows no window that would do it.
            _ = AppHost.model
            // Today's photos for the Apple Watch app (SPEC §15.3).
            WatchBridge.shared.start(app: AppHost.model)
            BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTasks.processing, using: nil) { task in
                let work = Task { @MainActor in await BackgroundTasks.run() }
                task.expirationHandler = { work.cancel() }
                Task {
                    await work.value
                    task.setTaskCompleted(success: !work.isCancelled)
                    BackgroundTasks.schedule()
                }
            }
            BackgroundTasks.schedule()
            // On-device recognition for search, while charging and idle (opt-in).
            ContentLabeling.register { AppHost.model }
            // On-device feature prints for "Show Similar" and key photos, while charging and idle.
            SimilarIndexing.register { AppHost.model }
            // Descriptions of photos for VoiceOver and search, while charging and idle (SPEC §16.2).
            PhotoDescriptions.register { AppHost.model }
            // Smart offline fills up while charging on Wi-Fi (SPEC §15.8.1).
            SmartOfflineScheduling.register { AppHost.model }
            // A backup pass that is running when the app leaves the screen gets the time to hand its next files to the system.
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    if AppHost.model.backup.status.isRunning { BackgroundTasks.continueBackup(UIApplication.shared) }
                }
            }
            PushNotifications.install(delegate: NotificationRouter.shared) { UIApplication.shared.registerForRemoteNotifications() }
            return true
        }

        func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
            AppHost.model.didRegisterForPush(deviceToken: deviceToken)
        }

        /// Uploads of the backup's background transfer session have finished while the app was suspended or not running.
        func application(
            _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void
        ) {
            let done = SystemCompletion(call: completionHandler)
            AppHost.model.handleBackgroundUploadEvents(identifier: identifier) { done.call() }
            BackgroundTasks.continueBackup(application)
        }

        /// Silent pushes withdraw notifications that were read or dismissed elsewhere (SPEC §7.21). Needs the
        /// `remote-notification` background mode.
        func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
            -> UIBackgroundFetchResult
        {
            let subject = userInfo["subject"] as? String
            return await AppHost.model.handleBackgroundPush(subject: subject) ? .newData : .noData
        }
    }
#endif

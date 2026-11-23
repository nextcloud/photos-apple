// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if os(iOS)
    import BackgroundTasks
    import PhotosCore
    import UIKit

    /// Background refresh and processing (SPEC §4.4, §7.18.6).
    enum BackgroundTasks {
        static let refresh = "com.nextcloud.photos.refresh"
        static let processing = "com.nextcloud.photos.processing"

        /// The work of both background tasks: a sync, then a backup pass.
        ///
        /// When the system takes the time away, the task this runs in is cancelled (by the expiration handler of the
        /// processing task; SwiftUI does it for the refresh task). The sync stops with its task. The backup pass is
        /// interrupted, which is not the user's pause: it stays due and goes on with the next task or in the foreground.
        @MainActor static func run() async {
            let app = AppHost.model
            await withTaskCancellationHandler {
                await app.session?.syncNow()
                guard !Task.isCancelled else { return }
                await app.backup.runInBackground()
            } onCancel: {
                Task { @MainActor in await interruptBackup() }
            }
        }

        @MainActor static func runRefresh() async {
            schedule()
            await run()
        }

        /// Stops the backup pass because the background time is over. Not while the app is in front: there the pass may go on.
        @MainActor static func interruptBackup() async {
            guard UIApplication.shared.applicationState != .active else { return }
            await AppHost.model.backup.interrupt()
        }

        /// Requests the next refresh and a longer processing window (network required) for backup and reconciliation.
        static func schedule() {
            let refreshRequest = BGAppRefreshTaskRequest(identifier: refresh)
            refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            try? BGTaskScheduler.shared.submit(refreshRequest)
            let processingRequest = BGProcessingTaskRequest(identifier: processing)
            processingRequest.requiresNetworkConnectivity = true
            processingRequest.requiresExternalPower = false
            try? BGTaskScheduler.shared.submit(processingRequest)
        }
    }

    final class AppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
        )
            -> Bool
        {
            // Creates the app model now: a launch in the background shows no window that would do it.
            _ = AppHost.model
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
            PushNotifications.install(delegate: NotificationRouter.shared) { UIApplication.shared.registerForRemoteNotifications() }
            return true
        }

        func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
            AppHost.model.didRegisterForPush(deviceToken: deviceToken)
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

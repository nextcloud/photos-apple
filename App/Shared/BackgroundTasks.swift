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

        @MainActor static func runRefresh() async {
            schedule()
            guard let session = AppDelegate.app?.session else { return }
            await session.syncNow()
            await session.backup.runInBackground()
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
        @MainActor static var app: AppModel?

        func application(
            _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
        )
            -> Bool
        {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTasks.processing, using: nil) { task in
                let work = Task { @MainActor in
                    guard let session = AppDelegate.app?.session else { return }
                    await session.syncNow(forceReconcile: false)
                    await session.backup.runInBackground()
                }
                task.expirationHandler = {
                    work.cancel()
                    Task { @MainActor in AppDelegate.app?.session?.backup.cancel() }
                }
                Task {
                    await work.value
                    task.setTaskCompleted(success: !work.isCancelled)
                    BackgroundTasks.schedule()
                }
            }
            BackgroundTasks.schedule()
            return true
        }
    }
#endif

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosNetworking
import PhotosStore
import Synchronization

/// The session's `notify_push` connection (SPEC §22.4.3): when the server has the app, a change made elsewhere is synced
/// a few seconds later instead of at the next periodic sync. Silent without it.
struct NotifyPushState {
    var task: Task<Void, Never>?
    /// The login went through and the connection has not dropped since.
    var isConnected = false
    /// The server refused the login: not tried again in this session.
    var refused = false
    /// A sync asked for by the server is waiting for its quiet moment.
    var syncScheduled = false
    /// When the last such sync started.
    var lastSync: Date?
}

extension SessionModel {
    /// The wait after a change before the sync: a folder copied elsewhere sends many changes; they make one sync.
    static let pushSyncDelay: Duration = .seconds(2)
    /// The shortest time between two syncs a server asked for (a backup of another device sends changes all the time).
    static let pushSyncMinimumInterval: TimeInterval = 15

    /// Opens the connection when the server announces `notify_push`; nothing otherwise.
    func startNotifyPush() {
        guard let services, !isStopped, notifyPush.task == nil else { return }
        let connection = services.api.connection
        let session = services.http.session
        let ocs = services.ocs
        notifyPush.task = Task { [weak self] in
            guard let endpoint = try? await NotifyPush.endpoint(ocs: ocs) else {
                await MainActor.run { self?.notifyPush.task = nil }
                return
            }
            let listener = NotifyPushListener(
                endpoint: endpoint, loginName: connection.loginName, password: connection.appPassword
            ) { url in URLSessionNotifyPushSocket(url: url, session: session, userAgent: connection.userAgent) }
            let end = await listener.run(
                onConnected: { [weak self] in await MainActor.run { self?.notifyPush.isConnected = true } },
                { [weak self] event in await self?.notifyPushEvent(event) })
            await MainActor.run {
                self?.notifyPush.isConnected = false
                // A refused login is not tried again in this session; a cancelled listener is restarted by its owner.
                if case .refused = end { self?.notifyPush.refused = true } else { self?.notifyPush.task = nil }
            }
        }
    }

    func stopNotifyPush() {
        notifyPush.task?.cancel()
        notifyPush = NotifyPushState()
    }

    /// Back in the foreground: a connection the system closed meanwhile (iPhone, iPad) is opened again at once instead
    /// of after its backoff.
    func resumeNotifyPushIfDropped() {
        guard notifyPush.task != nil, !notifyPush.isConnected, !notifyPush.refused else { return }
        stopNotifyPush()
        startNotifyPush()
    }

    func notifyPushEvent(_ event: NotifyPush.Event) {
        guard case .filesChanged = event, !isStopped, !notifyPush.syncScheduled else { return }
        notifyPush.syncScheduled = true
        let wait: Duration =
            notifyPush.lastSync.map { last in
                let left = Self.pushSyncMinimumInterval - Date().timeIntervalSince(last)
                return left > 0 ? .milliseconds(Int(left * 1000)) : Self.pushSyncDelay
            } ?? Self.pushSyncDelay
        Task { [weak self] in
            try? await Task.sleep(for: max(wait, Self.pushSyncDelay))
            guard let self, !self.isStopped else { return }
            self.notifyPush.syncScheduled = false
            self.notifyPush.lastSync = Date()
            // A window that cannot be seen syncs when it comes back (`didBecomeActive`).
            guard ForegroundState.shared.isVisible else { return }
            // Deletes and moves too, at once (a targeted walk), unless this device's own backup is uploading: its
            // uploads are what the server reports, and the walk waits for it as usual.
            await self.syncNow(reconcile: self.backup.isPassRunning ? .ifDue : .opened)
        }
    }
}

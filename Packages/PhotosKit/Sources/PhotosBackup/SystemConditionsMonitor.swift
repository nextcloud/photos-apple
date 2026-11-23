// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Network

/// Reports the network path and Low Power Mode to the backup engine while it lives.
final class SystemConditionsMonitor: Sendable {
    private let pathMonitor = NWPathMonitor()
    private let powerTask: Task<Void, Never>

    init(network: @escaping @Sendable (BackupNetwork) -> Void, lowPower: @escaping @Sendable (Bool) -> Void) {
        pathMonitor.pathUpdateHandler = { path in
            network(BackupNetwork(isConnected: path.status == .satisfied, isExpensive: path.isExpensive, isConstrained: path.isConstrained))
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.nextcloud.photos.backup.path"))
        powerTask = Task {
            lowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
            for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange).map({ _ in () }) {
                lowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
            }
        }
    }

    deinit {
        pathMonitor.cancel()
        powerTask.cancel()
    }
}

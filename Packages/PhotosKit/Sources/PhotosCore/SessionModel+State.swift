// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import PhotosModel
import PhotosNetworking
import PhotosStore

/// The server presents a certificate that neither the system nor the user trusts: it changed since the login.
public struct CertificateProblem: Sendable, Equatable, Identifiable {
    public var id: String { host }
    public var host: String
    /// The leaf certificate the server presented (DER).
    public var certificate: Data

    public init(host: String, certificate: Data) {
        self.host = host
        self.certificate = certificate
    }
}

extension SyncStatus {
    /// The state without its counters, for the log.
    var logName: String {
        switch self {
        case .idle: "idle"
        case .initialSync: "initialSync"
        case .syncing: "syncing"
        case .reconciling: "reconciling"
        case .offline: "offline"
        case .failed: "failed"
        }
    }
}

/// Account state the UI shows over cached content: a failing sync, a changed certificate (SPEC §6.3).
extension SessionModel {
    private static let stateLogger = Logger(subsystem: "com.nextcloud.photos", category: "session")

    /// Called for every status the sync engine publishes.
    func syncStatusChanged(from previous: SyncStatus?, to status: SyncStatus) {
        if previous?.logName != status.logName {
            Self.stateLogger.info("sync: \(previous?.logName ?? "-", privacy: .public) → \(status.logName, privacy: .public)")
        }
        // A sync that stopped (failed, offline, cancelled) may have stopped at the certificate; one that ran through
        // has been shown an acceptable certificate, which ends the refusal.
        if !status.isWorking { refreshCertificateProblem() }
    }

    /// Asks the transport whether it refuses the certificate of this account's server.
    public func refreshCertificateProblem() {
        guard let host = account.serverURL.host(), let certificate = app?.http.rejectedCertificate(for: host) else {
            if certificateProblem != nil { Self.stateLogger.notice("certificate: accepted again") }
            certificateProblem = nil
            return
        }
        let problem = CertificateProblem(host: host, certificate: certificate)
        if certificateProblem != problem {
            Self.stateLogger.error("certificate: the server presents a certificate that is not trusted")
            certificateProblem = problem
        }
    }

    /// The user looked at the changed certificate and accepts it: trust it for this host and sync again.
    public func trust(_ problem: CertificateProblem) async {
        guard let app else { return }
        do {
            try app.http.trustStore.trust(certificate: problem.certificate, for: problem.host)
        } catch {
            Self.stateLogger.error("certificate: could not store the trusted certificate: \(error.localizedDescription, privacy: .public)")
        }
        Self.stateLogger.notice("certificate: trusted by the user")
        certificateProblem = nil
        await refreshFeatures()
        await syncNow()
    }
}

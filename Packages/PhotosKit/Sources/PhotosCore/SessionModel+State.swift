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
    /// The certificate the user had trusted for this host (a certificate the system doesn't trust that was replaced). Nil when
    /// the system trusted the server: then the new certificate can't be accepted from this dialog (`canTrustInApp`).
    public var previouslyTrusted: Data?
    /// The certificate the server presented before, when the app saw it during this run (for the comparison in the dialog).
    public var previous: Data?

    public init(host: String, certificate: Data, previouslyTrusted: Data? = nil, previous: Data? = nil) {
        self.host = host
        self.certificate = certificate
        self.previouslyTrusted = previouslyTrusted
        self.previous = previous ?? previouslyTrusted
    }

    /// Accepting the new certificate in place is offered only when the user had trusted a certificate of this host already:
    /// a self-signed certificate that was renewed. A server whose certificate the system trusted, and that now presents one it
    /// doesn't, is what someone intercepting the connection looks like; trusting it takes a new login (SPEC §8).
    public var canTrustInApp: Bool { previouslyTrusted != nil }
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
        // A sync that stopped (failed, offline, cancelled) may have stopped at the certificate; one that ran through got
        // answers, which ends the refusal (`HTTPClient` clears it on every response, also on a connection that was open).
        if !status.isWorking { refreshCertificateProblem() }
    }

    /// Asks the transport whether it refuses the certificate of this account's server.
    public func refreshCertificateProblem() {
        guard let host = account.serverURL.host(), let certificate = app?.http.rejectedCertificate(for: host) else {
            if certificateProblem != nil { Self.stateLogger.notice("certificate: accepted again") }
            certificateProblem = nil
            return
        }
        let store = app?.http.trustStore
        let problem = CertificateProblem(
            host: host, certificate: certificate, previouslyTrusted: store?.trustedCertificate(for: host),
            previous: store?.lastAccepted(for: host))
        if certificateProblem != problem {
            Self.stateLogger.error("certificate: the server presents a certificate that is not trusted")
            certificateProblem = problem
        }
    }

    /// The user compared the old and the new certificate and explicitly accepted the new one: trust it for this host and
    /// sync again. Nothing has been sent to the server with this certificate before (the connection was refused at the
    /// handshake), so the app password only goes to it from here on. Refused when the server was trusted by the system.
    public func trust(_ problem: CertificateProblem) async {
        guard let app, problem.canTrustInApp else {
            Self.stateLogger.error("certificate: a certificate of a server the system trusted can only be accepted by logging in again")
            return
        }
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

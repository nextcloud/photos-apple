// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import PhotosStore
import SwiftUI

/// What the banner over a grid says about the account (SPEC §4.6, §6.3). One thing at a time, the most urgent first.
enum GridBanner: Equatable {
    /// The login is no longer valid; the cached library is still shown.
    case signedOut
    /// The server presents a certificate that is not trusted.
    case certificateChanged(host: String)
    /// Changes the server refused.
    case failedChanges(Int)
    case syncFailed(message: String)
    case offline
    /// The first sync is still running behind a grid that already shows photos.
    case loading(Int)

    /// - Parameter hasItems: the grid shows photos. Without any, the screen's empty state says what is wrong
    ///   ("Signed out", the sync error) and a banner would say it twice.
    static func resolve(
        isSignedOut: Bool, certificateHost: String?, failedChanges: Int, status: SyncStatus, hasItems: Bool
    ) -> GridBanner? {
        if isSignedOut { return hasItems ? .signedOut : nil }
        if let certificateHost { return .certificateChanged(host: certificateHost) }
        if failedChanges > 0 { return .failedChanges(failedChanges) }
        switch status {
        case .failed(let message, _): return hasItems ? .syncFailed(message: message) : nil
        case .offline: return .offline
        case .initialSync(let count): return hasItems ? .loading(count) : nil
        case .idle, .syncing, .reconciling: return nil
        }
    }
}

/// What the first sync says about its progress: "Loading your library — 12,000 of 48,213" where the server tells the
/// total (the day counts of the extended Photos API), else how many arrived so far.
enum InitialSyncProgress {
    static func text(count: Int, total: Int?) -> String {
        let fetched = count.formatted()
        // The day counts leave out shared folders, so the sync can find more than they promised: then no total.
        if let total, total > 0, count <= total {
            return String(
                localized: "Loading your library — \(fetched) of \(total.formatted())", bundle: .module,
                comment: "Progress of the first sync: photos and videos loaded so far, and how many there are")
        }
        if count > 0 {
            return String(
                localized: "Loading your library — \(fetched)", bundle: .module,
                comment: "Progress of the first sync when the total is not known: photos and videos loaded so far")
        }
        return String(localized: "Loading your library…", bundle: .module)
    }
}

/// The banner at the bottom of a grid: failed sync, revoked login, changed certificate, failed changes, offline.
struct GridStatusBanner: View {
    let hasItems: Bool
    @Environment(SessionModel.self) private var session
    @State private var relogin = false
    @State private var reviewedCertificate: CertificateProblem?

    var banner: GridBanner? {
        GridBanner.resolve(
            isSignedOut: session.isSignedOut, certificateHost: session.certificateProblem?.host,
            failedChanges: session.failedOperations.count, status: session.syncStatus, hasItems: hasItems)
    }

    var body: some View {
        Group {
            switch banner {
            case .signedOut:
                bar(
                    String(localized: "Signed out – showing saved photos", bundle: .module),
                    systemImage: "person.crop.circle.badge.exclamationmark"
                ) {
                    Button(String(localized: "Log in again", bundle: .module)) { relogin = true }
                }
            case .certificateChanged:
                bar(
                    String(localized: "The server's certificate changed", bundle: .module),
                    systemImage: "lock.trianglebadge.exclamationmark"
                ) {
                    Button(String(localized: "Review…", bundle: .module)) { reviewedCertificate = session.certificateProblem }
                }
            case .failedChanges(let count):
                bar(
                    String(localized: "\(count) changes couldn't be saved on the server.", bundle: .module),
                    systemImage: "exclamationmark.icloud"
                ) {
                    Button(String(localized: "Retry", bundle: .module)) { Task { await session.retryFailedOperations() } }
                    Button(String(localized: "Discard", bundle: .module), role: .destructive) {
                        Task { await session.discardFailedOperations() }
                    }
                }
            case .syncFailed(let message):
                bar(
                    String(localized: "Couldn't sync", bundle: .module), detail: message,
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                ) {
                    Button(String(localized: "Retry", bundle: .module)) { Task { await session.syncNow() } }
                }
            case .offline:
                pill(String(localized: "Offline – showing saved photos", bundle: .module), systemImage: "wifi.slash")
            case .loading(let count):
                pill(
                    InitialSyncProgress.text(count: count, total: session.initialSyncTotal), systemImage: "arrow.triangle.2.circlepath")
            case nil:
                EmptyView()
            }
        }
        .sheet(isPresented: $relogin) { AddAccountSheet() }
        .certificateReview($reviewedCertificate) { problem in
            Task { await session.trust(problem) }
        }
    }

    func bar(_ title: String, detail: String? = nil, systemImage: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
            }
            // Title and reason are read as one thing; the buttons stay separate controls.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            actions()
        }
        .font(.callout)
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    func pill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .capsule)
            .padding(.bottom, 12)
    }
}

/// Wording of the confirmation for an undoable change.
enum ChangeNoticeText {
    static func text(_ notice: ChangeNotice, trashbin: Bool) -> String {
        let count = notice.change.count
        if notice.isReverted {
            if notice.failures > 0 {
                return String(localized: "\(notice.failures) items couldn't be restored from the trash bin.", bundle: .module)
            }
            switch notice.change.kind {
            case .delete: return String(localized: "Restored \(count) items", bundle: .module)
            default: return String(localized: "Change undone", bundle: .module)
            }
        }
        switch notice.change.kind {
        case .favorite: return String(localized: "Added \(count) items to favorites", bundle: .module)
        case .unfavorite: return String(localized: "Removed \(count) items from favorites", bundle: .module)
        case .archive: return String(localized: "Archived \(count) items", bundle: .module)
        case .unarchive: return String(localized: "Unarchived \(count) items", bundle: .module)
        case .removeFromAlbum: return String(localized: "Removed \(count) items from the album", bundle: .module)
        case .delete:
            return trashbin
                ? String(localized: "Moved \(count) items to the trash bin", bundle: .module)
                : String(localized: "Deleted \(count) items", bundle: .module)
        }
    }

    /// How long the confirmation stays.
    static let duration: Duration = .seconds(7)
}

/// "Archived 3 items · Undo": shown for a few seconds after a change; Edit › Undo (⌘Z, shake) does the same.
struct ChangeNoticeToast: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        if let notice = session.lastChange {
            let text: String = ChangeNoticeText.text(notice, trashbin: session.features.has(.trashbin))
            HStack(spacing: 12) {
                Text(text)
                if notice.isReverting {
                    // Undo runs (a delete waits for the server): no second Undo meanwhile.
                    Divider().frame(height: 14)
                    ProgressView().controlSize(.small)
                } else if notice.canUndo && !notice.isReverted {
                    Divider().frame(height: 14)
                    Button(String(localized: "Undo", bundle: .module)) { Task { await session.undo(notice) } }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .capsule)
            .padding(.bottom, 12)
            .transition(.opacity)
            .task(id: notice.id) {
                AccessibilityNotification.Announcement(text).post()
                try? await Task.sleep(for: ChangeNoticeText.duration)
                if !Task.isCancelled { session.dismissNotice(notice.id) }
            }
        }
    }
}

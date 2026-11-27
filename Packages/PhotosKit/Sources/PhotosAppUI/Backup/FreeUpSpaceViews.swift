// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import PhotosCore
import SwiftUI

// Free up space on this device (SPEC §7.18.8, §22.1): the screen, the review grid, and the offer on the Backup screen.

/// "Free up space on this iPhone/iPad/Mac": how much the photos and videos that are safely on the server take, which
/// stay and why, the keep options, and the removal (checked against the server once more; the system asks; Recently
/// Deleted).
struct FreeUpSpaceView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plan: FreeUpPlan?
    @State private var progress: FreeUpProgress?
    @State private var error: String?
    /// Photos the user chose to keep in the review.
    @State private var excluded: Set<String> = []
    @State private var confirming = false
    @State private var removing = false
    @State private var result: FreeUpRemoval?

    var chosen: [FreeUpCandidate] { plan?.candidates.filter { !excluded.contains($0.id) } ?? [] }

    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.byteSize } }

    var body: some View {
        let backup = session.backup
        Form {
            headline
            if let result { FreeUpResultSection(result: result) }
            FreeUpOptionsSection()
                .disabled(removing)
            if let plan, plan.keptCount > 0 { FreeUpKeptSection(kept: plan.kept) }
        }
        .formStyle(.grouped)
        .navigationTitle(DeviceWording.freeUpTitle)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: backup.freeUpOptions) { await check() }
        .confirmationDialog(
            DeviceWording.confirmTitle(chosen.count), isPresented: $confirming, titleVisibility: .visible
        ) {
            Button(DeviceWording.removeButton, role: .destructive) { Task { await remove() } }
        } message: {
            Text(FreeUpWording.confirmMessage(bytes: chosenBytes))
        }
    }

    @ViewBuilder var headline: some View {
        Section {
            if let error {
                Text(error).foregroundStyle(.red)
                Button(String(localized: "Try again", bundle: .module)) { Task { await check() } }
            } else if removing || plan == nil {
                FreeUpProgressRow(progress: progress, removing: removing)
            } else if let plan, plan.candidates.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(FreeUpWording.nothingTitle, systemImage: "checkmark.circle")
                        .font(.headline)
                    Text(FreeUpWording.nothingExplanation(keptCount: plan.keptCount))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("freeUp.nothing")
            } else if let plan {
                FreeUpHeadline(bytes: chosenBytes, count: chosen.count, reduceMotion: reduceMotion)
                NavigationLink {
                    FreeUpReviewView(candidates: plan.candidates, excluded: $excluded)
                } label: {
                    FreeUpPreviewStrip(candidates: chosen, excludedCount: excluded.count)
                }
                .accessibilityIdentifier("freeUp.review")
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    Label(FreeUpWording.removeButton(bytes: chosenBytes), systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                // The symbol in the same red as the title.
                .tint(.red)
                .disabled(chosen.isEmpty)
                .accessibilityIdentifier("freeUp.remove")
            }
        } footer: {
            Text(FreeUpWording.footer)
        }
    }

    func check() async {
        error = nil
        plan = nil
        progress = nil
        let reporter = FreeUpProgressReporter { value in progress = value }
        do {
            let checked = try await session.backup.freeUpPlan { value in reporter.report(value) }
            // Kept choices of the review hold as long as the photo is still offered.
            excluded.formIntersection(Set(checked.candidates.map(\.id)))
            plan = checked
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove() async {
        let chosen = chosen
        guard !chosen.isEmpty else { return }
        removing = true
        progress = nil
        result = nil
        defer { removing = false }
        let reporter = FreeUpProgressReporter { value in progress = value }
        do {
            // Checked against the server once more right before (with checksums); the system asks again.
            result = try await session.backup.removeFromDevice(chosen) { value in reporter.report(value) }
            excluded = []
            await check()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Hands progress from the check's task to the main actor.
private struct FreeUpProgressReporter: Sendable {
    let update: @MainActor @Sendable (FreeUpProgress) -> Void

    func report(_ value: FreeUpProgress) {
        Task { @MainActor in update(value) }
    }
}

/// The size in large type and what it is.
private struct FreeUpHeadline: View {
    let bytes: Int64
    let count: Int
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(Formatters.bytes(bytes))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .snappy, value: bytes)
            Text(FreeUpWording.headline(count: count))
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("freeUp.headline")
    }
}

/// A few of the photos that would go, leading to the review.
private struct FreeUpPreviewStrip: View {
    let candidates: [FreeUpCandidate]
    let excludedCount: Int
    @ScaledMetric(relativeTo: .body) private var side = 44.0

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: -side / 4) {
                // The newest of them: the ones the user is most likely to recognise.
                ForEach(Array(candidates.suffix(5).reversed())) { candidate in
                    LocalAssetThumbnail(localIdentifier: candidate.localIdentifier)
                        .frame(width: side, height: side)
                        .clipShape(.rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.background, lineWidth: 1.5))
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(FreeUpWording.reviewTitle)
                if excludedCount > 0 {
                    Text(FreeUpWording.keptByChoice(excludedCount))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Listing folders, hashing photos, or waiting for the first answer.
private struct FreeUpProgressRow: View {
    let progress: FreeUpProgress?
    let removing: Bool

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading) {
                Text(removing ? FreeUpWording.recheckTitle : FreeUpWording.checkTitle)
                if let detail = FreeUpWording.progress(progress) {
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("freeUp.progress")
    }
}

/// What happened after a removal.
private struct FreeUpResultSection: View {
    let result: FreeUpRemoval

    var body: some View {
        Section {
            if result.removed > 0 {
                Label(FreeUpWording.removed(result.removed, bytes: result.bytes), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(FreeUpWording.recentlyDeleted).font(.subheadline).foregroundStyle(.secondary)
            } else if result.declined {
                Text(FreeUpWording.declined).foregroundStyle(.secondary)
            }
            if result.stayed > 0 {
                Text(FreeUpWording.stayedAfterRecheck(result.stayed)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("freeUp.result")
    }
}

/// The keep options (a preference of this device).
struct FreeUpOptionsSection: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        let backup = session.backup
        let recent: Binding<FreeUpKeepPeriod> = Binding(
            get: { backup.freeUpOptions.keepRecent }, set: { value in backup.freeUpOptions.keepRecent = value })
        let favorites: Binding<Bool> = Binding(
            get: { backup.freeUpOptions.keepFavorites }, set: { value in backup.freeUpOptions.keepFavorites = value })
        let hidden: Binding<Bool> = Binding(
            get: { backup.freeUpOptions.keepHidden }, set: { value in backup.freeUpOptions.keepHidden = value })
        Section {
            Picker(FreeUpWording.recentLabel, selection: recent) {
                ForEach(FreeUpKeepPeriod.allCases) { period in
                    Text(FreeUpWording.period(period)).tag(period)
                }
            }
            .accessibilityIdentifier("freeUp.keepRecent")
            Toggle(FreeUpWording.favoritesLabel, isOn: favorites)
                .accessibilityIdentifier("freeUp.keepFavorites")
            Toggle(FreeUpWording.hiddenLabel, isOn: hidden)
                .accessibilityIdentifier("freeUp.keepHidden")
        } header: {
            Text(FreeUpWording.keepHeader)
        } footer: {
            Text(FreeUpWording.alwaysKept)
        }
    }
}

/// The photos that stay, by reason, with their count and size.
private struct FreeUpKeptSection: View {
    let kept: [FreeUpKeepReason: FreeUpTally]

    var body: some View {
        Section {
            ForEach(kept.keys.sorted(), id: \.self) { reason in
                if let tally = kept[reason] {
                    LabeledContent {
                        Text(FreeUpWording.tally(tally)).monospacedDigit()
                    } label: {
                        Label(FreeUpWording.reason(reason), systemImage: FreeUpWording.symbol(reason))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text(FreeUpWording.keptHeader)
        } footer: {
            if kept[.notVerified] != nil || kept[.incomplete] != nil || kept[.editNotBackedUp] != nil {
                Text(FreeUpWording.keptFooter)
            }
        }
    }
}

// MARK: - Review

/// The photos and videos that would be removed; a tap keeps one on the device.
struct FreeUpReviewView: View {
    let candidates: [FreeUpCandidate]
    @Binding var excluded: Set<String>
    @ScaledMetric(relativeTo: .body) private var tileSize = 96.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(FreeUpWording.reviewHint)
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 2)], spacing: 2) {
                    ForEach(candidates) { candidate in
                        FreeUpReviewTile(candidate: candidate, isKept: excluded.contains(candidate.id)) {
                            if excluded.contains(candidate.id) {
                                excluded.remove(candidate.id)
                            } else {
                                excluded.insert(candidate.id)
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(FreeUpWording.reviewTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if excluded.isEmpty {
                    Button(FreeUpWording.keepAll) { excluded = Set(candidates.map(\.id)) }
                } else {
                    Button(FreeUpWording.removeAll) { excluded = [] }
                }
            }
        }
    }
}

private struct FreeUpReviewTile: View {
    let candidate: FreeUpCandidate
    let isKept: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            LocalAssetThumbnail(localIdentifier: candidate.localIdentifier)
                .aspectRatio(1, contentMode: .fit)
                .opacity(isKept ? 0.45 : 1)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isKept ? "circle" : "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .shadow(radius: 2)
                        .padding(5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(FreeUpWording.tileLabel(candidate)))
        .accessibilityValue(Text(isKept ? FreeUpWording.tileKept : FreeUpWording.tileRemoved))
        .accessibilityAddTraits(isKept ? [] : .isSelected)
    }
}

// MARK: - The offer

/// The offer on the Backup screen once everything is backed up (SPEC §22.1): "Free up 3.2 GB on this iPhone".
struct FreeUpOfferSection: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        let backup = session.backup
        if let estimate = backup.freeUpEstimate, estimate.isWorthOffering, backup.canFreeUp, case .upToDate = backup.status.phase {
            Section {
                NavigationLink {
                    FreeUpSpaceView()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "internaldrive")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FreeUpWording.offerTitle(bytes: estimate.bytes)).font(.headline)
                            Text(FreeUpWording.offerDetail(count: estimate.count))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("freeUp.offer")
            }
        }
    }
}

// MARK: - Wording

/// Texts of free up. Those that name the device come in iPhone, iPad and Mac versions (native wording per platform).
@MainActor enum FreeUpWording {
    static var nothingTitle: String {
        String(localized: "Nothing to remove right now", bundle: .module, comment: "Free up space: no photo can be removed.")
    }

    static func nothingExplanation(keptCount: Int) -> String {
        keptCount > 0
            ? String(
                localized:
                    "Your options keep every photo that is on your Nextcloud, or they are not verified there yet. See below what stays.",
                bundle: .module, comment: "Free up space: nothing can be removed, but backed-up photos stay for the reasons listed below.")
            : String(
                localized: "Once your photos and videos are backed up to your Nextcloud, you can remove them here.", bundle: .module,
                comment: "Free up space: nothing is backed up yet.")
    }

    static var footer: String {
        String(
            localized:
                "Only photos and videos whose files are all on your Nextcloud with exactly the same size are offered: original, edited version, RAW and Live Photo. Right before they are removed they are checked again, with checksums where your Nextcloud has them.",
            bundle: .module, comment: "Footer of Free up space: which photos are offered for removal.")
    }

    static func headline(count: Int) -> String {
        switch DeviceWording.kind {
        case .iPhone:
            String(
                localized: "\(count) photos and videos are safely on your Nextcloud and can be removed from this iPhone.", bundle: .module,
                comment: "Free up space: below the size that can be freed (iPhone). The placeholder is the number of items.")
        case .iPad:
            String(
                localized: "\(count) photos and videos are safely on your Nextcloud and can be removed from this iPad.", bundle: .module,
                comment: "Free up space: below the size that can be freed (iPad). The placeholder is the number of items.")
        case .mac:
            String(
                localized:
                    "\(count) photos and videos are safely on your Nextcloud and can be removed from the Photos library of this Mac.",
                bundle: .module, comment: "Free up space: below the size that can be freed (Mac). The placeholder is the number of items.")
        }
    }

    static func removeButton(bytes: Int64) -> String {
        String(
            localized: "Free Up \(Formatters.bytes(bytes))", bundle: .module,
            comment: "Free up space: the button that removes the chosen photos from the device. The placeholder is a size.")
    }

    static func confirmMessage(bytes: Int64) -> String {
        String(
            localized:
                "This frees about \(Formatters.bytes(bytes)). They stay on your Nextcloud. The system asks you once more and keeps them in Recently Deleted for 30 days. If you use iCloud Photos, they are also removed from iCloud and your other devices.",
            bundle: .module, comment: "Free up space: confirmation message. The placeholder is a size.")
    }

    static var reviewTitle: String {
        String(
            localized: "Review Photos and Videos", bundle: .module,
            comment: "Free up space: opens the grid of the photos that would be removed; also its title.")
    }

    static func keptByChoice(_ count: Int) -> String {
        String(
            localized: "\(count) kept by you", bundle: .module,
            comment: "Free up space: how many photos the user chose to keep in the review.")
    }

    static var checkTitle: String {
        String(
            localized: "Checking which photos are on your Nextcloud…", bundle: .module,
            comment: "Free up space: shown while the server copies are checked.")
    }

    static var recheckTitle: String {
        String(
            localized: "Checking once more with your Nextcloud…", bundle: .module,
            comment: "Free up space: the check right before the photos are removed.")
    }

    static func progress(_ progress: FreeUpProgress?) -> String? {
        switch progress {
        case .listing(let done, let total):
            String(
                localized: "Folder \(done) of \(total)", bundle: .module,
                comment: "Free up space: progress of the server check, in server folders.")
        case .hashing(let done, let total):
            String(
                localized: "Comparing checksums: \(done) of \(total)", bundle: .module,
                comment: "Free up space: the device's files are compared with the server's checksums. Placeholders: done, total.")
        case nil: nil
        }
    }

    static func removed(_ count: Int, bytes: Int64) -> String {
        String(
            localized: "\(count) photos and videos (\(Formatters.bytes(bytes))) moved to Recently Deleted.", bundle: .module,
            comment:
                "Free up space: result after removing. Placeholders: number of items, size. Recently Deleted is the album of Apple's Photos app."
        )
    }

    static var recentlyDeleted: String {
        String(
            localized: "The space comes free when Recently Deleted is emptied: in the Photos app, or by itself after 30 days.",
            bundle: .module,
            comment: "Free up space: after removing. Recently Deleted is the album of Apple's Photos app.")
    }

    static var declined: String {
        String(localized: "Nothing was removed.", bundle: .module, comment: "Free up space: the user declined the system's question.")
    }

    static func stayedAfterRecheck(_ count: Int) -> String {
        String(
            localized: "\(count) stayed because they changed since the first check.", bundle: .module,
            comment: "Free up space: photos left out by the check right before removing.")
    }

    static var recentLabel: String {
        String(localized: "Recent photos", bundle: .module, comment: "Free up space option: how long new photos stay on the device.")
    }

    static func period(_ period: FreeUpKeepPeriod) -> String {
        switch period {
        case .none: String(localized: "None", bundle: .module, comment: "Free up space option: recent photos are not kept for their age.")
        case .week: String(localized: "Last 7 days", bundle: .module, comment: "Free up space option: keep photos of the last 7 days.")
        case .month: String(localized: "Last 30 days", bundle: .module, comment: "Free up space option: keep photos of the last 30 days.")
        case .threeMonths:
            String(localized: "Last 3 months", bundle: .module, comment: "Free up space option: keep photos of the last 3 months.")
        case .sixMonths:
            String(localized: "Last 6 months", bundle: .module, comment: "Free up space option: keep photos of the last 6 months.")
        case .year: String(localized: "Last year", bundle: .module, comment: "Free up space option: keep photos of the last 12 months.")
        }
    }

    static var favoritesLabel: String {
        String(localized: "Favorites", bundle: .module, comment: "Free up space option: favourites stay on the device.")
    }

    static var hiddenLabel: String {
        String(localized: "Hidden photos", bundle: .module, comment: "Free up space option: photos hidden in the Photos app stay.")
    }

    static var keepHeader: String {
        switch DeviceWording.kind {
        case .iPhone:
            String(localized: "Keep on this iPhone", bundle: .module, comment: "Free up space: header of the keep options (iPhone).")
        case .iPad: String(localized: "Keep on this iPad", bundle: .module, comment: "Free up space: header of the keep options (iPad).")
        case .mac: String(localized: "Keep on this Mac", bundle: .module, comment: "Free up space: header of the keep options (Mac).")
        }
    }

    static var alwaysKept: String {
        String(
            localized: "Items of shared albums, and edited photos whose edit is not on your Nextcloud, always stay.", bundle: .module,
            comment: "Free up space: footer of the keep options.")
    }

    static var keptHeader: String {
        switch DeviceWording.kind {
        case .iPhone:
            String(localized: "Staying on this iPhone", bundle: .module, comment: "Free up space: header of the photos that stay (iPhone).")
        case .iPad:
            String(localized: "Staying on this iPad", bundle: .module, comment: "Free up space: header of the photos that stay (iPad).")
        case .mac:
            String(localized: "Staying on this Mac", bundle: .module, comment: "Free up space: header of the photos that stay (Mac).")
        }
    }

    static func reason(_ reason: FreeUpKeepReason) -> String {
        switch reason {
        case .notInLibrary:
            String(
                localized: "Shared albums and synced photos", bundle: .module,
                comment: "Free up space: photos that stay because they belong to a shared album or were synced from a computer.")
        case .hidden: String(localized: "Hidden", bundle: .module, comment: "Free up space: photos that stay because they are hidden.")
        case .favorite:
            String(localized: "Favorites", bundle: .module, comment: "Free up space: photos that stay because they are favourites.")
        case .recent:
            String(localized: "Recent", bundle: .module, comment: "Free up space: photos that stay because they are recent.")
        case .editNotBackedUp:
            String(
                localized: "Edit not backed up", bundle: .module,
                comment: "Free up space: edited photos that stay because the edit is not on the server.")
        case .incomplete:
            String(
                localized: "Not completely backed up", bundle: .module,
                comment: "Free up space: photos that stay because a part (RAW, Live Photo, original) is not on the server.")
        case .notVerified:
            String(
                localized: "Not verified on your Nextcloud", bundle: .module,
                comment: "Free up space: photos that stay because the server does not have exactly the same file right now.")
        }
    }

    static func symbol(_ reason: FreeUpKeepReason) -> String {
        switch reason {
        case .notInLibrary: "person.2"
        case .hidden: "eye.slash"
        case .favorite: "heart"
        case .recent: "clock"
        case .editNotBackedUp: "slider.horizontal.3"
        case .incomplete: "icloud.slash"
        case .notVerified: "exclamationmark.shield"
        }
    }

    static func tally(_ tally: FreeUpTally) -> String {
        String(
            localized: "\(tally.count) · \(Formatters.bytes(tally.bytes))", bundle: .module,
            comment: "Free up space: count and size of photos that stay for one reason.")
    }

    static var keptFooter: String {
        String(
            localized:
                "Your Nextcloud does not have exactly the same file of these right now: a copy converted to JPEG, a photo found by its name only, a part that is missing, or a file changed since. They stay until backup has uploaded them.",
            bundle: .module, comment: "Free up space: footer explaining photos that are not verified or not completely backed up.")
    }

    static var reviewHint: String {
        switch DeviceWording.kind {
        case .iPhone:
            String(localized: "Tap a photo to keep it on this iPhone.", bundle: .module, comment: "Free up space review: hint (iPhone).")
        case .iPad:
            String(localized: "Tap a photo to keep it on this iPad.", bundle: .module, comment: "Free up space review: hint (iPad).")
        case .mac:
            String(localized: "Click a photo to keep it on this Mac.", bundle: .module, comment: "Free up space review: hint (Mac).")
        }
    }

    static var keepAll: String {
        String(localized: "Deselect All", bundle: .module, comment: "Free up space review: keep every photo on the device.")
    }

    static var removeAll: String {
        String(localized: "Select All", bundle: .module, comment: "Free up space review: remove every offered photo again.")
    }

    static func tileLabel(_ candidate: FreeUpCandidate) -> String {
        let size = Formatters.bytes(candidate.byteSize)
        guard let date = candidate.createdAt else { return size }
        return String(
            localized: "\(date.formatted(date: .abbreviated, time: .shortened)), \(size)", bundle: .module,
            comment: "Free up space review: VoiceOver label of a photo. Placeholders: when it was taken, its size.")
    }

    static var tileKept: String {
        String(localized: "Stays", bundle: .module, comment: "Free up space review: VoiceOver value of a photo the user keeps.")
    }

    static var tileRemoved: String {
        String(localized: "Will be removed", bundle: .module, comment: "Free up space review: VoiceOver value of a photo that goes.")
    }

    static func offerTitle(bytes: Int64) -> String {
        let size = Formatters.bytes(bytes)
        return switch DeviceWording.kind {
        case .iPhone:
            String(
                localized: "Free up \(size) on this iPhone", bundle: .module,
                comment: "Backup screen: the offer to remove backed-up photos (iPhone). The placeholder is a size.")
        case .iPad:
            String(
                localized: "Free up \(size) on this iPad", bundle: .module,
                comment: "Backup screen: the offer to remove backed-up photos (iPad). The placeholder is a size.")
        case .mac:
            String(
                localized: "Free up \(size) on this Mac", bundle: .module,
                comment: "Backup screen: the offer to remove backed-up photos (Mac). The placeholder is a size.")
        }
    }

    static func offerDetail(count: Int) -> String {
        String(
            localized: "\(count) photos and videos are safely on your Nextcloud.", bundle: .module,
            comment: "Backup screen: below the offer to free up space. The placeholder is the number of items.")
    }

    /// The account menu once everything is backed up and enough can be freed.
    static func summary(bytes: Int64) -> String {
        String(
            localized: "All backed up · Free up \(Formatters.bytes(bytes))", bundle: .module,
            comment:
                "Account menu: every photo is on the server, and backed-up photos can be removed from the device. The placeholder is a size."
        )
    }
}

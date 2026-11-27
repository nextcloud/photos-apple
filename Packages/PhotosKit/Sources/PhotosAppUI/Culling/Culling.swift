// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Observation
import PhotosCore
import PhotosModel
import SwiftUI

// MARK: - Wording

/// Names of ratings, flags and filters (SPEC §15.2). The tags on the server have fixed names ("★★★", "Pick",
/// "Rejected"); people see these instead.
enum CullingWording {
    static func flagTitle(_ flag: CullingFlag) -> String {
        switch flag {
        case .pick:
            PlatformWording.title(
                mac: LocalizedStringResource("Pick", bundle: .module, comment: "Culling: flag the photo as a keeper (key P). Mac menu."),
                other: LocalizedStringResource("Pick", bundle: .module, comment: "Culling: flag the photo as a keeper (key P)."))
        case .reject:
            PlatformWording.title(
                mac: LocalizedStringResource("Reject", bundle: .module, comment: "Culling: flag the photo as rejected (key X). Mac menu."),
                other: LocalizedStringResource("Reject", bundle: .module, comment: "Culling: flag the photo as rejected (key X)."))
        case .none:
            PlatformWording.title(
                mac: LocalizedStringResource("Unflag", bundle: .module, comment: "Culling: remove Pick or Reject (key U). Mac menu."),
                other: LocalizedStringResource("Unflag", bundle: .module, comment: "Culling: remove Pick or Reject (key U)."))
        }
    }

    static func flagSymbol(_ flag: CullingFlag) -> String {
        switch flag {
        case .pick: "flag.fill"
        case .reject: "xmark.circle"
        case .none: "flag.slash"
        }
    }

    /// "3 Stars", "No Rating".
    static func ratingTitle(_ stars: Int) -> String {
        stars == 0
            ? PlatformWording.title(
                mac: LocalizedStringResource("No Rating", bundle: .module, comment: "Culling: clear the star rating (key 0). Mac menu."),
                other: LocalizedStringResource("No rating", bundle: .module, comment: "Culling: clear the star rating (key 0)."))
            : PlatformWording.title(
                mac: LocalizedStringResource(
                    "\(stars) Stars", bundle: .module,
                    comment: "Culling: a star rating from 1 to 5 (keys 1–5). Mac menu, title case. Plural variations in the catalog."),
                other: LocalizedStringResource(
                    "\(stars) stars", bundle: .module,
                    comment: "Culling: a star rating from 1 to 5 (keys 1–5). Plural variations in the catalog."))
    }

    /// For VoiceOver and the feedback after a key: "3 stars, Pick".
    static func description(of mark: CullingMark) -> String {
        var parts: [String] = []
        if mark.rating > 0 { parts.append(ratingTitle(mark.rating)) }
        switch mark.flag {
        case .pick: parts.append(String(localized: "Picked", bundle: .module, comment: "Culling state of a photo: flagged as a keeper."))
        case .reject:
            parts.append(String(localized: "Rejected", bundle: .module, comment: "Culling state of a photo: flagged as rejected."))
        case .none: break
        }
        return parts.isEmpty
            ? String(localized: "Not rated", bundle: .module, comment: "Culling state of a photo: no stars and no flag.")
            : parts.joined(separator: ", ")
    }

    static var ratingMenuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Rating", bundle: .module, comment: "Submenu with 0–5 stars. Mac menu."),
            other: LocalizedStringResource("Rating", bundle: .module, comment: "Submenu with 0–5 stars."))
    }

    static var flagMenuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Flag", bundle: .module, comment: "Submenu with Pick, Reject, Unflag. Mac menu."),
            other: LocalizedStringResource("Flag", bundle: .module, comment: "Submenu with Pick, Reject, Unflag."))
    }

    static func filterTitle(_ filter: CullingFilter) -> String {
        switch filter {
        case .all: String(localized: "All Items", bundle: .module, comment: "Culling filter: show everything.")
        case .picks: String(localized: "Picks", bundle: .module, comment: "Culling filter: only photos flagged Pick.")
        case .rejected: String(localized: "Rejected", bundle: .module, comment: "Culling filter: only photos flagged Rejected.")
        case .unflagged: String(localized: "Unflagged", bundle: .module, comment: "Culling filter: photos neither picked nor rejected.")
        case .notRejected: String(localized: "Hide Rejected", bundle: .module, comment: "Culling filter: everything but rejected photos.")
        case .rating(let stars):
            String(
                localized: "\(stars) Stars or More", bundle: .module,
                comment: "Culling filter: photos rated at least this many stars. Plural variations in the catalog.")
        case .unrated: String(localized: "Unrated", bundle: .module, comment: "Culling filter: photos without stars.")
        }
    }

    static var deleteRejectedTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Delete Rejected…", bundle: .module, comment: "Deletes every photo flagged Rejected. Mac menu."),
            other: LocalizedStringResource("Delete rejected…", bundle: .module, comment: "Deletes every photo flagged Rejected."))
    }

    static var autoAdvanceTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Auto-Advance After Rating", bundle: .module,
                comment: "Culling option: go to the next photo after a rating or flag key. Mac menu."),
            other: LocalizedStringResource(
                "Auto-advance after rating", bundle: .module, comment: "Culling option: go to the next photo after a rating or flag key."))
    }
}

/// Culling options of this device.
enum CullingSettings {
    /// After a rating or flag key the next photo is selected (grid) or shown (viewer). On by default: culling is going
    /// through a shoot one photo after the other.
    static let autoAdvanceKey = "cullingAutoAdvance"

    static var autoAdvance: Bool {
        UserDefaults.standard.object(forKey: autoAdvanceKey) as? Bool ?? true
    }
}

// MARK: - Applying

/// Gives ratings and flags from a grid or the viewer: optimistic through the outbox, undoable, with a short
/// confirmation ("★★★", "Picked") where the photo is.
@MainActor
@Observable
final class CullingModel {
    /// The confirmation shown for a moment after a key.
    struct Feedback: Equatable, Identifiable {
        let id = UUID()
        var mark: CullingMark
        var command: CullingCommand
        var count: Int
    }

    private(set) var feedback: Feedback?
    var error: String?
    /// "Pick Best Shots" is comparing the photos (SPEC §21.4).
    private(set) var isChoosingBest = false
    /// What "Pick Best Shots" found when there was nothing to pick.
    var notice: String?

    /// Applies `command` to `items` (a stacked tile's copies included by the caller).
    func apply(_ command: CullingCommand, to items: [MediaItem], session: SessionModel, undoManager: UndoManager?) {
        guard !items.isEmpty else { return }
        let current = session.cullingMarks(of: items.map(\.fileId))
        let shown = command.applied(to: current[items[0].fileId] ?? .none)
        feedback = Feedback(mark: shown, command: command, count: items.count)
        AccessibilityNotification.Announcement(CullingWording.description(of: shown)).post()
        Task {
            do {
                let before = try await session.applyCulling(command, to: items)
                registerUndo(restoring: before, items: items, session: session, undoManager: undoManager)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The same with the files' ids (read from the index).
    func apply(_ command: CullingCommand, ids: [FileID], session: SessionModel, undoManager: UndoManager?) {
        guard let library = session.services?.library, let map = try? library.items(ids) else { return }
        apply(command, to: ids.compactMap { map[$0] }, session: session, undoManager: undoManager)
    }

    private func registerUndo(
        restoring marks: [FileID: CullingMark], items: [MediaItem], session: SessionModel, undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let redo = session.cullingMarks(of: items.map(\.fileId))
                Task { try? await session.setCullingMarks(marks, on: items) }
                model.registerUndo(restoring: redo, items: items, session: session, undoManager: undoManager)
            }
        }
        undoManager.setActionName(
            String(localized: "Rating", bundle: .module, comment: "Edit › Undo Rating: undoes a rating or flag."))
    }

    func clearFeedback() { feedback = nil }

    /// "Pick Best Shots" (SPEC §21.4): cuts `ids` into series of shots of one scene, finds the best shot of each on this
    /// device and flags it Pick (undoable like any flag). The other shots are left as they are. Photos in no series are
    /// not touched.
    func pickBest(ids: [FileID], session: SessionModel, undoManager: UndoManager?) {
        guard !isChoosingBest, let services = session.services, let map = try? services.library.items(ids) else { return }
        let items = ids.compactMap { map[$0] }.sorted { ($0.timestamp, $0.fileId) < ($1.timestamp, $1.fileId) }
        guard !items.isEmpty else { return }
        isChoosingBest = true
        Task {
            let service = BestShotService(services: services)
            let series = await Task.detached(priority: .userInitiated) { await service.series(of: items) }.value
            var best: [MediaItem] = []
            for shots in series {
                let chosen = Task.detached(priority: .userInitiated) { await service.choose(shots, fetch: true) }
                guard let choice = await chosen.value,
                    let item = shots.first(where: { $0.fileId == choice.best })
                else { continue }
                best.append(item)
            }
            isChoosingBest = false
            guard !best.isEmpty else {
                notice = BestShotWording.noSeries
                return
            }
            apply(.flag(.pick), to: best, session: session, undoManager: undoManager)
            AccessibilityNotification.Announcement(BestShotWording.picked(best.count, of: series.count)).post()
        }
    }
}

extension View {
    /// The short confirmation after a rating or flag key, and an alert when it could not be given.
    func cullingFeedback(_ model: CullingModel) -> some View {
        modifier(CullingFeedbackModifier(model: model))
    }
}

private struct CullingFeedbackModifier: ViewModifier {
    let model: CullingModel

    /// Long enough to be read, short enough not to be in the way of the next key.
    static var feedbackDuration: Duration {
        #if DEBUG
            // Screenshots: `PHOTOS_DEBUG_CULLING_HUD=<seconds>` keeps the confirmation longer.
            if let raw = ProcessInfo.processInfo.environment["PHOTOS_DEBUG_CULLING_HUD"], let seconds = Double(raw) {
                return .seconds(seconds)
            }
        #endif
        return .milliseconds(700)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if let feedback = model.feedback {
                    CullingFeedbackView(feedback: feedback)
                        .id(feedback.id)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if model.isChoosingBest {
                    Label {
                        Text("Choosing the best shots…", bundle: .module, comment: "Pick Best Shots is comparing the photos.")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.bottom, 24)
                    .accessibilityElement(children: .combine)
                }
            }
            .animation(.snappy(duration: 0.18), value: model.feedback)
            .task(id: model.feedback?.id) {
                guard model.feedback != nil else { return }
                try? await Task.sleep(for: Self.feedbackDuration)
                if !Task.isCancelled { model.clearFeedback() }
            }
            .alert(
                String(localized: "Couldn't rate", bundle: .module, comment: "Alert title: a rating or flag could not be given."),
                isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
            } message: {
                Text(model.error ?? "")
            }
            .alert(
                String(localized: "No series to pick from", bundle: .module, comment: "Alert title: Pick Best Shots found no series."),
                isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })
            ) {
            } message: {
                Text(model.notice ?? "")
            }
    }
}

/// "★★★" or a flag, large, in the middle for a moment: the key was understood.
private struct CullingFeedbackView: View {
    let feedback: CullingModel.Feedback

    var body: some View {
        VStack(spacing: 6) {
            switch feedback.command {
            case .flag(let flag):
                Image(systemName: CullingWording.flagSymbol(flag))
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(flag == .pick ? AnyShapeStyle(.yellow) : AnyShapeStyle(.primary))
                Text(CullingWording.flagTitle(flag)).font(.headline)
            case .rate(let stars):
                HStack(spacing: 2) {
                    ForEach(1...CullingTags.maxRating, id: \.self) { index in
                        Image(systemName: index <= stars ? "star.fill" : "star")
                            .foregroundStyle(index <= stars ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                    }
                }
                .font(.system(size: 24, weight: .semibold))
                Text(CullingWording.ratingTitle(stars)).font(.headline)
            }
            if feedback.count > 1 {
                Text("\(feedback.count) items", bundle: .module).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .accessibilityHidden(true)
    }
}

// MARK: - Menus

/// The Rating and Flag submenus of the grid's context menu, the selection's More menu and the viewer.
enum CullingMenu {
    static func actions(
        apply: @escaping @MainActor (CullingCommand, [FileID]) -> Void, pickBest: (@MainActor ([FileID]) -> Void)? = nil
    ) -> [GridMenuAction] {
        var flags: [GridMenuAction] = [CullingFlag.pick, .reject, .none].map { flag in
            GridMenuAction(
                id: "cull.flag.\(flag.rawValue)", title: CullingWording.flagTitle(flag), systemImage: CullingWording.flagSymbol(flag)
            ) { ids in apply(.flag(flag), ids) }
        }
        if let pickBest {
            flags.append(
                GridMenuAction(
                    id: "cull.flag.best", title: BestShotWording.pickBestTitle, systemImage: "star.square.on.square", startsGroup: true
                ) { ids in pickBest(ids) })
        }
        let ratings: [GridMenuAction] = (0...CullingTags.maxRating).reversed().map { stars in
            GridMenuAction(
                id: "cull.rate.\(stars)", title: CullingWording.ratingTitle(stars), systemImage: stars == 0 ? "star.slash" : "star.fill",
                startsGroup: stars == 0
            ) { ids in apply(.rate(stars), ids) }
        }
        return [
            GridMenuAction(
                id: "cull.flag", title: CullingWording.flagMenuTitle, systemImage: "flag", startsGroup: true, handler: { _ in },
                children: flags),
            GridMenuAction(
                id: "cull.rate", title: CullingWording.ratingMenuTitle, systemImage: "star", handler: { _ in }, children: ratings),
        ]
    }
}

/// "Delete Rejected…": every rejected photo of the library, after a confirmation that says how many.
struct DeleteRejectedConfirmation: Identifiable {
    let id = UUID()
    var items: [MediaItem]

    var title: String {
        String(
            localized: "Delete \(items.count) rejected items?", bundle: .module,
            comment: "Confirmation of Delete Rejected. Plural variations in the catalog.")
    }

    static var nothingTitle: String {
        String(localized: "No rejected photos", bundle: .module, comment: "Delete Rejected found nothing to delete.")
    }

    static var nothingMessage: String {
        String(
            localized: "Press X on a photo to reject it. Rejected photos can be deleted together when you are done.", bundle: .module,
            comment: "Delete Rejected found nothing to delete: how to reject.")
    }
}

// MARK: - Menu bar

/// Image ▸ Flag, Rating, Compare, Edit With and Delete Rejected… (SPEC §15.2). The keys (P, X, U, 0–5, C) are not
/// menu key equivalents: a letter without ⌘ in the menu bar would also fire while typing in a text field. The grid and
/// the viewer handle them.
struct CullingCommands: View {
    let grid: GridActions?
    @AppStorage(CullingSettings.autoAdvanceKey) private var autoAdvance = true

    var body: some View {
        Divider()
        Menu(CullingWording.flagMenuTitle) {
            ForEach([CullingFlag.pick, .reject, .none], id: \.self) { flag in
                Button(CullingWording.flagTitle(flag)) { grid?.cull?(.flag(flag)) }
            }
            Divider()
            Button(BestShotWording.pickBestTitle) { grid?.pickBest?() }
                .disabled(grid?.pickBest == nil)
        }
        .disabled(grid?.cull == nil)
        Menu(CullingWording.ratingMenuTitle) {
            ForEach((0...CullingTags.maxRating).reversed(), id: \.self) { stars in
                Button(CullingWording.ratingTitle(stars)) { grid?.cull?(.rate(stars)) }
            }
        }
        .disabled(grid?.cull == nil)
        Toggle(CullingWording.autoAdvanceTitle, isOn: $autoAdvance)
        Button(CompareWording.menuTitle) { grid?.compare?() }
            .disabled(grid?.compare == nil)
        // ⌥⌘L: L for loupe.
        Button(LoupeWording.menuTitle) { grid?.loupe?() }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(grid?.loupe == nil)
        #if os(macOS)
            EditWithMenu(item: grid?.editWith)
        #endif
        Button(CullingWording.deleteRejectedTitle) { grid?.deleteRejected?() }
            .disabled(grid?.deleteRejected == nil)
    }
}

enum CompareWording {
    static var menuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Compare", bundle: .module, comment: "Image menu: compare 2–4 selected photos side by side (key C)."),
            other: LocalizedStringResource("Compare", bundle: .module, comment: "Compare 2–4 selected photos side by side (key C)."))
    }
}

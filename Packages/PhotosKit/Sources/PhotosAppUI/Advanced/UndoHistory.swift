// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import PhotosModel
import SwiftUI

/// Wording of changes in the undo history and the confirmation banner (SPEC §16.3.4).
enum ChangeWording {
    /// "Added 12 items to Summer", "Edited IMG_1234", "Rotated 3 photos", "Deleted 3 items"…
    static func title(_ change: UndoableChange, trashbin: Bool = true) -> String {
        let count = change.count
        switch change {
        case .addToAlbum(_, let album):
            return String(
                localized: "Added \(count) items to \(album.title)", bundle: .module,
                comment:
                    "Undo history and confirmation: photos added to an album. %lld is the number, %@ the album's name. Has plural forms.")
        case .edit(let changes, let action):
            let name: String? = changes.count == 1 ? changes[0].name : nil
            switch action {
            case .edit:
                if let name {
                    return String(
                        localized: "Edited \(name)", bundle: .module,
                        comment: "Undo history and confirmation: a photo was edited. %@ is the file name, e.g. IMG_1234.HEIC.")
                }
                return String(
                    localized: "Edited \(count) photos", bundle: .module,
                    comment: "Undo history and confirmation: photos were edited together (a RAW file and its JPEG). Has plural forms.")
            case .rotate:
                return String(
                    localized: "Rotated \(count) photos", bundle: .module,
                    comment: "Undo history and confirmation after Image › Rotate (the originals are not changed). Has plural forms.")
            case .revert:
                if let name {
                    return String(
                        localized: "Reverted \(name) to the original", bundle: .module,
                        comment: "Undo history and confirmation: a photo's edits were removed. %@ is the file name.")
                }
                return String(
                    localized: "Reverted \(count) photos to the original", bundle: .module,
                    comment: "Undo history and confirmation: the edits of several photos were removed. Has plural forms.")
            }
        default:
            return ChangeNoticeText.text(ChangeNotice(change: change, canUndo: false), trashbin: trashbin)
        }
    }

    /// Why a change cannot be undone (any more), in the row's place of the Undo button.
    static func problem(_ problem: HistoryRevertProblem) -> String {
        switch problem {
        case .reverted:
            String(localized: "Undone", bundle: .module, comment: "Undo history: this change has been taken back.")
        case .reverting:
            String(localized: "Undoing…", bundle: .module, comment: "Undo history: this change is being taken back.")
        case .noTrashbin:
            String(
                localized: "Deleted for good: the trash bin is turned off on your server.", bundle: .module,
                comment: "Undo history: a delete that cannot be undone.")
        case .notUndoable:
            String(
                localized: "Can't be undone here (shared with you).", bundle: .module,
                comment: "Undo history: a change of photos somebody else shared with the user, which this app cannot take back.")
        case .editedLater:
            String(
                localized: "Edited again since. Open the photo to change its edit.", bundle: .module,
                comment: "Undo history: an edit that a later edit (on this or another device) replaced.")
        }
    }

    static var historyTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource("Undo History", bundle: .module, comment: "Window and menu title: the list of recent changes."),
            other: LocalizedStringResource("Undo history", bundle: .module, comment: "Sheet and menu title: the list of recent changes."))
    }

    static var historyMenuTitle: String {
        PlatformWording.title(
            mac: LocalizedStringResource(
                "Undo History…", bundle: .module, comment: "Edit menu item that opens the list of recent changes."),
            other: LocalizedStringResource("Undo history", bundle: .module, comment: "Sheet and menu title: the list of recent changes."))
    }
}

/// The undo history (SPEC §16.3.4): the session's recent changes, newest first, with what they changed and an Undo
/// button for each that can still be taken back — not only the last one.
struct UndoHistoryView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if session.history.isEmpty {
                    ContentUnavailableView {
                        Label(ChangeWording.historyTitle, systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text(
                            "Changes you make in this session — favorites, albums, edits, rotations, deletions — appear here, and you can undo each of them.",
                            bundle: .module, comment: "Undo history without changes yet.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(session.history) { entry in
                                UndoHistoryRow(entry: entry)
                            }
                        } footer: {
                            Text(
                                "Undoing a change does not undo the ones after it. The history starts again when the app is opened.",
                                bundle: .module, comment: "Footnote below the undo history.")
                        }
                    }
                    #if os(macOS)
                        .listStyle(.inset)
                    #endif
                }
            }
            .navigationTitle(ChangeWording.historyTitle)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 460, minHeight: 420)
        #endif
    }
}

private struct UndoHistoryRow: View {
    let entry: ChangeHistoryEntry
    @Environment(SessionModel.self) private var session

    var body: some View {
        let title: String = ChangeWording.title(entry.change, trashbin: session.features.has(.trashbin))
        let problem: HistoryRevertProblem? = session.revertProblem(entry)
        HStack(spacing: 12) {
            HistoryThumbnails(fileIds: Array(entry.change.fileIds.prefix(3)))
                .frame(width: 52, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .strikethrough(entry.isReverted)
                    .lineLimit(2)
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let problem, problem != .reverting {
                    Text(ChangeWording.problem(problem))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if entry.failures > 0 {
                    Text("\(entry.failures) items couldn't be restored from the trash bin.", bundle: .module)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            if problem == .reverting {
                ProgressView().controlSize(.small)
            } else if problem == nil {
                Button(String(localized: "Undo", bundle: .module)) {
                    let id = entry.id
                    Task { await session.revertHistoryEntry(id) }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(
                    Text("Undo: \(title)", bundle: .module, comment: "VoiceOver label of a history row's Undo button. %@ is the change."))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Up to three small previews of the photos a change touched, fanned out.
private struct HistoryThumbnails: View {
    let fileIds: [FileID]
    @Environment(SessionModel.self) private var session
    @State private var items: [MediaItem] = []

    var body: some View {
        ZStack(alignment: .leading) {
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .frame(width: 40, height: 40)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            ForEach(Array(items.enumerated()), id: \.element.fileId) { index, item in
                PreviewImage(item: item, bucket: 256)
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(.background, lineWidth: 1.5) }
                    .offset(x: CGFloat(index) * 6, y: CGFloat(index) * -2)
                    .zIndex(Double(items.count - index))
            }
        }
        .task(id: fileIds) {
            guard let library = session.services?.library else { return }
            let found = (try? await library.fetchItems(fileIds)) ?? [:]
            items = fileIds.compactMap { found[$0] }
        }
    }
}

extension View {
    /// The undo history as a sheet.
    func undoHistorySheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) { UndoHistoryView() }
    }
}

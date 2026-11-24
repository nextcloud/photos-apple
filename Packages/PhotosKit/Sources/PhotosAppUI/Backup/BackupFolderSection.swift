// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosBackup
import PhotosCore
import SwiftUI

/// The backup folder, chosen from the server's folders and checked against the folders the timeline shows (round-3
/// item 34): uploads into a folder the timeline doesn't show would never appear in the library.
struct BackupFolderSection: View {
    @Environment(SessionModel.self) private var session
    @State private var picking = false
    /// A picked folder the timeline doesn't show, waiting for the user's decision.
    @State private var outside: String?
    @State private var error: String?

    var timelineFolders: [String] { session.features.userConfig.photosSourceFolders }

    var body: some View {
        let backup = session.backup
        let folder = backup.settings.folder
        // Another account's folders cannot be browsed or checked from here.
        let canCheck = !backup.isForOtherAccount
        let isShown = !canCheck || BackupFolder.isShown(folder, inTimelineFolders: timelineFolders)
        Section {
            LabeledContent {
                Button(
                    String(
                        localized: "Choose…", bundle: .module,
                        comment: "Button next to the backup folder: opens the server's folders.")
                ) {
                    picking = true
                }
                .disabled(!canCheck)
            } label: {
                Text("Folder", bundle: .module)
                Text(folder).lineLimit(1).truncationMode(.middle)
            }
            if !isShown {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(
                            "Backed-up photos don't appear in your library", bundle: .module,
                            comment: "Warning on the Backup screen: the backup folder is not one of the folders the timeline shows."
                        )
                        .font(.headline)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(BackupFolderWording.notShown(folder: folder, timelineFolders: timelineFolders))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button(BackupFolderWording.showInLibrary) { showInLibrary(folder) }
                    if let suggestion = BackupFolder.suggestion(
                        photosLocation: session.features.userConfig.photosLocation, timelineFolders: timelineFolders)
                    {
                        Button(BackupFolderWording.backUpTo(suggestion)) { backup.update { $0.folder = suggestion } }
                    }
                }
            }
        } footer: {
            if let error {
                Text(error).foregroundStyle(.red)
            } else {
                Text(
                    "New photos are uploaded here, in subfolders by date. Your library shows the photos in your timeline folders.",
                    bundle: .module, comment: "Footer of the backup folder on the Backup screen.")
            }
        }
        .sheet(isPresented: $picking) {
            ServerFolderPicker(
                confirmTitle: String(
                    localized: "Back up here", bundle: .module,
                    comment: "Confirming button of the folder browser when choosing the backup folder.")
            ) { picked in
                choose(picked)
            }
            .environment(session)
        }
        .confirmationDialog(
            BackupFolderWording.outsideTitle(outside ?? ""),
            isPresented: Binding(get: { outside != nil }, set: { if !$0 { outside = nil } }),
            titleVisibility: .visible
        ) {
            if let picked = outside {
                Button(BackupFolderWording.backUpAndShow) {
                    backup.update { $0.folder = picked }
                    showInLibrary(picked)
                }
                Button(BackupFolderWording.chooseAnother) {
                    // After the dialog has gone.
                    Task { picking = true }
                }
            }
        } message: {
            Text(BackupFolderWording.notShown(folder: outside ?? "", timelineFolders: timelineFolders))
        }
    }

    func choose(_ picked: String) {
        let picked = BackupFolder.normalized(picked)
        if BackupFolder.isShown(picked, inTimelineFolders: timelineFolders) {
            session.backup.update { $0.folder = picked }
        } else {
            outside = picked
        }
    }

    /// Adds the folder to the timeline folders (Photos' own setting, also used by the web app).
    func showInLibrary(_ folder: String) {
        error = nil
        Task {
            do {
                try await session.setUserConfig(.photosSourceFolders) { config in
                    if !BackupFolder.isShown(folder, inTimelineFolders: config.photosSourceFolders) {
                        config.photosSourceFolders.append(BackupFolder.normalized(folder))
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

enum BackupFolderWording {
    static func notShown(folder: String, timelineFolders: [String]) -> String {
        String(
            localized:
                "Your library only shows photos in \(timelineFolders.joined(separator: ", ")). Photos uploaded to \(folder) are on your Nextcloud, but not in your library.",
            bundle: .module,
            comment:
                "Explains why backed-up photos would not appear. The first placeholder lists the timeline folders (\"/Photos, /InstantUpload\"), the second is the backup folder."
        )
    }

    static var showInLibrary: String {
        String(
            localized: "Show this folder in your library", bundle: .module,
            comment: "Button: adds the backup folder to the folders the timeline shows.")
    }

    static func backUpTo(_ folder: String) -> String {
        String(
            localized: "Back up to \(folder) instead", bundle: .module,
            comment: "Button: changes the backup folder to one the timeline shows. The placeholder is a folder path such as /Photos.")
    }

    static func outsideTitle(_ folder: String) -> String {
        String(
            localized: "\(folder) is not in your library", bundle: .module,
            comment:
                "Title of the question after choosing a backup folder that the timeline doesn't show. The placeholder is the folder path.")
    }

    static var backUpAndShow: String {
        String(
            localized: "Back up here and show in library", bundle: .module,
            comment: "Choice after picking a backup folder the timeline doesn't show: use it and add it to the timeline folders.")
    }

    static var chooseAnother: String {
        String(
            localized: "Choose another folder", bundle: .module,
            comment: "Choice after picking a backup folder the timeline doesn't show.")
    }
}

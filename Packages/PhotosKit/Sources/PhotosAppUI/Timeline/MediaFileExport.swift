// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

enum MediaFileNaming {
    /// `name` in `folder`, with " 2", " 3"… before the extension when a file of that name exists.
    static func freeURL(
        for name: String, in folder: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var counter = 2
        while exists(candidate) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}

#if os(macOS)
    import AppKit

    /// "Export…" on the Mac: the originals are downloaded into a folder the user picks (`MediaSaveModel` does the saving).
    enum MediaFileExport {
        /// Asks for the folder; nil when the panel is cancelled.
        @MainActor static func chooseFolder() async -> URL? {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Export", bundle: .module)
            panel.message = String(localized: "Choose where to save the originals.", bundle: .module)
            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = await panel.begin()
            }
            guard response == .OK else { return nil }
            return panel.url
        }
    }
#endif

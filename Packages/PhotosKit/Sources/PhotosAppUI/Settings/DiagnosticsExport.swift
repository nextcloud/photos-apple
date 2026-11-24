// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosCore
import SwiftUI

#if os(macOS)
    import AppKit
    import UniformTypeIdentifiers
#else
    import UIKit
#endif

/// Settings › Diagnostics: "Export diagnostics…" writes the app's log and what is needed to read it into a text file
/// and hands it to the save panel (Mac) or the share sheet (SPEC §4.5).
struct DiagnosticsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionModel.self) private var session
    @State private var exporting = false
    @State private var error: String?
    @AppStorage(PersistentLog.enabledKey) private var keepsLog = true
    #if !os(macOS)
        @State private var shared: SharedFile?

        struct SharedFile: Identifiable {
            var id: URL { url }
            var url: URL
        }
    #endif

    var body: some View {
        Section {
            Button {
                export()
            } label: {
                HStack {
                    Text("Export diagnostics…", bundle: .module)
                    if exporting {
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(exporting)
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            Toggle(String(localized: "Keep log across restarts", bundle: .module), isOn: $keepsLog)
                .onChange(of: keepsLog) { _, keep in
                    if !keep { Task { await DiagnosticsLogWriter.shared.removeAll() } }
                }
        } header: {
            Text("Diagnostics", bundle: .module)
        } footer: {
            Text(
                "A text file with what the app logged since it was opened (the last two days at most), its version, the system version, the server version and the detected server features. With \"Keep log across restarts\", it also contains the log of earlier runs, which the app keeps on this device (1 MB at most). It contains no account names, server addresses, file names or passwords. Attach it when you report a problem.",
                bundle: .module)
        }
        #if !os(macOS)
            // The report is not kept once the share sheet is closed.
            .sheet(item: $shared, onDismiss: { Diagnostics.removeExports() }) { file in ActivitySheet(items: [file.url]) }
        #endif
    }

    func export() {
        exporting = true
        error = nil
        Task {
            defer { exporting = false }
            do {
                let file: URL = try await Diagnostics.export(app: app, session: session)
                #if os(macOS)
                    try await Self.save(file)
                #else
                    shared = SharedFile(url: file)
                #endif
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    #if os(macOS)
        /// Asks where to save the report and copies it there.
        @MainActor static func save(_ file: URL) async throws {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.lastPathComponent
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true
            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = await panel.begin()
            }
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            guard response == .OK, let target = panel.url else { return }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: file, to: target)
        }
    #else
        /// The system share sheet for a file.
        struct ActivitySheet: UIViewControllerRepresentable {
            let items: [Any]

            func makeUIViewController(context: Context) -> UIActivityViewController {
                UIActivityViewController(activityItems: items, applicationActivities: nil)
            }

            func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
        }
    #endif
}

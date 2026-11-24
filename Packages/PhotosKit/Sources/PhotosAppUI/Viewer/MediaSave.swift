// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation
import Observation
import PhotosCore
import PhotosModel
import SwiftUI

/// What saving originals did (SPEC §7.3: per-item failures are reported).
struct MediaSaveResult: Equatable, Sendable {
    var total: Int
    var saved = 0
    /// One message per item that could not be saved.
    var failures: [String] = []
    /// The user stopped it; what was saved until then stays.
    var wasCancelled = false
    /// The folder the files went to (Mac).
    var folder: URL?

    var failed: Int { failures.count }
    var isSuccess: Bool { failures.isEmpty && !wasCancelled && saved == total }

    /// "Exported 3 items" on the Mac, "Saved 3 items to Photos" elsewhere; nil when nothing was saved.
    var confirmation: String? {
        guard saved > 0 else { return nil }
        if saved == total { return MediaSaveWording.saved(saved) }
        return MediaSaveWording.savedPart(saved, of: total)
    }

    /// What went wrong, for an alert; nil when nothing did.
    var failureMessage: String? {
        guard let first = failures.first else { return nil }
        let reasons: [String] = failures.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        guard failed > 1 else { return first }
        let summary: String = MediaSaveWording.notSaved(failed)
        // Several items usually fail for one reason; it is said once.
        return reasons.count == 1 ? "\(summary) \(first)" : summary
    }
}

/// Texts of the save status: the Mac exports into a folder, the other platforms save to the photo library.
enum MediaSaveWording {
    static func saved(_ count: Int) -> String {
        #if os(macOS)
            String(localized: "Exported \(count) items", bundle: .module)
        #else
            String(localized: "Saved \(count) items to Photos", bundle: .module)
        #endif
    }

    static func savedPart(_ count: Int, of total: Int) -> String {
        #if os(macOS)
            String(localized: "Exported \(count) of \(total) items", bundle: .module)
        #else
            String(localized: "Saved \(count) of \(total) items to Photos", bundle: .module)
        #endif
    }

    static func notSaved(_ count: Int) -> String {
        #if os(macOS)
            String(localized: "\(count) items could not be exported.", bundle: .module)
        #else
            String(localized: "\(count) items could not be saved.", bundle: .module)
        #endif
    }

    static func progress(_ done: Int, of total: Int) -> String {
        #if os(macOS)
            String(localized: "Exporting \(min(done + 1, total)) of \(total)…", bundle: .module)
        #else
            String(localized: "Saving \(min(done + 1, total)) of \(total)…", bundle: .module)
        #endif
    }

    static var failureTitle: String {
        #if os(macOS)
            String(localized: "Couldn't export", bundle: .module)
        #else
            String(localized: "Couldn't save", bundle: .module)
        #endif
    }
}

enum MediaSaveRunner {
    /// Saves one element after the other and keeps count. A failing element does not stop the others; cancelling
    /// the task does, and what was saved until then is reported.
    static func run<Element: Sendable>(
        _ elements: [Element],
        progress: @MainActor @Sendable (Int) -> Void = { _ in },
        save: @Sendable (Element) async throws -> Void
    ) async -> MediaSaveResult {
        var result = MediaSaveResult(total: elements.count)
        for (index, element) in elements.enumerated() {
            if Task.isCancelled {
                result.wasCancelled = true
                break
            }
            do {
                try await save(element)
                result.saved += 1
            } catch {
                // A cancelled download fails with its own error (`URLError.cancelled`): not a failure of that item.
                if Task.isCancelled || error is CancellationError {
                    result.wasCancelled = true
                    break
                }
                result.failures.append(error.localizedDescription)
            }
            await progress(index + 1)
        }
        return result
    }
}

/// The one way originals are saved from the app — grid, viewer and menu bar: "Export…" into a folder on the Mac,
/// "Save to Photos" elsewhere — with progress, Cancel and a result (`mediaSaveStatus`).
@MainActor
@Observable
final class MediaSaveModel {
    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    private(set) var progress: Progress?
    /// The last result, until it is dismissed.
    private(set) var result: MediaSaveResult?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func save(_ items: [MediaItem], services: AccountServices) {
        guard !isRunning, !items.isEmpty else { return }
        result = nil
        task = Task { [weak self] in
            defer { self?.finished() }
            let destination: MediaExport.Destination
            #if os(macOS)
                // As the grid's "Export…": the user picks the folder. Closing the panel is not a result.
                guard let folder = await MediaFileExport.chooseFolder() else { return }
                destination = .folder(folder)
            #else
                destination = .photoLibrary
            #endif
            self?.progress = Progress(done: 0, total: items.count)
            let total: Int = items.count
            let result: MediaSaveResult = await MediaExport.save(items, to: destination, services: services) { [weak self] done in
                self?.progress = Progress(done: done, total: total)
            }
            self?.result = result
        }
    }

    private func finished() {
        task = nil
        progress = nil
    }

    func cancel() {
        task?.cancel()
    }

    func dismissResult() {
        result = nil
    }
}

extension View {
    /// Progress with Cancel while `model` saves, then "Saved 3 items" for a moment, or an alert with what failed.
    func mediaSaveStatus(_ model: MediaSaveModel) -> some View {
        modifier(MediaSaveStatus(model: model))
    }
}

private struct MediaSaveStatus: ViewModifier {
    let model: MediaSaveModel

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let progress = model.progress {
                    banner { running(progress) }
                } else if let result = model.result, let confirmation = result.confirmation {
                    banner { finished(result, text: confirmation) }
                }
            }
            .animation(.default, value: model.progress != nil)
            .animation(.default, value: model.result)
            .task(id: model.result) {
                guard let result = model.result else { return }
                if let confirmation = result.confirmation { AccessibilityNotification.Announcement(confirmation).post() }
                // A plain confirmation leaves by itself; one with failures goes with its alert.
                guard result.failures.isEmpty else { return }
                try? await Task.sleep(for: .seconds(result.confirmation == nil ? 0 : 5))
                if !Task.isCancelled { model.dismissResult() }
            }
            .alert(
                MediaSaveWording.failureTitle,
                isPresented: Binding(
                    get: { model.result?.failureMessage != nil },
                    set: { if !$0 { model.dismissResult() } })
            ) {
            } message: {
                Text(model.result?.failureMessage ?? "")
            }
    }

    func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .padding()
            .transition(.opacity)
    }

    func running(_ progress: MediaSaveModel.Progress) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .progressViewStyle(.circular)
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(MediaSaveWording.progress(progress.done, of: progress.total))
                .monospacedDigit()
            Button(String(localized: "Cancel", bundle: .module)) { model.cancel() }
        }
        .accessibilityElement(children: .contain)
    }

    func finished(_ result: MediaSaveResult, text: String) -> some View {
        HStack(spacing: 12) {
            Label(text, systemImage: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle")
            #if os(macOS)
                if let folder = result.folder {
                    Button(String(localized: "Show in Finder", bundle: .module)) {
                        NSWorkspace.shared.open(folder)
                    }
                }
            #endif
        }
    }
}

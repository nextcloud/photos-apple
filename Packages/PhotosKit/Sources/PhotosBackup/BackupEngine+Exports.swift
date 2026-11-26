// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import GRDB
import OSLog
import Photos
import PhotosModel
import PhotosNetworking
import PhotosStore

extension BackupEngine {
    // MARK: Exported files

    /// The directory an interrupted upload's export waits in for the next attempt.
    private func keptDirectory(of resource: BackupResource, settings: BackupSettings) -> URL? {
        guard let exportDirectory else { return nil }
        // Another edit, another size or another format is another file.
        let identity =
            "\(resource.localIdentifier)|\(resource.kind.rawValue)|\(resource.modifiedAt?.timeIntervalSince1970 ?? 0)|\(resource.byteSize ?? -1)|\(settings.format.rawValue)"
        let name = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return exportDirectory.appending(path: "\(Self.keptFolder)/\(name)")
    }

    static let keptFolder = "Kept"
    static let keptInfoFile = "resource.json"

    /// What a kept export belongs to, next to it, so that it can be told later whether anybody still needs it.
    struct KeptExport: Codable {
        var localIdentifier: String
        var kind: String
        var keptAt: Date
    }

    /// The export an earlier, interrupted attempt left for this resource.
    func keptExport(of resource: BackupResource, settings: BackupSettings) -> URL? {
        guard let directory = keptDirectory(of: resource, settings: settings) else { return nil }
        let files =
            (try? FileManager.default.contentsOfDirectory(at: directory.appending(path: "data"), includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first, Self.size(of: file) > 0 else { return nil }
        return file
    }

    /// What happens to an exported file when the engine is done with it: removed, or, when its upload was interrupted and
    /// it is large, put aside for the next attempt (`keep`).
    func keepOrDiscard(_ file: URL, of resource: BackupResource, settings: BackupSettings, keep: Bool) {
        let files = FileManager.default
        let directory = file.deletingLastPathComponent()
        let kept = keptDirectory(of: resource, settings: settings)
        let isKept = kept.map { directory.standardizedFileURL.path == $0.appending(path: "data").standardizedFileURL.path } ?? false
        guard keep, let kept, files.fileExists(atPath: file.path(percentEncoded: false)),
            Self.size(of: file) >= keptExportMinimumSize
        else {
            try? files.removeItem(at: isKept ? directory.deletingLastPathComponent() : directory)
            return
        }
        if isKept { return }
        do {
            try? files.removeItem(at: kept)
            try files.createDirectory(at: kept, withIntermediateDirectories: true)
            try files.moveItem(at: directory, to: kept.appending(path: "data"))
            let info = KeptExport(localIdentifier: resource.localIdentifier, kind: resource.kind.rawValue, keptAt: now())
            try JSONEncoder().encode(info).write(to: kept.appending(path: Self.keptInfoFile))
        } catch {
            try? files.removeItem(at: directory)
            try? files.removeItem(at: kept)
        }
    }

    /// Removes what earlier runs left in the export directory, once, before the first pass of this engine: exports of a
    /// pass that did not end (the app was ended in the middle), and kept exports nobody needs any more (their resource is
    /// uploaded, gone from the ledger, or they are old).
    func sweepExports() {
        guard let exportDirectory, !exportsSwept else { return }
        exportsSwept = true
        let files = FileManager.default
        let ledger = (try? loadLedger()) ?? [:]
        for url in (try? files.contentsOfDirectory(at: exportDirectory, includingPropertiesForKeys: nil)) ?? [] {
            guard url.lastPathComponent == Self.keptFolder else {
                try? files.removeItem(at: url)
                continue
            }
            for kept in (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                if !isNeeded(kept, ledger: ledger) { try? files.removeItem(at: kept) }
            }
        }
    }

    private func isNeeded(_ kept: URL, ledger: [LedgerKey: BackupLedgerEntry]) -> Bool {
        guard let data = try? Data(contentsOf: kept.appending(path: Self.keptInfoFile)),
            let info = try? JSONDecoder().decode(KeptExport.self, from: data),
            now().timeIntervalSince(info.keptAt) < BackupPolicy.keptExportAge,
            let entry = ledger[LedgerKey(localIdentifier: info.localIdentifier, kind: info.kind)]
        else { return false }
        return !BackupPolicy.isComplete(entry) && !BackupPolicy.isSkipped(entry)
    }
}

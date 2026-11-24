// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Google Takeout (Google Photos): year folders (`Photos from 2019`), album folders with a `metadata.json` (its name
/// translated), JSON sidecars next to the media (`GoogleTakeoutSidecars`), the trash folder. A folder is Google's when
/// it lies below the export's root folder (`Google Photos`, `Google Fotos`…) or when a sidecar in it describes one of
/// its photos.
enum GoogleTakeoutExport: ExportAdapter {
    static let source = ImportSourceKind.googlePhotos

    /// Folders that are not albums although they are not year folders either.
    static let plainFolders: Set<String> = [
        "archive", "archiv", "archives", "archivio", "archivo", "archief", "failed videos",
    ]
    /// The folder of the export that holds the others.
    static let rootFolders: Set<String> = ["google photos", "google fotos", "google foto", "fotky google", "takeout"]
    /// The export's trash; deleted photos are not imported.
    static let trashFolders: Set<String> = [
        "trash", "bin", "papierkorb", "corbeille", "papelera", "cestino", "prullenbak", "kosz", "lixeira", "lixo",
    ]

    /// "Photos from 2019", "Fotos von 2019", "Photos de 2019": words and a year, nothing else.
    static func isYearFolder(_ name: String) -> Bool {
        name.wholeMatch(of: /\D*(19|20)\d{2}/) != nil
    }

    static func isBelowRoot(_ folder: String) -> Bool {
        folder.split(separator: "/").contains { rootFolders.contains($0.lowercased()) }
    }

    static func read(_ files: ExportFiles, unclaimed: [Int]) throws -> ImportFindings {
        var found = ImportFindings()
        var index: [String: Int] = [:]
        let byFolder = Dictionary(grouping: unclaimed, by: { files.files[$0].directory })
        for folder in byFolder.keys.sorted() {
            try Task.checkCancellation()
            let positions = byFolder[folder] ?? []
            let folderName = (folder as NSString).lastPathComponent
            let media = positions.filter { ExportFiles.kind(of: files.files[$0].name) != nil }
            let jsons = positions.filter {
                GoogleTakeoutSidecars.isSidecarName(files.files[$0].name) && files.files[$0].size <= GoogleTakeoutSidecars.maxSidecarSize
            }
            let names = jsons.map { files.files[$0].name }
            let sidecars = GoogleTakeoutSidecars.index(names)
            let jsonByName = Dictionary(zip(names, jsons), uniquingKeysWith: { first, _ in first })
            let sidecarOf = Dictionary(
                media.compactMap { position in
                    GoogleTakeoutSidecars.sidecar(for: files.files[position].name, in: sidecars).flatMap { name in
                        jsonByName[name].map { (position, $0) }
                    }
                }, uniquingKeysWith: { first, _ in first })
            guard isBelowRoot(folder) || !sidecarOf.isEmpty else { continue }
            found.claimed.formUnion(positions)
            if trashFolders.contains(folderName.lowercased()) {
                for position in media { found.skip(.deleted, files.files[position].name) }
                continue
            }
            guard !media.isEmpty else { continue }
            // An album folder: one that describes itself with a title, or any other folder that is not a year folder, the
            // export's root or a special folder.
            var album: String?
            let lowercased = folderName.lowercased()
            let isPlain = isYearFolder(folderName) || plainFolders.contains(lowercased) || rootFolders.contains(lowercased)
            let used = Set(sidecarOf.values)
            for json in jsons where !isPlain && !used.contains(json) {
                if let data = try? files.data(of: files.files[json]), let title = GoogleTakeoutSidecars.albumTitle(data) {
                    album = title
                    break
                }
            }
            if album == nil, !folder.isEmpty, !isPlain { album = folderName }
            if let album { found.addAlbum(album, source: source) }
            for position in media.sorted(by: { files.files[$0].name < files.files[$1].name }) {
                let file = files.files[position]
                var metadata: ImportMetadata?
                if let sidecar = sidecarOf[position], let read = (try? files.data(of: files.files[sidecar])).flatMap(GoogleTakeoutSidecars.read) {
                    if read.trashed {
                        found.skip(.deleted, file.name)
                        continue
                    }
                    metadata = read.metadata
                }
                let item = ImportItem(
                    origin: .file(file), name: file.name, size: file.size, kind: ExportFiles.kind(of: file.name) ?? .image, source: source,
                    metadata: metadata ?? ImportMetadata(), albums: album.map { [$0] } ?? [])
                if found.add(item, index: &index), metadata == nil { found.withoutDetails += 1 }
            }
        }
        return found
    }
}

// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import MapKit
import PhotosCore
import PhotosDomain
import PhotosModel
import PhotosStore
import SwiftUI
import UniformTypeIdentifiers

/// Places for photos from a GPS track (GPX or KML) recorded by a phone, watch or GPS logger, matched by time
/// (SPEC §16.4). The camera clock offset is suggested from the photos and can be corrected; the map shows the track and
/// where each photo lands before anything is changed.
struct TrackGeotagForm: View {
    /// The photos to tag; empty: photos of the library taken while the track was recorded.
    let items: [MediaItem]
    @Binding var edits: [MetadataEdit]
    @Environment(SessionModel.self) private var session
    @State private var importing = false
    @State private var track: GeoTrack?
    @State private var fileNames: [String] = []
    @State private var error: String?
    @State private var candidates: [MediaItem] = []
    @State private var offsetMinutes = 0
    @State private var suggestedMinutes: Int?
    @State private var toleranceMinutes = 5
    @State private var onlyMissing = true
    @State private var position: MapCameraPosition = .automatic

    static let trackTypes: [UTType] = [
        UTType(filenameExtension: "gpx") ?? .xml, UTType(filenameExtension: "kml") ?? .xml, .xml,
    ]

    var pool: [MediaItem] {
        let base: [MediaItem] = items.isEmpty ? candidates : items
        return onlyMissing ? base.filter { !$0.hasLocation } : base
    }

    var matches: [GeoTagger.Match] {
        guard let track else { return [] }
        return GeoTagger.match(pool, track: track, offset: TimeInterval(offsetMinutes * 60), tolerance: TimeInterval(toleranceMinutes * 60))
    }

    var body: some View {
        Form {
            Section {
                Button {
                    importing = true
                } label: {
                    Label(
                        track == nil
                            ? String(localized: "Choose GPX or KML File…", bundle: .module)
                            : String(localized: "Choose Another File…", bundle: .module), systemImage: "doc.badge.plus")
                }
                if let track, let start = track.start, let end = track.end {
                    LabeledContent(fileNames.joined(separator: ", ")) {
                        Text(
                            "\(track.points.count) points · \(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))",
                            bundle: .module)
                    }
                    .font(.footnote)
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            } header: {
                Text("GPS track", bundle: .module)
            } footer: {
                Text(
                    "Export the track from your sports watch, bike computer, GPS logger or an app like Strava or Komoot. The photos get the position the track had when they were taken.",
                    bundle: .module)
            }
            if track != nil {
                mapSection
                Section {
                    Stepper(value: $offsetMinutes, in: -14 * 60...14 * 60, step: 15) {
                        LabeledContent(String(localized: "Camera clock", bundle: .module), value: Self.offsetText(offsetMinutes))
                    }
                    if let suggestedMinutes, suggestedMinutes != offsetMinutes {
                        Button(String(localized: "Use the suggested correction (\(Self.offsetText(suggestedMinutes)))", bundle: .module)) {
                            offsetMinutes = suggestedMinutes
                        }
                    }
                    Picker(String(localized: "Largest time difference", bundle: .module), selection: $toleranceMinutes) {
                        ForEach([1, 2, 5, 15, 30, 60], id: \.self) { minutes in
                            Text("\(minutes) min", bundle: .module).tag(minutes)
                        }
                    }
                    Toggle(String(localized: "Only photos without a location", bundle: .module), isOn: $onlyMissing)
                } header: {
                    Text("Matching", bundle: .module)
                } footer: {
                    Text(
                        "If the camera's clock was off or set to another time zone, correct it here; the suggestion is the correction that places the most photos on the track.",
                        bundle: .module)
                }
                Section(String(localized: "Photos", bundle: .module)) {
                    let found: [FileID: GeoTagger.Match] = Dictionary(
                        matches.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
                    Text("^[\(found.count) item](inflect: true) of \(pool.count) on the track", bundle: .module).font(.headline)
                    ForEach(pool.sorted { $0.timestamp < $1.timestamp }.prefix(40)) { item in
                        BatchPreviewRow(item: item) {
                            if let match = found[item.fileId] {
                                Text(
                                    "\(match.latitude.formatted(.number.precision(.fractionLength(5)))), \(match.longitude.formatted(.number.precision(.fractionLength(5)))) · \(Int(match.distance.rounded())) s",
                                    bundle: .module
                                )
                                .font(.footnote.monospacedDigit())
                            } else {
                                Text("Not on the track", bundle: .module).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                WhereItIsWritten(items: pool)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.trackTypes, allowsMultipleSelection: true) { result in
            Task { await load(result) }
        }
        .onChange(of: matches, initial: true) { _, matches in
            edits = matches.map {
                MetadataEdit(fileId: $0.fileId, latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude)
            }
        }
    }

    var mapSection: some View {
        Section {
            let byId: [FileID: MediaItem] = Dictionary(pool.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })
            Map(position: $position) {
                if let track {
                    MapPolyline(coordinates: track.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                        .stroke(Design.accent, lineWidth: 4)
                }
                ForEach(matches.prefix(300), id: \.fileId) { match in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: match.latitude, longitude: match.longitude)) {
                        if let item = byId[match.fileId] {
                            PreviewImage(
                                fileId: item.fileId, etag: item.etag, bucket: 64, blurhash: item.blurhash, hasPreview: item.hasPreview,
                                mimeType: item.mimeType, path: item.path
                            )
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white, lineWidth: 2))
                            .shadow(radius: 2)
                        }
                    }
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    static func offsetText(_ minutes: Int) -> String {
        if minutes == 0 {
            return String(localized: "Correct", bundle: .module, comment: "GPS track: the camera clock needs no correction.")
        }
        let sign: String = minutes > 0 ? "+" : "−"
        let value: Int = abs(minutes)
        let hours: Int = value / 60
        let rest: Int = value % 60
        if hours == 0 { return String(localized: "\(sign)\(rest) min", bundle: .module) }
        if rest == 0 { return String(localized: "\(sign)\(hours) h", bundle: .module) }
        return String(localized: "\(sign)\(hours) h \(rest) min", bundle: .module)
    }

    func load(_ result: Result<[URL], any Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        var tracks: [GeoTrack] = []
        var names: [String] = []
        var problems: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                tracks.append(try GeoTrack.parse(data))
                names.append(url.lastPathComponent)
            } catch {
                problems.append(url.lastPathComponent)
            }
        }
        error =
            problems.isEmpty
            ? nil : String(localized: "No track with times in \(problems.joined(separator: ", ")).", bundle: .module)
        guard !tracks.isEmpty else { return }
        let merged = GeoTrack.merged(tracks)
        track = merged
        fileNames = names
        if items.isEmpty { await loadCandidates(for: merged) }
        let suggestion = GeoTagger.suggestedOffset(
            for: items.isEmpty ? candidates : items, track: merged, tolerance: TimeInterval(toleranceMinutes * 60))
        suggestedMinutes = suggestion.map { Int($0 / 60) }
        if let suggestedMinutes { offsetMinutes = suggestedMinutes }
        position = .automatic
    }

    /// Library photos from the track's time, with 14 hours either side for a camera in another time zone.
    func loadCandidates(for track: GeoTrack) async {
        guard let services = session.services, let start = track.start, let end = track.end else { return }
        let window: TimeInterval = 14 * 3600
        let all: [MediaItem] =
            (try? await OrganizeStore(database: services.database).ruleItems(excludedFolders: session.excludedFolders)) ?? []
        candidates = all.filter {
            $0.timestamp >= start.addingTimeInterval(-window) && $0.timestamp <= end.addingTimeInterval(window) && $0.isOwnStorage
        }
    }
}

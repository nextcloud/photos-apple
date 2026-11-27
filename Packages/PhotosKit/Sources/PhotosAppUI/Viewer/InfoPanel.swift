// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import MapKit
import PhotosCore
import PhotosDomain
import PhotosModel
import SwiftUI

/// Photo details (SPEC §7.4), laid out as an aligned two-column list.
struct InfoPanel: View {
    let item: MediaItem
    /// Shown as an inspector (sidebar) rather than a sheet: no Done button.
    var inInspector = false
    /// The photo as a thumbnail on top. Left out in the viewer, where the panel sits beside the photo itself.
    var showsPreview = true
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var exif: [String: String] = [:]
    @State private var faces: [FaceDetection] = []
    @State private var tags: [SystemTag] = []

    var body: some View {
        Form {
            Section {
                if showsPreview {
                    PreviewImage(item: item, bucket: 256)
                        .frame(height: 160)
                        .clipShape(.rect(cornerRadius: 8))
                        .listRowInsets(EdgeInsets())
                }
                row(String(localized: "Name", bundle: .module), item.name)
                row(String(localized: "Taken", bundle: .module), CaptureTime.format(item.timestamp, offset: captureOffset))
                if let caption = item.caption {
                    row(String(localized: "Description", bundle: .module), caption)
                } else if let described = session.services?.descriptions.text(of: item.fileId) {
                    // Written on this device (SPEC §16.2).
                    row(String(localized: "Description", bundle: .module), described)
                }
            }
            if !faces.isEmpty {
                Section(String(localized: "People", bundle: .module)) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(faces) { face in
                                VStack {
                                    FaceCroppedPreview(fileId: item.fileId, box: face.box).frame(width: 56, height: 56).clipShape(Circle())
                                    Text(face.title ?? "").font(.caption).lineLimit(1)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(face.title.map { Text(verbatim: $0) } ?? Text("Unnamed person", bundle: .module))
                            }
                        }
                    }
                }
            }
            if !tags.isEmpty {
                Section(String(localized: "Tags", bundle: .module)) {
                    Text(tags.map(\.name).joined(separator: ", "))
                }
            }
            if !camera.isEmpty {
                Section(String(localized: "Camera", bundle: .module)) {
                    ForEach(camera, id: \.0) { row($0.0, $0.1) }
                }
            }
            Section(String(localized: "File", bundle: .module)) {
                if let width = item.width, let height = item.height {
                    let megapixels = (Double(width * height) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
                    row(
                        String(localized: "Dimensions", bundle: .module),
                        String(
                            localized: "\(width) × \(height) (\(megapixels) MP)", bundle: .module,
                            comment: "Width × height in pixels and megapixels."))
                }
                row(String(localized: "Size", bundle: .module), Formatters.bytes(item.size))
                row(String(localized: "Type", bundle: .module), MimeTypes.formatName(mimeType: item.mimeType, fileName: item.name))
                row(String(localized: "Folder", bundle: .module), item.directory)
                if OfflineAvailability.isAvailable(item, session: session) {
                    row(String(localized: "Offline", bundle: .module), String(localized: "Available offline", bundle: .module))
                }
                if let owner = item.ownerDisplayName ?? item.ownerId, !item.isOwnStorage {
                    row(String(localized: "Owner", bundle: .module), owner)
                }
                if let duration = item.duration { row(String(localized: "Duration", bundle: .module), Formatters.duration(duration)) }
                // Uploaded by this device's backup (SPEC §21.1).
                BackupInfoRow(item: item)
            }
            if item.hasLocation, let latitude = item.latitude, let longitude = item.longitude {
                Section(String(localized: "Location", bundle: .module)) {
                    if let place = item.place {
                        row(
                            String(localized: "Place", bundle: .module),
                            [place, item.placeCountry.flatMap { Locale.current.localizedString(forRegionCode: $0) }].compactMap { $0 }
                                .joined(separator: ", "))
                    }
                    Map(
                        initialPosition: .region(
                            MKCoordinateRegion(
                                center: .init(latitude: latitude, longitude: longitude), latitudinalMeters: 3000, longitudinalMeters: 3000))
                    ) {
                        Marker(item.place ?? "", coordinate: .init(latitude: latitude, longitude: longitude))
                    }
                    .frame(height: 180)
                    .clipShape(.rect(cornerRadius: 8))
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
            // Section headers in the text colour: the system's grey ones came out at 3.4:1 on the inspector's material
            // (accessibility audit, SPEC §20.3).
            .headerProminence(.increased)
        #endif
        .modifier(InfoPanelTitle(inInspector: inInspector))
        .toolbar {
            if !inInspector {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: .module)) { dismiss() }
                }
            }
        }
        .task(id: item.fileId) {
            guard item.kind == .image, let services = session.services else { return }
            exif = (try? await services.api.exif(userPath: item.path)) ?? [:]
            if session.features.has(.recognize) { faces = (try? await services.api.faceDetections(userPath: item.path)) ?? [] }
            if session.features.has(.systemtags) { tags = (try? await services.api.tags(of: item.fileId)) ?? [] }
        }
    }

    var captureOffset: Int? {
        item.captureOffset ?? exif["OffsetTimeOriginal"].flatMap(CaptureTime.parseOffset)
    }

    var camera: [(String, String)] {
        var rows: [(String, String)] = []
        let model: String = Self.cameraName(make: exif["Make"], model: exif["Model"])
        if !model.isEmpty { rows.append((String(localized: "Camera", bundle: .module), model)) }
        if let lens = exif["LensModel"] { rows.append((String(localized: "Lens", bundle: .module), lens)) }
        var exposure: [String] = []
        if let focal = exif["FocalLength"].flatMap(Self.rational) { exposure.append("\(Int(focal.rounded())) mm") }
        // Photographic notation (ƒ/2.8, 1/250 s), with the locale's decimal separator.
        let oneDecimal: FloatingPointFormatStyle<Double> = .number.precision(.fractionLength(1))
        if let aperture = exif["FNumber"].flatMap(Self.rational) { exposure.append("ƒ/\(aperture.formatted(oneDecimal))") }
        if let time = exif["ExposureTime"].flatMap(Self.rational) {
            exposure.append(time >= 1 ? "\(time.formatted(oneDecimal)) s" : "1/\(Int((1 / time).rounded())) s")
        }
        if let iso = exif["ISOSpeedRatings"] ?? exif["PhotographicSensitivity"] { exposure.append("ISO \(iso)") }
        if !exposure.isEmpty { rows.append((String(localized: "Exposure", bundle: .module), exposure.joined(separator: " · "))) }
        return rows
    }

    /// "Canon EOS 6D", not "Canon Canon EOS 6D": most cameras repeat the maker in the model name, some only its first
    /// word ("NIKON CORPORATION" / "NIKON D750"). The maker is put in front only where the model does not say it.
    nonisolated static func cameraName(make: String?, model: String?) -> String {
        let make: String = (make ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model: String = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !make.isEmpty else { return model }
        guard !model.isEmpty else { return make }
        let brand: String = make.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? make
        if model.range(of: brand, options: [.caseInsensitive, .anchored]) != nil { return model }
        return "\(make) \(model)"
    }

    /// EXIF values come as `"28/10"` or plain numbers.
    static func rational(_ value: String) -> Double? {
        let parts = value.split(separator: "/")
        if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 {
            return numerator / denominator
        }
        return Double(value)
    }

    func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }
}

/// "Info" as title where the panel has a navigation bar of its own (sheets). In an inspector it has none, and the title
/// would replace the window's ("3 selected", the album's name).
private struct InfoPanelTitle: ViewModifier {
    let inInspector: Bool

    func body(content: Content) -> some View {
        #if os(visionOS)
            content.navigationTitle(String(localized: "Info", bundle: .module))
        #else
            if inInspector {
                content
            } else {
                content.navigationTitle(String(localized: "Info", bundle: .module))
            }
        #endif
    }
}

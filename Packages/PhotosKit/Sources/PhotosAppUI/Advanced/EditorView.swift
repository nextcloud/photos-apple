// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import MapKit
import PhotosCore
import PhotosMedia
import PhotosModel
import PhotosNetworking
import SwiftUI

/// Photo editor (SPEC §7.16): geometry, auto-enhance, filters, adjustments; save as copy or overwrite.
struct EditorView: View {
    let item: MediaItem
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var edits = PhotoEdits()
    @State private var history: [PhotoEdits] = []
    @State private var future: [PhotoEdits] = []
    @State private var source: CIImage?
    @State private var preview: CGImage?
    @State private var originalFile: URL?
    @State private var tab = 0
    @State private var saving = false
    @State private var showOriginal = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let image = showOriginal ? source.flatMap(render(original:)) : preview {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .onLongPressGesture(minimumDuration: 0.1) {
                } onPressingChanged: {
                    showOriginal = $0
                }
                Picker("", selection: $tab) {
                    Text("Adjust", bundle: .module).tag(0)
                    Text("Filters", bundle: .module).tag(1)
                    Text("Crop", bundle: .module).tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                controls.frame(height: 200)
            }
            .navigationTitle(String(localized: "Edit", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .module)) { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        if let last = history.popLast() {
                            future.append(edits)
                            edits = last
                        }
                    } label: {
                        Label(String(localized: "Undo", bundle: .module), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(history.isEmpty)
                    Button {
                        if let next = future.popLast() {
                            history.append(edits)
                            edits = next
                        }
                    } label: {
                        Label(String(localized: "Redo", bundle: .module), systemImage: "arrow.uturn.forward")
                    }
                    .disabled(future.isEmpty)
                    Menu(String(localized: "Save", bundle: .module)) {
                        Button(String(localized: "Save as copy", bundle: .module)) { save(overwrite: false) }
                        if item.permissions.canWrite {
                            Button(String(localized: "Overwrite original", bundle: .module)) { save(overwrite: true) }
                        }
                    }
                    .disabled(edits.isIdentity || saving)
                }
            }
            .overlay {
                if saving {
                    ProgressView(String(localized: "Saving…", bundle: .module)).padding().background(
                        .regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
            .alert(
                String(localized: "Couldn't save", bundle: .module),
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
            } message: {
                Text(error ?? "")
            }
        }
        .frame(minWidth: 700, minHeight: 640)
        .task { await loadOriginal() }
        .onChange(of: edits) { old, _ in
            if history.last != old { history.append(old) }
            future = []
            updatePreview()
        }
    }

    @ViewBuilder var controls: some View {
        switch tab {
        case 0:
            ScrollView {
                VStack(spacing: 6) {
                    Toggle(String(localized: "Auto-enhance", bundle: .module), isOn: $edits.autoEnhance)
                    slider(String(localized: "Exposure", bundle: .module), $edits.exposure, -2...2)
                    slider(String(localized: "Brightness", bundle: .module), $edits.brightness, -0.5...0.5)
                    slider(String(localized: "Contrast", bundle: .module), $edits.contrast, 0.5...1.5)
                    slider(String(localized: "Highlights", bundle: .module), $edits.highlights, 0...1)
                    slider(String(localized: "Shadows", bundle: .module), $edits.shadows, -1...1)
                    slider(String(localized: "Saturation", bundle: .module), $edits.saturation, 0...2)
                    slider(String(localized: "Vibrance", bundle: .module), $edits.vibrance, -1...1)
                    slider(String(localized: "Warmth", bundle: .module), $edits.warmth, -1...1)
                    slider(String(localized: "Tint", bundle: .module), $edits.tint, -1...1)
                    slider(String(localized: "Sharpness", bundle: .module), $edits.sharpness, 0...2)
                    slider(String(localized: "Vignette", bundle: .module), $edits.vignette, 0...2)
                }
                .padding(.horizontal)
            }
        case 1:
            ScrollView(.horizontal) {
                HStack {
                    ForEach(PhotoEdits.Filter.allCases, id: \.self) { filter in
                        Button(filter.rawValue.capitalized) { edits.filter = filter }
                            .buttonStyle(.bordered)
                            .tint(edits.filter == filter ? .accentColor : .secondary)
                    }
                }
                .padding()
            }
        default:
            VStack {
                HStack {
                    Button {
                        edits.rotation = (edits.rotation + 3) % 4
                    } label: {
                        Label(String(localized: "Rotate", bundle: .module), systemImage: "rotate.left")
                    }
                    Button {
                        edits.flipped.toggle()
                    } label: {
                        Label(
                            String(localized: "Flip", bundle: .module),
                            systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    Picker(String(localized: "Aspect", bundle: .module), selection: $edits.aspect) {
                        ForEach(PhotoEdits.Aspect.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                slider(String(localized: "Straighten", bundle: .module), $edits.straighten, -45...45)
                Button(String(localized: "Reset", bundle: .module)) { edits = PhotoEdits() }
            }
            .padding()
        }
    }

    func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    func render(original: CIImage) -> CGImage? {
        PhotoEditor.context.createCGImage(original, from: original.extent)
    }

    func loadOriginal() async {
        guard let services = session.services else { return }
        do {
            let file = try await services.images.originals.original(
                fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
            originalFile = file
            // Edit on a ≤ 2048 px proxy for responsiveness; save renders the full original.
            if let image = PhotoEditor.load(file) {
                let scale = min(1, 2048 / max(image.extent.width, image.extent.height))
                source = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            updatePreview()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func updatePreview() {
        guard let source else { return }
        let output = PhotoEditor.apply(edits, to: source)
        preview = PhotoEditor.context.createCGImage(output, from: output.extent)
    }

    func save(overwrite: Bool) {
        guard let originalFile, let services = session.services else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let directory = FileManager.default.temporaryDirectory.appending(path: "Edits/\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let rendered = try PhotoEditor.render(edits, original: originalFile, to: directory)
                if overwrite {
                    _ = try await services.dav.put(services.connection.filesURL(item.path), file: rendered)
                } else {
                    let uploaded = try await Uploader(dav: services.dav).upload(
                        file: rendered, fileName: rendered.lastPathComponent, folder: item.directory, capturedAt: item.capturedAt)
                    // Keep the copy in the same own albums.
                    for album in (try? services.collections.albums(.own)) ?? [] {
                        if (try? services.collections.albumItems(albumId: album.id).contains { $0.fileId == item.fileId }) == true {
                            try? await services.api.addToAlbum(album, userPath: uploaded.path)
                        }
                    }
                }
                try? FileManager.default.removeItem(at: directory)
                await session.syncNow()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Edit capture date and location of one or many photos (SPEC §7.16.3).
struct MetadataEditor: View {
    let items: [MediaItem]
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var date = Date()
    @State private var shiftDays = 0
    @State private var shiftHours = 0
    @State private var shiftMinutes = 0
    @State private var changeLocation = false
    @State private var removeLocation = false
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Date and time", bundle: .module)) {
                    Picker("", selection: $mode) {
                        Text("Keep", bundle: .module).tag(0)
                        Text("Shift", bundle: .module).tag(1)
                        Text("Set", bundle: .module).tag(2)
                    }
                    .pickerStyle(.segmented)
                    if mode == 1 {
                        Stepper(String(localized: "Days: \(shiftDays)", bundle: .module), value: $shiftDays)
                        Stepper(String(localized: "Hours: \(shiftHours)", bundle: .module), value: $shiftHours)
                        Stepper(String(localized: "Minutes: \(shiftMinutes)", bundle: .module), value: $shiftMinutes)
                    } else if mode == 2 {
                        DatePicker(String(localized: "Date", bundle: .module), selection: $date)
                    }
                }
                Section(String(localized: "Location", bundle: .module)) {
                    Toggle(String(localized: "Change location", bundle: .module), isOn: $changeLocation)
                    if changeLocation {
                        Toggle(String(localized: "Remove location", bundle: .module), isOn: $removeLocation)
                        if !removeLocation {
                            MapReader { proxy in
                                Map(position: $position) {
                                    if let coordinate { Marker("", coordinate: coordinate) }
                                }
                                .onTapGesture { point in coordinate = proxy.convert(point, from: .local) }
                            }
                            .frame(height: 240)
                            Text("Tap the map to choose the place.", bundle: .module).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Edit date and location", bundle: .module))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .module)) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: .module)) { save() }
                }
            }
            .onAppear {
                date = items.first?.timestamp ?? Date()
                if let item = items.first, let lat = item.latitude, let lon = item.longitude {
                    coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    position = .region(MKCoordinateRegion(center: coordinate!, latitudinalMeters: 5000, longitudinalMeters: 5000))
                }
            }
        }
        .frame(minWidth: 420, minHeight: 560)
    }

    /// Split out (with explicit types) so the compiler type-checks it quickly on every platform.
    func save() {
        let days: Int = shiftDays * 86_400
        let hours: Int = shiftHours * 3600
        let minutes: Int = shiftMinutes * 60
        let shift = TimeInterval(days + hours + minutes)
        let mode: Int = self.mode
        let date: Date = self.date
        let setsLocation: Bool = changeLocation && !removeLocation
        let latitude: Double? = setsLocation ? coordinate?.latitude : nil
        let longitude: Double? = setsLocation ? coordinate?.longitude : nil
        let clearsLocation: Bool = changeLocation && removeLocation
        let capturedAt: (MediaItem) -> Date? = { item in
            switch mode {
            case 1: return item.timestamp.addingTimeInterval(shift)
            case 2: return date
            default: return nil
            }
        }
        Task {
            await session.setMetadata(items, capturedAt: capturedAt, latitude: latitude, longitude: longitude, removeLocation: clearsLocation)
            dismiss()
        }
    }
}

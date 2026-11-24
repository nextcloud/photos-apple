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
    /// The crop tool shows the whole picture with the crop's frame over it.
    @State private var uncropped: CGImage?
    /// The crop while a handle is dragged; it becomes an edit (one undo step) when the drag ends.
    @State private var draftCrop: CropRect?
    @State private var originalFile: URL?
    @State private var tab = 0
    @State private var saving = false
    @State private var showOriginal = false
    @State private var error: String?
    /// Width of the adjustment names; grows with the text size.
    @ScaledMetric(relativeTo: .body) private var labelWidth = 110.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    picture
                }
                Picker(String(localized: "Tools", bundle: .module), selection: $tab) {
                    Text("Adjust", bundle: .module).tag(0)
                    Text("Filters", bundle: .module).tag(1)
                    Text("Crop", bundle: .module).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
                        // Not for read-only shares or formats that can't be written back (SPEC §7.16.2).
                        if PhotoEditSaving.overwriteProblem(item) == nil {
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
        #if os(macOS)
            // The sheet's smallest size on the Mac. Elsewhere the presentation has the size: on iPad this made the editor
            // wider than its sheet, which cut off the picture's sides and the lower tools.
            .frame(minWidth: 700, minHeight: 640)
        #endif
        .task { await loadOriginal() }
        .onChange(of: edits) { old, _ in
            if history.last != old { history.append(old) }
            future = []
            updatePreview()
        }
        .onChange(of: tab) { _, _ in updatePreview() }
    }

    var isCropping: Bool { tab == 2 }

    /// The edited photo; in the crop tool the whole picture with the crop's frame and handles. Pressing and holding shows
    /// the original (not while cropping: there a press starts a drag).
    @ViewBuilder var picture: some View {
        if isCropping, let uncropped {
            let size = CGSize(width: uncropped.width, height: uncropped.height)
            let current: CropRect = PhotoEditor.cropArea(edits, size: size) ?? .full
            // The frame is the accessible element (its value and adjustable action), not the picture under it.
            Image(decorative: uncropped, scale: 1).resizable().scaledToFit()
                .accessibilityHidden(true)
                .overlay {
                    CropOverlay(
                        area: draftCrop ?? current, pictureSize: size, locksAspect: edits.aspectLocked,
                        changing: { draftCrop = $0 },
                        changed: { area in
                            draftCrop = nil
                            if area != current { edits.crop = area }
                        })
                }
                .padding(12)
        } else if let image = showOriginal ? source.flatMap(render(original:)) : preview {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    showOriginal ? Text("Original photo", bundle: .module) : Text("Edited photo", bundle: .module)
                )
                .accessibilityAddTraits(.isImage)
                .onLongPressGesture(minimumDuration: 0.1) {
                } onPressingChanged: {
                    showOriginal = $0
                }
        } else {
            ProgressView().tint(.white)
        }
    }

    /// The size of the picture the crop works on (after straighten, turns and flip), in proxy pixels.
    var cropPictureSize: CGSize? {
        uncropped.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// A preset: its ratio is locked and its largest area in the middle is the new crop ("Free" only unlocks).
    func choose(_ aspect: PhotoEdits.Aspect) {
        var next = edits
        next.aspect = aspect
        next.aspectLocked = aspect != .free
        if aspect != .free, let size = cropPictureSize, let ratio = aspect.pixelAspect(for: size) {
            next.crop = CropRect.centered(aspect: ratio, in: size)
        }
        edits = next
    }

    var aspectLock: Binding<Bool> {
        Binding(
            get: { edits.aspectLocked },
            set: { locked in
                var next = edits
                next.aspectLocked = locked
                // Unlocked, the frame is free: the preset no longer applies.
                if !locked {
                    if next.crop == nil, let size = cropPictureSize { next.crop = PhotoEditor.cropArea(next, size: size) }
                    next.aspect = .free
                }
                edits = next
            })
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
                        Button(Self.title(of: filter)) { edits.filter = filter }
                            .buttonStyle(.bordered)
                            .tint(edits.filter == filter ? .accentColor : .secondary)
                            .accessibilityAddTraits(edits.filter == filter ? .isSelected : [])
                    }
                }
                .padding()
            }
        default:
            VStack {
                HStack {
                    Button {
                        edits.rotate(clockwise: false)
                    } label: {
                        Label(String(localized: "Rotate Left", bundle: .module), systemImage: "rotate.left")
                    }
                    Button {
                        edits.rotate(clockwise: true)
                    } label: {
                        Label(String(localized: "Rotate Right", bundle: .module), systemImage: "rotate.right")
                    }
                    Button {
                        edits.flip()
                    } label: {
                        Label(
                            String(localized: "Flip", bundle: .module),
                            systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                }
                HStack {
                    Picker(
                        String(localized: "Aspect", bundle: .module),
                        selection: Binding<PhotoEdits.Aspect>(get: { edits.aspect }, set: { choose($0) })
                    ) {
                        ForEach(PhotoEdits.Aspect.allCases, id: \.self) { Text(Self.title(of: $0)).tag($0) }
                    }
                    .fixedSize()
                    Toggle(isOn: aspectLock) {
                        Label(
                            String(localized: "Lock Aspect Ratio", bundle: .module, comment: "Crop tool: resizing keeps the ratio."),
                            systemImage: edits.aspectLocked ? "lock" : "lock.open")
                    }
                    .toggleStyle(.button)
                    .help(String(localized: "Lock Aspect Ratio", bundle: .module, comment: "Crop tool: resizing keeps the ratio."))
                }
                slider(String(localized: "Straighten", bundle: .module), $edits.straighten, -45...45)
                Button(String(localized: "Reset", bundle: .module)) { edits = PhotoEdits() }
            }
            .padding()
        }
    }

    func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: labelWidth, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: value, in: range) { Text(title) }
                .accessibilityValue(value.wrappedValue.formatted(.number.precision(.fractionLength(0...2))))
        }
    }

    static func title(of filter: PhotoEdits.Filter) -> String {
        switch filter {
        case .none: String(localized: "None", bundle: .module, comment: "Photo filter: no filter.")
        case .vivid: String(localized: "Vivid", bundle: .module, comment: "Photo filter.")
        case .vividWarm: String(localized: "Vivid warm", bundle: .module, comment: "Photo filter.")
        case .vividCool: String(localized: "Vivid cool", bundle: .module, comment: "Photo filter.")
        case .dramatic: String(localized: "Dramatic", bundle: .module, comment: "Photo filter.")
        case .mono: String(localized: "Mono", bundle: .module, comment: "Photo filter.")
        case .silvertone: String(localized: "Silvertone", bundle: .module, comment: "Photo filter.")
        case .noir: String(localized: "Noir", bundle: .module, comment: "Photo filter.")
        }
    }

    static func title(of aspect: PhotoEdits.Aspect) -> String {
        switch aspect {
        case .free: String(localized: "Freeform", bundle: .module, comment: "Crop aspect ratio: any, dragged by hand.")
        case .original: String(localized: "Original", bundle: .module, comment: "Crop aspect ratio: the photo's own.")
        case .square: String(localized: "Square", bundle: .module, comment: "Crop aspect ratio.")
        // Ratios read the same in every language.
        case .fourThree, .sixteenNine, .threeTwo: aspect.rawValue
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
        if isCropping {
            let output = PhotoEditor.applyWithoutCrop(edits, to: source)
            uncropped = PhotoEditor.context.createCGImage(output, from: output.extent)
        } else {
            let output = PhotoEditor.apply(edits, to: source)
            preview = PhotoEditor.context.createCGImage(output, from: output.extent)
        }
    }

    func save(overwrite: Bool) {
        guard let originalFile, let services = session.services else { return }
        saving = true
        let item = item
        let edits = edits
        Task {
            defer { saving = false }
            do {
                // Rendered off the main thread (`PhotoEditSaving` is not bound to it): the UI stays responsive.
                if overwrite {
                    try await PhotoEditSaving.overwrite(item, with: edits, original: originalFile, services: services)
                } else {
                    try await PhotoEditSaving.saveCopy(item, with: edits, original: originalFile, services: services)
                }
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
            await session.setMetadata(
                items, capturedAt: capturedAt, latitude: latitude, longitude: longitude, removeLocation: clearsLocation)
            dismiss()
        }
    }
}

extension View {
    /// Shows the photo editor for `item`: full screen on iPad, as in Photos (a form sheet left the picture a few
    /// centimetres wide), a sheet elsewhere.
    @ViewBuilder func photoEditor(_ item: Binding<MediaItem?>) -> some View {
        #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                fullScreenCover(item: item) { (item: MediaItem) in EditorView(item: item) }
            } else {
                sheet(item: item) { (item: MediaItem) in EditorView(item: item) }
            }
        #else
            sheet(item: item) { (item: MediaItem) in EditorView(item: item) }
        #endif
    }
}

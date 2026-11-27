// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import MapKit
import PhotosCore
import PhotosMedia
import PhotosModel
import PhotosNetworking
import SwiftUI

/// What the editor changes, as one value: one step of its undo and redo.
struct EditorState: Equatable {
    var edits = PhotoEdits()
    /// RAW development; nil while the photo is not developed from RAW.
    var raw: RAWAdjustments?
    var live: LivePhotoEffect?
    var retouch: RetouchSteps?  // Erase tool (SPEC §21.5)

    init(edits: PhotoEdits = PhotoEdits(), raw: RAWAdjustments? = nil, live: LivePhotoEffect? = nil) {
        self.edits = edits
        self.raw = raw
        self.live = live
    }

    init(_ recipe: EditRecipe?) {
        self.init(edits: recipe?.edits ?? PhotoEdits(), raw: recipe?.raw, live: recipe?.live)
        retouch = recipe?.retouch
    }

    /// The recipe the editor saves.
    func recipe(developsRAW: Bool) -> EditRecipe {
        EditRecipe(
            edits: edits, raw: developsRAW ? (raw ?? RAWAdjustments()) : nil, live: live?.isIdentity == true ? nil : live, retouch: retouch)
    }

    /// Nothing that shows: Done saves no edit (or reverts one).
    var isIdentity: Bool { recipe(developsRAW: raw != nil).isIdentity }
}

/// Photo editor (SPEC §7.16, §16.3, §21.6): geometry, auto-enhance, presets, filters, adjustments, noise reduction,
/// curves, colour mixer, masks, RAW development and Live Photo effects. Non-destructive: Done saves an edit recipe in the
/// user's Nextcloud and the original stays as it is — unless "Apply Edits to the File" is on, then the edit is written
/// into the file and the original kept as a named file version. "Save as Copy" writes a new file, "Overwrite
/// Original…" (secondary) replaces the file once.
struct EditorView: View {
    let item: MediaItem
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var state = EditorState()
    @State private var history: [EditorState] = []
    /// Set while Undo or Redo puts a state back (or the editor loads): that is not a new step.
    @State private var restoring = false
    @State private var future: [EditorState] = []
    /// What the photo shows now (its recipe when the editor opened): Done with no change saves nothing.
    @State private var saved = EditorState()
    @State private var hadEdit = false
    /// The photo (non-RAW) at proxy size.
    @State private var source: CIImage?
    /// The RAW being developed (the photo itself, or the RAW file beside a JPEG), at proxy size.
    @State private var rawFilter: CIRAWFilter?
    @State private var rawInfo: EditRendering.RAWInfo?
    @State private var rawItem: MediaItem?
    @State private var rawFile: URL?
    /// The RAW or JPEG beside this photo (same shot), if any.
    @State private var partner: MediaItem?
    /// The still of a Live Photo effect (long exposure, another key photo), at proxy size.
    @State private var liveStill: CIImage?
    @State private var motionFile: URL?
    @State private var motionDuration: Double = 0
    @State private var preview: CGImage?
    /// The crop tool shows the whole picture with the crop's frame over it.
    @State private var uncropped: CGImage?
    /// The crop while a handle is dragged; it becomes an edit (one undo step) when the drag ends.
    @State private var draftCrop: CropRect?
    @State private var originalFile: URL?
    @State private var tab: Tool = .adjust
    @State private var working: String?
    @State private var showOriginal = false
    @State private var confirmingOverwrite = false
    @State private var confirmingRevert = false
    /// The recipe on the server was written by a newer version of the app.
    @State private var newerFormat = false
    @State private var error: String?
    /// "Apply Edits to the File" (SPEC §21.6.6): Done writes the edit into the file.
    @AppStorage(PhotoEditSaving.applyToFileKey) private var applyToFile = false
    @State private var confirmingApplyToFile = false
    /// The file has an original the app kept (a named version): "Restore Original…" puts it back.
    @State private var keptOriginal = false
    @State private var confirmingRestore = false
    /// The mask shown and changed in the Masks tool.
    @State private var selectedMask: Int?
    /// The chosen mask tinted over the picture; nil when there is none (yet).
    @State private var maskOverlay: CGImage?
    @State private var maskFound: Bool?
    @State private var userPresets: [EditPreset] = []
    /// Small previews of the photo with each preset, by preset id (made off the main thread when the tool opens).
    @State private var presetThumbnails: [String: CGImage] = [:]
    @State private var namingPreset = false
    @State private var presetName = ""
    /// Width of the adjustment names; grows with the text size.
    @State private var removeTool = RemoveToolModel()
    @ScaledMetric(relativeTo: .body) private var labelWidth = 110.0

    /// The editor's tools, in the order of the tool bar. Another package's tool adds its case here, its title and symbol
    /// below, its place in `tools` and its panel in `controls`.
    enum Tool: Hashable, CaseIterable {
        case adjust, crop, presets, filters, curves, color, masks, raw, live, remove

        var title: String {
            switch self {
            case .adjust: String(localized: "Adjust", bundle: .module)
            case .presets: String(localized: "Presets", bundle: .module, comment: "Editor tool: saved looks.")
            case .filters: String(localized: "Filters", bundle: .module)
            case .curves: String(localized: "Curves", bundle: .module, comment: "Editor tool: tone curves.")
            case .color: String(localized: "Color", bundle: .module, comment: "Editor tool: hue, saturation and luminance per colour.")
            case .masks: String(localized: "Masks", bundle: .module, comment: "Editor tool: adjustments of the subject, sky…")
            case .crop: String(localized: "Crop", bundle: .module)
            case .raw: String(localized: "RAW", bundle: .module, comment: "Editor tool: RAW development (exposure, white balance…).")
            case .live: String(localized: "Live", bundle: .module, comment: "Editor tool: Live Photo effects and key photo.")
            case .remove: RemoveTool.titleString
            }
        }

        var symbol: String {
            switch self {
            case .adjust: "dial.medium"
            case .presets: "square.stack"
            case .filters: "camera.filters"
            case .curves: "point.bottomleft.forward.to.point.topright.scurvepath"
            case .color: "paintpalette"
            case .masks: "person.and.background.dotted"
            case .crop: "crop.rotate"
            case .raw: "camera.aperture"
            case .live: "livephoto"
            case .remove: RemoveTool.symbol
            }
        }
    }

    /// The tools this photo offers; the everyday ones first (Adjust and Crop fit on the narrowest iPhone without scrolling).
    var tools: [Tool] {
        var tools: [Tool] = [.adjust, .crop, .remove, .presets, .filters, .curves, .color, .masks]
        if developsRAW || partnerIsRAW { tools.append(.raw) }
        if item.isLivePhoto { tools.append(.live) }
        return tools
    }

    /// Proxy size the editor works on; save and export render the full original.
    static let proxySize = 2048

    var developsRAW: Bool { rawFilter != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if newerFormat {
                    Label(
                        String(
                            localized: "This photo was edited with a newer version of the app. Saving here replaces that edit.",
                            bundle: .module, comment: "Editor: the photo's edit recipe has a format this version does not know."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .padding(8)
                }
                ZStack {
                    Color.black
                    picture
                    if tab == .masks, !showOriginal, let maskOverlay {
                        Image(decorative: maskOverlay, scale: 1).resizable().scaledToFit()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    if tab == .live, let live = state.live, live.playsByItself {
                        LiveEffectPlayer(item: item, effect: live.effect, recipe: state.recipe(developsRAW: developsRAW))
                            .allowsHitTesting(false)
                    }
                }
                toolBar
                controls.frame(height: tab == .curves ? 260 : 200)
            }
            .navigationTitle(String(localized: "Edit", bundle: .module))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .overlay {
                if let working {
                    ProgressView(working).padding().background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
            .alert(
                String(localized: "Couldn't save", bundle: .module),
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
            } message: {
                Text(error ?? "")
            }
            .confirmationDialog(
                String(localized: "Overwrite the original?", bundle: .module, comment: "Editor: asks before replacing the file."),
                isPresented: $confirmingOverwrite, titleVisibility: .visible
            ) {
                Button(String(localized: "Overwrite Original", bundle: .module, comment: "Editor: replaces the file."), role: .destructive)
                {
                    save(.overwrite)
                }
            } message: {
                Text(
                    "The edit is written into the file itself, for every app. The previous version stays in the file's versions on your Nextcloud.",
                    bundle: .module, comment: "Editor: what Overwrite Original does.")
            }
            .confirmationDialog(
                String(localized: "Apply edits to the file?", bundle: .module, comment: "Editor: asks before turning the option on."),
                isPresented: $confirmingApplyToFile, titleVisibility: .visible
            ) {
                Button(
                    String(
                        localized: "Apply Edits to the File", bundle: .module, comment: "Editor option: Done writes the edit into the file."
                    )
                ) {
                    applyToFile = true
                }
            } message: {
                Text(
                    "Done then writes your edits into the photo's file, so the web and every other app show them. The original is kept as a named version on your Nextcloud and can be restored at any time. Edits saved this way can't be changed later with the sliders.",
                    bundle: .module, comment: "Editor: what Apply Edits to the File does.")
            }
            .confirmationDialog(
                String(
                    localized: "Restore the original?", bundle: .module, comment: "Editor: asks before restoring the kept original version."
                ),
                isPresented: $confirmingRestore, titleVisibility: .visible
            ) {
                Button(
                    String(localized: "Restore Original", bundle: .module, comment: "Editor: puts the kept original back as the file."),
                    role: .destructive
                ) {
                    restoreOriginal()
                }
            } message: {
                Text(
                    "The original becomes the photo's file again. The edited picture stays in the file's versions on your Nextcloud.",
                    bundle: .module, comment: "Editor: what Restore Original does.")
            }
            .alert(
                String(localized: "Save as Preset", bundle: .module, comment: "Editor: title of the alert that names a new preset."),
                isPresented: $namingPreset
            ) {
                TextField(String(localized: "Name", bundle: .module), text: $presetName)
                Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
                Button(String(localized: "Save", bundle: .module)) { savePreset() }
                    .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text(
                    "The look of this edit — without crop and turns — on all your devices.", bundle: .module,
                    comment: "Editor: what a preset keeps.")
            }
            .confirmationDialog(
                String(localized: "Revert to the original?", bundle: .module, comment: "Editor: asks before removing all edits."),
                isPresented: $confirmingRevert, titleVisibility: .visible
            ) {
                Button(String(localized: "Revert to Original", bundle: .module), role: .destructive) { revert() }
            } message: {
                Text(
                    "All edits of this photo are removed on all your devices. You can undo this.", bundle: .module,
                    comment: "Editor: what Revert to Original does.")
            }
        }
        #if os(macOS)
            // The sheet's smallest size on the Mac. Elsewhere the presentation has the size: on iPad this made the editor
            // wider than its sheet, which cut off the picture's sides and the lower tools.
            .frame(minWidth: 700, minHeight: 640)
        #endif
        .task { await load() }
        .task(id: MaskRequest(tab: tab, mask: selectedMaskTarget, hasSource: baseImage != nil)) { await updateMaskOverlay() }
        .task(id: PresetRequest(open: tab == .presets, hasSource: baseImage != nil, presets: userPresets.map(\.id))) {
            await updatePresetThumbnails()
        }
        .onChange(of: state) { old, new in
            if restoring {
                restoring = false
            } else {
                if history.last != old { history.append(old) }
                future = []
            }
            if old.live != new.live {
                Task { await updateLiveStill() }
            } else {
                updatePreview()
            }
        }
        .onChange(of: tab) { _, _ in updatePreview() }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel", bundle: .module)) { dismiss() } }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let last = history.popLast() {
                    future.append(state)
                    restoring = true
                    state = last
                }
            } label: {
                Label(String(localized: "Undo", bundle: .module), systemImage: "arrow.uturn.backward")
            }
            .disabled(history.isEmpty)
            Button {
                if let next = future.popLast() {
                    history.append(state)
                    restoring = true
                    state = next
                }
            } label: {
                Label(String(localized: "Redo", bundle: .module), systemImage: "arrow.uturn.forward")
            }
            .disabled(future.isEmpty)
            Menu {
                Button(String(localized: "Copy Edits", bundle: .module, comment: "Editor: copies the look of this edit for other photos."))
                {
                    EditClipboard.look = state.recipe(developsRAW: developsRAW)
                }
                .disabled(!state.recipe(developsRAW: developsRAW).hasLook)
                if let look = EditClipboard.look {
                    Button(String(localized: "Paste Edits", bundle: .module, comment: "Editor: applies copied edits to this photo.")) {
                        apply(look: look)
                    }
                }
                Divider()
                Button(String(localized: "Save as Copy", bundle: .module, comment: "Editor: writes the edited photo as a new file.")) {
                    save(.copy)
                }
                .disabled(state.isIdentity)
                // Not for read-only shares, formats that can't be written back, or a JPEG developed from its RAW.
                if PhotoEditSaving.overwriteProblem(item) == nil && !developsRAW {
                    Button(String(localized: "Overwrite Original…", bundle: .module, comment: "Editor: replaces the file (secondary).")) {
                        confirmingOverwrite = true
                    }
                    .disabled(state.isIdentity)
                }
                Toggle(
                    String(
                        localized: "Apply Edits to the File", bundle: .module, comment: "Editor option: Done writes the edit into the file."
                    ),
                    isOn: Binding(get: { applyToFile }, set: { on in if on { confirmingApplyToFile = true } else { applyToFile = false } }))
                if hadEdit {
                    Divider()
                    Button(String(localized: "Revert to Original", bundle: .module), role: .destructive) { confirmingRevert = true }
                }
                if keptOriginal {
                    if !hadEdit { Divider() }
                    Button(
                        String(localized: "Restore Original…", bundle: .module, comment: "Editor: puts the kept original version back."),
                        role: .destructive
                    ) { confirmingRestore = true }
                }
            } label: {
                Label(String(localized: "More", bundle: .module), systemImage: "ellipsis.circle")
            }
            .disabled(working != nil)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Done", bundle: .module)) { done() }
                .disabled(working != nil)
        }
    }

    var isCropping: Bool { tab == .crop }

    /// The tools as a row of buttons (icon and name) that scrolls sideways when it does not fit.
    var toolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tools, id: \.self) { tool in
                    Button {
                        tab = tool
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tool.symbol).font(.title3).frame(height: 24)
                            Text(tool.title).font(.caption).lineLimit(1)
                        }
                        .frame(minWidth: 58)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .foregroundStyle(tab == tool ? Color.accentColor : Color.primary)
                        .background(tab == tool ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(tab == tool ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 6)
    }

    /// A slider as the panels of other files draw it.
    var panelSlider: (String, Binding<Double>, ClosedRange<Double>) -> AnyView {
        { title, value, range in AnyView(slider(title, value, range)) }
    }

    var partnerIsRAW: Bool { partner.map { EditRendering.isRAW(name: $0.name) } ?? false }

    /// The edited photo; in the crop tool the whole picture with the crop's frame and handles. Pressing and holding shows
    /// the original (not while cropping: there a press starts a drag).
    @ViewBuilder var picture: some View {
        if isCropping, let uncropped {
            let size = CGSize(width: uncropped.width, height: uncropped.height)
            let current: CropRect = PhotoEditor.cropArea(state.edits, size: size) ?? .full
            // The frame is the accessible element (its value and adjustable action), not the picture under it.
            Image(decorative: uncropped, scale: 1).resizable().scaledToFit()
                .accessibilityHidden(true)
                .overlay {
                    CropOverlay(
                        area: draftCrop ?? current, pictureSize: size, locksAspect: state.edits.aspectLocked,
                        changing: { draftCrop = $0 },
                        changed: { area in
                            draftCrop = nil
                            if area != current { state.edits.crop = area }
                        })
                }
                .padding(12)
        } else if let image = showOriginal ? originalPicture : preview {
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
                .overlay {
                    if tab == .remove {
                        RemoveToolCanvas(model: removeTool, steps: $state.retouch, base: baseImage?.image, edits: state.edits)
                    }
                }
        } else {
            // The preview the grid and viewer already have (or its BlurHash) until the original is decoded.
            PreviewImage(item: item, bucket: 1024, contentMode: .fit)
                .accessibilityHidden(true)
        }
    }

    /// The photo without any edit, for press-and-hold.
    var originalPicture: CGImage? {
        guard let image = source ?? rawFilter.flatMap({ Self.defaultDevelopment($0) }) else { return nil }
        return PhotoEditor.context.createCGImage(image, from: image.extent)
    }

    static func defaultDevelopment(_ filter: CIRAWFilter) -> CIImage? {
        EditRendering.configure(filter, RAWAdjustments())
        return filter.outputImage
    }

    /// The size of the picture the crop works on (after straighten, turns and flip), in proxy pixels.
    var cropPictureSize: CGSize? {
        uncropped.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// A preset: its ratio is locked and its largest area in the middle is the new crop ("Free" only unlocks).
    func choose(_ aspect: PhotoEdits.Aspect) {
        var next = state.edits
        next.aspect = aspect
        next.aspectLocked = aspect != .free
        if aspect != .free, let size = cropPictureSize, let ratio = aspect.pixelAspect(for: size) {
            next.crop = CropRect.centered(aspect: ratio, in: size)
        }
        state.edits = next
    }

    var aspectLock: Binding<Bool> {
        Binding(
            get: { state.edits.aspectLocked },
            set: { locked in
                var next = state.edits
                next.aspectLocked = locked
                // Unlocked, the frame is free: the preset no longer applies.
                if !locked {
                    if next.crop == nil, let size = cropPictureSize { next.crop = PhotoEditor.cropArea(next, size: size) }
                    next.aspect = .free
                }
                state.edits = next
            })
    }

    @ViewBuilder var controls: some View {
        switch tab {
        case .adjust:
            ScrollView {
                VStack(spacing: 6) {
                    Toggle(String(localized: "Auto-enhance", bundle: .module), isOn: $state.edits.autoEnhance)
                    slider(String(localized: "Exposure", bundle: .module), $state.edits.exposure, -2...2)
                    slider(String(localized: "Brightness", bundle: .module), $state.edits.brightness, -0.5...0.5)
                    slider(String(localized: "Contrast", bundle: .module), $state.edits.contrast, 0.5...1.5)
                    slider(String(localized: "Highlights", bundle: .module), $state.edits.highlights, 0...1)
                    slider(String(localized: "Shadows", bundle: .module), $state.edits.shadows, -1...1)
                    slider(String(localized: "Saturation", bundle: .module), $state.edits.saturation, 0...2)
                    slider(String(localized: "Vibrance", bundle: .module), $state.edits.vibrance, -1...1)
                    slider(String(localized: "Warmth", bundle: .module), $state.edits.warmth, -1...1)
                    slider(String(localized: "Tint", bundle: .module), $state.edits.tint, -1...1)
                    slider(String(localized: "Sharpness", bundle: .module), $state.edits.sharpness, 0...2)
                    slider(String(localized: "Vignette", bundle: .module), $state.edits.vignette, 0...2)
                    slider(
                        String(localized: "Noise Reduction", bundle: .module, comment: "RAW development: luminance noise reduction."),
                        $state.edits.noiseReduction, 0...1)
                    slider(
                        String(localized: "Color Noise", bundle: .module, comment: "Editor: colour noise reduction (blotches of colour)."),
                        $state.edits.colorNoiseReduction, 0...1)
                }
                .padding(.horizontal)
            }
        case .presets:
            PresetsPanel(
                presets: PresetsPanel.all(user: userPresets), thumbnail: { presetThumbnails[$0.id] }, apply: { apply(look: $0.recipe) },
                delete: { deletePreset($0) },
                saveCurrent: state.recipe(developsRAW: developsRAW).hasLook
                    ? {
                        presetName = ""
                        namingPreset = true
                    } : nil)
        case .curves:
            CurvesPanel(curves: $state.edits.curves)
        case .color:
            ColorMixerPanel(mixer: $state.edits.colorMixer, slider: panelSlider)
        case .masks:
            MasksPanel(masks: $state.edits.masks, selected: $selectedMask, found: maskFound, slider: panelSlider)
        case .filters:
            ScrollView(.horizontal) {
                HStack {
                    ForEach(PhotoEdits.Filter.allCases, id: \.self) { filter in
                        Button(Self.title(of: filter)) { state.edits.filter = filter }
                            .buttonStyle(.bordered)
                            .tint(state.edits.filter == filter ? .accentColor : .secondary)
                            .accessibilityAddTraits(state.edits.filter == filter ? .isSelected : [])
                    }
                }
                .padding()
            }
        case .crop:
            cropControls
        case .raw:
            rawControls
        case .live:
            liveControls
        case .remove:
            RemoveToolPanel(model: removeTool, steps: $state.retouch, base: baseImage?.image)
        }
    }

    var cropControls: some View {
        VStack {
            HStack {
                Button {
                    state.edits.rotate(clockwise: false)
                } label: {
                    Label(String(localized: "Rotate Left", bundle: .module), systemImage: "rotate.left")
                }
                Button {
                    state.edits.rotate(clockwise: true)
                } label: {
                    Label(String(localized: "Rotate Right", bundle: .module), systemImage: "rotate.right")
                }
                Button {
                    state.edits.flip()
                } label: {
                    Label(
                        String(localized: "Flip", bundle: .module),
                        systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
            }
            HStack {
                Picker(
                    String(localized: "Aspect", bundle: .module),
                    selection: Binding<PhotoEdits.Aspect>(get: { state.edits.aspect }, set: { choose($0) })
                ) {
                    ForEach(PhotoEdits.Aspect.allCases, id: \.self) { Text(Self.title(of: $0)).tag($0) }
                }
                .fixedSize()
                Toggle(isOn: aspectLock) {
                    Label(
                        String(localized: "Lock Aspect Ratio", bundle: .module, comment: "Crop tool: resizing keeps the ratio."),
                        systemImage: state.edits.aspectLocked ? "lock" : "lock.open")
                }
                .toggleStyle(.button)
                .help(String(localized: "Lock Aspect Ratio", bundle: .module, comment: "Crop tool: resizing keeps the ratio."))
            }
            slider(String(localized: "Straighten", bundle: .module), $state.edits.straighten, -45...45)
            Button(String(localized: "Reset", bundle: .module)) { state.edits = PhotoEdits() }
        }
        .padding()
    }

    /// A RAW setting; its value is created when the photo is developed from RAW.
    func rawBinding<Value>(_ keyPath: WritableKeyPath<RAWAdjustments, Value>) -> Binding<Value> {
        Binding(
            get: { (state.raw ?? RAWAdjustments())[keyPath: keyPath] },
            set: { value in
                var raw = state.raw ?? RAWAdjustments()
                raw[keyPath: keyPath] = value
                state.raw = raw
            })
    }

    /// An optional RAW setting (nil keeps the decoder's default), shown from 0.
    func optionalRAW(_ keyPath: WritableKeyPath<RAWAdjustments, Double?>) -> Binding<Double> {
        Binding(
            get: { state.raw?[keyPath: keyPath] ?? 0 },
            set: { value in
                var raw = state.raw ?? RAWAdjustments()
                raw[keyPath: keyPath] = value
                state.raw = raw
            })
    }

    /// White balance in Kelvin, starting from the camera's.
    var temperature: Binding<Double> {
        Binding(
            get: { state.raw?.temperature ?? rawInfo?.temperature ?? EditRendering.assumedAsShotTemperature },
            set: { value in
                var raw = state.raw ?? RAWAdjustments()
                raw.temperature = value
                state.raw = raw
            })
    }

    var tint: Binding<Double> {
        Binding(
            get: { state.raw?.tint ?? rawInfo?.tint ?? 0 },
            set: { value in
                var raw = state.raw ?? RAWAdjustments()
                raw.tint = value
                state.raw = raw
            })
    }

    @ViewBuilder var rawControls: some View {
        if developsRAW {
            ScrollView {
                VStack(spacing: 6) {
                    slider(
                        String(localized: "RAW Exposure", bundle: .module, comment: "RAW development: exposure in EV."),
                        rawBinding(\.exposure), -3...3)
                    slider(
                        String(localized: "Temperature", bundle: .module, comment: "RAW development: white balance in Kelvin."),
                        temperature,
                        2000...12000)
                    slider(
                        String(localized: "RAW Tint", bundle: .module, comment: "RAW development: white balance tint."), tint, -150...150)
                    slider(
                        String(localized: "Shadow Boost", bundle: .module, comment: "RAW development: lifts the shadows."),
                        rawBinding(\.shadowBoost), 0...1)
                    if rawInfo?.supportsHighlightRecovery ?? true {
                        Toggle(
                            String(
                                localized: "Recover Highlights", bundle: .module, comment: "RAW development: brings back blown highlights."),
                            isOn: rawBinding(\.highlightRecovery))
                    }
                    if rawInfo?.supportsNoiseReduction ?? true {
                        slider(
                            String(localized: "Noise Reduction", bundle: .module, comment: "RAW development: luminance noise reduction."),
                            Binding(
                                get: { state.raw?.noiseReduction ?? 0 },
                                set: { value in
                                    var raw = state.raw ?? RAWAdjustments()
                                    raw.noiseReduction = value
                                    state.raw = raw
                                }), 0...1)
                    }
                    if rawInfo?.supportsColorNoiseReduction ?? true {
                        slider(
                            String(
                                localized: "Color Noise", bundle: .module, comment: "Editor: colour noise reduction (blotches of colour)."),
                            optionalRAW(\.colorNoiseReduction), 0...1)
                    }
                    if rawInfo?.supportsDetail ?? true {
                        slider(
                            String(
                                localized: "Detail", bundle: .module,
                                comment: "RAW development: how much fine detail the decoder brings out."),
                            optionalRAW(\.detail), 0...1)
                    }
                    Button(
                        String(localized: "Camera Settings", bundle: .module, comment: "RAW development: back to the camera's development.")
                    ) {
                        state.raw = RAWAdjustments()
                    }
                }
                .padding(.horizontal)
            }
        } else if let partner, partnerIsRAW {
            VStack(spacing: 10) {
                Text(
                    "Develop \(partner.name) instead of this JPEG: more detail in highlights and shadows, and the camera's white balance can be changed. The JPEG stays the quick preview.",
                    bundle: .module, comment: "Editor RAW tool for the JPEG of a RAW+JPEG pair. %@ is the RAW file's name."
                )
                .font(.callout)
                .multilineTextAlignment(.center)
                Button(String(localized: "Edit RAW", bundle: .module, comment: "Editor: develops the RAW file beside the JPEG.")) {
                    Task { await useRAW(partner) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    var effect: Binding<LivePhotoEffect.Effect> {
        Binding(
            get: { state.live?.effect ?? .live },
            set: { value in
                var live = state.live ?? LivePhotoEffect()
                live.effect = value
                state.live = live
            })
    }

    var keyFrame: Binding<Double> {
        Binding(
            get: { state.live?.keyFrameTime ?? motionDuration / 2 },
            set: { value in
                var live = state.live ?? LivePhotoEffect()
                live.keyFrameTime = value
                state.live = live
            })
    }

    var liveControls: some View {
        VStack(spacing: 10) {
            Picker(String(localized: "Effect", bundle: .module, comment: "Editor: Live Photo effect picker."), selection: effect) {
                ForEach(LivePhotoEffect.Effect.allCases, id: \.self) { effect in
                    Label(LiveEffectWording.title(effect), systemImage: LiveEffectWording.symbol(effect)).tag(effect)
                }
            }
            .pickerStyle(.segmented)
            if motionDuration > 0 && state.live?.effect != .longExposure {
                HStack {
                    Text("Key Photo", bundle: .module, comment: "Editor: the frame of a Live Photo that is its still.")
                        .frame(width: labelWidth, alignment: .leading)
                        .accessibilityHidden(true)
                    Slider(value: keyFrame, in: 0...motionDuration) {
                        Text("Key Photo", bundle: .module, comment: "Editor: the frame of a Live Photo that is its still.")
                    }
                    .accessibilityValue(keyFrame.wrappedValue.formatted(.number.precision(.fractionLength(1))))
                }
                if state.live?.keyFrameTime != nil {
                    Button(
                        String(
                            localized: "Use the Original Key Photo", bundle: .module, comment: "Editor: back to the photo the camera took.")
                    ) {
                        state.live?.keyFrameTime = nil
                    }
                }
            } else if motionDuration == 0 {
                ProgressView()
            }
        }
        .padding()
        .task { await loadMotion() }
    }

    func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: labelWidth, alignment: .leading)
                .accessibilityHidden(true)
            // The name is drawn beside it; on the Mac a slider would draw its label a second time.
            Slider(value: value, in: range) { Text(title) }
                .labelsHidden()
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

    // MARK: Loading

    /// Starts from the photo's edit (re-editing), on its original — a RAW developed with Core Image.
    func load() async {
        guard let services = session.services else { return }
        let recipe = services.edits.recipe(for: item.fileId)
        hadEdit = recipe != nil
        let start = EditorState(recipe)
        saved = start
        restoring = start != state
        state = start
        newerFormat = await services.edits.hasNewerFormat(item.fileId)
        partner = session.rawPartner(of: item)
        userPresets = services.edits.presets.userPresets()
        Task { keptOriginal = await PhotoEditSaving.hasKeptOriginal(item, services: services) }
        Task {
            await services.edits.presets.sync()
            userPresets = services.edits.presets.userPresets()
        }
        do {
            if EditRendering.isRAW(name: item.name) {
                await useRAW(item)
            } else {
                let file = try await services.images.originals.original(
                    fileId: item.fileId, etag: item.etag, url: services.originalURL(for: item))
                originalFile = file
                source = EditRendering.loadOriginal(file, name: item.name, raw: nil, maxPixelSize: Self.proxySize)?.image
                // The pair was developed from its RAW last time: go on with the RAW.
                if recipe?.raw != nil, let partner, partnerIsRAW { await useRAW(partner) }
            }
            if start.live?.changesStill == true { await updateLiveStill() } else { updatePreview() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Develops `raw` (this photo or the RAW beside it) from now on.
    func useRAW(_ raw: MediaItem) async {
        guard let services = session.services else { return }
        working = String(localized: "Loading RAW…", bundle: .module, comment: "Editor: the RAW file is downloaded and decoded.")
        defer { working = nil }
        do {
            let file = try await services.images.originals.original(
                fileId: raw.fileId, etag: raw.etag, url: services.originalURL(for: raw))
            guard let filter = CIRAWFilter(imageURL: file) else { throw CocoaError(.fileReadCorruptFile) }
            let native = max(filter.nativeSize.width, filter.nativeSize.height)
            if native > 0 { filter.scaleFactor = Float(min(1, CGFloat(Self.proxySize) / native)) }
            rawFile = file
            rawItem = raw
            rawInfo = EditRendering.rawInfo(file)
            rawFilter = filter
            if state.raw == nil {
                // Not an undo step: developing the RAW is not an edit of its own.
                restoring = true
                state.raw = RAWAdjustments()
            }
            tab = .raw
            updatePreview()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMotion() async {
        guard motionFile == nil, let services = session.services, item.isLivePhoto else { return }
        guard let file = try? await LiveEffectFiles.motion(of: item, services: services) else { return }
        motionFile = file
        motionDuration = (try? await LivePhotoEffects.duration(of: file)) ?? 0
    }

    /// The still of the effect (long exposure, another key photo) at proxy size, or none.
    func updateLiveStill() async {
        guard let live = state.live, live.changesStill else {
            liveStill = nil
            updatePreview()
            return
        }
        await loadMotion()
        guard let motionFile else { return }
        let image: CGImage?
        if live.effect == .longExposure {
            working = String(localized: "Making long exposure…", bundle: .module, comment: "Editor: frames of a Live Photo are blended.")
            image = try? await LivePhotoEffects.longExposure(of: motionFile, maxPixelSize: Self.proxySize)
            working = nil
        } else if let time = live.keyFrameTime {
            image = try? await LivePhotoEffects.frame(of: motionFile, at: time, maxPixelSize: Self.proxySize)
        } else {
            image = nil
        }
        // Another change came in meanwhile: its own update shows it.
        guard state.live == live else { return }
        liveStill = image.map { CIImage(cgImage: $0) }
        updatePreview()
    }

    /// The picture the edits are applied to.
    var baseImage: (image: CIImage, developed: Bool)? {
        if let liveStill { return (liveStill, false) }
        if let rawFilter {
            EditRendering.configure(rawFilter, state.raw ?? RAWAdjustments())
            if let output = rawFilter.outputImage { return (output, true) }
        }
        return source.map { ($0, false) }
    }

    func updatePreview() {
        guard let base = baseImage else { return }
        var recipe = state.recipe(developsRAW: developsRAW)
        if !base.developed { recipe.raw = nil }
        if isCropping {
            let output = EditRendering.apply(recipe, to: base.image, developed: true, crops: false)
            uncropped = PhotoEditor.context.createCGImage(output, from: output.extent)
        } else {
            let output = EditRendering.apply(recipe, to: base.image, developed: true)
            preview = PhotoEditor.context.createCGImage(output, from: output.extent)
        }
    }

    // MARK: Masks

    /// What the mask overlay depends on: it is made again when one of these changes.
    struct MaskRequest: Equatable {
        var tab: Tool
        var mask: MaskAdjustment?
        var hasSource: Bool
    }

    /// The chosen mask's kind (its adjustments do not change where it is).
    var selectedMaskTarget: MaskAdjustment? {
        guard let index = selectedMask, state.edits.masks.indices.contains(index) else { return nil }
        var mask = MaskAdjustment(target: state.edits.masks[index].target, inverted: state.edits.masks[index].inverted)
        mask.exposure = 0
        return mask
    }

    /// Tints the chosen mask over the picture (as Lightroom does), off the main thread: Vision takes a moment.
    func updateMaskOverlay() async {
        guard tab == .masks, let mask = selectedMaskTarget, let base = baseImage?.image else {
            maskOverlay = nil
            maskFound = nil
            return
        }
        maskFound = nil
        let edits = state.edits
        let image = base
        let result: (CGImage?, Bool) = await Task.detached(priority: .userInitiated) {
            guard let found = EditMasks.mask(mask.target, inverted: mask.inverted, for: image) else { return (nil, false) }
            // The tint goes where the picture is after turns and crop.
            var geometry = edits
            geometry.masks = []
            let tint = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.2, alpha: 0.45)).cropped(to: image.extent)
            let blend = CIFilter.blendWithRedMask()
            blend.inputImage = tint
            blend.backgroundImage = CIImage(color: .clear).cropped(to: image.extent)
            blend.maskImage = found
            guard let tinted = blend.outputImage else { return (nil, true) }
            let placed = PhotoEditor.applyGeometry(geometry, to: tinted.cropped(to: image.extent))
            return (PhotoEditor.context.createCGImage(placed, from: placed.extent), true)
        }.value
        guard !Task.isCancelled else { return }
        maskOverlay = result.0
        maskFound = result.1
    }

    // MARK: Presets, Copy and Paste

    /// The look of a preset or of copied edits on this photo (its crop and turns stay): one undo step.
    func apply(look: EditRecipe) {
        let current = state.recipe(developsRAW: developsRAW)
        let next = current.withLook(look, developsRAW: developsRAW)
        var updated = state
        updated.edits = next.edits
        if developsRAW { updated.raw = next.raw }
        state = updated
        selectedMask = state.edits.masks.isEmpty ? nil : 0
    }

    struct PresetRequest: Equatable {
        var open: Bool
        var hasSource: Bool
        var presets: [String]
    }

    /// Small pictures of the photo with each preset's look (the photo at 160 px, so masks run on a small picture), made
    /// off the main thread while the Presets tool is open; each shows as soon as it is ready.
    func updatePresetThumbnails() async {
        guard tab == .presets, let base = baseImage?.image else { return }
        let presets = PresetsPanel.all(user: userPresets).filter { presetThumbnails[$0.id] == nil }
        guard !presets.isEmpty else { return }
        let small: CIImage? = await Task.detached(priority: .userInitiated) {
            let scale = min(1, 160 / max(base.extent.width, base.extent.height, 1))
            let scaled = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return PhotoEditor.context.createCGImage(scaled, from: scaled.extent.integral).map { CIImage(cgImage: $0) }
        }.value
        guard let small else { return }
        for preset in presets {
            let recipe = preset.recipe
            let image: CGImage? = await Task.detached(priority: .userInitiated) {
                let output = EditRendering.apply(recipe, to: small)
                return PhotoEditor.context.createCGImage(output, from: output.extent)
            }.value
            if Task.isCancelled { return }
            if let image { presetThumbnails[preset.id] = image }
        }
    }

    func savePreset() {
        guard let services = session.services else { return }
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let preset = EditPreset(name: name, recipe: state.recipe(developsRAW: developsRAW))
        userPresets.insert(preset, at: 0)
        Task {
            await services.edits.presets.save(preset)
            userPresets = services.edits.presets.userPresets()
        }
    }

    func deletePreset(_ preset: EditPreset) {
        guard let services = session.services, !preset.isBuiltIn else { return }
        userPresets.removeAll { $0.id == preset.id }
        Task {
            await services.edits.presets.delete(id: preset.id)
            userPresets = services.edits.presets.userPresets()
        }
    }

    // MARK: Saving

    /// The photos the edit is saved for: this one, and the other half of a RAW+JPEG pair when the RAW is developed (the
    /// JPEG stays the quick preview, showing the same edit).
    var targets: [MediaItem] {
        guard developsRAW, let partner else { return [item] }
        return [item, partner]
    }

    /// Saves the edit recipe (non-destructive) and closes; with "Apply Edits to the File" on, writes the edit into the file
    /// where it can be (a photo of the user's that Image I/O can write, not developed from RAW).
    func done() {
        guard state != saved || newerFormat else {
            dismiss()
            return
        }
        if applyToFile && !state.isIdentity && PhotoEditSaving.overwriteProblem(item) == nil && !developsRAW {
            save(.overwrite)
            return
        }
        let recipe = state.recipe(developsRAW: developsRAW)
        let undoManager = undoManager
        let pairs: [(item: MediaItem, recipe: EditRecipe)] = targets.map { ($0, recipe) }
        Task { await session.saveEdits(pairs, undoManager: undoManager) }
        dismiss()
    }

    /// "Restore Original…": the kept original version becomes the file again.
    func restoreOriginal() {
        guard let services = session.services else { return }
        working = String(localized: "Restoring…", bundle: .module, comment: "Editor: the original version is being restored.")
        let target = item
        Task {
            defer { working = nil }
            do {
                try await PhotoEditSaving.restoreOriginal(target, services: services)
                await session.syncNow()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func revert() {
        guard let services = session.services else { return }
        let items: [MediaItem] = ([item] + (partner.map { [$0] } ?? [])).filter { services.edits.recipe(for: $0.fileId) != nil }
        let undoManager = undoManager
        Task { await session.revertToOriginal(items, undoManager: undoManager) }
        dismiss()
    }

    enum FileSave { case copy, overwrite }

    /// "Save as Copy" and "Overwrite Original…": the edit rendered at full resolution into a file.
    func save(_ kind: FileSave) {
        guard let services = session.services else { return }
        let source: MediaItem = developsRAW ? (rawItem ?? item) : item
        guard let file = developsRAW ? rawFile : originalFile else { return }
        working = String(localized: "Saving…", bundle: .module)
        let recipe = state.recipe(developsRAW: developsRAW)
        let target = item
        let motionFile = motionFile
        Task {
            defer { working = nil }
            do {
                let still = try await Self.fullStill(recipe, motion: motionFile)
                // Rendered off the main thread (`PhotoEditSaving` is not bound to it): the UI stays responsive.
                switch kind {
                case .overwrite:
                    try await PhotoEditSaving.overwrite(target, with: recipe, original: file, still: still, services: services)
                case .copy:
                    try await PhotoEditSaving.saveCopy(source, with: recipe, original: file, still: still, services: services)
                }
                await session.syncNow()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The effect's still at full size for a file (long exposure, another key photo); nil to use the original.
    nonisolated static func fullStill(_ recipe: EditRecipe, motion: URL?) async throws -> CGImage? {
        guard let live = recipe.live, live.changesStill, let motion else { return nil }
        if live.effect == .longExposure { return try await LivePhotoEffects.longExposure(of: motion, maxPixelSize: 4096) }
        if let time = live.keyFrameTime { return try await LivePhotoEffects.frame(of: motion, at: time, maxPixelSize: 4096) }
        return nil
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

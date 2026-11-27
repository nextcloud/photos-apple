// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import PhotosMedia
import SwiftUI

/// The editor's Remove tool, "Erase" (SPEC §21.5): tap an object to remove it, or brush over it; people in the background
/// are offered for removal. Each removal is a stroke in the edit recipe (`EditorState.retouch`), so the editor's undo,
/// redo, Done and Revert work on it like on every other edit, and the original keeps everything.
enum RemoveTool {
    static var titleString: String {
        String(
            localized: "Erase", bundle: .module, comment: "Editor tool: removes objects and people from the photo (tap or brush over them)."
        )
    }

    static let symbol = "eraser"

    /// How to use it, under the picture and as the picture's VoiceOver hint.
    static var hint: String {
        #if os(macOS)
            String(
                localized: "Click an object to erase it, or drag over it.", bundle: .module,
                comment: "Editor, Erase tool on the Mac: how to use it.")
        #else
            String(
                localized: "Tap an object to erase it, or brush over it.", bundle: .module, comment: "Editor, Erase tool: how to use it.")
        #endif
    }

    /// Brush sizes, as fractions of the photo's shorter side.
    static let brushSizes: ClosedRange<Double> = 0.01...0.08
}

/// What the Remove tool's canvas (over the picture) and its panel (below it) share.
@MainActor @Observable final class RemoveToolModel {
    /// Half the brush's width, as a fraction of the photo's shorter side.
    var brushSize = 0.025
    /// The stroke being brushed, in fractions of the picture as shown.
    var live: [CGPoint] = []
    /// A removal is being filled in.
    var working = false
    /// What happened when it was not what the user asked for (nothing found under a tap).
    var message: String?
    /// People in the background, found when the tool opens.
    var suggestions: [RetouchStroke] = []
    var lookedForSuggestions = false

    /// Fills the stroke in off the main thread, then adds it (one undo step): the editor's preview finds it ready.
    func add(_ strokes: [RetouchStroke], to steps: Binding<RetouchSteps?>, base: CIImage) async {
        guard !strokes.isEmpty, !working else { return }
        working = true
        defer { working = false }
        message = nil
        var next = steps.wrappedValue ?? RetouchSteps()
        for stroke in strokes { next = next.adding(stroke) }
        await Inpainting.prepare(next, on: base)
        steps.wrappedValue = next
    }

    /// The object under a tap (fractions of the original), found by Vision on a smaller copy of the picture.
    func select(at point: CGPoint, steps: Binding<RetouchSteps?>, base: CIImage) async {
        guard !working else { return }
        working = true
        guard let picture = Self.small(base) else {
            working = false
            return
        }
        let stroke = await Task.detached(priority: .userInitiated) { RetouchSelection.object(at: point, in: picture) }.value
        working = false
        guard let stroke else {
            message = Self.nothingFound
            return
        }
        await add([stroke], to: steps, base: base)
    }

    /// Looks once for people in the background to offer.
    func findSuggestions(base: CIImage?) async {
        guard !lookedForSuggestions, let base, let picture = Self.small(base) else { return }
        lookedForSuggestions = true
        suggestions = await Task.detached(priority: .utility) { RetouchSelection.backgroundPeople(in: picture) }.value
    }

    /// The picture at most 1024 pixels long, for Vision.
    static func small(_ image: CIImage) -> CGImage? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, 1024 / max(extent.width, extent.height))
        let scaled = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        return PhotoEditor.context.createCGImage(scaled, from: scaled.extent.integral)
    }

    static var nothingFound: String {
        #if os(macOS)
            String(
                localized: "Nothing to pick here. Drag over what you want to erase.", bundle: .module,
                comment: "Editor, Erase tool on the Mac: a click found no object; the user can paint over it instead.")
        #else
            String(
                localized: "Nothing to pick here. Brush over what you want to erase.", bundle: .module,
                comment: "Editor, Erase tool: a tap found no object; the user can paint over it instead.")
        #endif
    }

    /// The brushed points (fractions of the picture as shown) as a stroke on the original; nil when none lies on it.
    static func brush(_ points: [CGPoint], radius: Double, edits: PhotoEdits, originalSize: CGSize) -> RetouchStroke? {
        let mapped = points.compactMap { RetouchGeometry.originalPoint($0, edits: edits, originalSize: originalSize) }
        guard !mapped.isEmpty else { return nil }
        // Points closer than a tenth of the brush add nothing but size to the recipe.
        var kept = [mapped[0]]
        let short = min(originalSize.width, originalSize.height)
        for point in mapped.dropFirst() {
            let last = kept[kept.count - 1]
            let dx = (point.x - last.x) * originalSize.width
            let dy = (point.y - last.y) * originalSize.height
            if (dx * dx + dy * dy).squareRoot() >= radius * short / 10 { kept.append(point) }
        }
        if kept.count > 1, let end = mapped.last, kept.last != end { kept.append(end) }
        return .brush(RetouchStroke.Brush(radius: radius, points: kept.map(RetouchPoint.init)))
    }
}

/// Over the editor's picture while the Remove tool is open: brushing draws the stroke, lifting fills it in; a tap (or a
/// click) picks the object under it.
struct RemoveToolCanvas: View {
    @Bindable var model: RemoveToolModel
    @Binding var steps: RetouchSteps?
    /// The picture the edits are applied to (the editor's proxy, before any edit).
    let base: CIImage?
    let edits: PhotoEdits

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Path { path in
                    path.addLines(model.live.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                }
                .stroke(
                    Color.red.opacity(0.55), style: StrokeStyle(lineWidth: brushWidth(in: size), lineCap: .round, lineJoin: .round))
                if model.working {
                    ProgressView().padding(12).background(.regularMaterial, in: .circle)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(drag(in: size))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Edited photo", bundle: .module))
        .accessibilityAddTraits(.isImage)
        .accessibilityHint(Text(RemoveTool.hint))
        .accessibilityActions {
            if !model.suggestions.isEmpty { suggestionButton }
        }
    }

    var suggestionButton: some View {
        RemoveSuggestionButton(model: model, steps: $steps, base: base)
    }

    /// The brush on screen: its radius on the original is the same number of pixels on the edited picture.
    func brushWidth(in size: CGSize) -> CGFloat {
        guard let base else { return 20 }
        let original = base.extent.size
        let edited = RetouchGeometry.transform(edits, originalSize: original).size
        guard edited.width > 0 else { return 20 }
        return model.brushSize * min(original.width, original.height) * 2 * size.width / edited.width
    }

    func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !model.working, size.width > 0, size.height > 0 else { return }
                model.live.append(CGPoint(x: value.location.x / size.width, y: value.location.y / size.height))
            }
            .onEnded { value in
                let points = model.live
                model.live = []
                guard !model.working, let base, size.width > 0, size.height > 0 else { return }
                let original = base.extent.size
                let travel = hypot(value.translation.width, value.translation.height)
                if travel < 6 {
                    let point = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                    guard let onOriginal = RetouchGeometry.originalPoint(point, edits: edits, originalSize: original) else { return }
                    Task { await model.select(at: onOriginal, steps: $steps, base: base) }
                } else if let stroke = RemoveToolModel.brush(points, radius: model.brushSize, edits: edits, originalSize: original) {
                    Task { await model.add([stroke], to: $steps, base: base) }
                }
            }
    }
}

/// "Erase N People in the Background".
struct RemoveSuggestionButton: View {
    @Bindable var model: RemoveToolModel
    @Binding var steps: RetouchSteps?
    let base: CIImage?

    var body: some View {
        Button {
            guard let base else { return }
            let strokes = model.suggestions
            model.suggestions = []
            Task { await model.add(strokes, to: $steps, base: base) }
        } label: {
            Label(
                String(
                    localized: "Erase \(model.suggestions.count) People in the Background", bundle: .module,
                    comment: "Editor, Erase tool: removes the people Vision found behind the subject. Has plural forms."),
                systemImage: "person.2.slash")
        }
        .disabled(model.working)
    }
}

/// Below the picture while the Remove tool is open: how it works, the brush size, suggestions and "Restore All".
struct RemoveToolPanel: View {
    @Bindable var model: RemoveToolModel
    @Binding var steps: RetouchSteps?
    let base: CIImage?
    @ScaledMetric(relativeTo: .body) private var labelWidth = 110.0

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(model.message ?? RemoveTool.hint)
                    .font(.callout)
                    .foregroundStyle(model.message == nil ? .secondary : .primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Brush Size", bundle: .module, comment: "Editor, Erase tool: how wide the brush is.")
                        .frame(width: labelWidth, alignment: .leading)
                        .accessibilityHidden(true)
                    Slider(value: $model.brushSize, in: RemoveTool.brushSizes) {
                        Text("Brush Size", bundle: .module, comment: "Editor, Erase tool: how wide the brush is.")
                    }
                    .accessibilityValue(
                        (model.brushSize / RemoveTool.brushSizes.upperBound).formatted(.percent.precision(.fractionLength(0))))
                }
                HStack {
                    if !model.suggestions.isEmpty {
                        RemoveSuggestionButton(model: model, steps: $steps, base: base)
                            .buttonStyle(.bordered)
                    }
                    if steps?.isIdentity == false {
                        Button(
                            String(
                                localized: "Restore All", bundle: .module,
                                comment: "Editor, Erase tool: brings back everything that was erased (can be undone).")
                        ) {
                            steps = nil
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.working)
                    }
                }
                Label(
                    String(
                        localized: "Works best on spots and small things.", bundle: .module,
                        comment: "Editor, Erase tool: the fill blends in the surroundings, so large objects leave a soft patch."),
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .task { await model.findSuggestions(base: base) }
    }
}

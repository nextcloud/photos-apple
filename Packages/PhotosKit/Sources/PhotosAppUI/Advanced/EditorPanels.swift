// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreImage
import PhotosMedia
import SwiftUI

// MARK: - Curves

/// The Curves tool (SPEC §21.6.1): a channel picker (RGB, red, green, blue) and the curve. Drag a point to move it, tap
/// the curve's area to add one, double-tap a point (or drag it off the area) to remove it. VoiceOver: each point is an
/// adjustable element (swipe up and down to raise or lower its output).
struct CurvesPanel: View {
    @Binding var curves: ToneCurves
    @State private var channel: ToneCurves.Channel = .rgb

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker(String(localized: "Channel", bundle: .module, comment: "Curves tool: which curve is shown."), selection: $channel) {
                    ForEach(ToneCurves.Channel.allCases, id: \.self) { channel in
                        Text(Self.title(of: channel)).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button(String(localized: "Reset", bundle: .module)) { curves[channel] = .identity }
                    .disabled(curves[channel].isIdentity)
            }
            CurveEditor(curve: $curves[channel], color: Self.color(of: channel), channelName: Self.title(of: channel))
                .frame(maxWidth: 360)
        }
        .padding(.horizontal)
    }

    static func title(of channel: ToneCurves.Channel) -> String {
        switch channel {
        case .rgb: String(localized: "RGB", bundle: .module, comment: "Curves tool: the curve of all three colour channels.")
        case .red: String(localized: "Red", bundle: .module, comment: "Curves tool: the red channel.")
        case .green: String(localized: "Green", bundle: .module, comment: "Curves tool: the green channel.")
        case .blue: String(localized: "Blue", bundle: .module, comment: "Curves tool: the blue channel.")
        }
    }

    static func color(of channel: ToneCurves.Channel) -> Color {
        switch channel {
        case .rgb: .primary
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }
}

/// One tone curve, drawn and edited in a square.
struct CurveEditor: View {
    @Binding var curve: ToneCurve
    var color: Color
    var channelName: String
    /// The point being dragged, by index.
    @State private var dragging: Int?
    @State private var draft: ToneCurve?

    var shown: ToneCurve { draft ?? curve }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                grid(size)
                path(shown, size).stroke(color, lineWidth: 2)
                ForEach(Array(shown.points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(dragging == index ? color : Color.secondary.opacity(0.9))
                        .overlay(Circle().stroke(Color.primary.opacity(0.6), lineWidth: 1))
                        .frame(width: 14, height: 14)
                        .position(location(point, size))
                        .accessibilityElement()
                        .accessibilityLabel(
                            Text(
                                "\(channelName) curve point \(index + 1)", bundle: .module,
                                comment: "Curves tool, VoiceOver: one point of the curve. %1$@ is the channel, %2$lld its number.")
                        )
                        .accessibilityValue(
                            Text(
                                "Input \(Int((point.x * 100).rounded())) percent, output \(Int((point.y * 100).rounded())) percent",
                                bundle: .module, comment: "Curves tool, VoiceOver: where a point of the curve is.")
                        )
                        .accessibilityAdjustableAction { direction in
                            let step = direction == .increment ? 0.02 : -0.02
                            curve = curve.moving(at: index, to: CurvePoint(x: point.x, y: point.y + step))
                        }
                        .onTapGesture(count: 2) { curve = curve.removing(at: index) }
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(size))
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("Add Point", bundle: .module, comment: "Curves tool, VoiceOver: adds a point in the middle."))
            {
                let x = 0.5
                curve = curve.adding(CurvePoint(x: x, y: curve.value(at: x)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    func location(_ point: CurvePoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }

    func point(_ location: CGPoint, _ size: CGSize) -> CurvePoint {
        CurvePoint(
            x: min(1, max(0, location.x / max(size.width, 1))), y: min(1, max(0, 1 - location.y / max(size.height, 1))))
    }

    func grid(_ size: CGSize) -> some View {
        Path { path in
            for step in 1..<4 {
                let x = size.width * CGFloat(step) / 4
                let y = size.height * CGFloat(step) / 4
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: size.width, y: 0))
        }
        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
        .background(Color.secondary.opacity(0.08))
        .accessibilityHidden(true)
    }

    func path(_ curve: ToneCurve, _ size: CGSize) -> Path {
        let samples = curve.table(count: 96)
        return Path { path in
            for (index, value) in samples.enumerated() {
                let point = CGPoint(x: CGFloat(index) / CGFloat(samples.count - 1) * size.width, y: (1 - value) * size.height)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    /// Dragging near a point moves it; starting elsewhere adds a point there and moves it. Dragged far outside the area,
    /// an inner point is removed. The curve becomes an edit (one undo step) when the drag ends.
    func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var working = draft ?? curve
                if dragging == nil {
                    let start = value.startLocation
                    let near = working.points.enumerated().min { lhs, rhs in
                        distance(location(lhs.element, size), start) < distance(location(rhs.element, size), start)
                    }
                    if let near, distance(location(near.element, size), start) < 22 {
                        dragging = near.offset
                    } else {
                        let added = point(start, size)
                        working = working.adding(added)
                        dragging = working.points.firstIndex { abs($0.x - added.x) < ToneCurve.minimumGapForUI }
                    }
                }
                guard let index = dragging else { return }
                let outside = value.location.y < -40 || value.location.y > size.height + 40
                if outside && index != 0 && index != working.points.count - 1 {
                    draft = working.removing(at: index)
                    return
                }
                let moved = working.moving(at: index, to: point(value.location, size))
                draft = moved
                // Keep the dragged point's index (moving never reorders points).
            }
            .onEnded { _ in
                if let draft { curve = draft }
                draft = nil
                dragging = nil
            }
    }

    func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

extension ToneCurve {
    /// Two points closer than this are found as one by the curve editor.
    static let minimumGapForUI = 0.011
}

// MARK: - Colour mixer

/// The Color tool (SPEC §21.6.2): the eight ranges as swatches, and hue, saturation and luminance of the chosen one.
struct ColorMixerPanel: View {
    @Binding var mixer: ColorMixer
    let slider: (String, Binding<Double>, ClosedRange<Double>) -> AnyView
    @State private var band: ColorMixer.Band = .red

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ForEach(ColorMixer.Band.allCases, id: \.self) { band in
                        Button {
                            self.band = band
                        } label: {
                            Circle()
                                .fill(Color(hue: band.hue / 360, saturation: 0.85, brightness: 0.9))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(Color.primary, lineWidth: self.band == band ? 2.5 : 0).padding(-3))
                                .overlay(alignment: .topTrailing) {
                                    if !mixer[band].isIdentity {
                                        Circle().fill(Color.primary).frame(width: 6, height: 6).accessibilityHidden(true)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.title(of: band))
                        .accessibilityAddTraits(self.band == band ? .isSelected : [])
                        .accessibilityValue(
                            mixer[band].isIdentity
                                ? Text("Unchanged", bundle: .module, comment: "Colour mixer, VoiceOver: this colour range is not changed.")
                                : Text("Changed", bundle: .module, comment: "Colour mixer, VoiceOver: this colour range is changed."))
                    }
                }
                .padding(.vertical, 4)
                slider(
                    String(localized: "Hue", bundle: .module, comment: "Colour mixer: shifts the hue of a colour range."), $mixer[band].hue,
                    -1...1)
                slider(
                    String(localized: "Saturation", bundle: .module), $mixer[band].saturation, -1...1)
                slider(
                    String(localized: "Luminance", bundle: .module, comment: "Colour mixer: brightness of a colour range."),
                    $mixer[band].luminance, -1...1)
                Button(String(localized: "Reset All Colors", bundle: .module, comment: "Colour mixer: removes every colour change.")) {
                    mixer = ColorMixer()
                }
                .disabled(mixer.isIdentity)
            }
            .padding(.horizontal)
        }
    }

    static func title(of band: ColorMixer.Band) -> String {
        switch band {
        case .red: String(localized: "Reds", bundle: .module, comment: "Colour mixer range.")
        case .orange: String(localized: "Oranges", bundle: .module, comment: "Colour mixer range.")
        case .yellow: String(localized: "Yellows", bundle: .module, comment: "Colour mixer range.")
        case .green: String(localized: "Greens", bundle: .module, comment: "Colour mixer range.")
        case .aqua: String(localized: "Aquas", bundle: .module, comment: "Colour mixer range (cyan).")
        case .blue: String(localized: "Blues", bundle: .module, comment: "Colour mixer range.")
        case .purple: String(localized: "Purples", bundle: .module, comment: "Colour mixer range.")
        case .magenta: String(localized: "Magentas", bundle: .module, comment: "Colour mixer range.")
        }
    }
}

// MARK: - Masks

/// The Masks tool (SPEC §21.6.3): the photo's masks as chips, "Add Mask" (subject, background, sky, people), and the
/// chosen mask's adjustments. While the tool is open the chosen mask is tinted on the picture.
struct MasksPanel: View {
    @Binding var masks: [MaskAdjustment]
    @Binding var selected: Int?
    /// Whether the chosen mask found its part in this photo (nil while it is being looked for).
    let found: Bool?
    let slider: (String, Binding<Double>, ClosedRange<Double>) -> AnyView

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(Array(masks.enumerated()), id: \.offset) { index, mask in
                                Button(Self.title(of: mask)) { selected = index }
                                    .buttonStyle(.bordered)
                                    .tint(selected == index ? .accentColor : .secondary)
                                    .accessibilityAddTraits(selected == index ? .isSelected : [])
                            }
                        }
                    }
                    Menu {
                        ForEach(MaskAdjustment.Target.allCases, id: \.self) { target in
                            Button {
                                masks.append(Self.started(target))
                                selected = masks.count - 1
                            } label: {
                                Label(Self.title(of: target), systemImage: Self.symbol(of: target))
                            }
                        }
                    } label: {
                        Label(
                            String(localized: "Add Mask", bundle: .module, comment: "Masks tool: adds a mask."), systemImage: "plus.circle")
                    }
                    .fixedSize()
                    .disabled(masks.count >= EditRecipe.maximumMasks)
                }
                if let index = selected, masks.indices.contains(index) {
                    if found == false {
                        Label(Self.notFound(masks[index].target), systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle(
                        String(localized: "Invert", bundle: .module, comment: "Masks tool: adjusts everything but the mask."),
                        isOn: $masks[index].inverted)
                    slider(String(localized: "Exposure", bundle: .module), $masks[index].exposure, -2...2)
                    slider(String(localized: "Brightness", bundle: .module), $masks[index].brightness, -0.5...0.5)
                    slider(String(localized: "Contrast", bundle: .module), $masks[index].contrast, 0.5...1.5)
                    slider(String(localized: "Highlights", bundle: .module), $masks[index].highlights, 0...1)
                    slider(String(localized: "Shadows", bundle: .module), $masks[index].shadows, -1...1)
                    slider(String(localized: "Saturation", bundle: .module), $masks[index].saturation, 0...2)
                    slider(String(localized: "Vibrance", bundle: .module), $masks[index].vibrance, -1...1)
                    slider(String(localized: "Warmth", bundle: .module), $masks[index].warmth, -1...1)
                    slider(String(localized: "Tint", bundle: .module), $masks[index].tint, -1...1)
                    slider(String(localized: "Sharpness", bundle: .module), $masks[index].sharpness, 0...2)
                    Button(
                        String(localized: "Delete Mask", bundle: .module, comment: "Masks tool: removes the chosen mask."),
                        role: .destructive
                    ) {
                        masks.remove(at: index)
                        selected = masks.isEmpty ? nil : min(index, masks.count - 1)
                    }
                } else {
                    Text(
                        "Add a mask to change only the subject, the background, the sky or the people of this photo.", bundle: .module,
                        comment: "Masks tool: shown while the photo has no mask."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal)
        }
    }

    /// A new mask starts with a visible change, so the user sees at once what it covers.
    static func started(_ target: MaskAdjustment.Target) -> MaskAdjustment {
        var mask = MaskAdjustment(target: target)
        switch target {
        case .subject, .people: mask.exposure = 0.2
        case .background: mask.exposure = -0.2
        case .sky: mask.saturation = 1.15
        }
        return mask
    }

    static func title(of target: MaskAdjustment.Target) -> String {
        switch target {
        case .subject: String(localized: "Subject", bundle: .module, comment: "Mask: the main subject of the photo.")
        case .background: String(localized: "Background", bundle: .module, comment: "Mask: everything but the subject.")
        case .sky: String(localized: "Sky", bundle: .module, comment: "Mask: the sky.")
        case .people: String(localized: "People", bundle: .module, comment: "Mask: all people in the photo.")
        }
    }

    static func title(of mask: MaskAdjustment) -> String {
        mask.inverted
            ? String(
                localized: "Not \(title(of: mask.target))", bundle: .module,
                comment: "Mask chip of an inverted mask, e.g. \"Not Sky\". %@ is the mask's kind.")
            : title(of: mask.target)
    }

    static func symbol(of target: MaskAdjustment.Target) -> String {
        switch target {
        case .subject: "person.and.background.dotted"
        case .background: "photo"
        case .sky: "cloud.sun"
        case .people: "person.2"
        }
    }

    static func notFound(_ target: MaskAdjustment.Target) -> String {
        switch target {
        case .subject, .background:
            String(localized: "No subject found in this photo.", bundle: .module, comment: "Masks tool: Vision found no subject.")
        case .sky: String(localized: "No sky found in this photo.", bundle: .module, comment: "Masks tool: no sky was found.")
        case .people: String(localized: "No people found in this photo.", bundle: .module, comment: "Masks tool: no person was found.")
        }
    }
}

// MARK: - Presets

/// The Presets tool (SPEC §21.6.5): built-in looks and the user's own, each as a small preview of this photo. Tapping
/// one applies its look (crop and turns stay); "Save as Preset…" keeps the current look.
struct PresetsPanel: View {
    let presets: [EditPreset]
    /// A small rendition of the photo with a preset applied.
    let thumbnail: (EditPreset) -> CGImage?
    let apply: (EditPreset) -> Void
    let delete: (EditPreset) -> Void
    let saveCurrent: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(presets) { preset in
                        Button {
                            apply(preset)
                        } label: {
                            VStack(spacing: 4) {
                                Group {
                                    if let image = thumbnail(preset) {
                                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                                    } else {
                                        Color.secondary.opacity(0.2)
                                    }
                                }
                                .frame(width: 72, height: 72)
                                .clipShape(.rect(cornerRadius: 8))
                                Text(PresetsPanel.name(of: preset)).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                    .frame(width: 80)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !preset.isBuiltIn {
                                Button(
                                    String(localized: "Delete Preset", bundle: .module, comment: "Presets: removes a preset of the user."),
                                    role: .destructive
                                ) {
                                    delete(preset)
                                }
                            }
                        }
                        .accessibilityLabel(PresetsPanel.name(of: preset))
                        .accessibilityHint(Text("Applies this look to the photo.", bundle: .module, comment: "Presets, VoiceOver hint."))
                        .accessibilityActions {
                            if !preset.isBuiltIn {
                                Button(
                                    String(localized: "Delete Preset", bundle: .module, comment: "Presets: removes a preset of the user.")
                                ) {
                                    delete(preset)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            if let saveCurrent {
                Button(String(localized: "Save as Preset…", bundle: .module, comment: "Presets: keeps the current look as a preset.")) {
                    saveCurrent()
                }
            }
        }
        .padding(.vertical, 8)
    }

    static func name(of preset: EditPreset) -> String {
        guard preset.isBuiltIn, let builtIn = EditPreset.BuiltIn(rawValue: String(preset.id.dropFirst("builtin.".count))) else {
            return preset.name
        }
        return title(of: builtIn)
    }

    static func title(of preset: EditPreset.BuiltIn) -> String {
        switch preset {
        case .vivid: String(localized: "Vivid", bundle: .module, comment: "Photo filter.")
        case .warm: String(localized: "Warm", bundle: .module, comment: "Edit preset: warmer colours.")
        case .cool: String(localized: "Cool", bundle: .module, comment: "Edit preset: cooler colours.")
        case .matte: String(localized: "Matte", bundle: .module, comment: "Edit preset: lifted blacks, softer colours.")
        case .blackAndWhite: String(localized: "Black & White", bundle: .module, comment: "Edit preset.")
        case .dramaticSky: String(localized: "Dramatic Sky", bundle: .module, comment: "Edit preset: darker, richer sky.")
        case .portrait: String(localized: "Portrait Pop", bundle: .module, comment: "Edit preset: brighter subject, calmer background.")
        case .night: String(localized: "Clean Night", bundle: .module, comment: "Edit preset: noise reduction and lifted shadows.")
        }
    }

    /// Built-in presets first, then the user's.
    static func all(user: [EditPreset]) -> [EditPreset] {
        EditPreset.BuiltIn.allCases.map(\.preset) + user
    }
}

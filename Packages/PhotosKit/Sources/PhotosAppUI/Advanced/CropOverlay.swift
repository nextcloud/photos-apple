// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import PhotosMedia
import SwiftUI

/// The crop frame of the editor (SPEC §7.16.1, free-form crop): drawn over the whole picture, with the area outside dimmed,
/// thirds lines, and handles at the corners and edges. Dragging a handle resizes the frame (keeping its aspect when
/// `locksAspect`), dragging inside it moves it. The frame is laid over the picture at the picture's displayed size.
struct CropOverlay: View {
    let area: CropRect
    /// The picture's size in pixels, for the aspect.
    let pictureSize: CGSize
    let locksAspect: Bool
    /// While dragging.
    var changing: (CropRect) -> Void
    /// When the drag ends: one edit, one undo step.
    var changed: (CropRect) -> Void
    /// The frame when the drag started; translations are relative to it.
    @State private var start: CropRect?

    /// The visible handle and the area that reacts to the pointer or finger around it.
    #if os(macOS)
        static let hitSize: CGFloat = 22
    #else
        static let hitSize: CGFloat = 44
    #endif
    static let cornerLength: CGFloat = 18
    static let lineWidth: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let size: CGSize = proxy.size
            let frame: CGRect = CGRect(
                x: area.x * size.width, y: area.y * size.height, width: area.width * size.width, height: area.height * size.height)
            ZStack(alignment: .topLeading) {
                dimming(size: size, frame: frame)
                ThirdsGrid()
                    .stroke(.white.opacity(start == nil ? 0.35 : 0.7), lineWidth: 0.5)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
                Rectangle()
                    .stroke(.white, lineWidth: 1)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
                // Inside the frame: moves it.
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(.rect)
                    .frame(width: max(0, frame.width - Self.hitSize), height: max(0, frame.height - Self.hitSize))
                    .offset(x: frame.minX + Self.hitSize / 2, y: frame.minY + Self.hitSize / 2)
                    .gesture(drag(.move, in: size))
                    #if os(macOS)
                        .onHover { inside in
                            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                        }
                    #endif
                ForEach(CropRect.Handle.allCases.filter { $0 != .move }, id: \.self) { handle in
                    handleView(handle)
                        .frame(width: Self.hitSize, height: Self.hitSize)
                        .contentShape(.rect)
                        .position(Self.point(of: handle, in: frame))
                        .gesture(drag(handle, in: size))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Crop area", bundle: .module, comment: "Accessibility label of the crop frame in the editor."))
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: changed(area.scaled(by: 1.1))
            case .decrement: changed(area.scaled(by: 1 / 1.1))
            @unknown default: break
            }
        }
    }

    /// "80% wide, 60% high".
    var accessibilityValue: String {
        let width = Int((area.width * 100).rounded())
        let height = Int((area.height * 100).rounded())
        return String(
            localized: "\(width)% wide, \(height)% high", bundle: .module,
            comment: "Accessibility value of the crop frame: how much of the photo's width and height it keeps.")
    }

    func dimming(size: CGSize, frame: CGRect) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(frame)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    @ViewBuilder func handleView(_ handle: CropRect.Handle) -> some View {
        if handle.isCorner {
            CornerMark(handle: handle)
                .stroke(.white, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .square))
                .frame(width: Self.cornerLength, height: Self.cornerLength)
        } else {
            let horizontal: Bool = handle == .top || handle == .bottom
            Capsule()
                .fill(.white)
                .frame(width: horizontal ? Self.cornerLength : Self.lineWidth, height: horizontal ? Self.lineWidth : Self.cornerLength)
        }
    }

    func drag(_ handle: CropRect.Handle, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let from: CropRect = start ?? area
                if start == nil { start = area }
                changing(dragged(from, handle, value.translation, size: size))
            }
            .onEnded { value in
                let from: CropRect = start ?? area
                start = nil
                changed(dragged(from, handle, value.translation, size: size))
            }
    }

    func dragged(_ from: CropRect, _ handle: CropRect.Handle, _ translation: CGSize, size: CGSize) -> CropRect {
        guard size.width > 0, size.height > 0 else { return from }
        let aspect: Double? = locksAspect ? from.pixelAspect(in: pictureSize) : nil
        return from.dragged(
            handle, dx: Double(translation.width / size.width), dy: Double(translation.height / size.height), lockedAspect: aspect,
            in: pictureSize)
    }

    static func point(of handle: CropRect.Handle, in frame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: frame.minX, y: frame.minY)
        case .top: CGPoint(x: frame.midX, y: frame.minY)
        case .topRight: CGPoint(x: frame.maxX, y: frame.minY)
        case .right: CGPoint(x: frame.maxX, y: frame.midY)
        case .bottomRight: CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY)
        case .bottomLeft: CGPoint(x: frame.minX, y: frame.maxY)
        case .left: CGPoint(x: frame.minX, y: frame.midY)
        case .move: CGPoint(x: frame.midX, y: frame.midY)
        }
    }
}

/// Lines at a third and two thirds of the frame, both ways.
private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3, 2.0 / 3] {
            path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        return path
    }
}

/// The L of a corner handle, its corner at the middle of the rect so it sits on the frame's corner.
private struct CornerMark: Shape {
    let handle: CropRect.Handle

    func path(in rect: CGRect) -> Path {
        let horizontal: CGFloat = handle == .topLeft || handle == .bottomLeft ? 1 : -1
        let vertical: CGFloat = handle == .topLeft || handle == .topRight ? 1 : -1
        let corner = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: CGPoint(x: corner.x + horizontal * rect.width / 2, y: corner.y))
        path.addLine(to: corner)
        path.addLine(to: CGPoint(x: corner.x, y: corner.y + vertical * rect.height / 2))
        return path
    }
}

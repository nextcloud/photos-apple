// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// A minimal SVG path-data parser (M, L, H, V, C, S, A, Z, absolute and relative) for vector marks such as the Nextcloud logo.
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var tokens: [String] = []
        let pattern = /[MmLlHhVvCcSsAaZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/
        for match in data.matches(of: pattern) { tokens.append(String(match.output)) }
        var path = Path()
        var index = 0
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?

        func number() -> CGFloat {
            defer { index += 1 }
            return CGFloat(Double(tokens[index]) ?? 0)
        }
        func point(relative: Bool) -> CGPoint {
            let x = number()
            let y = number()
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while index < tokens.count {
            if let first = tokens[index].first, first.isLetter {
                command = first
                index += 1
                if command == "Z" || command == "z" {
                    path.closeSubpath()
                    current = start
                    lastControl = nil
                    continue
                }
            }
            guard index < tokens.count else { break }
            let relative = command.isLowercase
            switch command.uppercased() {
            case "M":
                current = point(relative: relative)
                start = current
                path.move(to: current)
                command = relative ? "l" : "L"  // further pairs are line-tos
                lastControl = nil
            case "L":
                current = point(relative: relative)
                path.addLine(to: current)
                lastControl = nil
            case "H":
                let x = number()
                current.x = relative ? current.x + x : x
                path.addLine(to: current)
                lastControl = nil
            case "V":
                let y = number()
                current.y = relative ? current.y + y : y
                path.addLine(to: current)
                lastControl = nil
            case "C":
                let c1 = point(relative: relative)
                let c2 = point(relative: relative)
                let end = point(relative: relative)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "S":
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(relative: relative)
                let end = point(relative: relative)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "A":
                let rx = abs(number())
                let ry = abs(number())
                let rotation = number() * .pi / 180
                let largeArc = number() != 0
                let sweep = number() != 0
                let end = point(relative: relative)
                addArc(&path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc, sweep: sweep)
                current = end
                lastControl = nil
            default:
                index += 1  // unsupported command: skip
            }
        }
        return path
    }

    /// SVG elliptical arc, converted from endpoint to centre parameterisation (SVG 1.1 F.6.5).
    static func addArc(
        _ path: inout Path, from p1: CGPoint, to p2: CGPoint, rx: CGFloat, ry: CGFloat, rotation phi: CGFloat, largeArc: Bool, sweep: Bool
    ) {
        guard rx > 0, ry > 0, p1 != p2 else {
            path.addLine(to: p2)
            return
        }
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (p1.x - p2.x) / 2
        let dy = (p1.y - p2.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        var rx = rx
        var ry = ry
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = sqrt(max(0, numerator / denominator))
        if largeArc == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry
        let cy1 = -factor * ry * x1 / rx
        let center = CGPoint(x: cosPhi * cx1 - sinPhi * cy1 + (p1.x + p2.x) / 2, y: sinPhi * cx1 + cosPhi * cy1 + (p1.y + p2.y) / 2)
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        // Unit circle arc, mapped onto the ellipse.
        let transform = CGAffineTransform(a: rx * cosPhi, b: rx * sinPhi, c: -ry * sinPhi, d: ry * cosPhi, tx: center.x, ty: center.y)
        path.addArc(
            center: .zero, radius: 1, startAngle: .radians(theta1), endAngle: .radians(theta1 + delta), clockwise: delta < 0,
            transform: transform)
    }
}

/// An SVG path scaled to fit its view box into the rect.
struct SVGShape: Shape {
    let path: Path
    let viewBox: CGRect

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let x = rect.midX - (viewBox.midX * scale)
        let y = rect.midY - (viewBox.midY * scale)
        return path.applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: x, y: y)))
    }

    static let nextcloudLogo = SVGShape(
        path: SVGPath.parse(NextcloudLogoPath.data),
        viewBox: CGRect(x: 0, y: 0, width: NextcloudLogoPath.viewBox.width, height: NextcloudLogoPath.viewBox.height))
    static let photosIcon = SVGShape(path: SVGPath.parse(PhotosIconPath.data), viewBox: PhotosIconPath.viewBox)
}

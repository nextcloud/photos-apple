// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// A minimal SVG path-data parser (M, L, H, V, C, S, Z, absolute and relative) for vector marks such as the Nextcloud logo.
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var tokens: [String] = []
        let pattern = /[MmLlHhVvCcSsZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/
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
            default:
                index += 1  // unsupported command: skip
            }
        }
        return path
    }
}

/// The official Nextcloud logo as a shape, scaled to fit.
struct NextcloudLogoShape: Shape {
    static let path = SVGPath.parse(NextcloudLogoPath.data)

    func path(in rect: CGRect) -> Path {
        let (width, height) = NextcloudLogoPath.viewBox
        let scale = min(rect.width / width, rect.height / height)
        let x = rect.midX - width * scale / 2
        let y = rect.midY - height * scale / 2
        return Self.path.applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: x, y: y)))
    }
}

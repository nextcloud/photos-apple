// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import SwiftUI

#if canImport(UIKit)
    import UIKit
    public typealias PlatformImage = UIImage
#else
    import AppKit
    public typealias PlatformImage = NSImage
#endif

/// Design tokens (SPEC §6.5).
public enum Design {
    /// Nextcloud blue.
    public static let accent = Color(red: 0, green: 130 / 255, blue: 201 / 255)

    @MainActor public static var tileSpacing: CGFloat {
        #if os(macOS)
            2
        #elseif os(visionOS)
            4
        #else
            UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1
        #endif
    }

    public static let coverCornerRadius: CGFloat = 10
}

extension PlatformImage {
    static func from(_ cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
            UIImage(cgImage: cgImage)
        #else
            NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

/// Formatting helpers.
enum Formatters {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// The Nextcloud logo (three rings), drawn as a shape so it scales and needs no asset.
public struct NextcloudLogo: View {
    var color: Color = Design.accent

    public init(color: Color = Design.accent) {
        self.color = color
    }

    public var body: some View {
        GeometryReader { proxy in
            let height = min(proxy.size.height, proxy.size.width / 2)
            let big = height * 0.78
            let small = height * 0.44
            let line = height * 0.13
            ZStack {
                Circle().stroke(color, lineWidth: line).frame(width: big - line, height: big - line)
                Circle().stroke(color, lineWidth: line * 0.75).frame(width: small - line, height: small - line)
                    .offset(x: -height * 0.72)
                Circle().stroke(color, lineWidth: line * 0.75).frame(width: small - line, height: small - line)
                    .offset(x: height * 0.72)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

extension View {
    /// The info panel: a trailing inspector on iOS/iPadOS and macOS, a sheet on visionOS (which has no inspector).
    func infoInspector<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(visionOS)
            sheet(isPresented: isPresented) { NavigationStack { content() } }
        #else
            inspector(isPresented: isPresented) {
                content().inspectorColumnWidth(min: 260, ideal: 320, max: 420)
            }
        #endif
    }
}

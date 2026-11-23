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
    /// "1:05", "1:02:03" in the locale's digits and separators.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let duration = Duration.seconds(total)
        return total >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond)) : duration.formatted(.time(pattern: .minuteSecond))
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// The official Nextcloud logo (vector, from nextcloud/server), in the accent colour by default.
public struct NextcloudLogo: View {
    var color: Color = Design.accent

    public init(color: Color = Design.accent) {
        self.color = color
    }

    public var body: some View {
        SVGShape.nextcloudLogo
            .fill(color, style: FillStyle(eoFill: true))
            .aspectRatio(2, contentMode: .fit)
            .accessibilityLabel(Text(verbatim: "Nextcloud"))
    }
}

/// The Nextcloud Photos app icon (the Photos server app's icon, white on Nextcloud blue).
public struct PhotosAppIcon: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Design.accent, Color(red: 28 / 255, green: 175 / 255, blue: 1)], startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                SVGShape.photosIcon
                    .fill(.white)
                    .padding(side * 0.12)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(Text(verbatim: "Nextcloud Photos"))
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

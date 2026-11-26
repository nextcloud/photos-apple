// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: MIT

#if canImport(AVFoundation)
    import CoreVideo

    /// The frames the app draws into videos it writes (memory films, Live Photo effects).
    enum VideoFrames {
        /// 32-bit BGRA backed by IOSurface, which Core Image renders into and the encoders take without a copy.
        static func attributes(width: Int, height: Int) -> CVPixelBufferCreationAttributes {
            var attributes = CVPixelBufferCreationAttributes(
                pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA), size: CVImageSize(width: width, height: height))
            attributes.backing = .ioSurface
            return attributes
        }
    }
#endif

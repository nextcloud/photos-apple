// SPDX-FileCopyrightText: 2026 Nextcloud GmbH
// SPDX-License-Identifier: LicenseRef-NextcloudTrademarks
//
import CoreGraphics

// The glyph of the Nextcloud Photos app icon (icon/app.svg: a sun over two hills; the icon's two layers in
// `icon/Photos App Icon.icon`), in its 24×24 grid.

enum PhotosIconPath {
    static let viewBox = CGRect(x: 0, y: 0, width: 24, height: 24)
    static let data =
        "M14.6,6.4A2.6,2.6 0 1,0 19.8,6.4A2.6,2.6 0 1,0 14.6,6.4Z"
        + "M2.752,17.541L7.541,9.4A1.3,1.3 0 0,1 9.748,9.345L12.986,14.267A0.8,0.8 0 0,0 14.286,14.318L15.362,12.935"
        + "A1.3,1.3 0 0,1 17.423,12.947L20.815,17.414A1.3,1.3 0 0,1 19.78,19.5L3.873,19.5A1.3,1.3 0 0,1 2.752,17.541Z"
}

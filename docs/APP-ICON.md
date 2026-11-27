# App icon

The app icon is an Icon Composer file: `icon/Photos App Icon.icon`. Its glyph, a sun over two hills, is in
`icon/app.svg` (white) and `icon/app-dark.svg` (black).

What it covers:

- **iOS, iPadOS and macOS** (the "squares" look) and **watchOS** (the "circle" look). Both the iPhone app target and the
  watch app target take the file as a resource, and `ASSETCATALOG_COMPILER_APPICON_NAME` is `Photos App Icon`. Xcode
  renders every size and the default, dark, clear and tinted appearances from it. No PNGs are kept for these platforms.
- **The design:**
  - a fill from light blue (Display P3 0.110 / 0.686 / 1.0) at the top to Nextcloud blue #0082c9 at 70 % of the height;
  - two glass layers, the sun and the hills, at 50 % translucency with a neutral shadow.
- **Inside the app:** the login and welcome screens draw the same icon with `PhotosAppIcon` (`Common/Design.swift`,
  glyph in `Brand/PhotosIconPath.swift`). Change it together with the `.icon` file.

What Icon Composer does not cover:

1. **tvOS:** `App/TV/Assets.xcassets` still has the earlier glyph: the brand assets (layered App Icon and Top Shelf
   image). tvOS wants layered PNGs, which can be made from `icon/app.svg` and the gradient above.
2. **visionOS:** an image stack (`AppIcon.solidimagestack`) of two or three 1024 px layers (background, glyph). There
   is none yet, so the app has no proper icon on Apple Vision Pro.
3. **App Store artwork:** screenshots per device class, and an optional preview video.

The Nextcloud logo and name, and this icon, are trademarks of Nextcloud GmbH (`LicenseRef-NextcloudTrademarks`).

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

Icon Composer has no tvOS or visionOS look. `scripts/make-icon-layers.swift` makes those icons from the same artwork:
the layer SVGs of the `.icon` file and its gradient. Run it from the repository root after changing the `.icon` file:
`swift scripts/make-icon-layers.swift`.

- **tvOS** (`App/TV/Assets.xcassets`, brand assets):
  - the App Icon (400 × 240 pt, 1x and 2x) and the App Store icon (1280 × 768), each with three layers: Back (the
    gradient), Middle (the hills) and Front (the sun), so they part when the icon has the focus;
  - the Top Shelf images (1920 × 720 and wide 2320 × 720, 1x and 2x): the whole icon on the gradient.
- **visionOS:** `App/Resources/Assets.xcassets/AppIcon.solidimagestack`, the same three layers at 1024 px. The glyph is
  smaller there, so it stays inside the circle. The app target sets `ASSETCATALOG_COMPILER_APPICON_NAME` to `AppIcon`
  for the `xros` and `xrsimulator` SDKs.
- The glyph layers mimic the `.icon` file's glass: white, a little translucent towards the bottom, with a soft shadow.

Still to supply: **App Store artwork**, meaning screenshots per device class and an optional preview video.

The Nextcloud logo and name, and this icon, are trademarks of Nextcloud GmbH (`LicenseRef-NextcloudTrademarks`).

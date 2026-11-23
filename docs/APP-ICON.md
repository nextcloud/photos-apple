# App icon

`App/Resources/Assets.xcassets/AppIcon.appiconset` holds what could be made from the one piece of artwork there is: the
1024 px icon (the Photos server app's glyph on the Nextcloud gradient).

What is in place:

- iOS, iPadOS: the 1024 px image (single-size icon). Its unused alpha channel was removed; App Store Connect rejects
  icons that have one.
- macOS: every slot of the icon set (16, 32, 128, 256, 512 pt at 1x and 2x) scaled down from that image with `sips`.

What a designer has to supply; nothing of this can be derived from a flat PNG:

1. **Layered source artwork** (background gradient and glyph as separate vector layers), ideally as an Icon Composer
   `.icon` file. With it Xcode renders the default, dark, clear and tinted appearances on iOS, iPadOS and macOS, and
   the asset catalog entries below become unnecessary there.
2. If no `.icon` file: a **dark** and a **tinted** (grayscale, transparent background) 1024 px variant for iOS and
   iPadOS. Today the system darkens and tints the single image by itself.
3. A **macOS icon in the Mac shape** (rounded rectangle on a transparent canvas with the standard margins and
   shadow). The current Mac slots are the full-bleed iOS square, which the system masks; small sizes (16 and 32 px)
   want a simplified, hand-tuned glyph, not a downscale.
4. A **visionOS icon**: an image stack (`AppIcon.solidimagestack`) of two or three 1024 px layers (background, glyph).
   There is none yet, so the app has no proper icon on Apple Vision Pro.
5. App Store artwork: screenshots per device class, optional preview video.

The Nextcloud logo and name are trademarks of Nextcloud GmbH; new artwork needs their approval.

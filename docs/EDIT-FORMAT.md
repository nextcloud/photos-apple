<!--
SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
SPDX-License-Identifier: MIT
-->

# Edit recipes: format, storage and rendering

For the Android and web teams (and anybody who wants their app to show photos edited in Nextcloud Photos for Apple
platforms). The Apple app edits photos **non-destructively**: the original file is not changed; a small JSON document —
the **edit recipe** — says what was done, and every view renders the edited picture from the original and the recipe.
Another app that does not know recipes shows the original. This document is enough to read, render and write recipes
that the Apple app shows the same way. SPEC §16.3 and §21.6 have the reasons behind the decisions; the source of truth is
`Packages/PhotosKit/Sources/PhotosMedia/Editing/` (`EditRecipe.swift` for the format, `EditRendering.swift`,
`PhotoEditing.swift`, `ToneCurve.swift`, `ColorMixer.swift`, `EditMasks.swift`, `NoiseReduction.swift` for rendering).

Contents: 1 Where recipes are stored · 2 Syncing safely · 3 The JSON · 4 Rendering · 5 Presets · 6 "Apply edits to the
file" and the original version · 7 What a client should do at minimum · 8 Examples.

## 1. Where recipes are stored

- One file per photo in the **user's own files**: `/.nextcloud-photos/edits/<fileId>.json` (WebDAV
  `/remote.php/dav/files/<user>/.nextcloud-photos/edits/<fileId>.json`). `<fileId>` is the Nextcloud file id
  (`oc:fileid`) of the photo, in decimal.
- **Keyed by file id**, not by name: a photo moved or renamed anywhere keeps its file id, so its edit follows it. A copy
  is a new file without the edit.
- The **dot folder** keeps recipes out of sight (the Files web app hides dot files by default, the desktop client does not
  sync them by default, the Photos web app lists only pictures and videos).
- A photo **shared with the user** is edited in the user's own folder (it is that user's view of the photo; the owner and
  other recipients do not see it).
- **Deleting** a photo leaves its recipe; restoring the photo from the trash bin brings its edit back.
- Content type `application/json`, UTF-8. Recipes are a few hundred bytes.

## 2. Syncing safely

- **Write** with `PUT` and `If-Match: "<etag>"` of the version you read, or `If-None-Match: *` for a new recipe. Create
  `/.nextcloud-photos/edits` (`MKCOL`, parents first) when the PUT answers 404 or 409.
- **Revert** (back to the original) = `DELETE` with `If-Match`.
- On **412** read the server's recipe: the edit with the later `updatedAt` (when the user made it) wins. If yours is
  later, PUT again with the server's ETag; otherwise take the server's. The replaced recipe stays in the server's file
  versions.
- **Pull**: `PROPFIND` depth 0 of the folder; only when its ETag changed list it (depth 1) and `GET` the files whose ETag
  changed. A file that disappeared was reverted on another device.
- Offline changes wait and go out with the next sync.

## 3. The JSON

```json
{
  "format": "nextcloud-photos-edit",
  "version": 2,
  "updatedAt": "2026-11-26T10:00:00Z",
  "original": { "name": "IMG_1234.HEIC", "etag": "…", "width": 4032, "height": 3024 },
  "geometry": { "rotation": 1, "straighten": 2.5, "flipped": true, "aspect": "4:3", "aspectLocked": true,
                "crop": { "x": 0.1, "y": 0, "width": 0.8, "height": 1 } },
  "adjustments": { "autoEnhance": true, "exposure": 0.4, "contrast": 1.1, "noiseReduction": 0.3, "colorNoiseReduction": 0.5 },
  "curves": { "rgb": [[0, 0], [0.25, 0.2], [0.75, 0.82], [1, 1]], "blue": [[0, 0.05], [1, 1]] },
  "colorMixer": { "blue": { "saturation": 0.3, "luminance": -0.2 }, "orange": { "hue": -0.1 } },
  "masks": [ { "target": "sky", "adjustments": { "exposure": -0.4, "saturation": 1.2 } },
             { "target": "people", "inverted": true, "adjustments": { "warmth": 0.2 } } ],
  "filter": "noir",
  "raw": { "exposure": 0.5, "temperature": 5200, "highlightRecovery": true, "colorNoiseReduction": 0.4, "detail": 0.6 },
  "live": { "effect": "bounce", "keyFrameTime": 1.2 }
}
```

### 3.1 Rules for every reader and writer

- `format` must be `"nextcloud-photos-edit"`; anything else is not a recipe.
- **`version`**: the lowest format version that shows the edit completely. **A reader that knows versions up to N must
  not apply a recipe with version > N**: show the original and, in an editor, say "edited with a newer version"; never
  overwrite it without the user's consent. Version 1 is the format of SPEC §16.3; version 2 (SPEC §21.6) added `curves`,
  `colorMixer`, `masks`, the adjustments `noiseReduction` and `colorNoiseReduction`, and `raw.colorNoiseReduction` /
  `raw.detail`. **Writers write the lowest version their recipe needs** (an edit that uses none of the version-2 fields
  is version 1, so older apps keep showing it).
- **Only values that differ from "unchanged" are written.** A missing key means unchanged; so does an empty object.
- **Unknown keys are ignored** (within the version you know). Unknown filter names, Live effects and mask targets are
  ignored (a mask of an unknown target is left out, the others still apply).
- **Broken values fall back to unchanged** (not a number, wrong type); ranges are clamped as listed below.
- `updatedAt` (ISO 8601, UTC) is when the user last changed the edit; it decides conflicts. `original` is informational.

### 3.2 Fields

| Key | Type | Unchanged | Range / meaning |
| --- | --- | --- | --- |
| `geometry.rotation` | int | 0 | quarter turns **clockwise**, 0…3 |
| `geometry.straighten` | number | 0 | degrees, −45…45, positive turns **counterclockwise** as seen |
| `geometry.flipped` | bool | false | mirrored left↔right, applied **after** the quarter turns |
| `geometry.aspect` | string | `"original"` | `free`, `original`, `square`, `4:3`, `16:9`, `3:2` (ratios follow the picture's orientation) |
| `geometry.aspectLocked` | bool | false | UI only |
| `geometry.crop` | {x,y,width,height} | none | fractions (0…1) of the straightened, turned and mirrored picture, origin **top left**; each side ≥ 0.05 |
| `adjustments.autoEnhance` | bool | false | the platform's automatic enhancement (Core Image `autoAdjustmentFilters`) |
| `adjustments.exposure` | number | 0 | EV, −2…2 |
| `adjustments.brightness` | number | 0 | −0.5…0.5 |
| `adjustments.contrast` | number | 1 | 0.5…1.5 |
| `adjustments.highlights` | number | 1 | 0…1 (lower recovers highlights) |
| `adjustments.shadows` | number | 0 | −1…1 |
| `adjustments.saturation` | number | 1 | 0…2 |
| `adjustments.vibrance` | number | 0 | −1…1 |
| `adjustments.warmth` | number | 0 | −1…1 |
| `adjustments.tint` | number | 0 | −1…1 (green … magenta) |
| `adjustments.sharpness` | number | 0 | 0…2 |
| `adjustments.vignette` | number | 0 | 0…2 |
| `adjustments.noiseReduction` (v2) | number | 0 | 0…1, luminance noise |
| `adjustments.colorNoiseReduction` (v2) | number | 0 | 0…1, colour blotches |
| `curves.rgb`/`red`/`green`/`blue` (v2) | [[x, y], …] | straight line | 2…16 points, each 0…1, sorted by x (§4.4) |
| `colorMixer.<range>` (v2) | {hue, saturation, luminance} | 0 each | each −1…1; ranges `red orange yellow green aqua blue purple magenta` (§4.5) |
| `masks` (v2) | array | none | at most 8 (more are ignored); §4.6 |
| `filter` | string | none | `vivid vividWarm vividCool dramatic mono silvertone noir` (§4.7) |
| `raw.exposure` | number | 0 | EV on top of the camera's baseline |
| `raw.temperature` / `raw.tint` | number | camera's | Kelvin / −150…150 |
| `raw.highlightRecovery` | bool | false | |
| `raw.shadowBoost` | number | 0 | 0…1 |
| `raw.noiseReduction` | number | decoder's | 0…1 luminance |
| `raw.colorNoiseReduction` (v2) | number | decoder's | 0…1 |
| `raw.detail` (v2) | number | decoder's | 0…1 |
| `live.effect` | string | `live` | `live loop bounce longExposure` |
| `live.keyFrameTime` | number | camera's | seconds into the Live Photo's motion: that frame is the still |
| `retouch.strokes` (v2) | array | none | objects removed with the Erase tool, in order (§4.9) |

Each mask: `{ "target": "subject" | "background" | "sky" | "people", "inverted": bool (default false), "adjustments": {…} }`
where `adjustments` has the same names, ranges and unchanged values as the photo's own `exposure brightness contrast
highlights shadows saturation vibrance warmth tint sharpness`. A mask without any adjustment is no mask.

## 4. Rendering

The Apple app renders with Core Image. Another platform will not match it to the last bit; it should follow the **order**
and the **formulas** below, and approximate the Core Image filters with its own. Curves and the colour mixer are defined
exactly and should match closely.

### 4.1 Input and order

1. **The picture**: the original with its EXIF orientation applied (or the server's preview of it for grids; the edit
   fits any size). A RAW file is developed with the `raw` settings; a picture that is not the RAW itself (the server's
   preview, the JPEG of a RAW+JPEG pair) approximates them (exposure, white balance shift from 5500 K, highlights/shadows,
   noise) — or ignores them. A Live Photo whose `live` changes the still (`longExposure`, `keyFrameTime`) starts from that
   frame (long exposure: 48 frames sampled evenly from the motion, averaged).
2. **Removed objects** (`retouch`, version 2), §4.9 — before colour, on the photo's own pixels.
2a. **Noise reduction** (`colorNoiseReduction`, then `noiseReduction`), §4.3.
3. **Auto-enhance**.
4. **Adjustments** in this order: exposure, contrast/brightness/saturation, highlights/shadows, vibrance, warmth/tint.
5. **Curves**, §4.4.
6. **Colour mixer**, §4.5.
7. **Masks**, in their order, §4.6.
8. **Filter**, then **sharpness**, then **vignette**.
9. **Geometry**: straighten, quarter turns, mirror, crop (§4.8).

Steps 2–8 never change the picture's size.

Why removal comes first: the fill should see the photo as it was taken, and a client may cache the filled areas by the
picture they were made from — changing colours or the crop afterwards then never fills again.

### 4.2 Adjustments (Core Image reference)

| Key | Core Image | Approximation elsewhere |
| --- | --- | --- |
| exposure | `CIExposureAdjust` (EV): linear RGB × 2^ev | same |
| contrast, brightness, saturation | `CIColorControls` | contrast around mid grey, brightness added, saturation as luminance mix |
| highlights, shadows | `CIHighlightShadowAdjust` (`highlightAmount`, `shadowAmount`) | tone-mapping of highlights / shadows |
| vibrance | `CIVibrance` (`amount`) | saturation that spares saturated colours and skin |
| warmth, tint | `CITemperatureAndTint`, neutral (6500, 0) → target (6500 − warmth × 2000, tint × 50) | white-balance shift |
| sharpness | `CISharpenLuminance` (`sharpness`) | unsharp mask on luminance |
| vignette | `CIVignette` (intensity = value, radius 2) | radial darkening |
| autoEnhance | `CIImage.autoAdjustmentFilters()` | the platform's auto-enhance, or skip |

### 4.3 Noise reduction (version 2)

Strengths are **relative to the picture's size**, so a thumbnail and the full photo look alike.

- `colorNoiseReduction` c > 0: blur the picture with a Gaussian of radius `c × 0.0025 × longEdge` pixels (edges clamped),
  then take **hue and saturation from the blurred picture and luminosity from the unblurred** one (the "color" blend mode,
  `CIColorBlendMode`).
- `noiseReduction` n > 0: Core Image `CINoiseReduction` with `noiseLevel = n × 0.06`, `sharpness = 0.6 − n × 0.3`. Any
  edge-preserving luminance denoiser of similar strength is fine.

### 4.4 Curves (version 2)

- Curves work on **sRGB (gamma-encoded) values 0…1**, as every editor shows them.
- A curve is a list of points `[x, y]`, sorted by x. Readers clamp to 0…1, drop non-finite points, sort, merge points
  closer than 0.01 in x (the later one wins), keep at most 16 (the first 15 and the last). Fewer than 2 points = the
  straight line.
- Left of the first point the curve is flat at its y, right of the last point flat at its y (moving the end points sets
  the black and white points).
- Between points: **monotone cubic Hermite interpolation (Fritsch–Carlson)**:
  1. slopes `d[k] = (y[k+1] − y[k]) / (x[k+1] − x[k])`;
  2. tangents `m[0] = d[0]`, `m[n−1] = d[n−2]`; inner `m[k] = 0` if `d[k−1] × d[k] ≤ 0`, else `(d[k−1] + d[k]) / 2`;
  3. for each segment with `d[k] = 0`: `m[k] = m[k+1] = 0`; otherwise `a = m[k]/d[k]`, `b = m[k+1]/d[k]`, and if
     `a² + b² > 9`: `t = 3/√(a²+b²)`, `m[k] = t·a·d[k]`, `m[k+1] = t·b·d[k]`;
  4. with `h = x[k+1] − x[k]`, `t = (x − x[k]) / h`:
     `y = (2t³ − 3t² + 1)·y[k] + (t³ − 2t² + t)·h·m[k] + (−2t³ + 3t²)·y[k+1] + (t³ − t²)·h·m[k+1]`, clamped to 0…1.
- **Per channel after RGB**: `red_out = red(rgb(red_in))`, the same for green and blue. The Apple app samples this into a
  1024-entry table per channel (`CIColorCurves` in sRGB).

### 4.5 Colour mixer (version 2)

Eight ranges by their hue centre (degrees): red 0, orange 30, yellow 60, green 120, aqua 180, blue 225, purple 270,
magenta 315. For each pixel (sRGB 0…1):

1. Convert to **HSL** (hue 0…360, saturation and lightness 0…1, the usual formulas). Pixels with saturation ≤ 0.0001 are
   left unchanged.
2. **Weights**: find the two neighbouring centres around the hue (wrapping at 360: magenta 315 → red 360); with `t` the
   position between them (0 at the lower, 1 at the upper), the lower range gets `1 − t`, the upper `t`. Weights add up
   to 1.
3. Sum the weighted values of those two ranges: `H`, `S`, `L` (each −1…1).
4. `hue' = hue + H × 30°`; `saturation' = clamp(saturation × (1 + S))`;
   `lightness' = clamp(lightness + L × 0.5 × saturation × room)` with `room = 1 − lightness` when `L > 0`, else
   `lightness` (greys stay grey, nothing clips).
5. Back to RGB.

The Apple app evaluates this on a 32 × 32 × 32 lookup table (`CIColorCubeWithColorSpace`, sRGB) with trilinear
interpolation.

### 4.6 Masks (version 2)

Only the **kind** of mask is stored, never the mask: each app finds it on the device when it renders, on the picture
**before any edit** (step 1), so it does not change while sliders move.

- `subject`: the main subjects (people, pets, objects in front). Apple: Vision's foreground instance mask, all
  instances. Android: ML Kit Subject Segmentation. Web: skip or any salient-object segmentation.
- `background`: the inverse of `subject` (the whole picture when there is no subject).
- `people`: every person. Apple: Vision's person segmentation (accurate). Android: ML Kit Selfie Segmentation; web:
  MediaPipe.
- `sky`: no platform segments the sky, so the Apple app uses a heuristic, gated by its scene classification (no sky when
  Vision is sure there is none, confidence < 0.05 for every "sky" label). On a copy of the picture with a long edge of
  192 px:
  - a pixel is a **candidate** when it is smooth (|L(x+1)−L(x−1)| + |L(y+1)−L(y−1)| < 0.07, L = Rec. 601 luma) and
    either blue (hue 185…255°, blue ≥ red, max ≥ 0.3), or overcast (HSV saturation < 0.16, max > 0.62), or warm and
    bright in the upper half (hue ≤ 50° or ≥ 330°, max > 0.55: a sunset);
  - the **sky** is every candidate connected (4-neighbours, luma step < 0.05) to a candidate in the **top row**;
  - less than 2 % of the picture is no sky; the result is softened with a 3 × 3 average.
- Masks are found on a copy with a long edge of 768 px (sky: 192 px) and scaled up along the picture's own edges
  (Apple: `CIEdgePreserveUpsampleFilter`, spatial sigma 3, luma sigma 0.15; any guided/joint-bilateral upsampling works).
- **Applying a mask**: apply the mask's adjustments (§4.2, the same formulas) to the current picture, then blend:
  `out = mask × adjusted + (1 − mask) × current`, `mask` 0…1 (inverted: `1 − mask`).
- A mask that cannot be found (no person, no sky, or segmentation not available on the device) changes nothing.

### 4.7 Filters

Core Image's photo effects: `vivid` = `CIPhotoEffectChrome`, `vividWarm` = `CIPhotoEffectTransfer`, `vividCool` =
`CIPhotoEffectProcess`, `dramatic` = `CIPhotoEffectFade`, `mono` = `CIPhotoEffectMono`, `silvertone` =
`CIPhotoEffectTonal`, `noir` = `CIPhotoEffectNoir`. Elsewhere: a similar look (LUT), or skip an unknown one.

### 4.8 Geometry

1. **Straighten** by `straighten` degrees (positive: counterclockwise as seen) around the centre, then cut the largest
   centred rectangle of the picture's aspect: scale `s = 1 / (|cos a| + |sin a| × long/short)` of width and height.
2. **Quarter turns**: `rotation` × 90° clockwise.
3. **Mirror** left↔right when `flipped`.
4. **Crop**: `crop` as fractions of the picture after 1–3, origin top left; without `crop`, an `aspect` other than
   `original`/`free` keeps the largest centred area of that ratio (4:3 on a landscape picture is 3:4 on a portrait one).

### 4.9 Removed objects (`retouch`, version 2)

`"retouch": { "strokes": [ … ] }`, each stroke one of (unknown kinds and broken strokes are skipped, the others kept):

- `{ "brush": { "radius": r, "points": [[x, y], …] } }` — a line through the points, `r` wide on each side; `r` is a
  fraction of the picture's **shorter** side, points are fractions of width and height, origin top left. One point is a
  dot.
- `{ "area": { "width": w, "height": h, "runs": [n0, n1, n2, …], "grow": g } }` — an object picked by tapping it (a
  Vision mask). A `w × h` bitmap laid over the whole picture (at most 192 cells on the long side), row by row from the
  top left, as run lengths alternating *not removed* / *removed*, starting with *not removed* (the runs add up to
  `w × h`). Scale it up smoothly to the picture, cut at half, and grow it by `g` (fraction of the shorter side, default
  0.015).

Coordinates are those of the picture of step 1 (orientation applied, before geometry), so the strokes fit any size.

**Rendering**: every masked area is filled in from its surroundings ("inpainting"). The Apple app uses a basic fill
without a machine-learning model (it uses only the AI of Apple's frameworks, and they have no inpainting API): per
stroke a square window around it, 2.2 × the stroke's size and at least 512 px of the picture (scaled to 512 × 512), the
mask grown by 4 of those pixels, the hole filled by pulling the surroundings smoothly into it ("push–pull" over an image
pyramid), the result blended back with a soft edge (2 px grown, 1.5 px blur). Strokes apply in order; earlier strokes
that touch a new one are filled again together with it (one hole). Another client may use any fill it has; the fill
will not match pixel for pixel, which is fine — it is a guess either way. A client
that cannot fill **must not** show the photo as if fully edited: show the original or the rendered file ("Apply edits
to the file", §6). Since `retouch` makes a recipe version 2, a version-1 client shows the original.

## 5. Presets

The user's own presets are one file in their files, `/.nextcloud-photos/edit-presets.json`:

```json
{ "format": "nextcloud-photos-edit-presets", "version": 1,
  "presets": [
    { "id": "6F1C…", "name": "Evening", "updatedAt": "2026-11-26T10:00:00.123Z",
      "recipe": { "format": "nextcloud-photos-edit", "version": 2, "adjustments": { "warmth": 0.3 },
                  "masks": [ { "target": "sky", "adjustments": { "exposure": -0.4 } } ] } },
    { "id": "2B9A…", "updatedAt": "2026-11-26T11:00:00.456Z", "deleted": true } ] }
```

- `recipe` is a recipe without `geometry`, `live` and `original` (a preset is a look; applying it keeps the photo's own
  crop and turns).
- Removed presets stay as `{"id", "updatedAt", "deleted": true}` so the removal reaches other devices.
- Sync like recipes (`If-Match` / `If-None-Match: *`); on 412 merge **preset by preset**: the later `updatedAt` wins
  (dates with milliseconds). Built-in presets are not in the file (each app has its own).

**Copy Edits / Paste Edits** and presets on a selection use the same rule: the look (everything but `geometry`, `live`,
`retouch`, `original`) replaces the target's look; the target keeps its geometry, Live effect and removed objects; `raw` settings are taken over only
by photos that are developed from RAW.

## 6. "Apply edits to the file" and the original version

So that edits show in apps that do not read recipes, the Apple app can **write the edited picture into the file**
(editor ▸ More ▸ "Apply Edits to the File", **off by default**; "Overwrite Original…" does it once):

1. The current version of the file is given the **version label** `Original (Nextcloud Photos)` — `PROPPATCH`
   `{http://nextcloud.org/ns}version-label` on `/remote.php/dav/versions/<user>/versions/<fileId>/<versionId>` (the
   versions listing contains the current version, its id is the file's modification time — verified on Nextcloud 36; the
   label stays when the next upload turns it into an older version). **Nextcloud never expires a labelled version**,
   neither by age nor when space runs out (`files_versions` `Storage::expire`). If a version already has that label (the
   photo was applied before), it is kept as the original and nothing is relabelled. A label the user gave the current
   version is kept inside ours: `Original (Nextcloud Photos): <their label>`. The label is read back; if the server lists
   no versions or does not keep the label, **nothing is overwritten**.
2. The recipe is rendered on the original at full resolution in the original's format and name (JPEG, HEIC/HEIF, PNG,
   TIFF; EXIF/GPS/dates kept, orientation reset), then `PUT` over the file with `If-Match` of the ETag that was edited
   (a newer version on the server is never replaced).
3. The photo's recipe is **deleted** (the edit is part of the file now).
4. **Restore Original** = `MOVE` the labelled version to `/remote.php/dav/versions/<user>/restore/target` with
   `Overwrite: T` (Nextcloud answers 412 without it). The edited picture stays as a version.

Other clients: please **do not remove the label** `Original (Nextcloud Photos)`; a "restore original" feature can look for
it. Verified on a Nextcloud 36 dev server (SPEC §21.6.6).

## 7. What a client should do at minimum

1. Read `/.nextcloud-photos/edits/<fileId>.json` for the photos it shows (pull as in §2).
2. If `version` is higher than it knows, show the original.
3. Render geometry (§4.8) — the most visible part — and as many of the rest as it can, in the order of §4.1.
4. When it edits, write a recipe of the version it needs, keep the keys it does not know (read-modify-write the JSON
   object, do not rebuild it from what it understood), and follow §2.

## 8. Examples

A rotation only (version 1, what Image ▸ Rotate writes):

```json
{ "format": "nextcloud-photos-edit", "version": 1, "updatedAt": "2026-11-26T09:00:00Z",
  "original": { "name": "IMG_0042.JPG", "etag": "a1b2", "width": 4032, "height": 3024 },
  "geometry": { "rotation": 1 }, "adjustments": {} }
```

A portrait with a darker, cooler background and a gentle S curve (version 2):

```json
{ "format": "nextcloud-photos-edit", "version": 2, "updatedAt": "2026-11-26T09:05:00Z",
  "geometry": { "crop": { "x": 0.1, "y": 0.05, "width": 0.8, "height": 0.9 } },
  "adjustments": { "vibrance": 0.2 },
  "curves": { "rgb": [[0, 0], [0.25, 0.22], [0.75, 0.79], [1, 1]] },
  "masks": [ { "target": "subject", "adjustments": { "exposure": 0.25 } },
             { "target": "background", "adjustments": { "exposure": -0.2, "saturation": 0.85, "warmth": -0.2 } } ] }
```

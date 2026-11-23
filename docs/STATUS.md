# Implementation status

State of the app against [SPEC.md](SPEC.md) on 2026-11-22. Work is delivered as stacked draft PRs:
#1 M0 + M1 (most), #2 M2, #3 M3, #4 M4a, #5 M4b, #6 M5.

Legend: ✅ implemented and checked against a real server · 🟡 implemented, not verified end to end · ⬜ not implemented yet.

## Verified how

- Unit tests (`xcodebuild test -scheme PhotosKit-Package -destination platform=macOS`): parsing, request bodies, initial-state scraping,
  store, timeline sections, memories, stacks, duplicates, search suggestions, backup matcher and naming, editing, BlurHash, push key encoding.
- Integration tests against a local Nextcloud 36 + Photos master server (504-item test library): feature detection, sync, albums,
  album content, places, previews, album/link/upload round trip, public album access, reconciliation SEARCH, trash, tags, folders.
- The Mac app was run against the same server (timeline, albums, places, memories).
- Not available on the build Mac: iOS/visionOS simulator runtimes, signed builds (App Groups, keychain group, push), devices.

## M0 Foundation — ✅
Login Flow v2 (✅ code; browser flow 🟡 not exercised by hand), login links ✅, untrusted certificates 🟡, client certificates 🟡,
accounts/switching ✅, revocation and remote wipe 🟡, feature detection ✅, store ✅, logging (os.Logger) ✅, CI ✅.
- ⬜ MDM / AppConfig keys (§5.1.9).
- ⬜ QR code camera scanner (paste of login links works).

## M1 Browse and view — mostly ✅
Index sync (initial, incremental, reconciliation) ✅, timeline views ✅, grid with day sections, pinch zoom, selection, context menus ✅
(macOS ✅, iOS 🟡), year index on iOS 🟡, viewer with zoom/video/Live Photos 🟡, info panel ✅, favourite/delete/archive/export ✅.
- ⬜ TL-6 stacks in the grid (the algorithm exists in `PhotosDomain/Stacks.swift`, not yet applied to the grid).
- ⬜ Timeline skeleton from `timelineDays` during the first sync; ⬜ date scrubber on macOS.
- ⬜ "Aspect ratio" tile mode (`croppedLayout`), only square tiles.
- ⬜ VW-4 Live Text / Visual Look Up overlay in the viewer (text extraction exists as an action), ⬜ VW-5 slideshow, ⬜ VW-6 stack strip.
- ⬜ Performance budgets (§10) not measured; no synthetic 100k performance tests yet.

## M2 Albums, sharing, upload, offline — ✅
Albums and shared albums ✅, collaborators 🟡 (sharee search not exercised), public links ✅, public album viewer ✅, quick share 🟡,
comments 🟡 (needs extended server), upload (PUT and chunked) ✅, share extension 🟡, drag and drop 🟡, offline albums 🟡.

## M3 Backup — 🟡
Settings, PhotoKit source, Files-app ledger, reconciliation (✅ SEARCH against server), matcher ✅, engine, UI, background tasks 🟡.
- ⬜ PhotoKit background-upload extension (iOS 27, §7.18.6).
- ⬜ §7.18.8 remove backed-up photos from the device.
- ⬜ Most-compatible video conversion (HEVC → H.264); images only.
- ✅ Run state machine unit-tested with a fake library and server: pause and resume (Wi-Fi, Low Data, Low Power, lost connection),
  stop on full quota / invalid login / refused upload (`BackupStatus.blocker`), retry delays for failing files, skipping assets the
  ledger knows completely, edits and RAW files matched per rendition, Live Photo halves linked across runs.
- 🟡 Not exercised on a device: `PHAssetResource.dataSize` for the exact-size match, the network path and Low Power Mode observers.
- ⬜ `BackupModel` does not yet pass changed options to a waiting run (`BackupEngine.settingsChanged`) or show `BackupStatus.blocker`.
- 🟡 Acceptance test (device library partly uploaded by Files, zero duplicates) still to run on a device.

## M4 Discover — 🟡
Places ✅, map 🟡, people 🟡 (no Recognize on test servers), tags ✅ (API), folders ✅ (API), shared with you 🟡, On this day ✅,
memories ✅, search and smart albums 🟡, archive and app lock 🟡, push 🟡 (needs proxy registration and provisioning), widgets 🟡.
- ⬜ Memory player (ME-4) and "Save as album" from a memory.
- ⬜ Map time slider; MapKit native clustering (grid clustering is used).
- ⬜ Tag assignment UI (API exists).

## M5 Advanced — 🟡
Editor (Core Image) 🟡, metadata editing 🟡, recently deleted ✅ (API), duplicates 🟡, free up space 🟡, extract text (server OCR or
Vision) 🟡, Ask your photos (server Assistant or on-device Foundation Models) 🟡, video renditions 🟡, App Intents and App Shortcuts 🟡.
- ⬜ Free-form crop (aspect presets only).
- ⬜ Spotlight indexing of albums/people/places; App Intent entities (albums, people) and search intent.
- ⬜ visionOS spatial photos / immersive panoramas.
- ⬜ Accessibility and localisation audit; Transifex setup.
- ⬜ App Store assets and review notes.

## Prerequisites from SPEC §14 still open
App Group / keychain group provisioning, push proxy topic, notification routing in the notifications app, app icon artwork,
a test server with Recognize and an Assistant provider.

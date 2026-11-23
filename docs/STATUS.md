# Implementation status

State of the app against [SPEC.md](SPEC.md) on 2026-11-22. Work is delivered as stacked draft PRs:
#1 M0 + M1 (most), #2 M2, #3 M3, #4 M4a, #5 M4b, #6 M5.

Legend: ✅ implemented and checked against a real server · 🟡 implemented, not verified end to end · ⬜ not implemented yet.

## Verified how

- Unit tests (`xcodebuild test -scheme PhotosKit-Package -destination platform=macOS`): parsing, request bodies, initial-state scraping,
  store, sync engine and outbox against a stubbed DAV server (changes made elsewhere, deletes/moves, ETag boundary, ordering/backoff,
  cancellation), timeline sections, memories, stacks, duplicates, search suggestions, backup matcher and naming, editing, BlurHash, push key encoding.
  In CI they run on the `xcode-27` runner (macOS 27); before 2026-11-23 the CI job skipped them because `macos-26` cannot load
  test bundles built for OS 27.
  `PhotosCoreTests` run the app model in a temporary container against a stubbed server: what logout and remote wipe leave on
  disk and in the secret store, logout order, the Notifications switch, push payload handling, offline downloads, backup outcome.
- Integration tests against a local Nextcloud 36 + Photos master server (504-item test library): feature detection, sync, albums,
  album content, places, previews, favourite/move/delete made elsewhere, album/link/upload round trip, public album access, reconciliation SEARCH, trash, tags, folders.
- The Mac app was run against the same server (timeline, albums, places, memories).
- Stock Photos (2026-11-23): unit tests replay responses recorded from upstream Photos master, the released Photos 8.0.0 and
  an extended server (`PhotosStoreTests/StockServerTests.swift`, `Fixtures/`): detection, 404 propstats, sync, albums, places,
  memories. Integration tests and the Mac app ran against stock master, Photos 8.0.0 (force-enabled on Nextcloud 36) and the
  extended `deploy/devel-all` server; upgrading and downgrading the server's Photos app switched the extended features on and off.
- Not available on the build Mac: iOS/visionOS simulator runtimes, signed builds (App Groups, keychain group, push), devices.

## M0 Foundation — ✅
Login Flow v2 (✅ code; browser flow 🟡 not exercised by hand), login links ✅, untrusted certificates 🟡, client certificates 🟡,
accounts/switching ✅, revocation and remote wipe 🟡, feature detection ✅, store ✅, logging (os.Logger) ✅, CI ✅.
- Feature detection on stock servers ✅: only core features, no extended API is called. Detection runs at launch, hourly, and
  when the capabilities fingerprint changes (checked on foreground, at most every 5 minutes); a failed probe turns only its
  feature off; a detection that fails with a server error keeps core features only; an extended API that answers 404/400
  (album comments, extended config keys) is switched off at once and detection runs again. Settings → Server features groups
  core, newer-Photos, Assistant and companion features.
- Logout, account removal and remote wipe share one clean-up (`AccountPurge`): database, caches, offline files, app password, push
  key and registration, backup options of that account; trusted and client certificates go with the last account on their host.
  Push is unregistered before the app password is revoked. ✅ unit-tested, logout ✅ in the Mac app; remote wipe 🟡 (no server-side test).
- Logging in to an `http://` server asks for confirmation first (not for localhost) ✅.
- ⬜ MDM / AppConfig keys (§5.1.9).
- ⬜ QR code camera scanner (paste of login links works).

## M1 Browse and view — mostly ✅
Index sync (initial, incremental, reconciliation) ✅, timeline views ✅, grid with day sections, pinch zoom, selection, context menus ✅
(macOS ✅, iOS 🟡), year index on iOS 🟡, viewer with zoom/video/Live Photos 🟡, info panel ✅, favourite/delete/archive/export ✅.
- Grid: the zoom step sets a target tile size and the column count follows from the width; days at normal zoom, months and years
  when zoomed out; the scroll position is kept across zoom and resize. Previews are requested for the tile's pixel size (aspect-fill
  aware) and upgraded when the zoom or the screen scale changes. Tiles without a preview show a file-type glyph, videos a badge.
  Sectioning runs off the main actor, bursts of database updates are coalesced, header texts are formatted for visible headers
  only (100 000 items: sections in ~9 ms, whole model ~45 ms in a debug build, see `GridModelTests`). macOS ✅ (run), iOS 🟡 (compiles,
  not run).
- Date scrubber on macOS ✅ (year labels along the scroller, month label while scrolling or hovering, click/drag; hover and drag
  were only exercised through accessibility, not with a real pointer).
- Skeleton grid during the first load and the first sync ✅; the empty state only after a completed sync.
- Keyboard and accessibility in the Mac grid ✅: tiles are buttons (press opens, the context menu actions are accessibility
  actions), arrow keys, Return/Space, Escape. iOS: hardware-keyboard focus and Escape 🟡 (not run).
- ⬜ TL-6 stacks in the grid (the algorithm exists in `PhotosDomain/Stacks.swift`, not yet applied to the grid).
- ⬜ Timeline skeleton from `timelineDays` during the first sync (a plain placeholder grid is shown instead).
- ⬜ "Aspect ratio" tile mode (`croppedLayout`), only square tiles.
- ⬜ VW-4 Live Text / Visual Look Up overlay in the viewer (text extraction exists as an action), ⬜ VW-5 slideshow, ⬜ VW-6 stack strip.
- Viewer on the Mac/iPad: pages fit the visible area (sidebar, toolbar, info inspector), arrow keys / Space / Escape, previous/next
  buttons under the pointer ✅. Video and Live Photo motion play from the local copy when there is one, else through the app's
  HTTP client 🟡 (not exercised against a server with a user-trusted or client certificate).
- Performance budgets (§10) 🟡: the store side is measured with a synthetic 100 000-item index
  (`LargeLibraryPerformanceTests`, tag `performance`; skip with `PHOTOS_SKIP_PERFORMANCE=1`). On an Apple-silicon Mac, release
  build: initial index 6.3 s (store only; was 382 s in a debug build before the search index was fixed, 15 s now in debug),
  1000-row page 65 ms, local search 0.1–10 ms (budget 100 ms), timeline 58 ms as grid rows and 13 ms as lightweight rows,
  map cells for 50 000 geotagged items 8–9 ms (budget 200 ms). ⬜ Launch, scroll hitch rate, viewer and memory budgets are not
  measured (need Instruments on devices); the grid does not use the lightweight timeline rows yet (its observation of grid
  rows is coalesced to one refetch per 300 ms during a sync).
- Search index: FTS5 (trigram, `rowid = fileId`), kept current by triggers on `media`, used for free-text search (SR-3) over
  file name, place, country, caption and folder path. ⬜ Tag, person and album names are not in the index (their memberships
  are not stored locally); tag and person filters still ask the server.
- Preview loading: a load is cancelled when nobody waits for it any more, loads are queued newest first with a limit, prefetches
  are taken back when the grid cancels them (`ImagePipeline.cancelPrefetch`), and previews are decoded at the tile's pixel size
  rather than the size of their bucket (a 400 px tile from the 1024 px bucket holds ~0.6 MB, not 3 MB). Preview and original caches are trimmed
  (LRU; 2 GB / 1 GB) at launch, in the background and every 2000 downloads; previews of offline files are kept; the memory
  cache is emptied on memory pressure and smaller on iPhone. ✅ unit-tested, 🟡 not measured on a device.

## Navigation, menus and windows (SPEC §4.8, §6.2) — 🟡
- Mac: `NavigationSplitView` with a sidebar (Library…Map, Collections, a collapsible "Utilities" section that remembers its state),
  search field with filter tokens in the window toolbar, Settings window titled and sized per tab ✅ (looked at in the Mac app).
  iPhone/iPad/Vision Pro keep `TabView(.sidebarAdaptable)` with the same grouping 🟡 (compiled for iOS, not run).
- Every destination has its own navigation path (`MainView.paths`); selected destination and open album are restored per
  scene (`NavigationSnapshot`) ✅ on the Mac.
- Deep links `nextcloudphotos://<destination>`, `…/album/<name>` (`…/album/shared/<name>`), `…/photo/<fileId>` ✅ parsing unit-tested,
  destination and album links ✅ in the Mac app, photo links 🟡. ⬜ The account part and the other routes of §4.8
  (`places/<name>`, `faces/<name>`, `tags/<name>`, `folders/<path>`), web URLs of the server.
- Menu bar: File (New Window, New Album…, Open Public Album Link…, Upload Photos…, Export…, Share…), View (Zoom In/Out, Sync Now),
  Image (Open, Get Info, Edit…, Edit Date and Location…, favourite, Add to Album…, Delete…), Go (the sidebar's destinations) ✅
  structure read from the running app; the same commands are the keyboard shortcuts on iPadOS 🟡.
  ⬜ Image ▸ Rotate (only inside the editor), Edit ▸ Copy of photos, "Add to Album" as a submenu, Share… in the grid's context
  menu (toolbar and File menu only), opening an album in a new window, View ▸ Square Tiles.
- Mac: "Export…" saves the originals of the selection into a folder 🟡 (the panel was not driven by hand).

## M2 Albums, sharing, upload, offline — ✅
Albums and shared albums ✅, collaborators 🟡 (sharee search not exercised), public links ✅, public album viewer ✅, quick share 🟡,
comments 🟡 (needs extended server), upload (PUT and chunked) ✅, share extension 🟡, drag and drop 🟡, offline albums 🟡
(originals download on Wi-Fi only by default — Settings → Storage; the folder is excluded from device backups).
- Uploads repeat a request after a timeout, a lost connection, a 5xx or a 429/503 with a short `Retry-After` (4 attempts,
  1/2/4 s). A chunked upload that still fails keeps its upload folder (named after destination, size, chunk size and
  checksum); the next attempt lists the chunks and continues with the first missing one ✅ unit-tested against a stub
  server and against the test server (interrupted after 2 of 5 chunks, continued, checksum compared).
- Share extension: uploaded items leave the list, the rest can be tried again after a failure, and it uses the app's
  trusted and client certificates 🟡 (compiled; not run). ⬜ It still uploads in its own process, not in a background session.

## M3 Backup — 🟡
Settings, PhotoKit source, Files-app ledger, reconciliation (✅ SEARCH against server), matcher ✅, engine, UI, background tasks 🟡.
- Backup belongs to one account and keeps running for it while another account is shown (the Backup screen says which) 🟡.
- ⬜ PhotoKit background-upload extension (iOS 27, §7.18.6).
- 🟡 iOS: files up to 100 MB are handed to a background `URLSession` (16 files / 256 MB ahead) and go on while the app is
  suspended; the app is woken for finished uploads (`handleEventsForBackgroundURLSession`), records them and hands over
  the next ones. Engine and bookkeeping ✅ unit-tested with a fake session; the real session ✅ against the test server
  on macOS. **Not run on a device**: suspension, relaunch for finished uploads, behaviour when the device is locked.
  ⬜ Larger files (chunked) are only uploaded while the app runs; they continue where they stopped.
  macOS uploads everything in the app.
- A pass that a background task has to give up is interrupted, not "Paused": it stays due and goes on with the next
  background task or when the app becomes active ✅ unit-tested (engine), 🟡 on a device.
- Background tasks, silent pushes and the "Back up now" intent find the app model after a launch without a window
  (`AppHost`) 🟡 compiled for iOS, not run on a device.
- ⬜ §7.18.8 remove backed-up photos from the device.
- ⬜ Most-compatible video conversion (HEVC → H.264); images only.
- ✅ Run state machine unit-tested with a fake library and server: pause and resume (Wi-Fi, Low Data, Low Power, lost connection),
  stop on full quota / invalid login / refused upload (`BackupStatus.blocker`), retry delays for failing files, skipping assets the
  ledger knows completely, edits and RAW files matched per rendition, Live Photo halves linked across runs.
- 🟡 Not exercised on a device: `PHAssetResource.dataSize` for the exact-size match, the network path and Low Power Mode observers.
- 🟡 `BackupModel` passes changed options to a waiting run (`BackupEngine.settingsChanged`); the Backup screen and the
  "Back up now" intent name what blocks the backup (full storage, login, refused upload, certificate). Compiled and
  unit-tested (outcome mapping), not looked at in the running app.
- 🟡 Acceptance test (device library partly uploaded by Files, zero duplicates) still to run on a device.

## M4 Discover — 🟡
Places ✅, map 🟡, people 🟡 (no Recognize on test servers), tags ✅ (API), folders ✅ (API), shared with you 🟡, On this day ✅,
memories ✅, search and smart albums 🟡, archive and app lock 🟡, push 🟡 (needs proxy registration and provisioning), widgets 🟡.
- Push: permission is asked after login or when the Notifications switch is turned on, not at first launch; the switch unregisters
  and registers; the notification extension only shows `photos` notifications and handles delete pushes. All 🟡: hiding the others
  needs the `com.apple.developer.usernotifications.filtering` entitlement (or the server-side routing of §S5). Silent delete
  pushes reach `AppModel.handleBackgroundPush` through the app delegates (`remote-notification` background mode).
- ⬜ Memory player (ME-4) and "Save as album" from a memory.
- ⬜ Map time slider; MapKit native clustering (grid clustering is used).
- ⬜ Tag assignment UI (API exists).

## M5 Advanced — 🟡
Editor (Core Image) 🟡, metadata editing 🟡, recently deleted ✅ (API), duplicates 🟡, free up space 🟡, extract text (server OCR or
Vision) 🟡, Ask your photos (server Assistant or on-device Foundation Models) 🟡, video renditions 🟡, App Intents and App Shortcuts 🟡.
- ⬜ Free-form crop (aspect presets only).
- Free up space works on the **server** (title "Free up server space"): screenshots by file name or PNG with a phone-screen size and no
  location — never every PNG (`PhotosDomain/Cleanup.swift`); the confirmation names the server, all devices and trash bin vs. permanent.
  Freeing device storage is §7.18.8 (Backup), ⬜.
- Duplicates: suggested copy to keep (favorite, own file, oldest upload) with the reason shown, user can pick another one.
  ⬜ Warning when a deleted copy is in an album.
- ⬜ Spotlight indexing of albums/people/places; App Intent entities (albums, people) and search intent.
- ⬜ visionOS spatial photos / immersive panoramas.
- Accessibility and localisation audit 🟡: every module and target with user-facing text has a string catalog
  (`Localizable.xcstrings` in PhotosAppUI, PhotosNetworking, PhotosCore, PhotosBackup, PhotosDomain, the app, the widgets;
  `AppShortcuts.xcstrings`, `InfoPlist.xcstrings` for the permission texts), English plural variations, `bundle: .module` in the
  packages; `xcodebuild -exportLocalizations` exports all of them. Cards, map markers, folder and public-album photos, viewer pages
  (description, "3 of 120", favourite/info/delete actions, swipe up/down to step on iOS) have VoiceOver labels; Reduce Motion,
  Increase Contrast / Reduce Transparency and accessibility text sizes are handled in the viewer, scrubber, tiles and cards; iOS
  haptics for selection, favourite and delete. Checked on the Mac through the accessibility tree; iOS only compiled.
  ⬜ Transifex setup (`.tx/config` for string catalogs), ⬜ server feature names in Settings › Server features are not localised.
- ⬜ App Store assets and review notes.

## Prerequisites from SPEC §14 still open
App Group / keychain group provisioning, push proxy topic, notification routing in the notifications app, app icon artwork,
a test server with Recognize and an Assistant provider.

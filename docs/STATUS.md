# Implementation status

State of the app against [SPEC.md](SPEC.md) on 2026-11-22. Work is delivered as stacked draft PRs:
#1 M0 + M1 (most), #2 M2, #3 M3, #4 M4a, #5 M4b, #6 M5.

Legend: ✅ implemented and checked against a real server · 🟡 implemented, not verified end to end · ⬜ not implemented yet.

## Verified how

- Unit tests (`xcodebuild test -scheme PhotosKit-Package -destination platform=macOS`): parsing, request bodies, initial-state scraping,
  store, sync engine and outbox against a stubbed DAV server (changes made elsewhere, deletes/moves, ETag boundary, ordering/backoff,
  cancellation), timeline sections, memories, stacks, duplicates, search suggestions, backup matcher and naming, editing, BlurHash, push key encoding.
  In CI they run on the `xcode-27` runner (macOS 27) and in an iOS 27 simulator (the simulator job was added on 2026-11-23
  and had not run when this was written; the tests compile for the simulator).
  `PhotosCoreTests` run the app model in a temporary container against a stubbed server: what logout and remote wipe leave on
  disk and in the secret store, logout order, the Notifications switch, push payload handling, offline downloads, backup outcome.
- Integration tests against a local Nextcloud 36 + Photos master server (504-item test library): feature detection, sync, albums,
  album content, places, previews, favourite/move/delete made elsewhere, album/link/upload round trip, public album access, reconciliation SEARCH, trash, tags, folders.
- The Mac app was run against the same server (timeline, albums, places, memories).
- Stock Photos (2026-11-23): unit tests replay responses recorded from upstream Photos master, the released Photos 8.0.0 and
  an extended server (`PhotosStoreTests/StockServerTests.swift`, `Fixtures/`): detection, 404 propstats, sync, albums, places,
  memories. Integration tests and the Mac app ran against stock master, Photos 8.0.0 (force-enabled on Nextcloud 36) and the
  extended test server (Photos integration branch); upgrading and downgrading the server's Photos app switched the extended features on and off.
- A fresh Nextcloud 35.0.3 from the release archive (`scripts/test-server.sh`, 2026-11-23): the nine integration tests pass
  when run one after the other; the nightly workflow uses the same script.
- UI smoke tests (`UITests`, three cases) 🟡 compile for macOS and iOS, never run.
- Nothing has run on a device; the plan for that is [test-plan.md](test-plan.md).
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
- QR code login 🟡: on iPhone and iPad "Scan QR code" opens the system scanner (VisionKit `DataScannerViewController`,
  only where it is supported; camera access is asked for first, without it the link can be pasted). Compiles for iOS, not
  run (no simulator runtime, no device). The Mac and Vision Pro offer "Log in with a link".
- Account state over a cached library ✅ (Mac app, against a proxy in front of the test server): the banner at the bottom of
  every grid says "Couldn't sync" with the reason and Retry, "Signed out" with "Log in again", and "The server's certificate
  changed" with "Review…" (the trust dialog of the login); Settings › Server shows the same. A refused certificate makes every
  request on the connection report the certificate (`HTTPClient`, unit-tested), so the sync fails visibly instead of
  stopping as "cancelled". The HTTP/2 case (several requests on one refused connection) is only unit-tested.
- Diagnostics ✅ (Mac app): Settings › Server › "Export diagnostics…" writes the app's log entries of this run (at most
  the last 48 hours; the system only gives an app the log of its running process), app, system and server versions and
  the detected features into a text file (backup passes and their phase changes are logged too: names and
  counts only) — save panel on the Mac, share sheet elsewhere (🟡 not run). Account names,
  addresses, paths, file names and tokens are removed (unit-tested). ⬜ The rotating log file of SPEC §4.5 (logs across launches).

## M1 Browse and view — mostly ✅
Index sync (initial, incremental, reconciliation) ✅, timeline views ✅, grid with day sections, pinch zoom, selection, context menus ✅
(macOS ✅, iOS 🟡), year index on iOS 🟡, viewer with zoom/video/Live Photos 🟡, info panel ✅, favourite/delete/archive/export ✅.
- Sync and outbox safety ✅ unit-tested against the stubbed DAV server (`PhotosStoreTests/DataLayerTests.swift`,
  `PhotosCoreTests/DataLayerTests.swift`), 🟡 not exercised against a real server:
  a detection that cannot read the Photos settings keeps the cached timeline folders, MIME types and `.nomedia` folders
  (404 = no Photos app = defaults); `.nomedia` folders come from a files SEARCH when the Photos page is not read; a change
  of the timeline folders rebuilds the index but keeps albums; offline originals are only removed when the server said
  their album no longer contains them. Index paging ends at an empty page only; a reconciliation that would remove more
  than half of an index of more than 20 items waits for a second listing (the next sync); a changed root ETag leads to
  a full reconciliation at most every 10 minutes ("Sync now" and pull-to-refresh at once). Queued deletes and moves find
  the file by its id first (one small SEARCH each); a locked file (423) is retried; an operation that failed for good or
  was discarded gives the local row back. Smart albums and album collaborators are read again before they are written.
  ETags are whitelisted or hashed before they become part of a cache file name.
- Viewer zoom (VW-1): every photo page is a real zooming scroll view (`ZoomSurface`: `UIScrollView` on iOS/visionOS,
  `NSScrollView` with magnification on the Mac) — pinch around the fingers or the pointer, double tap / double click zooms to
  that point, the photo cannot leave the page, two-finger scroll and mouse drag pan a zoomed photo on the Mac, View ▸ Zoom In /
  Zoom Out / Zoom to Fit (⌘+ / ⌘− / ⌘0), the same as actions for assistive technologies. Geometry ✅ unit-tested
  (`ViewerZoomTests`); Mac ✅ run (zoom steps, double click, centring and clamping read from the running app; **not** exercised
  with a real trackpad: pinch, and paging with a two-finger swipe over a photo that is not zoomed); iOS 🟡 compiled, not run.
- iPhone/iPad 🟡 (compiled, not run): swipe down closes the viewer (the page follows the finger, the backdrop fades), swipe up
  shows the info panel; every screen opens the viewer through one modifier (`mediaViewer`), with the navigation stack its
  toolbar needs — also from Folders, Shared with you and photo links. ⬜ Zoom transition from the tile (matched geometry).
- Viewer actions: More ▸ Add to Album… / Export… (Save to Photos on iOS), also from the menu bar; deleting or archiving takes
  the page out and shows the next photo ✅ Mac (delete; archive shares the code). Saving originals goes through one path for
  grid, viewer and menu bar (`MediaSaveModel`): progress with Cancel, "Exported 3 items" / what failed; on the Mac the viewer
  asks for a folder like the grid ✅ (panel opens; the export itself was not driven by hand) — result logic ✅ unit-tested.
- Video page: loading, "Preparing video…" (server converts, no warning sign) and failure (what happened, reason, "Try again")
  are separate states; a stream that fails after the player is shown ends in the failure state 🟡 (states unit-tested, not
  provoked against a server). iOS 🟡: the player is `AVPlayerViewController` without any gesture of the viewer over it (taps
  toggle the bars on photo pages only); not run on a device — that the scrubber does not page the viewer is expected from
  UIKit's gesture arbitration, not verified.
- Grid: the zoom step sets a target tile size and the column count follows from the width; days at normal zoom, months and years
  when zoomed out; the scroll position is kept across zoom and resize. Previews are requested for the tile's pixel size (aspect-fill
  aware) and upgraded when the zoom or the screen scale changes. Tiles without a preview show a file-type glyph, videos a badge.
  Sectioning runs off the main actor, bursts of database updates are coalesced, header texts are formatted for visible headers
  only (100 000 items: sections in ~9 ms, whole model ~45 ms in a debug build, see `GridModelTests`). macOS ✅ (run), iOS 🟡 (compiles,
  not run).
- The parts of the grid that do not depend on the platform (what an update means, section layout, the item kept in place
  across a relayout, prefetch requests, tile badges and preview loading) are shared by the AppKit and the UIKit grid
  (`Grid/GridCore.swift`) ✅ unit-tested; the Mac grid was compared before and after the extraction (zoom, resize, scrubber, selection).
- iPhone/iPad grid 🟡 (compiled for iOS and visionOS, not run): pull to refresh (a refresh control on the collection view, driven
  by the screen's `.refreshable`; it ends when the sync or reload has returned), a two-finger drag starts the selection mode,
  the context menu of a photo shows a large preview (a tap opens it), tiles can be dragged into other apps on iPad (the original
  is downloaded on drop), selection mark in the bottom trailing corner, hover effect under the pointer. The logic behind them
  (single-flight refresh, what a drag carries, mark and preview sizes) ✅ unit-tested.
- Date scrubber on macOS ✅ (year labels along the scroller, month label while scrolling or hovering, click/drag; hover and drag
  were only exercised through accessibility, not with a real pointer).
- Skeleton grid during the first load and the first sync ✅; the empty state only after a completed sync.
- Keyboard and accessibility in the Mac grid ✅: tiles are buttons (press opens, the context menu actions are accessibility
  actions), arrow keys, Return/Space, Escape. iOS: hardware-keyboard focus and Escape 🟡 (not run).
- ⬜ TL-6 stacks in the grid (the algorithm exists in `PhotosDomain/Stacks.swift`, not yet applied to the grid).
- ⬜ Timeline skeleton from `timelineDays` during the first sync (a plain placeholder grid is shown instead).
- ⬜ "Aspect ratio" tile mode (`croppedLayout`), only square tiles; the "Square tiles" switch is gone from Settings until
  the mode exists.
- Undo ✅ (Mac app): favourite, archive, remove from album and delete (restored from the server's trash bin) register with
  the window's undo manager (Edit › Undo/Redo, ⌘Z; shake on iPhone 🟡 not run) and show a confirmation with an Undo button
  ("Archived 3 items · Undo"), in the grids and in the viewer (favourite, archive, delete; an undo there brings the
  page back, Redo takes it out again). A photo
  restored after a delete comes back to the library, not to the albums it was in (the server drops those on delete).
- Empty and error states have an action (SPEC §6.3): "Sync now" / "Retry" in the library, "Refresh" / "Try again" in lists
  loaded from the server, "Clear search" for a search without results.
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
  iPad at regular width and Vision Pro keep `TabView(.sidebarAdaptable)` with the same grouping 🟡 (compiled for iOS, not run).
- iPhone and narrow iPad windows 🟡 (compiled, logic unit-tested in `CompactNavigationTests`, not run): tabs Library,
  Collections, Search, Settings. The Collections tab lists every place that is a sidebar row elsewhere (server features
  respected) and Backup with its state, and pushes it in its own stack; the navigation state stays the selected destination
  and its path, so deep links, state restoration and a change between tab bar and sidebar keep working.
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
- "Add photos" to an album uses the library's grid in selection mode: day headers, zoom, date scrubber, drag and ⇧/⌘ selection,
  a search field (local search index: name, place, caption, folder), the count of picked photos; picks survive a changed
  search. macOS ✅ (run: search, selection, add), iOS 🟡 (compiled, not run).
- Album toolbar: the album keeps its title while photos are selected, the count is the subtitle (visionOS: the title). The
  album options menu hides while selecting on iPhone and iPad and has its own symbol on the Mac; at compact width the
  album's actions are one menu. macOS ✅ (run), iOS 🟡 (compiled, layout rule unit-tested, not run).
- Uploads repeat a request after a timeout, a lost connection, a 5xx or a 429/503 with a short `Retry-After` (4 attempts,
  1/2/4 s). A chunked upload that still fails keeps its upload folder (named after destination, size, chunk size and
  checksum); the next attempt lists the chunks and continues with the first missing one ✅ unit-tested against a stub
  server and against the test server (interrupted after 2 of 5 chunks, continued, checksum compared).
- Share extension: uploaded items leave the list, the rest can be tried again after a failure, and it uses the app's
  trusted and client certificates 🟡 (compiled; not run). Items that cannot be read are counted ("2 of 5 items could
  not be read"), and its temporary copies are removed on cancel, on completion and (leftovers) at the start ✅ unit-tested. ⬜ It still uploads in its own process, not in a background session.

## M3 Backup — 🟡
Settings, PhotoKit source, Files-app ledger, reconciliation (✅ SEARCH against server), matcher ✅, engine, UI, background tasks 🟡.
- Backup belongs to one account and keeps running for it while another account is shown (the Backup screen says which) 🟡.
- ⬜ PhotoKit background-upload extension (iOS 27, §7.18.6).
- 🟡 iOS: files up to 100 MB are handed to a background `URLSession` (16 files / 256 MB ahead) and go on while the app is
  suspended; the app is woken for finished uploads (`handleEventsForBackgroundURLSession`), records them and hands over
  the next ones. Engine and bookkeeping ✅ unit-tested with a fake session; the real session ✅ against the test server
  on macOS. **Not run on a device**: suspension, relaunch for finished uploads, behaviour when the device is locked.
  ⬜ Larger files (chunked) are only uploaded while the app runs; they continue where they stopped. They come after
  everything the system can take, so one big video no longer holds back the queue in a short background pass, and
  their export is kept for the next attempt when the upload is interrupted (`tmp/Backup/Kept`) ✅ unit-tested.
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
- ✅ "Up to date" only when the ledger has no failed and no waiting item; otherwise the Backup screen and the "Back up
  now" intent say "N items could not be uploaded" (reason, "Try again"). Entries of photos that were deleted on the
  device no longer wait forever. Unit-tested (engine, outcome); the screen is 🟡 compiled, not looked at.
- ✅ A new file is sent with `If-None-Match: *` (direct PUT and background session), so a file that appeared after the
  name check is never overwritten; 412 → the name is looked up again (same size = already uploaded, otherwise the next
  free name). Unit-tested against the stub server and the fake session; the header ✅ against the test server.
- ✅ Matcher: a server name only stands for a device file when it is the same name or has every number of it
  (`PXL_20240501_123045123`, `20240501_123045_001`, UUID names no longer collide), and never when two device files of
  that second would fit. The Files app's record covers the photo or video itself, not RAW / edit / motion part.
- 🟡 Device side: no room on the device stops the pass ("free up space" blocker, checked before each export); originals
  that are only in iCloud are downloaded on Wi-Fi only and wait otherwise ("Waiting for Wi-Fi to download originals
  from iCloud"); with "Download originals from iCloud" off they are skipped and counted on the Backup screen until the
  option changes. Engine ✅ unit-tested with a fake library; PhotoKit's error for "only in iCloud"
  (`PHPhotosError.networkAccessRequired`) and the free-space value are **not exercised on a device**.
- 🟡 Scope: only the user's own library (no iCloud Shared Albums); hidden photos only with "Include hidden photos" (off
  by default, the screen says so). The unused "include shared-library photos" option (§7.18.2) is gone: PhotoKit has no
  public way to tell iCloud Shared Photo Library items apart, they are part of the user library. With access to
  selected photos only, the Backup screen keeps saying so (button to Settings) and the intent adds it to its answer.
  Fetch options compiled, not run against a real library.
- ✅ Leftover exports in `tmp/Backup` are removed before an engine's first pass; which resources of an asset are uploaded
  (edited / RAW / Live Photo) is unit-tested (`PhotoLibrarySource.select`).
- 🟡 Acceptance test (device library partly uploaded by Files, zero duplicates) still to run on a device.

## M4 Discover — 🟡
Places ✅, map 🟡, people 🟡 (no Recognize on test servers), tags ✅ (API), folders ✅, shared with you 🟡, On this day ✅,
memories ✅, search and smart albums 🟡 (Return searches, recent searches, error state with "Try again": ✅ Mac app), archive and app lock 🟡, push 🟡 (needs proxy registration and provisioning), widgets 🟡.
- Push: permission is asked after login or when the Notifications switch is turned on, not at first launch; the switch unregisters
  and registers; the notification extension only shows `photos` notifications and handles delete pushes. All 🟡: hiding the others
  needs the `com.apple.developer.usernotifications.filtering` entitlement (or the server-side routing of §S5). Silent delete
  pushes reach `AppModel.handleBackgroundPush` through the app delegates (`remote-notification` background mode).
- Folders and Shared with you show a folder's photos in the app's photo grid (selection, context menu, share, favourite,
  delete, keyboard, viewer), subfolders in a strip above it ✅ Mac. Like the other server-loaded lists (places, tags) the grid
  is loaded once: an item deleted there disappears after a reload.
- ⬜ Memory player (ME-4) and "Save as album" from a memory.
- ⬜ Map time slider; MapKit native clustering (grid clustering is used).
- ⬜ Tag assignment UI (API exists).

## M5 Advanced — 🟡
Editor (Core Image) 🟡, metadata editing 🟡, recently deleted ✅ (API; restore sends `Overwrite: T` — it was refused with 412 before; "Delete permanently" asks first and errors are shown; the screen itself 🟡: it is behind the device unlock, not opened in the test run), duplicates 🟡, free up space 🟡, extract text (server OCR or
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
  Server feature names in Settings › Server features come from the PhotosAppUI catalog. Every key of every catalog has a comment for translators.
  ⬜ Transifex: no `.tx/config` yet, the proposed setup waits for the localization team ([LOCALIZATION.md](LOCALIZATION.md)).
- Release readiness 🟡: privacy manifests for the app, the extensions and the package targets; push entitlement
  (`aps-environment`); export-compliance and ATS reasoning with the App Review note ([PRIVACY-AND-EXPORT.md](PRIVACY-AND-EXPORT.md));
  build number settable from CI; unsigned Release archives in CI and a release workflow without signing. Nothing was
  signed, uploaded or validated by App Store Connect.
- App icon 🟡: all Mac sizes from the one 1024 px image; ⬜ dark/tinted variants, Mac-shaped icon, visionOS layered icon
  ([APP-ICON.md](APP-ICON.md)).
- ⬜ App Store assets (screenshots), signing secrets in CI.

## Prerequisites from SPEC §14 still open
App Group / keychain group provisioning and the Push Notifications capability (table in the README), Apple's notification
filtering entitlement, push proxy topic, notification routing in the notifications app, app icon artwork,
a test server with Recognize and an Assistant provider.

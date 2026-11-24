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
- UI smoke tests (`UITests`) ✅ on iPhone: `PhoneTourTests` (library and date scrubber, selection, context menu, viewer, Collections,
  Settings, Search, a memory, every link destination) run in the iOS 27.2 simulator (iPhone 18 Pro and iPhone 17e) against the local test
  server, screenshots in `ios-fix-shots/r4-iphone/`; `SmokeTests` (three cases) pass there too. Not run on the Mac.
- Nothing has run on a device; the plan for that is [test-plan.md](test-plan.md).
- Not available on the build Mac: a visionOS simulator runtime (the iOS 27.2 simulator is installed since 2026-11-24), signed builds (App Groups, keychain group, push), devices.

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
  Also cleared (round 3): the account's delivered notifications, the widgets (timelines reloaded), shared diagnostics reports,
  the window's stored place when it names the removed account's album (`NavigationSnapshot.account`), and certificates of
  hosts without an account (trusted in a login that was cancelled or ended on another server; also swept at launch).
  ✅ unit-tested except the notification and widget calls (system services, 🟡).
- Logging in to an `http://` server asks for confirmation first (not for localhost) ✅. The Login Flow keeps `https://` for the
  login page and the poll when the typed address is `https://` (a proxy without `overwriteprotocol` names itself with http);
  the same host returned with `http://` stays on https; a refused http server gets its fresh app password revoked over the
  typed https address ✅ unit-tested (stubbed server), not run against a misconfigured proxy.
- QR codes and login links show "Log in to <host> as <user>?" before anything is sent ✅ compiled (iOS scanner 🟡 not run).
- Keychain items are `AfterFirstUnlockThisDeviceOnly` (not in backups or on other devices); existing items are switched once
  at launch 🟡 (signed builds only; unsigned Mac builds use the file store).
- MDM / AppConfig keys (§5.1.9) 🟡 (round 4): `serverUrl` (address filled in and fixed; logins to other servers refused, also
  QR codes, links and Files-app suggestions; `addAccount` checks again and revokes the granted app password), `username`
  (proposed on the login page with `?user=`), `disable_multiaccount` ("Add account" hidden, a second login refused, logging in
  again allowed), `enforce_passcode_lock` (app lock on and its switch disabled; written to the App Group so widgets and
  extensions follow), `disable_log` (no kept log, export and switch disabled, the log deleted), `disable_backup` (backup off,
  Backup screen says so). Read from `com.apple.configuration.managed` at launch and on every `UserDefaults` change. Existing
  accounts are kept when a restriction arrives. Parsing and policy ✅ unit-tested (`ManagedAndSpotlightTests`); the Mac app
  started with a managed configuration, the managed UI was not looked at (no MDM-delivered configuration on the build Mac).
- QR code login 🟡: on iPhone and iPad "Scan QR code" opens the system scanner (VisionKit `DataScannerViewController`,
  only where it is supported; camera access is asked for first, without it the link can be pasted). Compiles for iOS, not
  run (no simulator runtime, no device). The Mac and Vision Pro offer "Log in with a link".
- A login whose app password the keychain cannot store (an unsigned build without the keychain entitlement) fails with "Your
  login could not be saved in the keychain (error …)" and the granted app password is revoked; before, the write failed
  silently and the app showed "Signed out — your login … is no longer valid" at once. An account whose app password is
  missing from the keychain says so ("… is missing from the keychain") instead of "no longer valid" ✅ unit-tested; seen in
  the iOS 27.2 simulator before the fix.
- Account state over a cached library ✅ (Mac app, against a proxy in front of the test server): the banner at the bottom of
  every grid says "Couldn't sync" with the reason and Retry, "Signed out" with "Log in again", and "The server's certificate
  changed" with "Review…"; Settings › Server shows the same. Review shows the previous and the new certificate (subject,
  SHA-256). Only a host whose certificate the user had trusted before (renewed self-signed) can be trusted in place, after
  a confirmation switch; a host the system trusted needs "Log in again…". Nothing is sent with the new certificate before
  that. The state ends on the next answered request (also over a connection that stayed open) ✅ unit-tested; the sheet 🟡
  compiled, not run. A refused certificate makes every
  request on the connection report the certificate (`HTTPClient`, unit-tested), so the sync fails visibly instead of
  stopping as "cancelled". The HTTP/2 case (several requests on one refused connection) is only unit-tested.
- Diagnostics ✅ (Mac app): Settings › Server › "Export diagnostics…" writes the app's log entries of this run (at most
  the last 48 hours; the system only gives an app the log of its running process), app, system and server versions and
  the detected features into a text file (backup passes and their phase changes are logged too: names and
  counts only) — save panel on the Mac, share sheet elsewhere (🟡 not run). Account names,
  addresses, paths, file names and tokens are removed (unit-tested). Log across launches ✅ unit-tested, 🟡 in the app: the
  app copies its entries, redacted, into `Library/Logs/diagnostics.log` (256 KB, two older files) every 5 minutes and when it
  goes to the background; the export adds the earlier runs. "Keep log across restarts" in Settings › Diagnostics (on by
  default; off deletes the files). iOS: the exported report is deleted when the share sheet closes.
- Settings › About › Licences: the MIT texts of the app and GRDB.swift ✅ compiled.

## M1 Browse and view — mostly ✅
Index sync (initial, incremental, reconciliation) ✅, timeline views ✅, grid with day sections, pinch zoom, selection, context menus ✅
(macOS ✅, iOS 🟡), date scrubber on iOS ✅ run in the iOS 27.2 simulator, viewer with zoom/video/Live Photos 🟡, info panel ✅, favourite/delete/archive/export ✅.
- Sync and outbox safety ✅ unit-tested against the stubbed DAV server (`PhotosStoreTests/DataLayerTests.swift`,
  `PhotosCoreTests/DataLayerTests.swift`), 🟡 not exercised against a real server:
  a detection that cannot read the Photos settings keeps the cached timeline folders, MIME types and `.nomedia` folders
  (404 = no Photos app = defaults); `.nomedia` folders come from a files SEARCH when the Photos page is not read; a change
  of the timeline folders rebuilds the index but keeps albums; offline originals are only removed when the server said
  their album no longer contains them. Index paging ends at an empty page only. Mass-delete guard: a listing that lacks
  more than half of an index of more than 20 items, or any items on mounted storage (external, shares, group folders),
  keeps them as suspects; a later listing removes only the suspects it lacks too, at least an hour after the first, and
  only when a sample of them answers 404 by path (an external storage that is not available answers 503 and keeps
  everything). Reconciliation is resumable (unseen rows in `reconcileUnseen`, cursor in the sync state; an interrupted
  walk goes on from its page) and streamed page by page; a changed root ETag leads to one at most every 10 minutes,
  longer for large libraries (150 000 items: one hour), not while a backup pass uploads (unless a day has passed);
  pull-to-refresh reconciles only when the last walk is 10 minutes old, "Sync now" at once. Small removals are checked
  by id before they are applied. Recent uploads are read again at checkpoints (10 min, 1 h, 6 h, 24 h, 47 h after the
  upload) while their place is unknown, not on every sync. Opening an album asks for the album alone and reads its
  content only when count, last photo, date range or last-modified changed (or after a day); the content is written as
  a difference. The outbox sends up to 5 operations at a time, never two for the same file; queued deletes and moves
  address the file with the path and ETag the index knows (`If-Match`, one request) and look it up by its id only when
  that is refused; a connection problem pauses the queue, a locked file (423) holds back only its own operations and is
  given up after 8 answers of 423; an operation that failed for good or was discarded gives the local row back (only for
  files the timeline shows), and album content read from the server keeps the album changes still queued. Bulk
  archive/unarchive/delete ✅ against the 8089 test server (`IntegrationOutboxTests`). Smart albums and album
  collaborators are read again before they are written.
  ETags are whitelisted or hashed before they become part of a cache file name.
- Viewer zoom (VW-1): every photo page is a real zooming scroll view (`ZoomSurface`: `UIScrollView` on iOS/visionOS,
  `NSScrollView` with magnification on the Mac) — pinch around the fingers or the pointer, double tap / double click zooms to
  that point, the photo cannot leave the page, two-finger scroll and mouse drag pan a zoomed photo on the Mac, View ▸ Zoom In /
  Zoom Out / Zoom to Fit (⌘+ / ⌘− / ⌘0), the same as actions for assistive technologies. Geometry ✅ unit-tested
  (`ViewerZoomTests`); Mac ✅ run (zoom steps, double click, centring and clamping read from the running app; **not** exercised
  with a real trackpad: pinch, and paging with a two-finger swipe over a photo that is not zoomed); iOS 🟡 compiled, not run.
- iPhone/iPad 🟡 (compiled, not run): swipe down closes the viewer (the page follows the finger, the backdrop fades), swipe up
  shows the info panel; every screen opens the viewer through one modifier (`mediaViewer`), with the navigation stack its
  toolbar needs — also from Folders, Shared with you and photo links. Zoom transition from the tile 🟡 (compiled for iOS,
  not run): the grid marks the tapped tile's frame as `matchedTransitionSource` and the cover uses `.navigationTransition(.zoom)`;
  while paging, the grid scrolls the current photo's tile on screen and the transition follows it, so closing zooms back into the
  tile of the photo shown last. The system's own interactive dismissal is turned off (the viewer keeps its swipe down). The
  Mac pushes the viewer without a zoom (`navigationTransition(.zoom)` is not available on macOS).
- Viewer actions: More ▸ Add to Album… / Export… (Save to Photos on iOS), also from the menu bar; deleting or archiving takes
  the page out and shows the next photo ✅ Mac (delete; archive shares the code); Delete (⌘⌫) does nothing for a
  read-only photo, and a page whose photo was removed meanwhile says so instead of loading for ever (🟡 not run). Saving originals goes through one path for
  grid, viewer and menu bar (`MediaSaveModel`): progress with Cancel, "Exported 3 items" / what failed; on the Mac the viewer
  asks for a folder like the grid ✅ (panel opens; the export itself was not driven by hand) — result logic ✅ unit-tested.
- Only the video page shown holds a player (`VideoRetention`): a page that is paged away pauses, lets go of its item and its
  stream (`replaceCurrentItem(with: nil)`, the loader is released) and remembers the position, which playback goes on from when
  the page is shown again. No neighbour is preloaded. Live Photo motion is released when it disappears. Policy ✅ unit-tested,
  🟡 not measured.
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
- iPhone grid ✅ run in the iOS 27.2 simulator: scrolling, selection mode (the tab bar now makes room for the selection's
  actions, which were under it), context menu with preview; pull to refresh, pinch and the two-finger drag were not exercised.
  iPad and visionOS 🟡 (compiled, not run here). Pull to refresh (a refresh control on the collection view, driven
  by the screen's `.refreshable`; it ends when the sync or reload has returned), a two-finger drag starts the selection mode,
  the context menu of a photo shows a large preview (a tap opens it), tiles can be dragged into other apps on iPad (the original
  is downloaded on drop), selection mark in the bottom trailing corner, hover effect under the pointer. The logic behind them
  (single-flight refresh, what a drag carries, mark and preview sizes) ✅ unit-tested.
- Date scrubber on macOS ✅ (year labels along the scroller, month label while scrolling or hovering, click/drag; hover and drag
  were only exercised through accessibility, not with a real pointer).
- Date scrubber on iPhone, iPad and Vision Pro ✅ run in the iOS 27.2 simulator (iPhone): replaces UIKit's section index, which
  listed every year in a column over the photos and down into the tab bar. Runs between the bars, appears while the grid
  scrolls and fades out, can be grabbed at the edge while shown (month label while scrubbing, a tick of haptic feedback per
  year), leaves out year labels that do not fit (`GridScrubberTrack`, unit-tested, shared with the Mac), labels on a background
  of their own (opaque with Increase Contrast / Reduce Transparency), adjustable element for VoiceOver.
- Skeleton grid during the first load and the first sync ✅; the empty state only after a completed sync.
- First-sync progress "Loading your library — 12,000 of 48,213" where the extended server's `timelineDays` gives the total
  (summed once per session; no total once more items arrived than it counted, since it leaves out shared folders); stock
  servers have no cheap count and show "Loading your library — 12,000" 🟡 (text unit-tested, total read from the extended
  test server; not looked at on screen: the Mac was locked).
- Keyboard and accessibility in the Mac grid ✅: tiles are buttons (press opens, the context menu actions are accessibility
  actions), arrow keys, Return/Space, Escape. iOS: hardware-keyboard focus and Escape 🟡 (not run).
- TL-6 stacks, the conservative part 🟡 (unit-tested; Mac UI not checked, the screen was locked): copies of one shot — images in
  the same folder with the same name apart from extension and case, taken at most 2 s apart (HEIC + JPEG, RAW + JPEG) — are one
  tile in Library, Photos, Videos and Favorites (`CopyStacks`, `TimelineStacking`, off the main actor; 150 000 items ~90 ms in a
  debug build). The tile shows the JPEG (or the copy with a preview), with a stack badge and "2 copies" for VoiceOver; the viewer's
  "Show 2 copies" (bar above the photo and More menu) adds the other copies as pages. Settings › On this device › "Stack copies of a
  photo" (on by default).
- TL-6 bursts 🟡 (unit-tested, `BurstStacksTests`; not seen on screen, the test servers have no burst): only bursts the camera
  named as one are stacked — `…_BURST001_COVER.jpg`/`…_BURST002.jpg` (Google Camera), `00000IMG_00000_BURST<time>_COVER.jpg`
  (Pixel 2), `PXL_….BURST-01.COVER.jpg`: same marker, images, same folder, within 60 s; the `COVER` frame is shown, VoiceOver says
  "Burst of 5 photos"; copies of burst frames (RAW + JPEG) belong to the burst (`BurstStacks`, `TimelineStacks`). ⬜ iPhone bursts
  and time-based bursts, by decision: Apple marks a burst only in its maker note (BurstUUID), which stock servers do not hand out
  (no EXIF in the timeline's SEARCH; `photos-exif` keeps entries up to 1000 bytes and the maker note only as an opaque blob, if at
  all), and the web's "≤ 3 s apart" rule (`PhotosDomain/Stacks.swift`) also folds quick series of single shots, which Photos never
  does. Would need the server to report the burst identifier (or the client to read EXIF of every photo).
- Actions on a stacked tile 🟡 (logic unit-tested, `TimelineGridTests`; the confirmation dialog not looked at on screen, the Mac was
  locked): as in Photos, where RAW + JPEG are one photo and a burst one item, delete, favourite, archive/unarchive, add to album,
  tags and date/location apply to everything behind the tile (context menu, selection toolbar, menu bar); the delete confirmation
  counts all items ("Delete 3 items?") and says "This also deletes 2 photos stacked behind the selected ones."; the undo toast
  counts all. Open, Get Info, Edit, Share, Export and Share via Nextcloud stay with the copy the tile shows. (Albums are not
  stacked: an album then shows both copies.)
- Timeline skeleton during the first sync 🟡 (extended servers; ✅ Mac, run against the 8091 test server with a sync slowed down
  locally, screenshots `ios-fix-shots/r4-timeline/04…08`; iOS compiled, not run): the day counts of `timelineDays` are summed into
  months (`TimelineSkeleton`); the library grid gets a section of placeholder tiles for every month older than the oldest one
  loaded, and the rest of that month as placeholder tiles after its photos (`GridModel`, `GridSection.placeholders`), so the
  scroll height, date scrubber and year index (iOS section index) cover the whole library from the first page on; pages of the
  sync are batch updates of the tail. Placeholder tiles cannot be selected, opened or dragged; VoiceOver says "Loading…". Only for
  the unfiltered library (what the counts are of); stock servers (no counts) keep the plain placeholder grid and show what has
  loaded. The counts are UTC days and leave out shared folders: only the tail is estimated, and it is replaced as photos arrive.
- "Aspect ratio" grid 🟡 (✅ Mac, run: View ▸ Square Tiles ⌥⌘S toggles it, screenshots `01`/`02`; iOS/iPad compiled, not run):
  Settings › On this device › "Square tiles" (on by default) and View ▸ Square Tiles (⌥⌘S, also the iPad keyboard shortcut). Off,
  every grid fits each photo whole into its square cell, centred, as Photos' "Aspect Ratio Grid"; badges, the selection ring and
  mark go with the picture, and previews are requested for the long edge (smaller for wide photos). The layout and its budgets are
  unchanged (`GridModelTests`, 100 000 items). Decisions in SPEC §6.4: letterboxed cells, not the web's justified rows, and a
  setting of this device that does not follow or write the web's `croppedLayout`.
- Undo ✅ (Mac app): favourite, archive, remove from album and delete register with the undo manager of the window they
  were made in (Edit › Undo/Redo, ⌘Z; shake on iPhone 🟡 not run) and show a confirmation with an Undo button
  ("Archived 3 items · Undo"), in the grids and in the viewer (favourite, archive, delete; an undo there brings the
  page back, Redo takes it out again). The confirmation only undoes its own change (marked in the undo manager), a
  second tap while an undo runs does nothing, and a session that stops (account switch, removal) clears its undo actions.
  Undoing a delete takes the queued deletes back (their photos and album places return at once, also offline), waits for
  the ones being sent, and restores only what reached the server from the trash bin, by file id (TIFF and RAW too), then
  adds the photos to their albums again. No Undo for deleting a received share. Unit-tested (`SessionUndoTests`,
  `OutboxBulkAndUndoTests`); the trash bin restore with album re-add ✅ against the 8089 test server
  (`IntegrationOutboxTests`); 🟡 the round-3 changes were not driven in the Mac app (screen locked during the run).
- Empty and error states have an action (SPEC §6.3): "Sync now" / "Retry" in the library, "Refresh" / "Try again" in lists
  loaded from the server, "Clear search" for a search without results.
- VW-4 Live Text and Visual Look Up 🟡: VisionKit `ImageAnalysisInteraction` on the photo's image view (iPhone, iPad, Vision
  Pro) and `ImageAnalysisOverlayView` over it on the Mac (text selection, data detectors, Visual Look Up, lifting the
  subject; the system's Live Text button, hidden while zoomed in and kept inside the visible part of the photo). Only the
  photo shown is analysed, 0.35 s after it settles, from its preview (again when the sharper one arrives); paging away
  cancels the analysis and takes the result away; nothing is analysed while the app is locked or its window is not active.
  Taps/clicks and presses on text belong to Live Text (no bar toggling, no Live Photo playback, no drag of a zoomed photo).
  "Extract text" stays in the More menu. Policy ✅ unit-tested (`LiveTextPolicy`); Mac ✅ looked at (the Live Text button
  appears on a photo with text, `ios-fix-shots/r4-viewer/04-viewer-livetext.png`), selecting text not tried (needs real
  input); iOS and visionOS 🟡 compiled, not run.
- VW-5 slideshow of any grid 🟡 (`SlideshowPlayer`; memories keep their own player with title card): "Play Slideshow" (Mac) /
  "Slideshow" in the viewer's More menu (from the photo shown through the viewer's photos), in the grid's context menu and
  the selection's More menu (several selected: those; one: the whole grid from it) and File › Play Slideshow on the Mac
  (selection or whole grid). Options menu: 2/3/5/10/20 s per photo (default 3), Repeat (on by default; off: it stops on
  the last photo with the controls shown). Videos play to their end without controls (formats only the server's conversion
  can play show their still for the interval). The screen stays on while it plays; it ends when the app locks; after it
  the viewer shows the photo it ended on. iPhone/iPad: full screen with an AirPlay button (`AVRoutePickerView`: videos go
  to the receiver; photos reach a TV or external display by Screen Mirroring — a second-screen scene of its own would need
  an app scene change). Mac: a window of its own that goes full screen (the library window keeps its sidebar). Vision Pro:
  pushed in the window. Order/repeat/interval ✅ unit-tested (`SlideshowPlan`); Mac ✅ run in a window
  (`PHOTOS_DEBUG_SLIDESHOW_WINDOWED=1`, so as not to switch Spaces on the owner's Mac): started from the viewer (the
  grid offers it as a tile action, seen), advanced, interval changed to 10 s, paused, closed, viewer moved to the last photo
  (`05-slideshow.png`); the full-screen switch itself, videos in a slideshow and AirPlay 🟡 not run.
- VW-6 stacks 🟡: a stack is one page; a strip of its copies above the photo (small picture and format, "JPG", "HEIC",
  "DNG"; VoiceOver "Copy 2 of 3 · IMG_7.DNG", selected trait) chooses the copy the page shows, and every action applies to
  that copy. A copy deleted or archived in the viewer leaves the strip; the page goes with its last copy. ✅ unit-tested
  (`ViewerStacks`), Mac ✅ looked at and driven (`02-viewer-stack.png`); iOS 🟡 compiled.
- "Show in folder" 🟡 (VW-3; viewer More menu and the grid's context menu, every platform): opens the app's folder browser at the
  photo's folder with a screen for each folder above it (`AppRoute.folder`, `FolderTrail` ✅ unit-tested), and closes the viewer.
- "Show in library" 🟡 (VW-3 "Show in timeline", named after the place it opens, as Apple's "Show in All Photos"; viewer More
  menu and grid context menu next to "Show in folder", not in the Library itself, not for archived photos): closes the
  viewer, opens the Library from its root with all media, scrolls to the photo's tile (or its stack's tile; a photo the
  Library does not show: the tile closest in time) and marks it — selected on the Mac, a short ring elsewhere. Target ✅
  unit-tested (`TimelineReveal`); the Mac grid got a `reveal` for it. 🟡 Not driven in the app (the screen locked).
- Viewer on the Mac/iPad: pages fit the visible area (sidebar, toolbar, info inspector), arrow keys / Space / Escape, previous/next
  buttons under the pointer ✅. Video and Live Photo motion play from the local copy when there is one, else through the app's
  HTTP client 🟡 (not exercised against a server with a user-trusted or client certificate).
- Performance budgets (§10) 🟡: the store side is measured with a synthetic 100 000-item index
  (`LargeLibraryPerformanceTests`, tag `performance`; skip with `PHOTOS_SKIP_PERFORMANCE=1`). On an Apple-silicon Mac, release
  build: initial index 6.3 s (store only; was 382 s in a debug build before the search index was fixed, 15 s now in debug),
  1000-row page 65 ms, local search 0.1–10 ms (budget 100 ms), timeline 58 ms as grid rows and 13 ms as lightweight rows,
  map cells for 50 000 geotagged items 8–9 ms (budget 200 ms; debug, round 4: the cells MapKit clusters 9 ms, with the time
  slider 34 ms, a cluster's first page 6–34 ms, the map's opening area 19 ms; MapKit takes 20 ms for 1024 cell annotations
  and 1.45 s for 50 000, one per photo, `MapClusteringTests`). ⬜ Launch, scroll hitch rate, viewer and memory budgets are not
  measured (need Instruments on devices); the grid does not use the lightweight timeline rows yet (its observation of grid
  rows is coalesced to one refetch per 300 ms, and to one per 2 s while writes keep coming: a sync, a backup, the
  outbox). A grid update that only touches some sections (an upload, a sync page) is applied as a batch update of those
  sections instead of a reload (checked against a real `NSCollectionView` with random changes, `GridBatchUpdateTests`);
  more than max(64, sections/8) changed sections reload. Select all: the toolbar and menus work from a summary counted in
  the database off the main thread (100 000 items: 43 ms, debug), the items are read only when an action runs; the
  grids keep the selection from their own changes instead of rebuilding it on every update. Further store numbers
  (debug, 100 000 items): a whole reconciliation walk's store side 233 ms (snapshot 20 ms) instead of a 290 ms
  dictionary of every row; an unchanged album of 5000 read again 25 ms (one row written). The map's markers bring their
  place names with the cell query (no reads per marker), and "Photos in this area" loads grid rows in pages of 2000.
  The preview cache writes "last used" in batches and at most once a day per file.
- Search index: FTS5 (trigram, `rowid = fileId`), kept current by triggers on `media`, used for free-text search (SR-3) over
  file name, place, country, caption, folder path, and (migration `v3-search-labels`) the names of the file's system tags, of
  the named people in it (Recognize) and the labels recognised on the device (SR-7). Tag and people memberships are copied
  from the server by `LabelSync` (every 30 min, changed tags/people only, all once a day; file ids only) ✅ unit-tested and
  against the stock and extended test servers. Tag and person filters still ask the server first and fall back to the stored
  memberships offline. Album titles ✅ (round 4, migration `v4-search-albums`, `SearchAlbums`): the titles of the own and shared
  albums a file is in (once the album's content was read; not public links) are in its index text, kept current by triggers
  on `albumItem` and `album` (rename, content change, deleted album). Photos of albums that are not in the index (another
  user's photos in an album shared with the user, own albums' photos outside the timeline folders) are found by free text
  (name, place, caption, album titles) and by the album chip, with the other criteria applied to them too; searches without
  text or album stay in the library. Unit-tested (incl. migration of a v3 database) and against the stock (8093) and extended
  (8091) servers with a second user sharing an album (`AlbumSearchIntegrationTests`). First write of an album of 5000:
  350 ms in debug (every new member's index row is written again).
- On-device labels (SR-7, opt-in in Settings › Search): Vision classification of cached previews into the index, in a
  power-requiring `BGProcessingTask` (iOS) or an `NSBackgroundActivityScheduler` activity (Mac) 🟡: labelling unit-tested with a
  real classifier run, labels checked on two test photos ("cat", "food"); the background scheduling was not seen to run
  (iOS not run; on the Mac only the debug trigger `PHOTOS_DEBUG_LABEL_NOW=1` was used, with an empty preview cache).
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
  destination and album links ✅ in the Mac app, photo links 🟡. Links wait while the app is locked and open after the
  unlock; photo links only open photos the library shows (not archived, not the video half of a Live Photo, not unknown
  ids) ✅ policy unit-tested, 🟡 not run.
- Round 4: the account part and the other routes of §4.8 ✅ parsing unit-tested (`IncomingLink`, `DeepLinkRouteTests`).
  `nextcloudphotos://<user>@<host>[:port][/<server path>]/<route>` names the account; routes `albums/<name>`,
  `sharedalbums/<name>`, `places/<name>`, `faces/<name>`, `tags/<name>`, `folders/<path>`, `shared`, `search/<text>` and the web
  app's aliases. A link for another logged-in account asks "Open the link in another account?" and switches; an account that
  is not logged in is explained ("This link is for another account") ✅ in the Mac app. Web links of an account's server
  (`https://<host>/index.php/apps/photos/<route>`, opened with the app) open the same route ✅ Mac (folders); several accounts
  on that server: the user picks one. Public album links open the "Open public link" sheet with the link filled in 🟡. Place,
  tag and search links ✅ in the Mac app; person links 🟡 (no named person on the test server). The questions wait for the
  unlock while the app is locked.
- Menu bar: File (New Window, New Album…, Open Public Album Link…, Upload Photos…, Export…, Share…), View (Zoom In/Out, Sync Now),
  Image (Open, Get Info, Edit…, Edit Date and Location…, favourite, Add to Album…, Delete…), Go (the sidebar's destinations) ✅
  structure read from the running app; the same commands are the keyboard shortcuts on iPadOS 🟡.
  🟡 Image ▸ Rotate Left ⌘R / Rotate Right ⌥⌘R on the selection (as in Photos; Sync Now moved to ⇧⌘R), also in the grid's
  context menu: saved like the editor's "Overwrite original" — a new version of each file, only replacing the version the app
  knows (`If-Match`), read-only shares/videos/RAW-GIF-WebP left alone and reported; save path ✅ run against the 8089 server
  (`PhotoEditSavingIntegrationTests`: 1920×1280 → 1280×1920, stale ETag → 412, nothing overwritten), menu items ✅ read from
  the running app (key equivalents), run from the menu 🟡 (Mac locked, menus need a focused window). Edit ▸ Copy (⌘C, and
  "Copy" in the context menu) downloads the originals (≤ 100) and puts image data + file URLs (Mac) / item providers (iPad) on
  the pasteboard 🟡 (compiled, unit-tested wording only). "Add to Album" is a submenu (Image menu, context menu, selection
  menu): New Album… with the selection, the albums used last in this app (`recent-albums.json` in the account folder) then
  the most recently changed, All Albums… 🟡 (Image menu structure ✅ read from the app). Share… in the grid's context menu (the
  system Share menu on the Mac, share sheet on iPhone/iPad, originals downloaded on demand) 🟡. Albums open in their own window
  (`WindowGroup(for: AlbumWindowValue)`): File ▸ Open in New Window, the album card's context menu, ⌥-click 🟡 (built for
  macOS/iOS/visionOS, not run: Mac locked). ⬜ View ▸ Square Tiles (timeline area).
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
  not be read"), and its temporary copies are removed on cancel, on completion and (leftovers) at the start ✅ unit-tested.
  🟡 (round 4) Its uploads go to a background `URLSession` of their own in the App Group container (one per share; files
  up to 100 MB as one PUT, larger ones in chunks); "Continue in Background" closes the sheet. When the extension has ended,
  the app takes the share over (iOS: the system launches it for the session's events; at every launch: shares whose
  extension stopped renewing its claim), adds the uploads to the album, hands over the next chunks and tells what still
  failed in a local notification. Batch logic (single and chunked, take-over from the record, 412 → next name, retry
  without a second copy, lost requests) ✅ unit-tested with a fake session; the chunked upload through a real background
  session ✅ against 8089, 8091 and 8093. **Not run**: the extension itself (share sheet not driven), the system
  relaunching the app for a share's session on a device.

- Share via Nextcloud (SH-7): OCS Files Sharing for a photo (grid context menu, selection "More" menu) or a folder (Folders toolbar):
  users, groups, other servers, email, Teams, Talk (when installed), public links with password, expiry, permissions, hide
  download; list, change, remove. API ✅ unit-tested and ✅ against the stock (8093), extended (8091) and default (8089)
  test servers (create, update, list, delete, sharee search); the sheet 🟡 compiled, not looked at (screen locked). Albums
  keep album sharing; the album sheet says what only photos and folders can do. From the viewer's More menu 🟡 (Mac: item
  seen in the menu). Several photos at once 🟡 (grid context menu and selection "More"): one share per photo and recipient
  (Nextcloud shares one file per share), four requests at a time, with progress and the failures listed with the server's
  reason; recipients as for one photo except email addresses (one email per photo); a public link to all of them is an
  album with a link (SH-4 quick share, own photos). ✅ batch unit-tested (`ShareBatchTests`), 🟡 sheet not looked at.
- Partner sharing (SH-8): received folder shares in the timeline with badge and show/hide ✅ sync unit-tested and ✅ against
  8089 and 8093 (a real received share indexed and removed again); Settings section, badge and toolbar button 🟡 compiled,
  not looked at.

## M3 Backup — 🟡
Settings, PhotoKit source, Files-app ledger, reconciliation (✅ SEARCH against server), matcher ✅, engine, UI, background tasks 🟡.
- Backup belongs to one account and keeps running for it while another account is shown (the Backup screen says which) 🟡.
- 🟡 PhotoKit background-upload extension (§7.18.6, round 4): `Extensions/BackgroundUpload` (ExtensionKit,
  `PHBackgroundResourceUploadJobExtension`) for iOS/iPadOS **and macOS** (macOS 27.3 has the extension point; it requires
  the `com.apple.photos.background-upload` entitlement, which is in the extension's entitlement file and has to be
  enabled for Nextcloud's App ID). The app turns PhotoKit's background uploads on while backup is on with full library
  access. Each run records and acknowledges ended jobs (file id from the answer, else the destination; one retry under a
  new name), then scans and reconciles like the app and creates jobs for resources ≤ 100 MB that are not converted, up to
  the job limit. The app and PhotoKit never take the same resource (journal `UploadJobs.json`, names kept free,
  `If-None-Match: *`). Job logic ✅ unit-tested with a fake PhotoKit (creation up to the limit, recording, retry, failure,
  cancelled, eligibility, Low Power, orphans, the limit error, both directions of "never the same resource"); the
  extension builds for iOS and macOS and is embedded. **Not run**: PhotoKit itself (needs the entitlement and a signed
  build), the real job states and response headers.
- 🟡 iOS: files up to 100 MB are handed to a background `URLSession` (16 files / 256 MB ahead) and go on while the app is
  suspended; the app is woken for finished uploads (`handleEventsForBackgroundURLSession`), records them and hands over
  the next ones. Engine and bookkeeping ✅ unit-tested with a fake session; the real session ✅ against the test server
  on macOS. **Not run on a device**: suspension, relaunch for finished uploads, behaviour when the device is locked.
  🟡 (round 4) Larger files go in chunks through the same background session: the export waits in the account's
  container, 8 chunk PUTs at a time are with the system, each report (also to a later launch, without a pass) hands over
  the next ones and finally the MOVE; the upload folder is the one the app's own upload would use, so either continues
  the other. A pass continues uploads whose chunks the system lost, the user's pause takes them back (only what the
  server lacks is sent later), a refused chunk fails the file, turning backup off removes what waits. State machine,
  driver and engine ✅ unit-tested (fake session; stub server with lost MOVE answers, expired upload folders, names taken
  meanwhile); a real background session ✅ against 8089, 8091 and 8093. Large files still come after everything else,
  and an interrupted export is kept (`tmp/Backup/Kept`) ✅ unit-tested. **Not run on a device.** macOS uploads
  everything in the app.
- A pass that a background task has to give up is interrupted, not "Paused": it stays due and goes on with the next
  background task or when the app becomes active ✅ unit-tested (engine), 🟡 on a device.
- Background tasks, silent pushes and the "Back up now" intent find the app model after a launch without a window
  (`AppHost`) 🟡 compiled for iOS, not run on a device.
- 🟡 §7.18.8 "Free up space on this iPhone/iPad" (Backup screen, iOS/iPadOS only): offers only assets whose every file the
  backup keeps (original, edited version, RAW, Live Photo motion) is uploaded or matched in the ledger with a server path and
  is listed by the server right now (one `PROPFIND` per folder) with exactly the device's size and, when both are known, the
  same file id; nothing converted to JPEG, matched by name only, recorded by the Files app without a path, or with an
  edited Live Photo motion. Photos of the last 30 days only with a switch. Count and size, a confirmation, a second server
  check right before, then `PHAssetChangeRequest.deleteAssets` (the system confirms; Recently Deleted). Verification logic
  and the server listing ✅ unit-tested; compiled for iOS, **not run on a device** (PhotoKit sizes, deletion).
- 🟡 After the first login on iPhone/iPad, backup is offered once (full-screen step) before the notification permission:
  photo access, "N photos and videos on this iPhone", then a dry run that shows "X already on your Nextcloud · Y to
  upload" as it counts (per asset, from the ledger), and Start backup / Not now. The Files-app question is part of the
  step only when the Files app is installed (`nextcloud://`) or left data in its App Group, pre-answered "switch" when it
  uploaded for this account. The Mac sets up backup in Settings › Backup with the same step (no offer after login).
  Policies ✅ unit-tested; the iOS step compiled, **not run** (no simulator); the Mac step not looked at (screen locked).
- 🟡 Backup folder: chosen with the server folder browser instead of a text field; a folder the timeline folders don't
  cover asks "Back up here and show in library" (adds it to `photosSourceFolders`) or another folder; an existing folder
  outside them shows a warning with "Show this folder in your library" and "Back up to /Photos instead". Path logic ✅
  unit-tested; UI compiled, not looked at.
- 🟡 iOS: "Back up now" and the first backup run as a `BGContinuedProcessingTask` (identifier
  `<bundle id>.backup.continued`, wildcard in `BGTaskSchedulerPermittedIdentifiers`) when it is the first pass or ≥ 50 items
  wait: system progress (looking, checking, uploading N of M), the system's Stop interrupts the pass; refresh/processing
  expirations and the short background time no longer interrupt such a pass. Falls back to a normal pass when the system
  refuses or doesn't start it within 10 s. "Keep screen on while backing up" turns the idle timer off only while a pass
  runs and the app is active. Compiled, **not run on a device**.
- 🟡 "Not backed up yet" on the Backup screen (iOS, iPadOS, macOS): the device's photos the options select that the ledger
  doesn't have completely on the server, newest first, as PhotoKit thumbnails with a badge for failed / only in iCloud.
  Classification ✅ unit-tested; UI compiled, not looked at.
- 🟡 §7.18.9 mirror device albums into Nextcloud albums (iOS, opt-in, picked albums): mirror logic ✅ unit-tested with a fake
  library and server; PhotoKit album reading and the Backup › Albums screen compiled for iOS, **not run on a device**.
- 🟡 §7.18.10 Google Takeout import (Mac): ZIP reader (deflate, stored, ZIP64, checksum), sidecar matching, plan, importer
  (duplicates, albums, comments, journal, stop/resume) ✅ unit-tested and ✅ end-to-end against 8089, 8091 and 8093 (dates
  as mtime, album, second import uploads nothing); the import window 🟡 compiled, not looked at (screen locked).
- ✅ Most compatible (round 4): HEVC videos become H.264 (QuickTime, metadata kept; Live Photo motion parts too), next
  to the export and removed with it; a video that cannot be converted is uploaded as it is. Converted files are found
  again by name and capture time (layer 5) and by the matcher's name/pixel-size rules, never by size (SPEC §7.18.4).
  Real conversion of a generated HEVC clip ✅ unit-tested (codec, capture date kept, nothing left behind); engine
  wiring ✅ unit-tested; not run against a device library.
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
- ✅ Large libraries (r3 items 22, 26): a pass only looks at the assets that changed since the last one (PhotoKit's
  persistent change token; the whole library once a day after the uploads, on "Back up now", or when the options or the
  selection change). What waits keeps its resource and the time the server was asked in the ledger, so a background
  wake uploads it without reading the library or asking the server again (for 7 days). The server is asked a batch at a
  time and the uploads start after the first one; an interrupted pass goes on where it stopped. The matcher looks up
  candidates by second instead of comparing every pair, and writes a batch's matches in one transaction. Engine ✅
  unit-tested with a fake library that hands out change tokens; 🟡 `PHPhotoLibrary.fetchPersistentChanges` and the
  `localIdentifier IN` fetch are compiled, **not run against a real library**.
- ✅ A file the server reports as locked (423) fails on its own and waits for its next attempt; the pass goes on with
  the others (r3 item 5). Unit-tested for the app's own uploads and those the system reports.
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
Places ✅, map 🟡, people 🟡 (no Recognize on test servers; managing people below), tags ✅ (API), folders ✅, shared with you 🟡, On this day ✅,
memories ✅, search and smart albums 🟡 (Return searches, recent searches, error state with "Try again": ✅ Mac app), archive and app lock 🟡, push 🟡 (needs proxy registration and provisioning), widgets 🟡.
- App lock (round 3) 🟡 compiled for iOS, macOS and visionOS, state machine unit-tested, not run: one lock state for the
  process (`AppLock`), setting in the App Group. Locked windows don't show their content at all (the viewer and sheets close);
  on iPhone and iPad the cover is a window of its own above the app (covers the full-screen viewer, sheets and the app
  switcher snapshot). The Mac Settings window and the share extension need the unlock too. Widgets show a lock placeholder
  while app lock is on and redact photo, place and date on a locked device (`privacySensitive`).
- Shared albums: photos of other users are fetched through the album's DAV child (`MediaItem.collectionChildMountType`),
  never by their name in the user's root folder ✅ parsing unit-tested.
- Push: permission is asked after login (on iPhone/iPad after the backup offer) or when the Notifications switch is turned on, not at first launch; the switch unregisters
  and registers; the notification extension only shows `photos` notifications and handles delete pushes. All 🟡: hiding the others
  needs the `com.apple.developer.usernotifications.filtering` entitlement (or the server-side routing of §S5). Silent delete
  pushes reach `AppModel.handleBackgroundPush` through the app delegates (`remote-notification` background mode).
- Folders and Shared with you show a folder's photos in the app's photo grid (selection, context menu, share, favourite,
  delete, keyboard, viewer), subfolders in a strip above it ✅ Mac. Like the other server-loaded lists (places, tags) the grid
  is loaded once: an item deleted there disappears after a reload.
- Memories strip at the top of the Library (TL-3) ✅ run in the iOS 27.2 simulator (the strip took a third of the screen's
  height as empty space above the cards — a horizontal scroll view takes the height it is offered —; it now has the height of
  its cards on every platform, also checked in the Mac app, `ios-fix-shots/r4-iphone/04-mac-library-strip.png`). On this day, the year in review and trips (at most 12) as small cards over
  the grid of the whole library (not with a filter, not while selecting), "All memories" at the end; loaded off the main actor
  after each finished sync and when the day changes. Context menu "Hide memories"; Settings › On this device › "Show memories".
  Memories stay in the sidebar / Collections.
- Memory slideshow (ME-4) 🟡: "Play slideshow" in a memory's toolbar and in the cards' context menus. Full screen on iPhone and
  iPad, pushed in the window on the Mac and Vision Pro; the title over the first photo, 4 s per photo, 1.2 s cross-fade with a
  slow zoom, starts over after the last; Pause/Play, Previous, Next and Close (tap shows/hides them; ← → Space Esc on a
  keyboard). Reduce Motion: a 0.4 s dissolve without the zoom. With VoiceOver it starts paused. Videos show their still.
  Stepping ✅ unit-tested; not run (Mac screen locked).
- Memory menu (ME-4, round 4) 🟡: "More" in a memory's toolbar. "Save as album" makes an own Nextcloud album named after the
  memory (trip and recap titles; for On this day its dates, "1 year ago" says nothing later; " (2)" when taken, "/" becomes
  "-"; a trip's places become the album's location) and adds the user's own photos through the outbox; photos of shared
  folders are left out and counted in the confirmation. "Share as link…" makes an album with a public link named after the
  memory (SH-4) and shows the link sheet. "Slideshow music": none (default), an audio file (copied into Application
  Support, so it keeps playing after the original moves) or, on iPhone and iPad, a song of the Music library
  (`MPMediaPickerController`, played by the app's own queue of the system player, so Apple Music songs work;
  `NSAppleMusicUsageDescription`). One choice for all memory slideshows; the app ships no music (licences). It fades in,
  pauses with the slideshow, loops, stops on close; a speaker button next to the controls turns it off for this slideshow;
  files play in the `ambient` category (mixes with other audio, silenced by the Ring/Silent switch, as in Photos). Only
  memory slideshows play it (`SlideshowStart.playsMemoryMusic`). Album name, save (stub server: MKCOL, location, outbox COPY
  of the own photos only) and the music choice and file copy ✅ unit-tested; the menu, the link sheet, the pickers and the
  playback were not run (Mac screen locked; iOS not run).
- Managing people 🟡 (PE-3, PE-4; no Recognize on the test servers, so not run): rename (People grid context menu and the
  person's menu; empty, digits-only and taken names are refused before sending), merge, remove person, "Not this person",
  "Move to another person…" and, for unassigned faces, "Assign to person…" (pick a person or create one: MKCOL + MOVE of the
  detections). "Hide person" is kept on this device only, per account, in the account's folder (removed on logout): Recognize has
  no way to hide a person, and the People screen says so under the grid ("N people are hidden on this device…", "Show hidden
  people"). Name check and hidden list ✅ unit-tested.
- Map clustering and time slider (MP-1, round 4) 🟡: the map is an `MKMapView` (SwiftUI's `Map` has no clustering on OS 27).
  The database still adds the located photos up into grid cells, now of power-of-two degrees between a 16th and an 8th of
  the visible span (at most 32 × 32 for the loaded area, cut along cell borders so every marker counts all its photos), and
  MapKit clusters the cells' markers where they overlap (`MKClusterAnnotation`; newest photo, photos of all its cells; a
  click lists them, newest first, in pages). MapKit alone over every photo is no option (50 000 annotations: 1.45 s to add,
  budget 200 ms), so the grid stays as the first step rather than as a fallback. The map opens on the area of all
  geotagged photos. "Time range" in the toolbar shows two month sliders (From, To; VoiceOver reads the month) and "All
  time"; the markers, a cluster's list and "Photos in this area" follow it. Queries, cell maths and months ✅ unit-tested,
  timings above; the map itself not looked at (Mac screen locked during this round), iOS and visionOS compiled only.
- Tags ✅/🟡: "Tags…" in the viewer's More menu and the grid's context and selection menus opens a sheet with all
  assignable tags (on all / some / none of the photos), a filter field and "New tag"; changes go through the outbox
  (`PendingOperation.tag`) and show in search at once. Tag browsing falls back to the stored memberships offline and offers
  "Remove tag" for a selection. Outbox, store and refresh ✅ unit-tested and against the stock (8093) and extended (8091)
  servers (create, assign, refresh, search, remove); the sheet itself 🟡 (compiled for macOS, iOS and visionOS; not looked at:
  the Mac was locked during this round). A photo whose tag was removed stays in the open tag grid until it is reloaded.
- Activity in shared albums (SH-9) ✅/🟡: album listings are compared (counts) and new photos or newly shared albums become
  entries of "New in shared albums" (row above Albums and Shared albums, list with "Mark all as seen"; opening the album marks
  it seen); a background refresh posts a local notification (Settings › Shared albums). Detection ✅ unit-tested and run in
  the Mac app against the stock server with a second user (new album, added photo, removal not reported, re-add reported);
  the screens and the notification 🟡 (not seen: locked Mac, notifications not allowed for the test build). Instant push needs
  the server (§S5).

## M5 Advanced — 🟡
Editor (Core Image) 🟡, metadata editing 🟡, recently deleted ✅ (API; restore sends `Overwrite: T` — it was refused with 412 before; "Delete permanently" asks first and errors are shown; the screen itself 🟡: it is behind the device unlock, not opened in the test run), duplicates 🟡, free up space 🟡, extract text (server OCR or
Vision) 🟡, Ask your photos (server Assistant or on-device Foundation Models) 🟡, video renditions 🟡, App Intents and App Shortcuts 🟡.
- Free-form crop 🟡: the crop tool shows the whole picture with a frame (corner and edge handles, drag inside to move, thirds
  lines, dimmed outside), a lock for the aspect, presets Freeform/Original/Square/4:3/16:9/3:2 (they set the largest centred
  area and lock it); the crop turns and mirrors with the picture; VoiceOver adjusts its size. Geometry ✅ unit-tested
  (`CropAndSaveTests`); the UI built for macOS, iOS and visionOS but not run (Mac locked). Fixed on the way: "Flip" mirrored
  top-to-bottom after a turn; "Overwrite original" wrote JPEG data over PNG/TIFF and is now only offered for formats that can
  be written back; "Save as copy" was named after the cache file.
- Free up space works on the **server** (title "Free up server space"): screenshots by file name or PNG with a phone-screen size and no
  location — never every PNG (`PhotosDomain/Cleanup.swift`); the confirmation names the server, all devices and trash bin vs. permanent.
  Freeing device storage is §7.18.8 (Backup), 🟡.
- Duplicates: suggested copy to keep (favorite, own file, oldest upload) with the reason shown, user can pick another one.
  Warning when a deleted copy is in an album 🟡: the confirmation names the albums the deleted copies are in and the kept copy
  is not, from the album content in the local index (albums never opened on the device are counted as "not checked"), and offers
  "Keep in albums and move N items to the trash bin" (the kept copy is added first); filter albums are left out, a kept copy
  shared with the user can't be added. Logic ✅ unit-tested with the store (`DuplicateAlbumNoteTests`); the dialog not run (Mac
  locked).
- Spotlight (round 4) 🟡: albums (own and shared), named people and places are indexed with Core Spotlight, one domain per
  account (a digest of the account id), the item id is the account link, so a result opens in its account (after asking
  when another one is shown). Updated after every sync when something changed; removed on logout and remote wipe
  (`AccountPurge` path) ✅ unit-tested. Never indexed: anything while app lock is on (all items are deleted when it is turned
  on, also by MDM), people hidden on this device (removed at once when hidden), unnamed people, places that only archived
  photos have, public-link albums; no thumbnails (a cover may be archived since) ✅ policy unit-tested. Not seen in Spotlight:
  the unsigned test build cannot be checked from the shell (🟡).
- App Intents (round 4) 🟡: `AlbumEntity` and `PersonEntity` (`EntityStringQuery`, the same entries as Spotlight: nothing hidden,
  nothing while app lock is on), `OpenAlbumIntent` / `OpenPersonIntent` (`OpenIntent`), "Search photos" (`ShowInAppSearchResultsIntent`,
  opens the search with the text), App Shortcuts phrases ("Search photos in …", "Open <album> in …", "Show photos of <person> in …";
  parameters updated after indexing). Compiled for all three platforms, metadata extracted (5 intents, 2 entities); not run in
  Shortcuts or Siri. PlaceEntity/TagEntity and the other intents of §7.23 remain ⬜.
- visionOS spatial photos / immersive panoramas (round 4) 🟡 compiled for visionOS 27.2, not run (no visionOS runtime or device):
  a HEIC's original is read when it is viewed and a stereo pair group in its image properties makes it a spatial photo
  (`SpatialMedia`, ✅ unit-tested with a generated stereo HEIC); the viewer then shows "Spatial", which opens it with RealityKit's
  `ImagePresentationComponent` (`.spatialStereo`, "Immersive" switches to `.spatialStereoImmersive`). A still of 3000 px or more
  and 2:1 or wider (from the server's size) is a panorama: "Immersive" opens an immersive space with the photo on the inside of
  a cylinder segment as wide as the photo reaches (aspect × 60°, at most 360°); a tap ends it.
- Accessibility and localisation audit 🟡: every module and target with user-facing text has a string catalog
  (`Localizable.xcstrings` in PhotosAppUI, PhotosNetworking, PhotosCore, PhotosBackup, PhotosDomain, the app, the widgets;
  `AppShortcuts.xcstrings`, `InfoPlist.xcstrings` for the permission texts), English plural variations, `bundle: .module` in the
  packages; `xcodebuild -exportLocalizations` exports all of them. Cards, map markers, folder and public-album photos, viewer pages
  (description, "3 of 120", favourite/info/delete actions, swipe up/down to step on iOS) have VoiceOver labels; Reduce Motion,
  Increase Contrast / Reduce Transparency and accessibility text sizes are handled in the viewer, scrubber, tiles and cards; iOS
  haptics for selection, favourite and delete. Checked on the Mac through the accessibility tree; iOS only compiled.
  Server feature names in Settings › Server features come from the PhotosAppUI catalog. Every key of every catalog has a comment for translators.
  ⬜ Transifex: no `.tx/config` yet, the proposed setup waits for the localization team ([LOCALIZATION.md](LOCALIZATION.md)).
- Release readiness 🟡: privacy manifests for the app, the extensions and the package targets (disk space `E174.1` added for
  backup's free-space check; audited in round 3, see PRIVACY-AND-EXPORT.md); push entitlement
  (`aps-environment`); export-compliance and ATS reasoning with the App Review note ([PRIVACY-AND-EXPORT.md](PRIVACY-AND-EXPORT.md));
  build number settable from CI; unsigned Release archives in CI and a release workflow without signing. Nothing was
  signed, uploaded or validated by App Store Connect.
- App icon 🟡: all Mac sizes from the one 1024 px image; ⬜ dark/tinted variants, Mac-shaped icon, visionOS layered icon
  ([APP-ICON.md](APP-ICON.md)).
- ⬜ App Store assets (screenshots), signing secrets in CI.

## M6 Delight (SPEC §15) — ⬜

### §15.1 Memory films and Year in Review
- ⬜ Not started.

### §15.2 Photographer's Mac: import, culling, compare, external editors
- ✅ Culling (ratings 1–5, Pick/Reject as collaborative system tags, outbox, Undo, P/X/U/0–5 keys in grid and viewer,
  auto-advance, tile badges, dimmed rejected, Image ▸ Flag/Rating, Library filter, Delete Rejected…). Unit tests (model,
  store filter vs. marks for every filter). Run on the Mac against the 8089 test server (keys through `PHOTOS_DEBUG_GRID_KEYS`,
  tags created and assigned on the server, badges live, filter "Picks", Delete Rejected confirmation) and in the iPad
  simulator (iOS 27.2: badges of the server's tags on a fresh device). iPad hardware-keyboard keys built, not run.
- ✅ Compare view (2-up/4-up, synchronised zoom/pan, 100 %, keep one). Run on the Mac (`PHOTOS_DEBUG_COMPARE=2`, 100 % via the
  toolbar). Pinch/drag/keys not driven (no real input).
- 🟡 Import from camera or card. Engine unit-tested (pairing, patterns, ledger, matching, verification, delete only
  verified, stop). Run on the Mac with a folder card: new-only (4 of 6 found on the server), upload into the date folder,
  checksum verified, deleted from the card, toolbar summary; iPad simulator: the sheet with the same card folder. Not run:
  a real USB camera or card reader (ImageCaptureCore paths are built for Mac and iPad, untested), eject, the Dock bar
  (drawn, not seen), and reading a mounted card in the sandbox (the TCC/sandbox refusal path was seen and explains itself).
- 🟡 Edit With (Mac). Run on the Mac with `PHOTOS_DEBUG_EDIT_WITH`/`_NO_OPEN` (another app is not brought to the front in
  checks): download, a save changed the file on the server (new ETag), a server-side change in between gave
  `IMG_8001 (edited).JPG`, Done removed the local copy. Not run: opening a real editor (Pixelmator, Photoshop…) and its
  saving; apps that save by replacing the file through a sandboxed save panel may not reach the watched file.
- ⬜ Not done: thumbnails grid for a camera's RAW-only shots on iPad (ImageCaptureCore thumbnails untested), tethered
  shooting, import into an album, keywords/XMP sidecars, a Lightroom-style loupe with filmstrip.

### §15.3 New platforms: Apple TV and Apple Watch
- ✅ Package builds for tvOS and watchOS (GRDB supports both); `PhotosCore` runs on tvOS with Spotlight, notification
  banners and app lock left out (`#if os(tvOS)`). Generic tvOS and watchOS builds in CI (`ci.yml` build matrix).
- ✅ TV login with Login Flow v2 as a QR code: run in the tvOS 27.2 simulator against the test server — the QR code was
  decoded from the screenshot and the flow granted with the server's own grant page (as a phone browser would); the TV
  signed in and showed Home. Certificate-trust and http questions built, not run.
- ✅ TV Home shelves (memories, favourites, albums, shared albums, recent), memory/album/all-photos grids, Albums tab,
  Settings: run in the simulator (XCUITest tour with the Siri Remote, `UITestsTV/TVTourTests.swift`, passes).
- ✅ TV viewer (left/right, info, Play/Pause → slideshow) and slideshows (title over the first photo, drift, pause, skip,
  cross-dissolve measured frame by frame): run in the simulator. 🟡 Video playback in the system player: built, not run (the test library's videos were not
  reached in the tour).
- ✅ Family slideshow (shuffled rounds, resumes, clock): run in the simulator; order logic unit-tested.
- ✅ Top Shelf: run in the tvOS 27.2 simulator — with the app in the Home screen's top row and focused, the Top Shelf
  showed the cover of the first memory ("2 years ago") from the manifest the app wrote into the App Group; the memory
  links open the memory or play it (run via the debug route). The full-screen carousel itself (swipe up) was not
  opened.
- 🟡 Watch app (photo of the day, On This Day, Favorites, pager): run in the watchOS 27.2 simulator with a digest the
  iPhone app built from the test server. Phone → watch in a paired simulator pair: the digest (application context)
  arrived; the photo files (`transferFile`) were reported sent by the phone but never reached the watch simulator — to be
  checked on devices.
- 🟡 Complication (accessory families): built and embedded, not seen on a face (the simulator's face editor needs input).
- ⬜ Login hand-off from the iPhone app, TV account switcher and search (plan in SPEC §15.3).
- Needs Nextcloud's team: App IDs `com.nextcloud.photos.tv`, `.tv.topshelf`, `.watchkitapp`, `.watchkitapp.widgets`
  with the App Group, an App Store record decision for the TV app (separate app or universal purchase), tvOS icon and
  Top Shelf artwork (README).

### §15.4 Ambient: wallpaper, StandBy, Live Activity, Controls, Vision Pro memory room
Screenshots: `~/aloha-work/photos-tools/ios-fix-shots/r5-ambient/` (not in the repository).
- ✅ Live Activity of the backup (iPhone, iPad): run in the iOS 27.2 simulator (`AmbientUITests.testBackupLiveActivity`,
  15 new photos): starts while many photos are compared with the server, Dynamic Island (compact, paused state), Lock
  Screen banner "14 left · 21.8 MB left · Pause", then "Backed up · 14 uploaded". Start/update/end rules unit-tested
  (`BackupActivityTests`); remaining size from `BackupStatus.pendingBytes` (engine test). Found and fixed in the
  simulator: the activity first only started once the uploads began, by then the user had often left the app and the
  system refused ("Target is not foreground"); it now starts during the server check and only while the app is in front
  (or from the intent). Not seen: the expanded Dynamic Island, the stale state, the Pause button's effect, a real device.
- ✅ Controls (iOS 18+ ControlWidget): "Backup" switch, "Back Up Now", "Nextcloud Photos" — added through Control
  Center's gallery in the simulator (`testControls`); the switch turned backup off and on in the app's process while the
  app was in the background, "Back Up Now" started a backup with its Live Activity from the background
  (`testControlActions`, log: "turned off/on", "Live Activity started"). Lock Screen and Action button placement not
  tried (same controls). Not on the Mac or Vision Pro (decided, SPEC §15.4).
- ✅ Photo frame widget and backup widget: added to the Home Screen through the widget gallery in the simulator
  (`testPhotoFrameWidget`): the frame shows a favourite with place and day, the backup widget "Backed up · Last backup …".
  Rotation and sources unit-tested (`AmbientRotationTests`, `AmbientPhotosTests`). 🟡 Not seen: StandBy and its night mode
  (the simulator has no StandBy), Lock Screen accessory families, the tinted Home Screen, the album picker of the frame's
  settings, the Mac desktop and Vision Pro widgets; on visionOS the frame builds with paper texture and mounting styles.
- 🟡 Mac desktop pictures: "Use as Desktop Picture" (grid context menu, viewer More menu, Image menu), rotation in
  Settings ▸ Desktop and from an album's menu; plan/schedule/persistence/file clean-up unit-tested (`DesktopPictureTests`).
  Seen in the Mac app (accessibility API, screenshots): Image ▸ Use as Desktop Picture, Settings ▸ Desktop, the album
  menu's "Use as Desktop Pictures…" sheet preset to the album. Not run against the real desktop: starting it would
  change the owner's wallpaper on this Mac.
- ✅ Vision Pro memory room: run in the visionOS 27.2 simulator (`AmbientUITests.testMemoryRoom`): "Memory Room" in a
  memory's toolbar opens the immersive space, the memory's photos hang framed around the viewer with the title in front,
  the button becomes "Leave Memory Room"; a frame brought close (debug switch for the pinch) comes in front at eye height.
  Layout unit-tested (`MemoryRoomLayoutTests`). Found in the simulator and changed: frames right in front covered the
  window, and the frame brought close filled the view — the front 60° stay free now and the close frame sits 1.5 m away.
  🟡 Not seen: a real look-and-pinch, the hover glow, a spatial photo shown with depth (no spatial photo in the test
  library), VoiceOver in the room.
- Found on the way and fixed (shared, `project.yml`): the app embedded the share and notification-service extensions on
  visionOS, where these extension points do not exist, so it did not install in the visionOS simulator; and
  `UIApplicationSupportsMultipleScenes` was not inside `UIApplicationSceneManifest`, so visionOS refused every immersive
  space (also the round-4 panorama) and iPadOS may have kept the app to one window.

### §15.5 Feel and craft: zoom levels, haptics, no spinners, similar photos
- ✅ Zoom levels Years › Months › Days › All Photos (all four Library filters): cards with key photos and date overlays,
  day mosaics, pinch that follows the fingers with momentum and settles on the stop it was heading for (anchored on the
  photo or card under the fingers), taps zoom in, segmented picker (bottom on iPhone/iPad/Vision Pro, toolbar on the
  Mac), ⌘+/⌘− along the same ladder, Mac trackpad pinch through the grid steps into the days. Unit tests
  (`LibraryZoomTests`, `KeyPhotoTests`, `LibrarySummaryTests`, `LibraryZoomModelTests`; 100 000 items: 80–190 ms, budget
  800 ms); run in the iOS 27.2 simulator with the UI tour
  `FeelTourTests` (years → tap → months → pinch → days → pinch out → months → tap a day's photo → All Photos at it; grid
  pinch steps). Not verified by the tour: the pinch out of the densest grid into the days (XCUITest's synthesized pinch
  starts UIKit's two-finger selection there; the grid now refuses that selection while a pinch runs, and the move
  itself is unit-tested). Mac: built, not verified (the display was asleep, no window could be captured); visionOS
  compiled, not run.
- ✅ Haptics: year ticks while scrolling fast or scrubbing the year index, zoom snaps, selection start (iPhone, iPad);
  trackpad level change and alignment feedback on the Mac. Logic unit-tested (`YearBoundaryTickerTests`); the
  simulator cannot play haptics, so the feel itself is unverified on a device.
- 🟡 No spinners: skeletons instead of spinners on albums, people, folders, tags, album picker, sharing sheets, partner
  sharing, links; cached preview in the editor; delayed spinners (0.9 s) where nothing better exists. Remaining
  spinners listed in SPEC §15.5. Built for all platforms; the screens were not looked at one by one in the simulator.
- ✅ Show Similar (viewer More menu, grid context menu) with best shot of a series and "Keep Best…"; on-device feature
  prints from cached previews, migration `v5-similarity`, incremental background indexing (BGProcessingTask with power,
  Mac background activity, battery-aware trickle while the Library is shown), in-memory sketches searched in
  milliseconds. Unit tests with real Vision on the Mac (`SimilarityIndexTests`, `SimilarityMathTests`,
  `SimilarityStoreTests`; search over 100 000 sketches 40 ms); menu and screen run in the iOS simulator with prints made
  on the Mac (the simulator cannot run Vision's models).
- ⬜ Not done: a "Similar shots" section in Duplicates (series across the whole library) — the series logic
  (`SimilarSeries.series`) is there and tested, the screen is not; a live cross-fade between grid steps in the middle of
  an iPhone pinch (the grid scales with the fingers and changes step on release).

### §15.6 Then and now, travel globe
- ⬜ Not started.

### §15.7 Bring everything home: imports
- ⬜ Not started.

### §15.8 Smart offline and fun extras: stickers, collages, photo of the day
- ⬜ Not started.

## Prerequisites from SPEC §14 still open
App Group / keychain group provisioning and the Push Notifications capability (table in the README), Apple's notification
filtering entitlement, push proxy topic, notification routing in the notifications app, app icon artwork,
a test server with Recognize and an Assistant provider.

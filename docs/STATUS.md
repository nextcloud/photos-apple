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
- Nothing has run on a device; what must be tested there first is [DEVICE-TEST-PLAN.md](DEVICE-TEST-PLAN.md) (round 10), the
  full pass per screen [test-plan.md](test-plan.md).
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
- QR codes and login links show "Log in to <host> as <user>?" before anything is sent ✅ compiled (iOS scanner ⬜ device D16.1).
- Keychain items are `AfterFirstUnlockThisDeviceOnly` (not in backups or on other devices); existing items are switched once
  at launch ⬜ device D16.1 (signed builds only; unsigned Mac builds use the file store).
- MDM / AppConfig keys (§5.1.9) ⬜ device D16.2 (round 4): `serverUrl` (address filled in and fixed; logins to other servers refused, also
  QR codes, links and Files-app suggestions; `addAccount` checks again and revokes the granted app password), `username`
  (proposed on the login page with `?user=`), `disable_multiaccount` ("Add account" hidden, a second login refused, logging in
  again allowed), `enforce_passcode_lock` (app lock on and its switch disabled; written to the App Group so widgets and
  extensions follow), `disable_log` (no kept log, export and switch disabled, the log deleted), `disable_backup` (backup off,
  Backup screen says so). Read from `com.apple.configuration.managed` at launch and on every `UserDefaults` change. Existing
  accounts are kept when a restriction arrives. Parsing and policy ✅ unit-tested (`ManagedAndSpotlightTests`); the Mac app
  started with a managed configuration, the managed UI was not looked at (no MDM-delivered configuration on the build Mac).
- QR code login ⬜ device D16.1: on iPhone and iPad "Scan QR code" opens the system scanner (VisionKit `DataScannerViewController`,
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
(macOS ✅, iOS ✅ round 11 `VerifyTourTests`), date scrubber on iOS ✅ run in the iOS 27.2 simulator, viewer with zoom/video/Live Photos 🟡, info panel ✅, favourite/delete/archive/export ✅.
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
  but the first sync after a launch or a return to the app (`ReconcileRequest.opened`, at most every 5 minutes) and
  pull-to-refresh walk at once when a root changed (2026-11-27: a Mac build kept the photos of a folder deleted on the
  server through four launches in eight minutes — the walk the change owed waited for the 10-minute interval since the
  walk of a launch shortly before; ✅ `SyncSafetyTests.folderDeletedSoonAfterAWalkIsGoneAtTheNextLaunch`,
  `IntegrationSyncTests.folderDeletedElsewhereIsGoneAfterTheNextLaunch` and the Mac app against the 8089 server);
  pull-to-refresh without a change reconciles only when the last walk is 10 minutes old, "Sync now" at once. While a
  window can be seen (on the Mac also behind other apps) the library syncs every 5 minutes (SPEC §5.4.4; before, it
  synced only at launch, on activation and on push). Small removals are checked
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
  with a real trackpad: pinch, and paging with a two-finger swipe over a photo that is not zoomed); iOS ✅ run in the iOS 27.2
  simulator (round 11, `VerifyTourTests.testViewerGestures`, shots `ios-fix-shots/r11-verify/*-0[1-7]-viewer*`): a double tap
  zooms in at the point, a swipe on the zoomed photo pans it instead of paging, a second double tap zooms out; pinch not
  driven (XCUITest's pinch is not a two-finger gesture at a point).
- iPhone ✅ (round 11, `testViewerGestures`, twice; iPad see §21.2): swipe down closes the viewer (the page following the
  finger was not caught: the host's frames come too late, `v5-07-…-frame*`), swipe up shows the info panel (name, date,
  size, type, folder, `ios-fix-shots/r11-verify/v1-05`); a swipe down on the info card closes the card and keeps the viewer (it closed both, and Info left the card
  on screen — fixed in round 11, `testInfoCardSwipeDown`, `v8-0[89]-info-card*`); every screen opens the viewer through one modifier (`mediaViewer`), with the navigation stack its
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
  actions, which were under it), context menu with preview; pull to refresh ✅ round 11 (`testPullToRefresh`, the refresh
  control above the memories while the finger holds, frames `ios-fix-shots/r11-verify/v5-30-pull-to-refresh-frame*`; pinch:
  `FeelTourTests`); the two-finger drag was not exercised.
  iPad ✅ round 11 for the grid, viewer, info inspector column, albums, map, memories, stacks (`VerifyTourTests` 10 of 12 on
  the iPad Pro 13-inch, `ios-fix-shots/r11-verify/p1-*`); visionOS 🟡 (compiled, not run here). Pull to refresh (a refresh control on the collection view, driven
  by the screen's `.refreshable`; it ends when the sync or reload has returned), a two-finger drag starts the selection mode,
  the context menu of a photo shows a large preview (a tap opens it), tiles can be dragged into other apps on iPad (the original
  is downloaded on drop), selection mark in the bottom trailing corner, hover effect under the pointer. The logic behind them
  (single-flight refresh, what a drag carries, mark and preview sizes) ✅ unit-tested.
  iPad drag and drop ✅ run in the iOS 27.2 simulator (windowed apps, two windows side by side): a photo dragged from the
  library into an album window is added to that album — the same file, not an uploaded copy (`AlbumDrop`; it was ignored
  before, the album only took file URLs); a photo dropped back on its own grid uploads nothing. Dragging into other apps
  🟡 (XCUITest cannot drive another app's window).
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
  actions), arrow keys, Return/Space, Escape. iOS: hardware-keyboard focus and Escape ⬜ device D16.4.
- TL-6 stacks, the conservative part ✅ iPhone (round 11, `testStacksAndBursts`: `R11STACK.jpg` + `.jpeg` uploaded by the
  test are one tile with the stack badge, VoiceOver "2 copies", `ios-fix-shots/r11-verify/v4-100…`); Mac UI 🟡 not checked (screen locked): copies of one shot — images in
  the same folder with the same name apart from extension and case, taken at most 2 s apart (HEIC + JPEG, RAW + JPEG) — are one
  tile in Library, Photos, Videos and Favorites (`CopyStacks`, `TimelineStacking`, off the main actor; 150 000 items ~90 ms in a
  debug build). The tile shows the JPEG (or the copy with a preview), with a stack badge and "2 copies" for VoiceOver; the viewer's
  "Show 2 copies" (bar above the photo and More menu) adds the other copies as pages. Settings › On this device › "Stack copies of a
  photo" (on by default).
- TL-6 bursts ✅ iPhone (round 11: three frames `R11_BURST00n…` the test uploads are one tile, "Burst of 3 photos", the
  viewer's strip shows the three, `ios-fix-shots/r11-verify/v4-100/103`; unit-tested, `BurstStacksTests`): only bursts the camera
  named as one are stacked — `…_BURST001_COVER.jpg`/`…_BURST002.jpg` (Google Camera), `00000IMG_00000_BURST<time>_COVER.jpg`
  (Pixel 2), `PXL_….BURST-01.COVER.jpg`: same marker, images, same folder, within 60 s; the `COVER` frame is shown, VoiceOver says
  "Burst of 5 photos"; copies of burst frames (RAW + JPEG) belong to the burst (`BurstStacks`, `TimelineStacks`). Round 11
  (§21.4): time-based bursts ✅ (alike photos, ≥ 3 frames, ≥ 2 a second, seen on the Mac) and PhotoKit bursts 🟡 replace
  the earlier ⬜ — the old reasoning was: Apple marks a burst only in its maker note (BurstUUID), which stock servers do not hand out
  (no EXIF in the timeline's SEARCH; `photos-exif` keeps entries up to 1000 bytes and the maker note only as an opaque blob, if at
  all), and the web's "≤ 3 s apart" rule (`PhotosDomain/Stacks.swift`) also folds quick series of single shots, which Photos never
  does. Would need the server to report the burst identifier (or the client to read EXIF of every photo).
- Actions on a stacked tile ✅ iPhone (round 11: the context menu's Delete… on a 2-copy stack asks "Delete 2 items? This also
  deletes 1 photo stacked behind the selected ones.", `ios-fix-shots/r11-verify/v4-104-stack-delete-confirmation-host.png`, not confirmed;
  logic unit-tested, `TimelineGridTests`; Mac 🟡 not looked at): as in Photos, where RAW + JPEG are one photo and a burst one item, delete, favourite, archive/unarchive, add to album,
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
- "Aspect ratio" grid ✅ (Mac, run: View ▸ Square Tiles ⌥⌘S toggles it, screenshots `01`/`02`; iPhone ✅ round 11, Settings ›
  Library › Square tiles off, the Library letterboxes wide photos, `ios-fix-shots/r11-verify/v4-32/33`):
  Settings › On this device › "Square tiles" (on by default) and View ▸ Square Tiles (⌥⌘S, also the iPad keyboard shortcut). Off,
  every grid fits each photo whole into its square cell, centred, as Photos' "Aspect Ratio Grid"; badges, the selection ring and
  mark go with the picture, and previews are requested for the long edge (smaller for wide photos). The layout and its budgets are
  unchanged (`GridModelTests`, 100 000 items). Decisions in SPEC §6.4: letterboxed cells, not the web's justified rows, and a
  setting of this device that does not follow or write the web's `croppedLayout`.
- Undo ✅ (Mac app): favourite, archive, remove from album and delete register with the undo manager of the window they
  were made in (Edit › Undo/Redo, ⌘Z; shake on iPhone ⬜ device D16.4) and show a confirmation with an Undo button
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
- VW-5 slideshow of any grid ✅ (iPhone round 11, `testSlideshowFromTheViewer`: from the viewer's More menu, full screen,
  advances, controls on a tap, Close back to the viewer, `ios-fix-shots/r11-verify/v1-20…24`; Mac ✅ below) (`SlideshowPlayer`; memories keep their own player with title card): "Play Slideshow" (Mac) /
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
  (`05-slideshow.png`); the full-screen switch itself, videos in a slideshow and AirPlay ⬜ device D16.3.
- VW-6 stacks ✅: a stack is one page; a strip of its copies above the photo (small picture and format, "JPG", "HEIC",
  "DNG"; VoiceOver "Copy 2 of 3 · IMG_7.DNG", selected trait) chooses the copy the page shows, and every action applies to
  that copy. A copy deleted or archived in the viewer leaves the strip; the page goes with its last copy. ✅ unit-tested
  (`ViewerStacks`), Mac ✅ looked at and driven (`02-viewer-stack.png`); iPhone ✅ round 11 (strip "JPG · JPEG", the second
  copy chosen, `ios-fix-shots/r11-verify/v4-101/102`).
- "Show in folder" ✅ iPhone (round 11, `testShowInFolder`, `ios-fix-shots/r11-verify/v1-10/11`: the viewer closes, the folder opens with
  Back to its parent; Mac 🟡) (VW-3; viewer More menu and the grid's context menu, every platform): opens the app's folder browser at the
  photo's folder with a screen for each folder above it (`AppRoute.folder`, `FolderTrail` ✅ unit-tested), and closes the viewer.
- "Show in library" ✅ iPhone (round 11, `testShowInLibrary` from a folder's viewer: the viewer closes and the Library
  tab shows, `ios-fix-shots/r11-verify/v4-13`; the short ring was not caught on a screenshot; Mac 🟡) (VW-3 "Show in timeline", named after the place it opens, as Apple's "Show in All Photos"; viewer More
  menu and grid context menu next to "Show in folder", not in the Library itself, not for archived photos): closes the
  viewer, opens the Library from its root with all media, scrolls to the photo's tile (or its stack's tile; a photo the
  Library does not show: the tile closest in time) and marks it — selected on the Mac, a short ring elsewhere. Target ✅
  unit-tested (`TimelineReveal`); the Mac grid got a `reveal` for it. 🟡 Not driven in the app (the screen locked).
- Viewer on the Mac/iPad: pages fit the visible area (sidebar, toolbar, info inspector), arrow keys / Space / Escape, previous/next
  buttons under the pointer ✅ (iPad: inspector beside the photo in both orientations, → pages, run in the iOS 27.2 simulator;
  the pointer was not). The grid's info inspector on iPad ✅ (simulator): opened from the context menu, closed with "Hide
  info" in the toolbar, not brought back empty by the system at the next launch. Video and Live Photo motion play from the local copy when there is one, else through the app's
  HTTP client 🟡 (not exercised against a server with a user-trusted or client certificate).
- Performance budgets (§10) 🟡: the store side is measured with a synthetic 100 000-item index
  (`LargeLibraryPerformanceTests`, tag `performance`; skip with `PHOTOS_SKIP_PERFORMANCE=1`). On an Apple-silicon Mac, release
  build: initial index 6.3 s (store only; was 382 s in a debug build before the search index was fixed, 15 s now in debug),
  1000-row page 65 ms, local search 0.1–10 ms (budget 100 ms), timeline 58 ms as grid rows and 13 ms as lightweight rows,
  map cells for 50 000 geotagged items 8–9 ms (budget 200 ms; debug, round 4: the cells MapKit clusters 9 ms, with the time
  slider 34 ms, a cluster's first page 6–34 ms, the map's opening area 19 ms; MapKit takes 20 ms for 1024 cell annotations
  and 1.45 s for 50 000, one per photo, `MapClusteringTests`). Launch, scrolling, viewer and memory 🟡 measured in the
  simulator and on the Mac in round 10 (§20.6, PERFORMANCE.md; scroll hitches and the real budgets need a device); the grid does not use the lightweight timeline rows yet (its observation of grid
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
  cache is emptied on memory pressure and smaller on iPhone. ✅ unit-tested, ⬜ device D8 (not measured on a device).

## Navigation, menus and windows (SPEC §4.8, §6.2) — 🟡
- Mac: `NavigationSplitView` with a sidebar (since M10 the slim, editable one of SPEC §19.1; before: Library…Map, Collections, a collapsible "Utilities" section that remembers its state),
  search field with filter tokens in the window toolbar, Settings window titled and sized per tab ✅ (looked at in the Mac app).
  iPad at regular width and Vision Pro keep `TabView(.sidebarAdaptable)` with the same grouping; iPad ✅ run in the iOS 27.2
  simulator on the iPad Pro 13-inch and the iPad mini (`IPadTourTests`: every sidebar row in landscape, the tab bar in
  portrait shows Library, Settings and Search, turning the device keeps the app running), Vision Pro 🟡. Fixed on the way: Photos/Videos/Favorites hung at 100 % CPU (undo manager,
  `UndoManagerBox`), the sidebar's sections and Backup were tabs of the portrait tab bar, rotating to landscape crashed (the
  sidebar header had no app model).
- iPhone and narrow iPad windows ✅ (logic unit-tested in `CompactNavigationTests`; iPhone ✅ round 11: `SmokeTests` 7 of 7 and
  `VerifyTourTests` reach every Collections row and link destination, `ios-fix-shots/r11-verify/smoke-*`; a narrow iPad
  window ✅ run in the iOS 27.2 simulator on the iPad Pro 13-inch and the iPad mini with "Windowed Apps": the tab bar with
  Collections and its list, `testWindowsNarrowWindowIsCompact`): tabs Library, Collections, Search (Settings is in the
  Library's account menu since §19.2). The Collections tab lists every place that is a sidebar row elsewhere (server features
  respected) and Backup with its state, and pushes it in its own stack; the navigation state stays the selected destination
  and its path, so deep links, state restoration and a change between tab bar and sidebar keep working.
- Every destination has its own navigation path (`MainView.paths`); selected destination and open album are restored per
  scene (`NavigationSnapshot`) ✅ on the Mac.
- Deep links `nextcloudphotos://<destination>`, `…/album/<name>` (`…/album/shared/<name>`), `…/photo/<fileId>` ✅ parsing unit-tested,
  destination and album links ✅ in the Mac app, photo links ✅ iPhone (round 11, `testPhotoLink`: a photo the test
  uploads opens in the viewer, an unknown id opens nothing, `ios-fix-shots/r11-verify/v4-40/41`). Links wait while the app is locked and open after the
  unlock; photo links only open photos the library shows (not archived, not the video half of a Live Photo, not unknown
  ids) ✅ policy unit-tested, the unknown id ✅ run (above).
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
  structure read from the running app; the same commands are the keyboard shortcuts on iPadOS: ⌘1…⌘9 (Go), ⇧⌘N, ⌘F, ⌥⌘S and
  ⌘. ✅ typed in the iOS 27.2 simulator; ⌘I (Get Info) and ⌘−/⌘+ (Zoom) are in the iPad's menu but did not reach their
  action there (open; ⌘I in the viewer, a button's own shortcut, works).
  🟡 Image ▸ Rotate Left ⌘R / Rotate Right ⌥⌘R on the selection (as in Photos; Sync Now moved to ⇧⌘R), also in the grid's
  context menu: since §16.3 a quarter turn added to each photo's edit recipe (the file is not changed; undoable; videos are
  left alone). The former save path — the editor's "Overwrite Original…" — ✅ run against the 8089 server
  (`PhotoEditSavingIntegrationTests`: 1920×1280 → 1280×1920, stale ETag → 412, nothing overwritten), menu items ✅ read from
  the running app (key equivalents), run from the menu 🟡 (Mac locked, menus need a focused window). Edit ▸ Copy (⌘C, and
  "Copy" in the context menu) downloads the originals (≤ 100) and puts image data + file URLs (Mac) / item providers (iPad) on
  the pasteboard 🟡 (compiled, unit-tested wording only). "Add to Album" is a submenu (Image menu, context menu, selection
  menu): New Album… with the selection, the albums used last in this app (`recent-albums.json` in the account folder) then
  the most recently changed, All Albums… 🟡 (Image menu structure ✅ read from the app). Share… in the grid's context menu (the
  system Share menu on the Mac, share sheet on iPhone/iPad, originals downloaded on demand) ✅ iPhone (round 11, the system
  share sheet with the photo, `ios-fix-shots/r11-verify/v1-61`; Mac 🟡). Albums open in their own window
  (`WindowGroup(for: AlbumWindowValue)`): File ▸ Open in New Window, the album card's context menu, ⌥-click 🟡 (built for
  macOS/iOS/visionOS, not run on the Mac: Mac locked). iPad ✅ run in the iOS 27.2 simulator: "Open in new window" in the
  album card's context menu opens the album in a window of its own, which is restored at the next launch (it never appeared
  before: the multiple-scenes key was outside the scene manifest). ⬜ View ▸ Square Tiles (timeline area).
- Mac: "Export…" saves the originals of the selection into a folder 🟡 (the panel was not driven by hand).

## M2 Albums, sharing, upload, offline — ✅
Albums and shared albums ✅, collaborators 🟡 (sharee search not exercised), public links ✅, public album viewer ✅, quick share 🟡,
comments 🟡 (needs extended server), upload (PUT and chunked) ✅, share extension 🟡, drag and drop 🟡, offline albums 🟡
(originals download on Wi-Fi only by default — Settings → Storage; the folder is excluded from device backups).
- "Add photos" to an album uses the library's grid in selection mode: day headers, zoom, date scrubber, drag and ⇧/⌘ selection,
  a search field (local search index: name, place, caption, folder), the count of picked photos; picks survive a changed
  search. macOS ✅ (run: search, selection, add), iPhone ✅ round 11 (`testAddPhotosToAnAlbum`: three photos the test uploads
  picked and added, the server's album holds them, `ios-fix-shots/r11-verify/v5-52/53`; the sheet was 720 pt wide on iPhone, its Cancel and Add
  off the screen — fixed, SPEC §21.2).
- Album toolbar: the album keeps its title while photos are selected, the count is the subtitle (visionOS: the title). The
  album options menu hides while selecting on iPhone and iPad and has its own symbol on the Mac; at compact width the
  album's actions are one menu. macOS ✅ (run), iPhone ✅ round 11 (title kept, "3 items" under it, only Done while
  selecting; the actions in one menu, `ios-fix-shots/r11-verify/v5-54`, `v4-50-album-options`).
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
  test servers (create, update, list, delete, sharee search); the sheet ✅ iPhone (round 11, from the grid's context menu,
  `ios-fix-shots/r11-verify/v4-63`; Mac 🟡). Albums
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
- 🟡 §7.18.10 Google Takeout import (now part of Import Library…, §15.7, on every platform): ZIP reader (deflate, stored, ZIP64, checksum), sidecar matching, plan, importer
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
Places ✅, map ✅ (iPhone, round 11), people 🟡 (no Recognize on test servers; managing people below), tags ✅ (API), folders ✅, shared with you 🟡, On this day ✅,
memories ✅, search and smart albums 🟡 (Return searches, recent searches, error state with "Try again": ✅ Mac app), archive and app lock ✅ (iPhone, round 11), push ⬜ device D5 (needs proxy registration and provisioning), widgets 🟡.
- App lock (round 3) ✅ iPhone (round 11, `testAppLock`: Settings › Privacy › "Lock with Face ID or passcode" on, 70 s in
  the background, back: the cover with "Unlock Nextcloud Photos" and the system's Face ID prompt, opened by a simulated
  match, `ios-fix-shots/r11-verify/v5-92…95`); macOS and visionOS 🟡; state machine unit-tested: one lock state for the
  process (`AppLock`), setting in the App Group. Locked windows don't show their content at all (the viewer and sheets close);
  on iPhone and iPad the cover is a window of its own above the app (covers the full-screen viewer, sheets and the app
  switcher snapshot). The Mac Settings window and the share extension need the unlock too. Widgets show a lock placeholder
  while app lock is on and redact photo, place and date on a locked device (`privacySensitive`).
- Shared albums: photos of other users are fetched through the album's DAV child (`MediaItem.collectionChildMountType`),
  never by their name in the user's root folder ✅ parsing unit-tested.
- Push: permission is asked after login (on iPhone/iPad after the backup offer) or when the Notifications switch is turned on, not at first launch; the switch unregisters
  and registers; the notification extension only shows `photos` notifications and handles delete pushes. All ⬜ device D5: hiding the others
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
- Memory slideshow (ME-4) ✅ iPhone (round 11, `testMemorySlideshowAndMenu`: "Play slideshow" in the memory's toolbar plays
  it — since §15.1 as the memory's film, title over the first photo, scrubber, Pause/Previous/Next, Close back to the
  memory, `ios-fix-shots/r11-verify/v4-82/84`; Mac 🟡): "Play slideshow" in a memory's toolbar and in the cards' context menus. Full screen on iPhone and
  iPad, pushed in the window on the Mac and Vision Pro; the title over the first photo, 4 s per photo, 1.2 s cross-fade with a
  slow zoom, starts over after the last; Pause/Play, Previous, Next and Close (tap shows/hides them; ← → Space Esc on a
  keyboard). Reduce Motion: a 0.4 s dissolve without the zoom. With VoiceOver it starts paused. Videos show their still.
  Stepping ✅ unit-tested; not run (Mac screen locked).
- Memory menu (ME-4, round 4) ✅ iPhone for the menu (round 11: Save as album, Share as link…, Export video…, Show to a
  guest…, Slideshow music, `ios-fix-shots/r11-verify/v1-81`); its actions 🟡 (below): "More" in a memory's toolbar. "Save as album" makes an own Nextcloud album named after the
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
- Map clustering and time slider (MP-1, round 4) ✅ iPhone (round 11, `testMapClustersAndTimeRange`: clustered markers
  with counts over Europe, Time range with From/To and "All time", `ios-fix-shots/r11-verify/v1-86…88`; iPad ✅ `p1-86…88`;
  Mac ✅ round 11, run through the accessibility API: Places shows the clustered markers, a marker lists its photos in a
  sheet, `mac-02-places.png`, `mac-03-map-cluster.png` — that sheet had no Done button on the Mac, fixed; visionOS 🟡): the map is an `MKMapView` (SwiftUI's `Map` has no clustering on OS 27).
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
  servers (create, assign, refresh, search, remove); the sheet itself ✅ iPhone (round 11, from the viewer's More menu: New tag,
  the tags with their state, Find a tag, `ios-fix-shots/r11-verify/v1-62`; Mac and visionOS 🟡). A photo whose tag was removed stays in the open tag grid until it is reloaded.
- Activity in shared albums (SH-9) ✅/🟡: album listings are compared (counts) and new photos or newly shared albums become
  entries of "New in shared albums" (row above Albums and Shared albums, list with "Mark all as seen"; opening the album marks
  it seen); a background refresh posts a local notification (Settings › Shared albums). Detection ✅ unit-tested and run in
  the Mac app against the stock server with a second user (new album, added photo, removal not reported, re-add reported);
  the screens and the notification 🟡 (not seen: locked Mac, notifications not allowed for the test build). Instant push needs
  the server (§S5).

## M5 Advanced — 🟡
Editor (Core Image) 🟡, metadata editing ✅ (sheet, iPhone round 11, `ios-fix-shots/r11-verify/v4-120`), recently deleted ✅ (API; restore sends `Overwrite: T` — it was refused with 412 before; "Delete permanently" asks first and errors are shown; the screen itself ✅ iPhone round 11: behind Face ID, enrolled and matched in the simulator, it lists the trash bin
  with Restore and Empty, `ios-fix-shots/r11-verify/v1-90/91`), duplicates 🟡, free up space 🟡, extract text (server OCR or
Vision) 🟡, Ask your photos (server Assistant or on-device Foundation Models) 🟡, video renditions 🟡, App Intents and App Shortcuts ⬜ device D16.6.
- Free-form crop 🟡: the crop tool shows the whole picture with a frame (corner and edge handles, drag inside to move, thirds
  lines, dimmed outside), a lock for the aspect, presets Freeform/Original/Square/4:3/16:9/3:2 (they set the largest centred
  area and lock it); the crop turns and mirrors with the picture; VoiceOver adjusts its size. Geometry ✅ unit-tested
  (`CropAndSaveTests`); the UI built for macOS, iOS and visionOS but not run (Mac locked). Fixed on the way: "Flip" mirrored
  top-to-bottom after a turn; "Overwrite original" wrote JPEG data over PNG/TIFF and is now only offered for formats that can
  be written back; "Save as copy" was named after the cache file.
- Free up space works on the **server** (title "Free up server space"): screenshots by file name or PNG with a phone-screen size and no
  location — never every PNG (`PhotosDomain/Cleanup.swift`); the confirmation names the server, all devices and trash bin vs. permanent.
  Freeing device storage is §7.18.8 (Backup), 🟡. Since M10 both are sections of Clean up (§19.3).
- Duplicates: suggested copy to keep (favorite, own file, oldest upload) with the reason shown, user can pick another one.
  Warning when a deleted copy is in an album 🟡: the confirmation names the albums the deleted copies are in and the kept copy
  is not, from the album content in the local index (albums never opened on the device are counted as "not checked"), and offers
  "Keep in albums and move N items to the trash bin" (the kept copy is added first); filter albums are left out, a kept copy
  shared with the user can't be added. Logic ✅ unit-tested with the store (`DuplicateAlbumNoteTests`); the dialog not run (Mac
  locked).
- Spotlight (round 4) ⬜ device D16.6 (signed build): albums (own and shared), named people and places are indexed with Core Spotlight, one domain per
  account (a digest of the account id), the item id is the account link, so a result opens in its account (after asking
  when another one is shown). Updated after every sync when something changed; removed on logout and remote wipe
  (`AccountPurge` path) ✅ unit-tested. Never indexed: anything while app lock is on (all items are deleted when it is turned
  on, also by MDM), people hidden on this device (removed at once when hidden), unnamed people, places that only archived
  photos have, public-link albums; no thumbnails (a cover may be archived since) ✅ policy unit-tested. Not seen in Spotlight:
  the unsigned test build cannot be checked from the shell (⬜ device D16.6).
- App Intents (round 4) ⬜ device D16.6 (Shortcuts, Siri): `AlbumEntity` and `PersonEntity` (`EntityStringQuery`, the same entries as Spotlight: nothing hidden,
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
- Memory films (MF-1) 🟡: memories play as films — title card, Ken Burns moves towards faces/salient regions (Vision, on
  the device), cuts on the music's beat (on-device beat detection; steady 3.2 s rhythm without music, without a clear
  beat and for Apple Music songs), dissolves at new days/stops, Live Photo motion and videos inline, map flights between a
  trip's stops (MapKit satellite snapshot; standard map, then a night-blue grid as fallbacks), Previous/Play/Next,
  scrubber, Mute, ← → Space M Esc, end card. Plan, camera, beat detection (click tracks at 75/100/128 BPM, noise,
  silence), stops/km and map-flight geometry ✅ unit-tested (`MemoryFilmTests`, `YearInReviewTests`). ✅ run in the iOS
  27.2 simulator (`UITests/MemoryFilmTourTests`: title card, cross-fades, faces framed, scrubbing, skip, landscape, a trip
  Lisbon → Porto → Madrid with two flights; there MapKit cannot draw snapshots, so the grid fallback shows;
  `ios-fix-shots/r5-memories/12…17`, `50-trip-*`). ✅ run on the Mac (AX only): film beside the sidebar, satellite map
  flights with the route (`r5-memories/mac/61…64`). 🟡 Not run: music playback with beat cuts in the app (no audio file
  chosen in the test containers), inline videos and Live Photos on screen (the test library has none; the export test
  renders a clip), Vision Pro.
- Export as video (MF-2) 🟡: 1080p H.264/HEVC with the music file or the clips' sound, progress and Cancel, Share…, Save to
  Nextcloud…, Save to Mac…; temporary folders removed. Rendering, music mix, clips, map flights, cancel clean-up ✅
  unit-tested (`FilmExporterTests`, real AVFoundation files; a 1080p 16 s film renders in about 2 s on this Mac). ✅
  exported in the iOS simulator (51 s film, `18…20`) and on the Mac (51 s trip film in 15 s, 1920 × 1080 H.264, the
  satellite flight in the video, `mac/65…67`); the temporary folder was empty after Done. 🟡 Share sheet targets and the
  upload to Nextcloud not completed in a test.
- Year in Review (MF-3) 🟡: swipeable cards (intro, busiest day, top month, streak, on the move, people, pet, first
  snow/beach, favorites, best of), share as images or video, Play film; in Memories and in the strip in Dec/Jan. Numbers,
  card choice, hidden/unnamed people, labels and the store queries ✅ unit-tested (`YearInReviewTests`,
  `YearReviewStoreTests`). ✅ run in the iOS simulator (`30…42`: intro, busiest day, top month, streak, on the move with
  9 places and km, best of, Play film) and on the Mac (`mac/68`). 🟡 People/pet/snow/beach cards not seen (no Recognize
  and no on-device labels on the test server); the strip's seasonal card only shows in December/January.

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
- ⬜ device D9: Complication (accessory families): built and embedded, not seen on a face (the simulator's face editor needs input).
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
  Rotation and sources unit-tested (`AmbientRotationTests`, `AmbientPhotosTests`). ⬜ device D7: StandBy and its night mode
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
  ⬜ device D11: a real look-and-pinch, the hover glow, a spatial photo shown with depth (no spatial photo in the test
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
- Done in M10: "Similar shots" across the whole library is a section of Clean up (§19.3).
- ⬜ Not done: a live cross-fade between grid steps in the middle of
  an iPhone pinch (the grid scales with the fingers and changes step on release).

### §15.6 Then and now, travel globe
- ✅ Then and now spots (TN-1): 100 m spots over ≥ 2 years, ranking, titles; unit tests (`PlacesDelightTests`,
  `TravelQueryTests`); run in the iOS 27.2 simulator against the test library (Places row, "See all", spot screen).
- ✅ Same view (TN-2): Vision feature prints of 256 px previews choose each year's photo; unit tests with a fake distance
  and with real feature prints of generated pictures (`ThenAndNowMediaTests`); ran in the simulator. Compass heading not
  used (not in the index) — decision in SPEC.
- ✅ Side by side, viewer More menu, time-lapse player and video export (TN-3, TN-4): run in the iOS 27.2 simulator
  (`UITests/PlacesTourTests`, screenshots in `ios-fix-shots/r5-places`); the MP4 writer has a unit test that reads the
  video back. Mac: the Places row seen in the running app (AX API, `mac-01-places.png`); visionOS: build only.
- ✅ Travel model (TG-1, `TravelHistory`): unit tests; reusable for Year in Review (`stats(in:)`).
- ✅ Travel globe (TG-2): MapKit hybrid realistic globe with legs, place markers, year filter, trips; run in the iOS
  27.2 simulator. Mac: the screen and its panel seen in the running app, the map imagery not (it does not draw in a
  window that is never brought to the front); visionOS: build only.
- 🟡 Countries and scratch map (TG-3): run in the simulator. The index only has the server's country where the
  extended Photos API is detected (`mediaIndexExtended` requests `nc:metadata-photos-place-country`), so on stock
  servers countries come from the opt-in Apple Maps lookup; requesting that property on every server is a sync change
  outside this package (left for the sync owner).

### §15.7 Bring everything home: imports
- ✅ General importer (`ImportPlanner`, `LibraryImporter`) with adapters for Google Takeout, Apple's iCloud Photos data
  export, Facebook and Instagram JSON exports (2018–2026 layouts), plain photos: unit-tested with fixtures written from
  documented real exports; ✅ end-to-end against 8089, 8091 and 8093 (Apple + Facebook: capture time written into the Facebook photo and
  read by the server, favourite, hidden photo in `/.archive`, album, second import uploads nothing; Google Takeout as in
  round 3).
- ✅ Duplicates across exports and against the server (`ImportMatcher`: name+size, Apple minutes, reduced copies),
  metadata write-back (`ImportMetadataWriter`), parallel uploads, free-space stop, journal/resume, summary and report:
  unit-tested.
- ✅ iPhone (iOS 27.2 simulator): start screen, review, progress with the photos sliding by, Welcome home (light, dark,
  XXL text) against 8089 with a 4-service demo export (16 items: 14 uploaded, 2 found on the server, 4 albums, 1 hidden
  photo archived, report uploaded). Screenshots: `ios-fix-shots/r5-import/`. The continued processing task is not
  available in the simulator (the import ran in the app, as designed when the system declines); 🟡 on a device.
- ✅ Mac: review, progress and Welcome home run (driven through the accessibility API). 🟡 Photos Library source:
  the import of its items (export one at a time, archive, favourite, album) ✅ unit-tested with an injected export; reading
  the library through PhotoKit not run (it needs the Photos permission prompt). 🟡 Picking
  files with the file picker and resuming via bookmarks after a relaunch not run (needs real input); the Mac needs
  `com.apple.security.files.bookmarks.app-scope` (added to the entitlements) for that.
- ⬜ iPad and Vision Pro layouts not looked at (same sheet).

### §15.8 Smart offline and fun extras: stickers, collages, photo of the day
Unit tests: `SmartOfflinePolicyTests`, `ExtrasTests` (photo of the day, collage layouts and picker, sticker subjects),
`ExtrasStoreTests`, `ExtrasCoreTests` (smart offline passes against a stubbed server, notification texts and dates, sticker
book), `ExtrasMediaTests` (pipeline uses kept previews, sticker styles, PNG/HEIC alpha). UI: `UITests/ExtrasTourTests`
in the iOS 27.2 simulator against the 504-photo test server; screenshots in `ios-fix-shots/r5-extras/`.
- ✅ Smart offline (§15.8.1): run in the iOS 27.2 simulator against the test server — the first foreground passes kept 135
  previews (62.6 MB) of the recent photos, favourites and the coming days' memories, and Settings shows that. Policy,
  eviction (LRU, stale, budget change, Off), Wi-Fi/Low Power rules and originals mode unit-tested. 🟡 The background task
  (charging) and the Mac's background activity were not seen to run; offline browsing was not tried in the simulator
  (the pipeline's use of kept previews is unit-tested). ⬜ No badge on grid tiles (decided against, see SPEC).
- 🟡 Stickers (§15.8.2): lifting and all four styles verified on the Mac with real photos of the test library
  (`StickerSampleTests`, outputs in `ios-fix-shots/r5-extras/mac-stickers/`). In the simulator Vision's segmentation is not
  available, so the sheet shows its explanation; the sticker book was shown with stickers made on the Mac (copied into
  the simulator's book). Not verified:
  the system's "Add Sticker" in VisionKit's menu (needs a device), a person's sticker pack (the test server has no
  Recognize), the Mac and Vision Pro sheets running.
- 🟡 Collage and card (§15.8.3): layouts, crop and picker unit-tested; the editor run in the iOS 27.2 simulator with six
  photos of the test library (mosaic, magazine, prints, grid, picking a photo to swap). Not verified: the PDF and image
  export through the share sheet, "Save to Nextcloud" (it uses the same uploader as "Save as copy"), the album and memory
  entry points, the Mac and Vision Pro.
- ✅ Photo of the day (§15.8.4): run in the iOS 27.2 simulator — turning it on asks for permission and schedules the
  coming days with their photos attached (the system log shows the attachments copied), the debug one arrived ("On this
  day 13 years ago · Dubai") and tapping it opened the photo in the viewer. Choice, texts (also with app lock) and dates
  unit-tested. Tapping any notification crashed the app before (UIKit asserted on the async delegate method finishing off
  the main thread); the router now uses the completion-handler form on the main queue. 🟡 The attached photo was not seen
  as a thumbnail or expanded in the simulator; the app-lock text and the Mac were not seen on screen.

## M7 Elegant and powerful (SPEC §16) — 🟡

Round 6 (2026-11-25): all 30 ideas built in eight packages (subsections below), combined in one branch. Open after combining:
- ⬜ Camera data is read twice: Insights (`photoExif`, §16.5.1) and the organising rules (`cameraDetails`, §16.4) each read
  the server's EXIF into their own table. Plan: one table and one reader, then a camera chip in the search (§16.2).
- ⬜ device D16.4: In the iOS simulator a software keyboard appears while some menus are open (the viewer's and editor's More menu, the
  film's Style menu). Making the viewer's keyboard focus conditional did not change it; to be checked on a device.
- ⬜ Strings of the round-5 import screens (`ImportLibrarySheet`, `WelcomeHomeView`) are not in the PhotosAppUI catalog yet.
- 🟡 The Memories "On this day" carousel's touch area reaches about 80 pt above its cards (worked around with `zIndex` for
  the family card, §16.7).

### §16.1 Library: moments, scrub to peek, range select, story cards
- ✅ Moments: grouping and titles (`LibraryMoments`, `MomentTitle`), the store query (`momentItems`), the worded-title
  store (`momentTitle`, migration `v6-library-moment-titles`) and the checks on the language model's answers
  (`MomentTitleWording`) unit-tested (`LibraryMomentsTests`, `MomentStoreTests`, `MomentTitleWordingTests`; 100 000
  items in 0.22 s in a debug build). Run in the iOS 27.2 simulator against the test server (UI tour
  `LibraryTourTests.testStoryCardsAndMoments`): 196 moments, 32 titled, of 513 items; "Weekend in Lisbon", "Monday in
  Sintra", "3 days in Kópavogur" on the day headers of All Photos and above the days of the Days level; a tap opens the
  moment's screen. The language model could not be tried: the simulator refuses it (SensitiveContentAnalysisML error
  15; the rule titles stay, as designed) and the Mac's screen was not used; 🟡 for the worded titles. Mac headers
  (pointer cursor, click, VoiceOver button) built, not verified on the Mac.
- 🟡 Scrub to peek: shared logic (`GridPeek`, `GridPeekLoader`, `GridPeekCache`, `GridPeekKind`) unit-tested, frames
  of a streamed video through `StreamingAssetLoader` unit-tested on the Mac (`PeekFramesTests`). iPhone ✅ run in the
  simulator with a video uploaded for the purpose (no server preview): hold and slide on its tile shows the video's
  frames in place with the bar under the finger, nothing opens, and a finger held still still brings the context menu
  (`testScrubToPeekAndContextMenu`, frames captured with `simctl io` during the hold; the context menu first won the
  race, so the menu and a tile's drag now wait until the scrub has decided, at most 0.6 s). Live Photos and stacks
  (none in the test library), iPad pointer hover and the Mac hover: built, not run (no pointer in XCUITest, Mac screen
  not used).
- ✅ Range selection on iPhone (one finger sliding sideways in the selection mode; `GridRangeSelection`, `GridAutoscroll`
  unit-tested): run in the simulator, a drag from one tile three tiles on and two rows down selected the 14 tiles between
  (`testRangeSelection`). Autoscroll at the edges and the two-finger drag (UIKit's, unchanged) not exercised by
  XCUITest. Mac: ⇧-click and the selection rectangle are NSCollectionView's, as before.
- ✅ Story cards: run in the simulator (On this day cards play with their bars, a tap on the right goes on, the context
  menu switches to the strip; band of fixed height, no empty band). Photo choice and tap rules unit-tested
  (`LibraryDelightTests`). Settings › On this device › Memories (Stories/Strip) and Name moments. iPad, Mac and Vision Pro
  layouts built, not run.

### §16.2 Search: command palette, natural-language search with chips, photo descriptions
- ✅ **Command palette (Quick Actions, ⌘K)**: destinations, Mac Settings pages, albums, people, places, tags, years,
  commands on the focused grid's/viewer's selection, "add to <album>" and "rate N" intents, typed searches as one entry,
  fuzzy matching, keyboard navigation, recent entries per account. Unit tests (`FuzzyMatchTests`,
  `CommandPaletteTests`, `SearchPaletteTests`). Run on the Mac (opened with the toolbar button through the AX API,
  "Lisbon 2025" → album first, "Lisbon · 2025" search → chips and 11 results; "settings descriptions" → General
  Settings opened the Settings window on that tab) and in the iOS 27.2 simulator (`UITests/SearchTourTests`
  `testCommandPalette`: "lisbn" finds Lisbon, Return opens it). ⌘K itself and ↑/↓/Return/Escape not pressed (no
  real keyboard input allowed); iPad not run.
- ✅ **Natural-language search with chips**: deterministic parser (`NaturalSearch`, `SearchDates`: dates in many
  forms, people/places/tags/albums from the index, labels, ratings, media kinds, favourites), editable chips with
  menus on all platforms, results live. Unit tests (`NaturalSearchTests`, 11 tests, ~40 date forms;
  `PhotoDescriptionStoreTests` for the new chip kinds in the index). Run in the iOS 27.2 simulator
  (`testSearchInWords`: "favourite photos from Lisbon in 2025" → Favorites · Lisbon · 2025, chip menu → 2024).
  🟡 The Foundation Models refinement (`NaturalSearchModel`) is built and its validation unit-tested, but has not run:
  the Mac's model is "not ready" (Apple Intelligence not downloaded) and the simulator has none.
- ✅ **Photo descriptions**: Vision facts + composer (English) or the on-device language model (user's language, from the
  picture), table `photoDescription` (migration `v6-search-descriptions`), full-text index, VoiceOver labels of tiles,
  viewer and info panel, background task / Mac activity / charging trickle, Settings › Search › Describe photos (off
  deletes). Unit tests (`PhotoDescriptionTests`, `PhotoDescriptionStoreTests`, `PhotoDescriberTests` — real Vision on
  the Mac only). Run on the Mac: 65 cached previews described with the composer ("A person with a child", "A tower",
  "A fountain"), tile VoiceOver labels read through the AX API (ios-fix-shots/r6-search/mac-tile-voiceover-labels.txt),
  Settings shows "Photos described 65 of 512". 🟡 Language-model descriptions not run (model not ready on this Mac);
  nothing is described in the simulator (no Vision).
- ⬜ **Camera chip**: the index has no camera make/model. Plan: ask for `nc:metadata-photos-ifd0` (Make/Model) in the
  sync's SEARCH (or read it lazily with the photographer stats of §16.5), store it in `media`, add a `.camera` chip.

### §16.3 Editing: non-destructive edits, RAW, Live Photo effects, visual undo history
- 🟡 Non-destructive edits (§16.3.1): recipes in `/.nextcloud-photos/edits/<fileId>.json`, format, ETag-safe sync,
  newest-edit-wins conflicts, offline queue, persistence and newer-format handling unit-tested against an in-memory
  WebDAV server (`EditLibraryTests`, `EditRecipeTests`); renditions (turn, crop, size) and "Save as Copy" rendering
  tested on the Mac (`EditRenditionTests`, disabled in the simulator). Editor Done/Save as Copy/Overwrite Original…/Revert,
  edited tiles, viewer, export and share: built for all platforms. Round 11: Done in the Mac test build saved the recipe
  on 8089 (`ios-fix-shots/r11-edit/recipe-sky.json`; the edit was a subtle sky saturation, not judged by eye in the
  viewer); Overwrite Original's
  server path proven by `ApplyEditsToFileIntegrationTests` (§21.6).
- 🟡 Image ▸ Rotate is now an edit (undoable, works on read-only shares and RAW): unit-tested through the session
  (`UndoHistoryTests`); menu/context menu not run in the app.
- 🟡 RAW (§16.3.2): `CIRAWFilter` development in the editor (RAW tool) and the viewer's RAW button, RAW+JPEG pairs saved
  for both files. Built; not run (no RAW files in the test library were tried).
- 🟡 Live Photo effects (§16.3.3): frame averaging and Loop/Bounce frame order unit-tested; long exposure, key photo,
  Loop/Bounce playback and video/GIF export built, not run (AVFoundation is not exercised by the unit tests).
- 🟡 Undo history (§16.3.4): history, undo of an older entry, edits replaced later, bounded size unit-tested
  (`UndoHistoryTests`); panel, Edit ▸ Undo History… (⌥⌘Z) and the More menu items built, not run in the app.
- ⬜ Orphaned recipes of photos deleted for good are not cleaned up (plan: on a full reconcile, remove recipes whose file
  id is neither in the files nor in the trash bin, after the trash retention).
- ⬜ Aspect-ratio grid tiles keep the original's shape for cropped photos (plan: store the rendition's aspect with the
  recipe and let `GridMedia` use it).

### §16.4 Organising: smart album builder, batch time/place/rename, GPX geotagging, folder rules, Shortcuts
- ✅ Smart album builder (rules with All/Any/None, negation, groups; person, place, tag, album, rating, flag, media
  type, favourite, dates, recent/older, folder, name, text, camera, lens, focal length, aperture, ISO), live count and
  first photos, sort and limit: rule model, JSON, evaluation and the builder's draft unit-tested (`OrganizeTests`,
  `RuleDraftTests`, `OrganizeStoreTests`); ✅ run in the iOS 27.2 simulator against 8089: built, counted (513 photos
  live), saved, listed with the albums, opened, deleted (`OrganizeTourTests`, shots `ios-fix-shots/r6-organize/01–08`).
- ✅ Shared between devices through `.nextcloud-photos/smart-albums.json` with ETag-safe merge: merge rules unit-tested;
  conditional writes against 8089 (`AppDataFilesIntegrationTests`, `PHOTOS_IT_SERVER`); the file the simulator wrote
  was read on the server (album, then its tombstone after deleting). ⬜ device D16.5: two real devices at once not tried (the merge
  and the conditional write are what makes it safe).
- ✅ Camera details: bulk SEARCH of `nc:metadata-photos-exif` checked against 8089 (200 files in 0.25 s), stored per
  ETag, unit-tested; 🟡 the background read of a large library (100 000 photos ≈ 1 100 requests) not timed.
- ✅ Batch fixes: date shift / first-photo date / time zone, place (map + search), rename patterns, with preview and
  undo; logic unit-tested; ✅ in the simulator on own test photos in `/Photos/r6-organize-test` on 8089 (opt-in UI test
  `testApplyAndUndoInOwnFolder`): +1 h applied (server capture times +3600 s) and undone (original values back);
  rename `{date} {place} {counter}` applied (`2024-06-14 001.jpg` …) and undone. Sheets seen on iPhone: shots 09–14, 19–20.
  File-level writing for servers before Nextcloud 35: `MetadataRewriter` unit-tested, the server's re-reading of
  EXIF date, offset and GPS after an overwrite checked by hand on 8093; ✅ the whole path against Nextcloud 33.0.11
  (round 10, `testApplyAndUndoInOwnFolder` on own copies in `Photos/r10-servers-organize`): +1 h written into the three
  files (GET, PUT of a new version), the server's capture times +3600 s, GPS kept; Undo wrote the original values back.
- ✅ GPS track geotagging: GPX/KML reading, matching with interpolation and tolerance, suggested clock correction
  unit-tested; ✅ sheet seen in the simulator; 🟡 picking a file in the simulator and applying not run (the file picker
  needs real input); ⬜ recording a track in the app — decided against (SPEC §16.4.3).
- ✅ Folder rules: planner, lease, state and log unit-tested; ✅ in the simulator against 8089: a rule written into
  `.nextcloud-photos/folder-rules.json` from outside (favourite everything in `/Photos/r6-organize-test`) was picked
  up after the next sync and ran by itself; log shown. ⬜ device D16.5: two devices competing for the lease not tried live.
- ✅ Shortcuts: 13 App Intents with `PhotoEntity`/`MemoryEntity`, one App Shortcut; compiled for iOS, macOS,
  visionOS; ⬜ device D16.6: not run in the Shortcuts app (needs real input).
- 🟡 Mac and iPad layouts compiled, not looked at (Mac screen locked); Vision Pro compiled only.

### §16.5 Photographer: stats, loupe and filmstrip culling, Continuity Camera, Mac menu bar extra
- ✅ Insights (cameras, lenses, focal lengths, apertures, ISO, shutter speeds, time of day, keeper rate by lens, tap-through
  to the photos). Model, scales, filters, summary, `photoExif` store (migration `v6-pro-exif`) and the background reader
  unit-tested (filters checked against SQL for every bar kind; reader against a stub server: by id, paging, stop). The
  SEARCH with `nc:metadata-photos-exif`/`-ifd0` checked by hand against the stock (8093) and extended (8089) test
  servers. Run on the Mac (8089: all 512 photos read in the background, 421 with camera data, every card; a camera bar
  opened its 14 photos through the AX API) and in the iPad simulator (iOS 27.2, while reading). Keeper rates not seen with
  real ratings (the test library has none); lens names not seen (the test library's EXIF has no `LensModel`).
- 🟡 Culling view (loupe, filmstrip, focus peaking, clipping, histogram, keys with auto-advance; Mac window full screen,
  iPad cover). Pixel analysis and loupe geometry unit-tested (Core Graphics adapter tests on the Mac only). Run in the
  iPad simulator (`PHOTOS_DEBUG_LOUPE`, keys through `PHOTOS_DEBUG_LOUPE_KEYS`): filmstrip, peaking, clipping, histogram
  with clipped share, Z to 100 % with the original. Not run: the Mac window (the owner was using the Mac), click/hold
  with a pointer, rating keys (not to change tags on the shared server; they use the tested culling code of §15.2).
- ⬜ device D16.7: Continuity Camera (Mac: File ▸ Import from iPhone or iPad into Library, own album, folder) and Take Photo / Scan
  Documents (iPhone, iPad). Not run: needs a nearby iPhone or a device camera.
- ⬜ device D16.7: Menu bar extra (Mac; Settings › General › Show in Menu Bar). Not run.
- ⬜ Not done: peaking/clipping computed on the visible crop of the original at 100 % (now from a 2048 px version), a
  second-display "loupe on the other screen" mode, tethered shooting, Insights over time (per year) and per album.

### §16.6 Films: through the years, film styles, SharePlay
- Through the years (FS-1) 🟡: one named person's face across the years — Recognize's photos of them, one per month /
  season / year (best face; the period's next photos when a face is turned away), eyes found with Vision face landmarks
  and lined up (level, same place, same size) over a blurred fill, dissolving with the date and (with a birthday kept on
  the device) the age; Slow/Normal/Fast, calm music, scrubber, export as 1080p video. Entry in the person's menu and a row
  in Memories; explains when Recognize is missing, the person is unnamed or there are too few photos. Selection, alignment
  geometry, timing and ages ✅ unit-tested (`ThroughTheYearsTests`); the Core Image alignment ✅ on the Mac with a
  synthetic face, and with Vision on the portraits of the test library's People folder (`FaceTimeLapseTests`,
  `TEST_RUNNER_PHOTOS_FACE_SAMPLES`): eyes on the guides, profiles skipped
  (`ios-fix-shots/r6-films/01-through-the-years-alignment-sheet.png`). The Memories row's "needs Recognize" note ✅ in the
  iOS 27.2 simulator (`20-memories-through-the-years`). 🟡 The film itself not run end to end: no test server has Recognize
  with named people, and Vision does not run in the simulator.
- Film styles (FS-2) ✅/🟡: Cinematic, Upbeat, Black & White, Super 8, Calm in the film's style menu — pacing,
  transitions, camera, Core Image look (colour matrix, vignette, grain, gate jitter, flicker; same numbers in player and
  export) and a score per style composed and synthesised on the device (or the user's own music: pacing only; or no
  music); remembered per memory; applied to the export. ✅ unit-tested (`FilmStyleTests`, `FilmChoiceTests`,
  `FilmScoreSynthTests`); Core Image grade = model and a Black & White export ✅ on the Mac (`FilmLookFilterTests`). ✅ run
  in the iOS 27.2 simulator (`UITests/FilmsTourTests`): every style, the menu, the remembered choice, the export's style
  note (`ios-fix-shots/r6-films/21…28`). Found and fixed there: the film waited for its score to be made (it now starts at
  once, the music joins), the style menu closed when the controls faded, Super 8 grain was too coarse on the phone. 🟡
  The music was not listened to (levels, loop seam and determinism are tested), clips' look not seen (no videos in the test
  library). Open: in the simulator a software keyboard appears while the style menu is open (no text field involved; not
  seen with other menus' screenshots; not reproduced on a device).
- SharePlay (FS-3) 🟡: GroupActivities activity with only the film's description (no photos, no preview, no places, no
  music), playback in step through `AVDelegatingPlaybackCoordinator`, per-participant reports of what they can see,
  explanations for "not shared with you", "other account" and "not signed in", slideshow shared as a film; iPhone, iPad,
  Mac (own window), Vision Pro and Apple TV (`TVSharedFilmView`). Payload, server matching, audience and clock maths ✅
  unit-tested (`SharedFilmTests`); "SharePlay isn't available" without a call ✅ in the simulator
  (`27-shareplay-without-call`). ⬜ device D16.5: not run with real participants: needs two devices in a FaceTime call and the Group
  Activities capability in the provisioning profiles (entitlement `com.apple.developer.group-session` added for the app
  and the TV app).
- ⬜ Birthdays from Nextcloud Contacts (CardDAV `BDAY`), syncing styles/birthdays between devices (`.nextcloud-photos/`),
  inline clips on Apple TV, a spatial SharePlay template on Vision Pro.

### §16.7 Sharing and family: postcards, family library, weekly prompts, Lock Screen shuffle album
Shots: `~/aloha-work/photos-tools/ios-fix-shots/r6-family/` (iPhone 17, iOS 27.2 simulator, test server 8089).
- ✅ **Postcards** (§16.7.1): composer with four frame styles, lettering, message/To/postmark place, live re-render, 3D
  flip, send, "SENT" stamp, copy link, share sheet. Run in the iOS 27.2 simulator (`UITests/FamilyTourTests.testPostcard`,
  shots 01–06): the card was uploaded as `/Postcards/2026-11-25 el Raval/{1 Front,2 Back}.jpg` with `.nomedia`, a public
  link labelled "Postcard to Grandma" with the message as note; the link was opened anonymously and served both sides
  (08/09). Rendering unit-tested on the Mac (`PostcardRendererTests`, all styles, portrait, long messages; renders with a
  real photo in `render-*.jpg`); sending unit-tested against a stub server (numbered folder name, link, cleanup of a half
  upload). ⬜ device D16.3: the share sheet itself (Messages/Mail) and the Mac/Vision Pro composer were not seen on screen.
- ✅ **Family library** (§16.7.2): shared-folder detection (own shared folders, received shares, Team folders),
  members, move/copy, suggestions by family members (month) and by shared day/place, card in Memories, Review, dismiss,
  remembered decisions. Run in the simulator (`testFamilyLibrary`, shots 20–24): the folder `r6-family-Family` shared by
  a second user was found, chosen, "11 photos from el Raval on December 29" was suggested from a photo of that day in
  the family folder, and Review listed them. Moving was unit-tested (stub server: motion part along, decisions recorded), not done on the test
  server (the suggested photos are in `Photos/Test library`). 🟡 Suggestions by family members need Recognize, which no
  test server has (unit-tested only).
- ✅ **Weekly photo prompts** (§16.7.3): invitation, card, adding this week's photos to "Prompt: Numbers", Past Prompts,
  settings and reminder. Run in the simulator (`testWeeklyPrompt`, shots 10–14); themes, weeks (also across a DST change),
  history and reminder dates unit-tested. 🟡 The reminder notification itself was not seen firing.
- ✅ **Lock Screen album** (§16.7.4, iPhone/iPad): run in the simulator (`testLockScreenAlbum`, shots 30–33): the album
  `r6-family-lockscreen` was copied (3 photos) into the simulator's Photos library (32b), and turning it off showed the
  system's "Allow … to delete N photos?" (33; XCUITest cannot press that alert, so the copies waited and Settings listed
  "N removed photos are still on this device"). Plan, hidden
  people, edits, declined/confirmed deletion and turning off unit-tested with a fake library. ⬜ device D16.6: Photo Shuffle on a real
  Lock Screen needs a device.
- ⬜ Family settings and dismissed suggestions are per device; syncing them through `.nextcloud-photos/` is left for
  later (plan: a `family.json` with the folder, members and dismissed file ids, merged as a union).
- ⬜ The Lock Screen album syncs only while the app runs (after syncs); a background refresh task would keep it current
  while the app is closed.

### §16.8 Look and access: colour from the photo, living album covers, guest mode
- ✅ Colour from the photo (§16.8.1): dominant colour from the BlurHash or an in-memory preview (`PhotoPalette`,
  `PhotoColors`), toned per role with a ≥ 7:1 contrast guarantee (`PhotoTintRole`, `AmbientField`; grey photos keep
  the dark backdrop near black); viewer backdrop Black / Photo Color / Ambient Glow, blended between pages by the
  scroll position; album and memory header washes (inline title, the bar hides a large one) and memory card scrims; off
  with Increase Contrast, solid with Reduce Transparency; Settings ▸ Appearance. Unit tests (palette, tones, ambient
  field, header washes, pager blend). Run in the iOS 27.2 simulator, dark and light mode: tinted and ambient viewer,
  album header, guest viewer (`ios-fix-shots/r6-look/01…04`, `look-14*`, `look-22`). Mac and Vision Pro: built, not run.
- ✅ Living album covers (§16.8.2): Live Photo covers play once per session (muted, in view, not with Reduce Motion, Low
  Power Mode, video autoplay off or the setting off); depth covers with an on-device Vision subject mask cached next to
  the previews; "Customize Cover…" sheet (card menu and album menu); choices synced in
  `/.nextcloud-photos/album-covers.json` with ETag merge (`AlbumLookStore`), follow renames, own albums on extended
  servers also set the server cover. Unit tests (book merge/decode/rename, depth layout, mask round trip and cache, store
  sync against a fake server, Vision "no subject" on the Mac). Simulator (UI test `LookTourTests.testCovers`): card menu,
  sheet with photo choices, depth preview with the title in front (no Vision in the simulator). Vision masks checked on
  the Mac with two library photos (`mac-vision-mask-*.png`); the Mac app itself was not run. 🟡 Live Photo playback not
  seen (the test library has no Live Photos).
- ✅ Guest Mode (§16.8.3): "Show to a Guest…" for albums and memories; every window shows only its photos (grid, viewer,
  slideshow) until Face ID / Touch ID / passcode; survives a relaunch; links, notifications and Spotlight do nothing,
  no banners; Mac presentation window with Dock, menu bar and app switching hidden and ⌘Q refused. Unit tests for
  `GuestMode`. Simulator (UI test `LookTourTests.testGuestMode`): start sheet, guest grid and viewer without Delete/Info,
  a link ignored, ended with a simulated Face ID match, and the app came back in Guest Mode after a relaunch
  (`look-20…23`). 🟡 The Mac kiosk window was deliberately not run on the owner's Mac (it takes over the screen).

## M8 Elegant motion and glass (SPEC §17) — ⬜

Combined (branch `feat/r7-combined`): where two packages met on one screen —
- Selection on iPhone: the grid's rolling "N selected" title in the bar and the chrome's glass action bar both stay.
- Album, memory and person screens: the albums' hero header lies in the grid's content inset, the Library's memories
  strip is the grid's own header (only one of them on a screen); the grid's date pill sits under the bars, not below
  the hero, and appears once the hero has scrolled away. On iPhone and iPad the cover colour wash (§16.8.1) is off where
  a hero shows the cover itself; the Mac keeps the tinted toolbar.
- Album cards: the caption plate uses the typography tokens (§17.5); at accessibility sizes the title is below the
  cover with `cardTitleStyle()`. Place section headers keep the chrome's glass capsule.
- Viewer on Vision Pro: the controls are a bottom ornament (§17.7); iPhone and iPad keep the stage's glass controls.
- Notices ("Change undone", "Moved 2 items to the trash bin") stand above the selection bar and above the Library's
  glass zoom picker instead of under them (found in the combined grid tour; `floatingBottomInset`). Under the picker,
  the notice's Undo could not be tapped: a delete in the Library could not be undone from the notice.
- ✅ SwiftUI trap in `ResolvedScrollBehavior.updateTarget` (display link, inside `AccessibilityViewGraph.needsUpdate`,
  so it happened while an accessibility client read the app: UI tests, and possibly VoiceOver, Voice Control or Switch
  Control): the Library's memory stories strip, hosted in the UIKit grid, with `.scrollTargetBehavior(.viewAligned)`.
  Round 8/9 combine, iPhone 17 simulator, `CacheMeasureTests.test1Grid`: 3 of 4 runs crashed with it; with the strip's
  scroll target behaviour and position off, 0 of 3; with only `.viewAligned` off on iPhone, iPad and Vision Pro (the
  fix), 0 of 3, and the Settings, Library and toolbar tours that had crashed pass. The Mac keeps `.viewAligned` (its strip
  is not in the grid; never seen there). ✅ Snapping is back without a scroll target behaviour (§20.1,
  `MemoryStorySnap`). Also kept: the stories play only while the strip is on screen
  (`GridHeaderVisibility`) and the header slot never gets an empty size. Crash logs in `~/aloha-work/photos-tools/r8r9/`. Crash logs: `~/aloha-work/photos-tools/r7merge/crash-scrolltarget-193447.ips`,
  `~/Library/Logs/DiagnosticReports/Retired/Nextcloud Photos-2026-11-2*`.

### §17.1 Viewer as a stage: full-screen photo, glass controls, info glass card, interactive dismissal, viewer colour
- ✅ Stage (§17.1.1): full-screen photo, glass close button, date pill and action bar (`ViewerStageControls`), tap to
  fade them and the status bar. Run in the iOS 27.2 simulator, light and dark (UI test `ViewerStageTourTests`,
  shots in `ios-fix-shots/r7-viewer/`). Mac keeps its toolbar, Vision Pro its toolbar and dark viewer (built, not run).
- ✅ Viewer colour (§17.1.2): black in Dark Mode, white in Light Mode, black while the controls are hidden; the three
  backdrop styles in a dark and a light version, Ambient Glow as a blurred copy of the photo. Unit tests
  (`ViewerStageTests`); simulator shots of all three styles in both modes.
- ✅ Info as a glass card (§17.1.3): the photo moves up above the half-height card. Simulator (`testInfoCard`).
- ✅ Interactive dismissal into the tile (§17.1.4): geometry unit-tested (`ViewerStageTests`: the photo lands exactly
  on the tile); run in the simulator with screen recordings (`dark.mp4`, `light-dismiss.mp4`, frame sheets
  `dismiss-*-frames.png`): the photo follows the finger, shrinks, lands in its tile and the grid appears with the tile
  in place; a short drag springs back. ⬜ The grid does not yet show *during* the drag: with the zoom transition UIKit
  removes the presenting view while the cover is up, so the backdrop fades to the system background (plan: present
  the viewer over the grid without removing it — a UIKit `overFullScreen` presentation with a custom zoom animator —
  or show a snapshot of the grid taken when the viewer opens). ⬜ device D8: not seen on a device (120 Hz); iPad see §21.2.
- ✅ Software keyboard with the viewer's, editor's and film's menus fixed (§17.1.5): `testStageAndMoreMenu` fails before
  (a keyboard was shown) and passes after; arrow keys page in the simulator (`testKeys`).

### §17.2 Grid: edge to edge, floating date pills, photo arrival, physical selection, action feedback, Live Photo and video tiles
Run in the iOS 27.2 simulator (iPhone 17) with the UI tour `GridMotionTourTests` (screenshots and recordings in
`ios-fix-shots/r7-grid/`, before/after pairs); logic in `GridMotionTests` and `GridBatchUpdateTests` (macOS).
- ✅ Edge to edge: grids under the bars with the soft scroll-edge effect, no header bands; the Library's memories
  scroll with the photos (hosted in the grid), the grid stays at the top when they come or go (selection mode).
- ✅ Album/memory cover colour as a wash under the bar instead of a solid band (solid with Reduce Transparency).
- ✅ Floating date pill with month and moment place, hand-over push, fades in after the first header; scrubber, year
  ticks and anchors unchanged (offsets include the memories header).
- ✅ Photo arrival: cross-fade and settle from the BlurHash (Core Animation only), instant for pictures in memory.
- ✅ Physical selection: shrink to 92 %, rounded corners, tick with symbol transition and bounce, rolling count.
- ✅ Heart burst on new favourites (iPhone, Mac code path built, not run on the Mac); delete collapse and undo
  return as an animated item batch, consistency tested with 300 random changes per mode on a real collection view.
- ✅ Archive slides away (iPhone, round 11, `testArchiveAndUndoOnOwnPhotos` on a photo the test uploads: "Archived 1 item ·
  Undo", undone, `ios-fix-shots/r11-verify/v1-71…73`); 🟡 Remove from Album: same code path, not run.
- ✅ Video duration in a glass capsule; 🟡 Live badge animation on long press / hover / peek built, not seen in the
  simulator (the test server has no Live Photos).
- 🟡 Mac: arrival fade, animated delete batch and heart burst built and compiled, not run (owner's screen).

### §17.3 Chrome: morphing toolbars, minimizing tab bar with progress accessory, animated icons, rolling numbers, edge to edge on the other screens
Run in the iOS 27.2 simulator (iPhone 17, light and dark) with `ChromeTourTests` (5 UI tests, pass); decisions unit-tested
in `ChromeMotionTests`. Shots: `~/aloha-work/photos-tools/ios-fix-shots/r7-chrome/`.
- ✅ Selection bar: Select turns the tab bar into a glass action bar (one "Select items" capsule that splits into Share ·
  count · Favorite, Add to album, Delete, More with the first selection and melts back); Done returns the tab bar.
- ✅ Tab bar minimises while scrolling down — SwiftUI lists and, with `registerContentScrollView`, the UIKit photo grid.
- ✅ Progress accessory above the tab bar (expanded and inline), its finished check mark and the tap to Backup — seen
  with the made-up activities of `PHOTOS_DEBUG_ACTIVITY`. 🟡 A real upload, backup or import driving it was not run in
  the simulator (the wiring reads the same models the toolbar gauge and Backup screen read).
- ✅ Animated symbols (upload, backup, sync, heart) and rolling numbers in the accessory, selection bar and Backup
  screen. 🟡 The padlock that clicks open (Archive, Recently deleted) is built but not seen: the simulator has no
  enrolled Face ID/passcode for the test. 🟡 Settings sync row and Insights counters compiled, not looked at.
- ✅ Edge to edge: Collections, Places, Memories, Map (under the bars, inline title), Search, Settings; Places headers
  and map panel on glass.
- 🟡 Mac and Vision Pro: compile only (the Mac keeps its toolbar; the accessory and the minimising tab bar are iPhone
  and narrow-iPad features). iPad not run.

### §17.4 Albums and transitions: glass caption plates, empty-album gradients, hero headers, parallax, zoom transitions everywhere
- ✅ Album cards (idea 4): title and count on a glass caption plate over the cover (`CaptionPlate`; solid with Reduce
  Transparency / Increase Contrast, material on Vision Pro; below the cover at accessibility sizes; count only on depth
  covers), glass sharing badge, `MeshGradient` from the album's name for albums without a cover (`AlbumGradient`);
  smart album cards the same. Unit tests (gradient determinism, hue family, mesh edges). Run in the iOS 27.2 simulator,
  light, dark and Reduce Transparency (`ios-fix-shots/r7-albums/before-albums-10*`, `after3-albums-10*`,
  `dark-albums-10*`, `rmrt-albums-10*`). Smart album cards: built, not run (no smart albums on the test server). Mac
  and Vision Pro: built, not run.
- ✅ Hero headers (idea 14): albums, memories and people on iPhone and iPad (`GridHero`, `GridHeroHost` in the UIKit
  grid's content inset, `HeroSkeleton` while loading); the bar takes the title over when the hero has scrolled under it;
  stretches when pulled down (a zoom-opened screen keeps the system's pull-down-to-close instead). Unit tests
  (`HeroHeaderLayout`: heights, resting frame, stretch, collapse). Run in the simulator, light, dark, Reduce Motion +
  Reduce Transparency (`after3-albums-25…27*`, `dark-albums-21/25/26*`, `rmrt-albums-*`, `rmrt-hero-pull-stretch.png`,
  `after2-albums-32*`). People: built, not run (the test servers have no Recognize). Mac and Vision Pro: no hero by
  design (title in the toolbar, cover tint).
- ✅ Parallax (idea 15): album, smart album, memory and story cards (`scrollParallax`, a `visualEffect`; off with
  Reduce Motion). Unit tests (`ScrollParallax.offset`). Seen in the simulator recording (`after*-tour.mp4`).
- ✅ Zoom transitions (idea 8): album cards and "New in shared albums" rows → album (by value, `routeTransitionNamespace`),
  memory / story / Year in review cards → memory, person → person page, place tile → place grid, Map button → map,
  smart album cards → grid; `.crossFade` with Reduce Motion and on Vision Pro, a fade on the Mac (`CardTransition`).
  Unit tests (style per platform and Reduce Motion, which routes zoom). Run in the simulator, frames from the recordings
  (`after-zoom-album-open.png`, `after-zoom-album-close.png`, `after-zoom-memory-open.png`, `after-zoom-map-open.png`,
  `rmrt-albums-20-zoom-in-progress.png`). Person, smart album and Mac fade: built, not run.
  UI tour `UITests/AlbumsMotionTourTests.swift`.

### §17.5 Zoom levels that morph, typography
- ✅ Zoom levels that morph (`LibraryZoomMorph`, `LibraryZoomMorphLayer`): years → months → days → grid and back, by
  tap, picker and pinch; the hero card cross-fades into the card it opens; grid tiles painted over while their copies
  travel; captions fade in on landing. Unit tests `LibraryZoomMorphTests` (matching, viewport, limit, hero, pinch scale,
  Reduce Motion) and `LibraryZoomModelTests.thePhotosTravelBetweenTheLevels`. Simulator (iPhone 17, iOS 27.2): UI tour
  `LevelsTourTests.testLevelsMorph` recorded; frames of every transition in `ios-fix-shots/r7-levels/`.
- ✅ Reduce Motion: plain cross-fade, no travelling photos (simulator, recorded).
- ✅ Fix: the grid under years/months/days takes no hits and its tiles are hidden from VoiceOver (a day's photo was not
  hittable; `FeelTourTests.testZoomLevelsTour` passes again; `LevelsTourTests` checks that no grid cell is reachable
  under the days and the toolbar still is). 🟡 The Mac side (`accessibilityHidden` on the grid) builds but was not run.
- ✅ Level picker on Liquid Glass (iPhone, iPad).
- 🟡 Mac: builds, the AppKit grid reports its tile frames; the morph was not run on the Mac (screen not used).
- ⬜ A level that follows the pinch with the next level already showing underneath (scrubbing the morph with the
  fingers). Today the level follows the fingers and the photos continue from there on release. Plan: while a pinch on a
  summary level passes a factor of 1.05, mount the next level underneath (focus on the card under the fingers) with
  opacity = pinch progress, interpolate the matched photos by progress, and on release animate to 1 or back to 0.
- ✅ Typography tokens (`Typography` in `Common/Design.swift`) applied: year cards, counts, days, "+N"; album titles (two
  lines), memory card titles; Insights counts and gauge; countries count; smart album count; Then and now years; grid
  date headers (bold date, light day line, semibold moment title, UIKit and AppKit); section headings.

### §17.6 First impressions: living gradients, first launch and login
- ✅ Living gradients (§17.6.1): `LivingGradient` (wash, hero, blend) behind the grid's empty and failed states (no
  photos, offline, couldn't load, no results), no albums / no shared albums, the search start screen and "Couldn't
  search", the backup offer, the login and the welcome; the Year in Review cards' flat gradient replaced by a moving blend.
  Unit tests: mesh geometry (corners fixed, edges on their edge, seamless loop, < 0.3 % of the size per frame), the
  pausing clock, when it moves, WCAG contrast of text on every palette colour, Increase Contrast flattening.
  iPhone 17 simulator (iOS 27.2, UI test `WelcomeTourTests`): empty states light/dark/Increase Contrast
  (`welcome-20…22*`), Year in Review cards (`welcome-31…34`).
- ✅ First launch (§17.6.2): drifting wall of generated pictures under the hero blue, "Welcome to Nextcloud Photos", the
  form on a glass card (solid with Reduce Transparency / Increase Contrast). Unit tests for the wall (tiles, coverage
  at every shift, directions and speed). Simulator: `welcome-01/02-login` (the wall has moved between the two),
  `welcome-01-login-dark`, `welcome-01-login-reduce-transparency` (no wall, solid card); before: `before-login`.
- ✅ Welcome into the Library after the first login and the launch reveal (§17.6.3), `PHOTOS_DEBUG_WELCOME=login|transition`;
  `AppModel.welcomesFirstLogin` unit-tested (first account only, skippable). UI tour `WelcomeTourTests` (the Library is
  hittable while the welcome shows); screen recordings `welcome-transition.mp4` and
  `welcome-transition-reduce-motion.mp4` with frame sheets (the icon grows and fades; with Reduce Motion it only fades).
  The hold waits until the app is calm (`WelcomeTiming.holdCalmly`): on a busy cold launch the greeting was otherwise
  gone before it was seen. Screenshots in `~/aloha-work/photos-tools/ios-fix-shots/r7-welcome/` (not in the repo).
- 🟡 iPad, Mac and Vision Pro: built, not run (the Mac login card is a material panel, Vision Pro uses the window's
  glass). The search start screen with recent searches is a list and keeps its plain background.

#### Accessibility audit of motion and glass (§17.6, idea 25), on `feat/r7-base`
The base has no `glassEffect` yet; its glass is system materials (`.regularMaterial`, `.ultraThinMaterial`, `.bar`),
which follow Reduce Transparency and Increase Contrast by themselves. What does not follow the settings:

Fixed in the welcome surface:
- Year in Review page dots: 35 % white for the other cards, too faint with Increase Contrast → 60 %
  (`YearInReviewScreen.otherDotOpacity`).
- The new gradients, wall, glass card, welcome and launch reveal all follow Reduce Motion / Reduce Transparency /
  Increase Contrast (§17.6). The existing Year in Review count-up and card stepping, the skeleton pulse and the backup
  offer already did.

For the other surfaces (file:line on `feat/r7-base`; the owner fixes them in parallel):
- viewer — `Viewer/ZoomablePhoto.swift:68` (Live Photo playback toggle animated without a Reduce Motion check; fade
  only, low priority); `Viewer/SlideshowPlayer.swift:355` and `Look/GuestModeViews.swift:438` (black 45 % control
  backgrounds over photos, not stronger with Increase Contrast — `OverlayLegibility.scrimOpacity` as in
  `MediaViewer.swift:806`); `Look/GuestModeViews.swift:462` (paging animated with the default animation, movement with
  Reduce Motion).
- grid — `Timeline/GridStatus.swift:141/151/211` materials are fine; nothing found besides what §17.2 changes.
- levels — `Timeline/LibraryZoomLevels.swift:481` (pinch spring-back `.smooth` without a Reduce Motion check).
- chrome — `Search/CommandPaletteView.swift:95/99` (palette scales in from 96 % without a Reduce Motion check;
  `Color.black.opacity(0.12)` dimming is fine); `Discover/MemoriesStrip.swift:75` and `Discover/MemoryStories.swift:159`
  (strip ↔ stories switch with the default animation).
- albums — nothing found in `Albums/` (only `.ultraThinMaterial` badges).
- platforms (Mac) — `Culling/LoupeCulling.swift:687/690` (the Mac loupe's zoom toggle animates without the Reduce Motion
  check the iOS path at :488 has), `:874` (filmstrip scroll animation), `:910` (black 60 % badge).
- no owner in round 7 (listed for a later round):
  - `Family/PostcardViews.swift:231/235/348/355/357/374` — the sent postcard flips in 3D, its stamp scales in from 240 %
    with a bouncy spring, the share bar moves in from the bottom: no Reduce Motion check at all (should cross-fade).
  - `Discover/TravelScreens.swift:273/416/420` — map camera flights of 1.2–1.5 s without a Reduce Motion check (should
    jump or use a short fade).
  - `Discover/ThenAndNowScreens.swift:385/593` — alignment and year changes animated `.smooth` without a check.
  - `Discover/MemoryStories.swift:173/178` — the next story card slides to the front with `.smooth`, no check.
  - `Extras/CollageEditor.swift:521/553/561` — theme, shuffle and remove animated with the default animation (tiles
    move) although the file checks Reduce Motion elsewhere.
  - `Insights/InsightsScreen.swift:231`, `Discover/MapScreen.swift:112` — expand/collapse animated, no check (minor).
  - `Organize/BatchFixSheet.swift:193`, `Import/WelcomeHomeView.swift:109/221` — `symbolEffect(.bounce)`: to check in
    the simulator whether the system tones the bounce down with Reduce Motion; if not, skip it then.
  - Translucent backgrounds that stay the same with Increase Contrast / Reduce Transparency (should use
    `OverlayLegibility.scrimOpacity`): `Discover/WatchTogetherViews.swift:123` (50 %),
    `Discover/ThroughTheYearsScreens.swift:749`, `Discover/MemoryFilmPlayer.swift:350/613`,
    `Discover/MemoryStories.swift:384/407` (35–45 %), `Backup/BackupDeviceViews.swift:112`,
    `Import/CardImportSheet.swift:422` (55 % badges).

### §17.7 Mac and Vision Pro polish
- ✅ Mac, photos under the toolbar: the grid reaches under the unified toolbar and scrolls under it with the system's
  scroll edge effect; first row and pinned headers stay below it. Run on the Mac (AX scrolling + `screencapture -l`):
  `ios-fix-shots/r7-platforms/after-mac-photos-top.png`, `after-mac-photos-scrolled.png`, `after-mac-light-scrolled.png`
  (before: `before-mac-library*.png`). In the Library the memories strip stays above the grid (unchanged).
- ✅ Mac, tiles lift under the pointer (`GridHoverLift`): run on the Mac with `PHOTOS_DEBUG_GRID_HOVER=x,y` (the pointer
  cannot be moved for checks): `after-mac-hover-lift.png`. Unit tests (`GridLiftMetrics`). Reduce Motion: shadow only
  (by code, not run).
- ✅ Mac, smooth trackpad zoom (`GridPinchZoom`, `GridPinchScaler`): run on the Mac with `PHOTOS_DEBUG_GRID_PINCH=…`
  (synthetic magnifications through the same code as the gesture): half way in `after-mac-pinch-halfway-in.png`, across
  a step and on `after-mac-pinch-step-then-hold.png`, half way out `after-mac-pinch-halfway-out.png`. Unit tests (scale
  maths, steps, snapping, rubber band). A real trackpad pinch and the haptics: not run (no real input on this Mac).
- ✅ Mac, sidebar and glass toolbar items: the system's own (translucent sidebar material, glass toolbar capsules);
  checked in Light and Dark Mode, nothing app-made over them.
- ✅ Mac viewer: opening the viewer hung the app at 100 % CPU (since round 6's ⌘K button): the window read the focused
  grid's actions (`@FocusedValue(\.gridActions)`, a struct of closures that is never equal) for the toolbar's palette
  button, so each update of the viewer re-rendered the window, which published new actions again. The button reads the
  focused value itself now (`FocusedCommandPaletteButton`). Run on the Mac with `PHOTOS_DEBUG_VIEWER`: CPU at 0–1 %
  with the viewer open, toolbar complete (`~/aloha-work/photos-tools/r7merge/mac-viewer-fixed.png`).
- ✅ Vision Pro, glass ornaments: the viewer's actions, a grid's selection actions (`.bottomOrnament`) and the
  slideshow's playback controls (`slideshowControls`) under the window. Run in the visionOS 27.2 simulator by the new
  UI tour `PlatformsTourTests.testOrnaments` (passes): `ios-fix-shots/r7-platforms/vision/after-vision-selection-ornament.png`,
  `after-vision-viewer-ornament-more-menu.png`, `after-vision-slideshow-ornament.png` (before: the actions were in the
  window's top bar, the slideshow bar over the photo).
- 🟡 Vision Pro, tile lift (`UIHoverStyle(.lift)`, rounded 6 pt) and viewer chrome depth (`offset(z:)` 24 pt): built,
  not seen — the simulator shows no gaze hover in screenshots, and the previous/next buttons only appear under a
  pointer.
- Note: incremental visionOS-simulator builds of the app fail with "Cycle inside NextcloudPhotos" (CodeSign of the app
  bundle, Xcode 27.2); clean builds (new DerivedData) work.

## M9 Caching for the photos that matter (SPEC §18) — ⬜

### §18.1 Loading and measuring
- ✅ One cache key per photo (§18.1.1): the pipeline fills an empty ETag from the library (`setEtagProvider`,
  `LibraryStore.etag(of:)`), so covers, memories, places and the other file-id-only callers read the grid's cache files.
  Unit tests (`LoadPathTests`: a cover after a grid load is a disk hit, and the reverse; `EtagLookupTests`); measured
  in the simulator (§18.1.4: covers served from the device 22 % → 45 %). Unused `PhotosAPI.previewBucket` removed.
- ✅ Viewer neighbours (§18.1.2): 1024 px of n±1 and n±2, the paging direction first, decoded from disk or downloaded,
  taken back when paging away or closing (`ViewerNeighbourPrefetch`, `ViewerPrefetchPlan`, `prefetch(_:decode:)`);
  the best picture on the device at once (`placeholder(for:)`). Unit tests for order, cancel, decode and placeholder;
  measured in the simulator (§18.1.4: without smart offline at 2 s per photo, 1024 px from memory when shown 9 % →
  58 %, pages sharp while shown 7 → 9 of 9). The 4096 px prefetch ran there (8 loaded, after 1.5 s); its delay is now
  3 s (not re-measured). 🟡 Zooming into a prefetched 4096 px preview was not exercised in a UI test.
- ⬜ The SwiftUI scroll-target trap of §M8 (`ResolvedScrollBehavior.updateTarget`) hit 2 of 4 runs of the measurement's
  first phase while the Library scrolled (crash logs in `~/Library/Logs/DiagnosticReports/Nextcloud Photos-2026-11-2*`);
  not caused by M9 (also in the build without it), not investigated here.
- ✅ Measuring (§18.1.3): `CacheMetrics` (layers × buckets, prefetch apart, p50/p95 ring buffers), os_signpost
  intervals "Preview", "Tile", "Viewer", Settings › Server › Cache performance (shots
  `ios-fix-shots/r8-load/*-metrics*.png`). Unit tests (`CacheMetricsTests`). 🟡 The signposts were not looked at in
  Instruments (no interactive Instruments session here); 🟡 Mac and visionOS builds of the screen not run.

### §18.2 Importance-aware cache
- ✅ Recently viewed (`CacheImportanceStore`, table `recentlyViewed`, newest 2000, migration `v8-cache-importance`): a
  photo shown ≥ 1 s in the viewer is recorded (`AccountServices.viewerShows`, one `.task` line in `MediaViewer.swift`).
  Seen in the iPhone 17 simulator against the 8089 library: paging through 31 photos with the UI tour
  `CacheEvictTourTests.testViewingAndZooming` recorded 31 rows (the tour's "quick" swipes still take 1.1 s each, so
  "shorter than a second records nothing" is only unit-tested).
- ✅ `CacheImportance` (PhotosDomain): one scorer for smart offline (old scores unchanged, now also viewed, memory covers,
  key photos, covers, faces) and for disk eviction (tiers, LRU within a tier). Seen in the simulator: 387 key photos
  (`LibraryZoomModel`) and 12 memory covers (`MemoriesStrip`) recorded; smart offline then kept 7 photos as memory
  covers and 2 as viewed besides 34 recent and 2 On this day. Unit tests: ordering; 100 000-photo library tiers + ETags
  < 3 s in a debug test (1.7 s with inserting the rows); 100 000-file eviction plan 0.26 s (debug).
- ✅ Per-size pools (thumbnails / screen / large ≤ 300 MB, 15 %), default limit from free space (512 MB – 4 GB), the
  user's limit is the total, whole-library contract (`CacheLimits.wholeLibraryThumbnailsKey`, unit-tested only until
  the filler sets it). Seen in the simulator on the real cache after the tour (38 thumbnails 0.63 MB, 24 screen 3.50 MB,
  6 large 4.61 MB) with `previewCacheLimitBytes` = 5 MB and a relaunch: kept all 38 thumbnails and all 24 viewer
  previews, removed the 6 zoomed-in previews; the old single LRU (simulated on the same files) would have kept 3
  thumbnails, 9 viewer previews and 4 large ones. Settings › Storage shows "4.1 MB, up to 4.29 GB"
  (`ios-fix-shots/r8-evict/settings-20-settings-storage.png`).
- 🟡 Memory pressure: own LRU (`MemoryImageCache`) and `MemoryPressurePolicy` replace `NSCache` and clear-all; viewer
  photo ± 1 and covers/key photos protected; on iPhone/iPad/Vision Pro the background does a warning's relief.
  Unit-tested; not observed under real memory pressure (the simulator's "memory warning" is a UIKit notification, not
  the dispatch memory-pressure source; plan: Instruments on a device, or a debug hook that calls `relieveMemory`).

### §18.3 Filling the cache
- ✅ §18.3.1 Thumbnails of the whole library (Settings › Storage › Thumbnails, on by default on the Mac): seen on the Mac
  (fix build, 8089 test library, Low Power Mode ignored through the debug variable `PHOTOS_DEBUG_FILL_IGNORE_LOW_POWER`
  because the test Mac is in Low Power Mode, which correctly stopped every fill before). 509 of 513 photos filled
  (4 previews the server could not render stay "remaining"): 256 px 5.1 MB (10.1 KB a photo), 64 px made on the device
  1.2 MB (2.3 KB) — 12.4 KB a photo, as estimated. The pass downloaded 383 previews in 576 s while three other agents
  loaded the same PHP server (1.8 s a preview). Progress row seen filling and nearly done:
  `ios-fix-shots/r8-fill/mac-settings-thumbnails-filling.png`, `mac-settings-thumbnails-done.png`. Unit tests: filling,
  resuming, 64 px made offline, cellular/Low Power/off, waiting while the pipeline loads, estimate.
- 🟡 Estimate row (setting off) and "Use cellular data" (iPhone/iPad): built, unit-tested, not seen (the Mac's default is
  on; no simulator run in this round). Plan: one look in the `r8-fill` simulator.
- 🟡 Evict side of the contract (thumbnails not trimmed while on): §18.2's part, to check after merging.
- 🟡 §18.3.2 Preparation before the app opens: runs and plans as specified in unit tests (two screens at the grid's bucket,
  album cover and first screen, skipped on cellular and in Low Power Mode, cached files skipped). On the Mac the debug run
  (`PHOTOS_DEBUG_FILL_NOW=1`) ran it: "33 present of 100" with the timeline already shown and nothing downloaded in Low
  Power Mode — not yet seen downloading before a launch. iOS: folded into the existing refresh task (no new task
  identifier); background tasks cannot be triggered here. Plan: in the simulator, `e -l objc -- (void)[[BGTaskScheduler
  sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.nextcloud.photos.refresh"]`, then open the app with the
  network off and compare placeholders. Memory covers only hit once §18.1's one-cache-key change is merged.
- ✅ §18.3.3 HEIC storage, measured: transcoding the server's JPEG previews does not pay (equal size at −0.65 dB, see
  SPEC); PNG previews are stored as HEIC. Seen on the Mac: 4 PNG photos of the test server kept by smart offline as HEIC,
  5.34 MB of PNG previews → 0.51 MB (9.6 %); the 134 JPEG previews (60.9 MB) unchanged, so the test library (all JPEG)
  saves 0 %. Lazy migration of kept PNG previews unit-tested (converted without network, row and lookup updated, old
  file removed, JPEGs looked at once).
- ⬜ HEIC for PNG previews in the pipeline's 1024/4096 cache files: plan in SPEC §18.3.3 (background conversion, not on the
  load path).

## M10 Simpler navigation (SPEC §19) — ⬜

### §19.1 Sidebar
- ✅ Mac (run, AX only, light and dark; `ios-fix-shots/r9-sidebar/`): slim sidebar — Library, Favorites, Memories, Places
  (People without Recognize is left out), Albums with the top albums listed and All Albums, Shared, Utilities collapsed
  (Folders, Tags, Archive, Recently deleted, Clean up, Insights, Stickers); compact account row at the bottom.
- ✅ Mac: Photos/Videos open the Library with that filter shown in the toolbar (`PHOTOS_DEBUG_DESTINATION=videos`); Map opens
  Places on its map, "Map | Grid" switches to the place tiles; Shared shows "Shared with you" on top (also over its empty state)
  and pushes it with Back; Duplicates opens Clean up with Utilities expanded; the album rows open their album.
- ✅ Mac: Edit Sidebar sheet (`PHOTOS_DEBUG_EDIT_SIDEBAR=1`): hiding a row, pinning a utility and Restore Defaults change the
  sidebar at once. 🟡 The rows' context menus, dragging pinned rows, View ▸ Edit Sidebar… and the account menu's items were
  not opened (they need real input or a key window); built and their logic unit-tested.
- ✅ Logic unit-tested (`SidebarTests`, `CompactNavigationTests`): where every destination opens, the highlight, the request
  that rebuilds the Library/Places/Clean up, pin/unpin/hide/reorder, storage of the customization (unknown rows dropped), the
  top albums, initials, the Go menu's fixed ⌘1…⌘9.
- ✅ iPad (iOS 27.2 simulator, iPad Pro 13-inch, landscape; `IPadTourTests.testSidebarDestinations` passes,
  `ipad-dest-*.png`): Browse (Favorites, Memories, Places), Albums (All albums, Shared with "Shared with you" on top),
  Utilities with Clean up, Insights, Stickers, Backup; every row opens its screen. `TabViewCustomization` per device
  (`@AppStorage`), Restore Default Sidebar in the menu of the account row at the bottom of the sidebar 🟡 (built, not opened). Vision Pro 🟡 (built).
  The top albums are not listed in the iPad sidebar (tabs need one selection type; album tabs would leave stale ids in the
  customization) — left for later.
- 🟡 Clean up row: routes to Duplicates / Free up server space until `CleanUpScreen(initialSection:)` (§19.3, its own branch)
  is merged; the destination request carries the section (`DestinationRequest.cleanUpSource`).

### §19.2 Toolbars
- ✅ No ⌘K button in the window toolbar; Go ▸ Quick Actions… ⌘K stays (seen in the Mac's menu bar; the same
  `PhotosCommands` give iPad, iPhone with a keyboard and Vision Pro the key). The Search tab keeps its ⌘ button.
- ✅ One filter menu (`LibraryFilterMenu`): Show (All Items/Photos/Videos/Favorites), Ratings and Flags (with
  Auto-Advance and Delete Rejected…), Hide partner photos (with partner folders; not on the test server, so not seen),
  Clear all filters; filled symbol + count badge while on; a chip per filter clears it (`LibraryFilterChips`) — seen on
  the Mac, iPhone 17 and iPad (UI test `ToolbarsTourTests` taps Favorites and the chip). `TimelineScreen(initialKind:)`
  for §19.1; debug builds: `PHOTOS_DEBUG_LIBRARY_KIND=favorites`. Unit tests: `LibraryToolbarTests`.
- ✅ One zoom control: the Mac's slider and step buttons removed (⌘+/⌘−, View menu, pinch remain).
- ✅ Upload only when needed: no upload button in the Library's toolbar; File ▸ Upload Photos… now ⌘U (was ⇧⌘U) and drag
  and drop on the Mac; the account menu's Upload submenu and the Collections tab's "+" (New album…, Upload) on iPhone and
  iPad (menus seen; the pickers not opened). 🟡 The uploads indicator only while uploads run or some failed
  (`TransfersIndicatorState`, unit-tested; no upload run in this round).
- ✅ Mac viewer: favourite, info, share, edit, More (with Delete…), no ⌘K — seen in the Mac app (AX tree and window
  shots); ⌫/⌦ delete after asking (unit-tested key routing, not pressed: no real input). 🟡 Vision Pro ornament: same
  order, Delete in More (built, not seen).
- ⬜ Mac viewer without the window's search field: `toolbar(removing: .search)` does not remove a split view's
  `searchable` on macOS 27.2 (tried on the viewer and the detail column; SPEC §19.2). Plan: a toolbar search field of our
  own that the viewer leaves out, or a later SwiftUI.
- ✅ Three tabs on iPhone (Library, Collections, Search); Settings is a sheet from the account button
  (`AccountMenuButton`, initials avatar) after Select in the Library's top bar and in Collections', also on iPad (seen:
  iPad tab bar is Library + Search). Links and the palette open the sheet (🟡 not run). UI tests use
  `XCUIApplication.openSettings()` instead of the Settings tab.
- ⬜ Filters for edited photos or RAW files: need new conditions in the grid query (`LibraryStore.sql`).

### §19.3 Clean up
- ✅ One Clean up screen (`CleanUpScreen`): headline "Up to X can be freed" (each file counted once), sections Duplicates,
  Similar shots, Large videos, Screenshots and screen recordings with count, size and small previews, each opening its
  review screen; on iPhone/iPad "Free up space on this iPhone/iPad" with the device's available storage. Seen on the
  Mac (light and dark), iPhone 17 and iPad Air simulators (iOS 27.2) with the test server; UI tour
  `CleanUpTourTests` passes on both (links land in Clean up, rows open their screens, device row present). Shots in
  `ios-fix-shots/r9-cleanup`. Built for macOS, iOS, visionOS, tvOS and watchOS.
- 🟡 Similar shots across the library (`SimilarShots`, `SimilarityStore.similarShots()`): series by time and sketch
  similarity, copies of one shot (HEIC+JPEG, same file twice) never offered against each other, best shot kept with
  its copies, choose another, delete the rest (server-delete confirmation); compares cached previews while open. Unit
  tests (`SimilarShotsTests`, `SimilarShotsStoreTests`, `CleanUpTests`). The screen was seen on the Mac with a series
  of three test shots whose sketches were written into the test build's database: the Mac was in Low Power Mode, so
  the app (correctly) compared nothing itself. Comparing real previews end to end is not seen yet.
- ✅ `AppDestination.duplicates`/`.freeSpace` (deep links, palette, Go menu) open Clean up at their section
  (`CleanUpSection.opened(by:)`), unit-tested; `FreeSpaceScreen(categories:)` shows one section's categories.
- ⬜ The sidebar row `.cleanUp` comes with §19.1 (sidebar package); until that is merged the Utilities rows Duplicates and
  Free up server space both open Clean up.

## M11 Stabilization (SPEC §20) — ⬜

### §20.1 Visible bugs
- ✅ Mac sidebar symbols: cause found — the launch reveal faded/scaled the split view in one animated transaction and
  sidebar rows built in it kept their symbols at that moment's opacity (Library half drawn, the rest invisible), only on
  some launches. Now only a cover above the content fades (`LaunchReveal`). Mac test build on the 8089 server: original
  2 of 2 launches without symbols, first fix (cover + scale) 2 of ~10, final 0 of 9, no reveal at all 0 of 6; light and
  dark, selected and unselected rows, window not key (shots `ios-fix-shots/r10-fixes/01–06`, trial crops in
  `~/aloha-work/photos-tools/r10/fixes/trial-*.png`). 🟡 Window key (needs real input) and the iPad sidebar not seen
  (the iPad has the same reveal and fix; the debug login did not take on a plain `simctl launch`). 🟡 The final Mac build
  (strip with content margins) was built but not looked at: the screen locked before the last launch.
- ✅ Photos without a server preview: `PreviewFailureLog` in `ImagePipeline` (asked again after a sync and a backoff of
  2 min → daily; a new ETag at once; network errors do not count); tiles show symbol, name, "No preview" (VoiceOver
  too); the viewer page says so (`ViewerNoPreview`). Unit tests: log rules, pipeline asks the server once for a 404 file
  across shows, sizes, prefetch and a sync within the backoff (`PreviewFailureTests`), tile states (`GridCoreTests`).
  Seen on the Mac with the test library's `evil.jpg`/`party.jpg` (shots 07, 08). 🟡 iPhone/iPad tiles: built and run in
  the UI tours, not looked at in a shot.
- ✅ Previews made on the device (polish, SPEC §20.1 item 7): images from the original (≤ 50 MB, ImageIO, downscaled),
  videos from one frame read in byte ranges through the account's DAV client (≤ 16 MB, never the whole file), stored
  once for every bucket up to 1024 px under the preview's key; `has-preview: false` skips the 404; Low Data Mode
  downloads nothing and retries when it ends; the viewer says why a file has none (`NoPreviewReason`). Unit tests
  (`DevicePreviewTests`, 10 + 1 in `PreviewFailureLogTests`): HEIC decoded once and on disk at 64/256/1024 with no
  request for a cover at 1024; a TIFF with `has-preview: false` asks no preview; a cover without URL finds its original;
  the 24-byte JPEG stays unreadable and is not asked again; an 80 MB original is not downloaded ("too large"); Low Data
  Mode; a 6 MB QuickTime movie gives its frame after reading 1.06 MB (index at the end) / 1.3–1.6 MB (fast start);
  a 64 KB limit stops after ≤ 64 KB in < 3 s; WebM is not read. iPhone 17 simulator on 8089: `NoPreviewTourTests`
  (uploads its own HEIC and QuickTime clip, which the server has no preview of: no HEIC/Movie provider) 2 of 2 passed,
  both tiles and the viewer show the pictures (shots `ios-fix-shots/r10-polish/nopreview-01/02`). Why the test
  library's two files have none: they are 24 bytes (JPEG header, no image data; SPEC §20.1 item 7) — they stay "No
  preview", correctly. 🟡 Mac, iPad, Vision Pro: built, not run with such files; a real 4K HEVC clip from a phone not
  tried (the frame of an H.264 1080p 30 MB clip was not measured against a server: the PHP test server keeps no access
  log).
- ✅ Places card caption (polish, item 6): not truncated but covered by the floating tab bar's glass (the card is the
  last of the iPhone's first screen of Collections); now at the top of the map. Album rows are plain `HStack`s: titles
  at accessibility sizes are no longer cut to the first card's height. `ScreensTourTests.testCollectionsCaptionsIn
  GermanAndLargeText` (German, English and German at AccessibilityXXXL, first screen and scrolled): passed 2 of 2 (the
  first run, before the `HStack` fix, showed "Fa- vo…"/"r7- grid-…" in its shots: that is how the cut titles were found);
  shots `screens-30/31-*` (before: `before-screens-01-collections.png`, "411 phot…" under the bar; the r10-combined
  XXXL shot had "r7-gr…").
- ✅ Favorites cover (polish, item 8): newest favourite (`LibraryStore.observeNewest(.favorites)`), small heart on the
  caption, a heart badge at accessibility sizes, the gradient without favourites. Seen in the shots above (8089:
  newest favourite of the test library). 🟡 The empty case (no favourites) not looked at: the test library has 59.
  Sidebars (iPad, Mac) keep their heart symbol rows, as Apple's; no other Favorites cover exists. Unit tests
  `FavoritesCoverTests` (follows the newest favourite, nil without favourites, hidden folders and archive left out).
  Polish round on the iPhone 17 simulator, 8089, final code: `SmokeTests` 7 of 7, `ScreensTourTests` 4 of 4,
  `NoPreviewTourTests` 1 of 1 in one run.
- ✅ Story snapping on iPhone/iPad without a scroll target behaviour: on the scroll phase's end the strip scrolls
  (`ScrollViewReader`) to the card `MemoryStorySnap` picks (compact: one card on in the swipe's direction if flung or
  dragged ⅓, else back; wider and stray rests: nearest); cards rest at the 12 pt content margin. Unit tests
  (`MemoryStorySnapTests`); iPhone 17 simulator, 8089: `StorySnapTourTests` (short drag back, fling, 3 × fast/slow/back
  swipes, each checked to rest at the margin) passed 2 of 2 (final code; an earlier run without a proxy found the missed snaps); the trap does not return: `CacheMeasureTests/test1Grid`
  3 of 3 passed (and 3 of 3 with the first version), `GridMotionTourTests` 7 of 7 passed (twice). 🟡 iPad and Vision Pro (wide layout: nearest card) not run.
- ✅ Undo of a delete whose DELETE failed after reaching the server (timeout/5xx): `DeleteWithdrawal.maybeSent`, restored
  from the trash bin (unit tests `OutboxBulkAndUndoTests.aDeleteThatFailedAfterReachingTheServerIsMaybeSent`,
  `SessionUndoTests.undoOfADeleteWhoseAnswerFailedRestoresFromTheTrashBin` — fails without the fix). `UndoDeleteTourTests`
  (own uploaded photos, checks the server): NC 35.0.3 (port 8099, own throw-away server) 3 of 3 passed (also before the fix: not reproduced); 8089 3 of 3 passed.
  The reported failure (photos left in the trash on NC 35 in the health tour) was not reproduced here; the trash bin API
  answers the same on NC 35.0.3 and 36 (probe with curl: same `oc:fileid`, restore `MOVE` 201). The fix closes the gap that
  matches it on a loaded server; 🟡 if it shows again, the tour's shots and the server's access log will tell which case.
- ✅ Mac memories: compact band (128 pt cards, was 210), "› Memories" title line folds it away (remembered,
  `memoriesCollapsed`), folded line shows the first memory; the line is in a non-scrolling scroll view so the toolbar's
  scroll edge effect does not blur the grid's first header (seen and fixed). Shots 12 (expanded), 13 (folded), folded and
  unfolded through the accessibility API.
- ✅ iPhone: a grid opened from the Collections tab (Favorites, Folders with photos — any place pushed there by value)
  hung the app at 100 % CPU (found by the servers pass, §20.2). Cause: `RouteView` gave the pushed `DestinationView`
  `.constant("")` / `.constant([])` search bindings, and SwiftUI counts a constant binding as changed at every update.
  So the screen ran its body each time its navigation host handed the environment down again, rebuilt the grid screen,
  and the rebuilt grid laid the stack out again, which handed the environment down again — all inside one Core
  Animation commit, so the main thread never returned to the run loop. Evidence: `_printChanges` showed
  `DestinationView: _searchText, _searchFilters changed` ~6000 times in 30 s with nothing above it re-rendering;
  `-UIViewLayoutFeedbackLoopDebuggingThreshold 100` showed the scene's hosting view re-applying the environment to the
  pushed grid's host in every pass. Albums, memories and `.folder` routes have no `DestinationView`; the Library's has
  real bindings — hence only Collections. Bisected in the iPhone 17 simulator (iOS 27.2) on Nextcloud 33 (8095):
  loop in every run with the constant bindings (9); idle (0.4–0.9 %) with real bindings in the 7 runs of the final
  builds, and with the folder screen pushed without `DestinationView` (2 of 2). Two early instrumented runs looped
  with real bindings too, while they had a debug `@Environment(\.self)` in `DestinationView`, which re-renders it at
  every hand-down the same way. Switched off one at a time, the loop stayed: the grid's focused actions, its toolbar
  (and, by the servers pass, the folder strip, the tab bar's minimizing and accessory). Fix: `RouteView` owns real
  (unused) bindings. Favorites opens in
  the Collections stack again (the Library-filter route of §20.4 was only the workaround; reverted).
  `UITests/CollectionsGridTests` (folder, Favorites, album, memory from Collections; a tap on a tile must open the
  viewer within 15 s, idle wait included): 4 of 4 on 8095 and 4 of 4 on 8089 (fresh install; Favorites with 59
  photos), the folder test fails without the fix (UI query timed out, the app never idle); longest wait for idle 4.4 s
  (60 s without the fix). CPU after opening Folders (8095) 0.4–0.7 %, Favorites (8089) 1.5–3.4 %; shots
  `ios-fix-shots/r10-gridloop/`.
- 🟡 UIKit's "Observation tracking feedback loop detected!" (`com.apple.UIKit:Assert`): not this hang — still logged
  after the fix (36–200 times per UI-test launch, in the first two seconds after launch, in the Library), never on a
  plain `simctl launch` (0 in 30 s), so it comes with XCUITest's accessibility automation; the sampled invalidations
  (66, `UIObservationTrackingInvalidated`) are all UIKit's own `_executeUpdateProperties`, no frame of the app. Plan:
  catch `UIObservationTrackingFeedbackLoopDetected` with the debugger attached from the first instruction of a UI-test
  launch (the burst ended before an attach could take). Also logged: SwiftUI's "FocusedValue update tried to update
  multiple times per frame" (the grid's `GridActions`, a struct of closures that is never equal; harmless on iPhone).

### §20.2 Servers
- ✅ Test servers: Nextcloud 33.0.11 (Photos 6.0.0) on 8095 and 34.0.6 (Photos 7.0.0) on 8096 from the release archives
  (`scripts/test-server.sh` with `NEXTCLOUD_ARCHIVE`), each with the sample files, a copy of the 448-photo test library
  (metadata refreshed per file, docs/TESTING.md) and the albums "Lisbon 2025" and "Rome 2021".
- ✅ Protocol probe of 8093 (stock), 8091 (extended), 8095 and 8096 (capabilities, initial state, every DAV collection and
  property the app reads, SEARCH by capture time, PROPPATCH of favourite / metadata / Live Photo link, preview sizes,
  chunked upload v2, auto-MKCOL, trash and restore, Login Flow v2). The differences are the matrix of SPEC §20.2; the
  only one that matters for the app is metadata editing (500 before Nextcloud 35), which the app already avoids there.
- ✅ Integration tests (23 each) pass against 8093, 8095 and 8096; the detection test also against 8091 (11 extended
  features found, each checked against the server). On 33/34 the metadata round trip skips itself (no `metadataEdit`).
- ✅ iPhone simulator, stock Photos (the 8093 installation, through a second listener on 8097 that logs every request):
  launch, Library and date scrubber, selection and context menu, viewer, Collections (no People without Recognize),
  Settings (Notifications explains that the server has no Notifications app), Search, a memory, every link destination,
  Clean up (both entry points), Travel globe and Countries ("33 places have no country on your server" + Apple Maps
  lookup offer), smart album builder (saved, deleted), batch fixes sheet, the editor with undo history (recipe written to
  and removed from `/.nextcloud-photos/edits/`), Settings › Storage. The request log shows no failing call of the app
  apart from the expected probes (404 for `timeline/days`, `recognize/`, app data files not made yet) and the previews of
  the two photos the server has none for (§20.1).
- ✅ iPhone simulator, Nextcloud 33: smoke tests, the phone tour (8 of 9, see below), Clean up, the Library's top bar and
  filter menu, Travel and Countries, the editor, the smart album builder, the batch fixes sheet; batch fixes applied to
  own copies: +1 h and Undo written into the files (see §16.4 above), rename `{date} {place} {counter}` and Undo (MOVE).
- ✅ iPhone simulator, Nextcloud 34: smoke tests, the phone tour (8 of 9, the same Folders hang), Clean up, the Library's
  top bar, the editor, the smart album builder, the batch fixes sheet. 🟡 Travel did not open once (the Collections row was
  not found in time; the same tour passed on 33 and stock) and the batch fixes were not applied there (the run was
  stopped); 34 answers the metadata PROPPATCH like 33 (500), so the app takes the same file-writing path.
- ✅ Links to a screen the server cannot fill (People without Recognize, Tags without the tags app, Recently deleted
  without the trash bin) now explain it in an alert instead of doing nothing (`UnavailableLinkAlert`, unit-tested; seen
  in the simulator on stock and Nextcloud 33: "People Isn't Available — This needs “Recognize (faces)” …").
- ✅ Tags screen: empty state "No tags yet" on a server without tagged photos (it showed only its title on 33/34).
- 🟡 Mac test build against stock: signs in, detects core features only, indexes the 503 items (410 with a place, 501
  with a BlurHash); the screens were not seen: the Mac's screen was locked during the run (screenshots black, the window
  has no accessibility tree). Not run against 33/34 (one container per test build).
- ✅ Found on the way, not server-specific — **iPhone hung (100 % CPU, main thread) on a grid screen pushed in the
  Collections tab**: Favorites, and Folders on a folder with photos (on 33/34 the root has `Nextcloud.png` and an MP4, so
  Folders hung there; on a real server any folder with photos would). `Self._printChanges()` showed `FoldersScreen` /
  `MediaGridScreen` re-created thousands of times a second from `DestinationView` (its bindings "change" each time).
  Cause and fix in §20.1: the pushed `DestinationView` had constant search bindings. Evidence of this pass in
  `ios-fix-shots/r10-servers/grid-loop/`.
- 🟡 UI tour failures that are test isolation, not servers: the app restores the last screen at every launch (scene
  storage), so tours that expect the Library after another tour left it elsewhere fail (stock run: Toolbars, story cards,
  viewer, Settings › Storage, Then and now — the same tours pass on a fresh installation, as on Nextcloud 33). The tours
  should start from the Library (health, §20.5).

### §20.3 Accessibility and German
- ✅ Accessibility audits (`UITests/AccessibilityAuditTests`, 13 tests): every main screen at the default size and at
  AX5, iPhone 17 simulator (iOS 27.2) against the 8089 test library: all pass with the policy of SPEC §20.3; the
  findings per screen (accepted ones with their reason) are in `ios-fix-shots/r10-a11y/run3/*-audit.txt`. iPad: see
  below.
- ✅ Fixed from the findings: accent colour #00679e in light mode (#00507a with Increase Contrast; `AccentPaletteTests`;
  kept by the owner's decision of 2026-11-27),
  text on glass in the text colour (caption plates, viewer pill), the viewer's action bar targets (44 points), account
  avatar, Settings' current-account check mark, the iPad's info inspector (thick material behind the info, prominent
  section headers), the year in review cards' year (scales with the text size), the close crosses of the weekly prompt and family suggestion cards.
- ⬜ Memory captions on photos (story cards in the Library, memory cards): the audit measures the white caption against
  the photo where the scrim is thin, and the story card's text stops at xxLarge (fixed card height; the full text is in
  its VoiceOver label). Plan: a scrim that reaches higher under the title, and at accessibility sizes the caption below
  the card as album cards do (SPEC §17.4). Accepted in the test as an open item until then.
- ⬜ The iPad sidebar's account line (server name) is secondary text on the sidebar's glass, 3.5:1 over the photos
  behind it. Plan: the text colour at a smaller size, as done for the caption plates (`SidebarViews.swift`, left to the
  sidebar's rendering work of §20.1 to avoid a conflict). Accepted in the test as an open item.
- 🟡 VoiceOver walk: element order and labels read from the accessibility trees of every audited screen (tiles "Photo,
  date, place…", story cards with adjustable action, viewer: close, date pill (header), previous/next, action bar);
  rotor actions (tile custom actions, viewer's favourite/info/delete) checked in code, not with VoiceOver itself, which
  the simulator does not run.
- ✅ German mechanics: no user-visible literal outside the catalogs (scan of all SwiftUI/Foundation calls with literals
  for `bundle: .module`); no hand-built date or number format in the UI (the fixed formats are file names, EXIF and
  server values in `en_US_POSIX`); date ranges through `DateRangeLabel`; English plural variations added where a count
  can be one (`LibraryMomentsTests` checks "1 day in Lisbon"); the iOS- and visionOS-only strings that were missing
  from the PhotosAppUI catalog added; composite texts verbatim. ✅ German run (iPhone simulator, survey of Library,
  viewer, Settings, Memories, Collections, Clean up: `ios-fix-shots/r10-a11y/german/`) and doubled texts (`double/`,
  `double2/`): the zoom picker overflowed and now fits. 🟡 Mac in German: the build was run, its window titles read
  through the accessibility API; window screenshots failed (screen locked). iPad in German: Library, viewer and info,
  sidebar (`german/de-ipad-*`), no new findings.
  "25. Nov 2026 at 15:07" is Foundation's `en_DE` format
  (English language, German region), correct system behaviour; it becomes "25. Nov. 2026, 15:07" once there is a `de`
  localization. ⬜ Translations: Transifex (LOCALIZATION.md); the repo has no `de` pattern yet, so none was added.

### §20.4 Screens
- ✅ Collections on iPhone is an overview of shelves (Albums with Favorites, Memories, People where Recognize is there,
  Places as a map snapshot with dots, Shared, then Utilities + Backup as compact rows), seen in the iOS 27.2 simulator
  (iPhone 17 Pro, test library on 8089; shots `ios-fix-shots/r10-screens/screens-0*`). An album opened from its cover is
  pushed on the overview and Back returns to Collections (`ScreensTourTests.testCollectionsShelves`). Logic unit-tested
  (`CompactNavigationTests`: shelves, paths, people order, map region, reload key). 🟡 People shelf not seen (the test
  server has no Recognize); 🟡 narrow iPad window, Vision Pro, Reduce Motion/Transparency and Dynamic Type sizes of the
  overview not run (compiled; the cards are the ones of Albums/Memories that handle them).
- ✅ Fixed: Favorites opened from Collections hung the iPhone app at full CPU (also on the base: probe run on a4accfa).
  First worked around (Favorites as the Library's filter where there is only a tab bar); the cause was the constant
  search bindings of every place pushed in Collections (§20.1), so Favorites is pushed in the Collections stack again,
  as SPEC §19.1 has it (`CollectionsGridTests.testFavoritesGrid`).
- ✅ Settings in pages with search (iPhone): first screen with the account and the pages, every page opens, search
  "face id" finds the app lock on Privacy & security and opens it (`ScreensTourTests.testSettingsPagesAndSearch`, shots
  `screens-1*`). Index and Mac tab mapping unit-tested (`SettingsPagesTests`).
- ✅ Mac Settings window (test build `fixr10screens`, 8089): opened through the app menu (AX press) on each stored tab —
  General, Accounts, Backup, Storage, Privacy, Desktop, Advanced, About open titled after the tab and sized to their
  content (488–714 pt high); a stored `server` (the old Server tab) opens Accounts. 🟡 Not looked at: the screen was
  locked, so no screenshots of the Mac windows (window titles and sizes read through CoreGraphics/AX only).
- ✅ Advanced features switch (off by default): turning it on lists Stickers and Insights in Collections, off hides them
  (`ScreensTourTests.testAdvancedFeaturesSwitch`, shots `screens-2*`); rows and gates unit-tested (`SettingsPagesTests`).
  Menu items behind it (Make Sticker, Send as Postcard, Flag/Rating, Make Collage/Card, culling/Compare/Loupe in the
  selection menu, Ratings filter) 🟡 compiled, not looked at one by one. The tours of those features launch with
  `-advancedFeatures YES`.

### §20.5 Code health
- ✅ Zero warnings: Mac app, generic iOS, visionOS, tvOS and watchOS builds and the PhotosKit tests (macOS) build without
  a warning with `PHOTOS_WARNINGS_AS_ERRORS=YES` (before: 38 Mac, 50 iOS). Deprecations moved to the 27 SDKs' API
  (AVFoundation reader/writer, `submitTaskRequest`, `PHAssetResource.filename`, `LanguageModelError`); macOS unit tests
  green incl. the film export, peek-frame and most-compatible video tests that exercise the new AVFoundation code.
- ✅ A deliberate warning fails the build, in PhotosKit and in the app target (checked locally); GRDB is not affected.
- 🟡 CI: `PHOTOS_WARNINGS_AS_ERRORS` in every job and `check-warnings.sh` on the build and unit-test logs; not run on
  GitHub yet (the round's branches are not pushed).
- ✅ Album dates are stored as seconds since 1970 (GRDB 7 per-column strategy); older text values still read (tests).
- 🟡 The AVFoundation migration on iOS (Live Photo effect videos, memory films, beat detection) is built, not seen on a
  device; the Mac unit tests cover the same code.
- ✅ UI smoke tests (`SmokeTests`: Library, viewer open/close, Albums, Collections, Settings sheet, filter menu with its
  chip, Clean up and Large videos) pass, 7 of 7, run like the CI job: a fresh server from `scripts/test-server.sh`
  (Nextcloud 35.0.3, sample photos), iPhone 17 Pro simulator, iOS 27.2, built with warnings as errors; about 8 minutes
  with the build. The summary step fails on a failed or skipped test (seen with an earlier failing run).
- 🟡 The `ui-smoke` job itself has not run on GitHub yet (not pushed).
- ✅ UI tests that waited 12–16 minutes on the combined branch (`SmokeTests`, `ToolbarsTourTests`, …, 26 Nov 17:33–20:00:
  "Wait for … to idle" 923 s, "Setting up automation session" 969 s, a screenshot timing out): not the app — the Mac
  was asleep. `pmset -g log` shows the lid closed and the Mac on battery from 17:33, and every stall is one sleep to the
  second: 17:49:45→18:05:55 (969 s, `testFilterMenu`), 18:46:52→19:02:20 (920 s, `testLaunchShowsTheTimeline`),
  19:18:46→19:31:22 (742 s, `testSwitchingToAlbums`), 19:43:22→19:59:50 (987 s, `testLibraryTopBarAndTabs`). In those
  windows the whole simulator logged nothing (no process at all); the app's requests that were open "took" as long
  (answers read after the wake), and one launch reached the app's first code 971 890 ms after its process start
  (spawned just before a sleep). The same tests on the combined code with the Mac awake: `SmokeTests` 7 of 7 and
  `ToolbarsTourTests/testLibraryTopBarAndTabs` twice in a row (longest wait for idle 4.3 s and 11.8 s, each test 9–38 s, no sleep in between); the whole
  sequence of that run (accessibility audits, screens, smoke, toolbars; 26 tests) also at normal durations (17–54 s)
  with a load average up to 166. A server that answers late does not keep the app from idling either (a proxy holding
  every request of the 8089 server for 240 s: idle after 6.5 s). For UI runs: on power with the lid open (a closed lid
  on battery sleeps whatever `caffeinate` asks); a run with long gaps is checked against `pmset -g log | grep -E
  "Sleep|Wake"` before the app is suspected.
- ✅ `GridMotionTourTests.testActionFeedback` no longer needs photos of "Today" from the tester: it uploads two of its
  own (dated now), runs, and deletes its folder and the trash bin entries of it afterwards; passed against the fresh
  server.
- ⬜ Seen on the way: after "Delete" and "Undo" in the selection bar, the two photos were not back in the Library 8 s
  later and stayed in the server's trash bin (Nextcloud 35, iPhone simulator). Plan: check the undo of a delete in the
  outbox (restore from the trash bin) — for the fixes package.

### §20.6 Release readiness
- 🟡 Performance (item 14), [PERFORMANCE.md](PERFORMANCE.md): `UITests/PerformanceTests` (launch metric, launch → first tile,
  scroll deceleration/dragging signposts, viewer paging, memory) ✅ run in the iPhone 17 Pro Max simulator (5 iterations,
  all passed); `LaunchMetrics` (launch → first picture / first screen in the log, every platform) and `FramePacing` unit-tested;
  `scripts/measure-performance.sh ios|mac` ✅ run. Results are **indicative only: the Mac was 20–40× oversubscribed**
  (load average 350–840 on 18 cores, six agents); a second run at load 20–110. Viewer 1024 preview p95 50–125 ms ✅
  (< 150), memory scrolling/paging 95–109 MB peak ✅ (< 300); **launch ⚠️ 9.5 s to the first picture even at low load**
  (37 s under full load; main thread in dyld, then seconds in the first SwiftUI commit of the Library); scroll hitch
  ratio ⬜ (the simulator reports no hitches; device D8).
- 🟡 Launch (phase 2, PERFORMANCE.md "Launch, round 10 phase 2"): profiled (Time Profiler, `sample`, new `LaunchMetrics`
  steps). Fixed: the Library's items and memories strip are prefetched off the main thread and are in the window's first
  commit (`LibraryLaunchPrefetch`; before, they came in two more full updates after it, 0.6–1.7 s later on a loaded Mac);
  the diagnostics log's first copy waits 60 s (it held a pool thread for ~1 s at launch). Measured at load 6–8,
  alternating builds: iPhone simulator Debug 3.42 → 3.06 s median to the first picture, Release 3.17 → 3.0 s; Mac Debug
  0.97 → 0.93 s (within the noise; under load the 1.2–1.7 s wait for the data is gone). ⚠️ Still over the 1 s budget in
  the simulator: 1.8–2.2 s of it is before `main` (dyld, Debug and Release alike; 0.12 s on the Mac), the rest the
  window's first SwiftUI update. ⬜ Device: Instruments App Launch with a Release build (D8, steps in PERFORMANCE.md);
  ⬜ the grid header is measured again on every Library update (`PhotoGridController.updateGridHeaderHeight`, left
  for after the file split).
  Mac: see PERFORMANCE.md (window stays in the background, its display link is throttled when covered).
  ⬜ Repeat on an idle Mac and run DEVICE-TEST-PLAN D8 on devices.
- ✅ Device test plan (item 15): [DEVICE-TEST-PLAN.md](DEVICE-TEST-PLAN.md), D1–D12 with steps, expected results, results
  table; 🟡 nothing of it has run (needs devices and a signed build).
- ✅ Privacy manifests (item 16): four undeclared required-reason uses found and declared;
  `scripts/check-privacy-manifests.py` passes. 🟡 The App Store privacy label and the push-token *Device ID* entry are
  Nextcloud's decision (RELEASE-CHECKLIST step 3).
- ✅ App Store screenshots: `UITests/AppStoreScreenshots` + `scripts/app-store-screenshots.sh` ran on iPhone 17 Pro Max
  (1320 × 2868) and iPad Pro 13" (2064 × 2752) simulators, all seven screens each, against 8089
  (`ios-fix-shots/r10-release/app-store/`). 🟡 Not store-ready as images: the test library shows other runs' test albums
  and two photos without previews, and on the overloaded Mac some previews were still blurred (a warm-up test was added
  after the first run); the iPad map opened over the Pacific. Mac: 3 of 5 window captures (`screencapture -l`, AX
  resize) at 2846 × 1800 / 2400 × 1600 — not an App Store size yet (the window could not be made 1440 × 900 pt on this
  display); Library and viewer captures failed. ⬜ visionOS and Apple TV screenshots not made (RELEASE-CHECKLIST step 7).
- ✅ Metadata draft [APP-STORE-METADATA.md](APP-STORE-METADATA.md) (within Apple's limits), release checklist
  [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md) for Nextcloud's team. ⬜ Everything in it that needs the developer account,
  the push proxy, Transifex or a designer.

### §20.7 Smaller files
- ✅ The six largest files are split into 49 files of 47–403 lines (map in SPEC §20.7). Pure moves, checked by
  script: every line of each original is in exactly one new file (ignoring `private` and blank lines), nothing else was
  added but headers, imports, `#if`, `extension X {`/`}` and two `// MARK: Layout`; 202 `private` members became
  internal.
- ✅ macOS unit suite green (1621 tests); Mac, generic iOS, visionOS, NextcloudPhotosTV and NextcloudPhotosWatch build
  with `PHOTOS_WARNINGS_AS_ERRORS=YES` and no warning; swift-format strict clean; `UITests/SmokeTests` 7 of 7 on an
  iPhone 17 Pro simulator (iOS 27.2) against 8089.

## M12 Trust, intelligence and editing (SPEC §21) — ⬜

### §21.1 Backup you can see
- ✅ Device photos that backup covers and that are not on the server stand in the Library, merged by their capture
  time, with a cloud-with-a-slash badge (arrow while uploading, warning when failed), in the iOS 27.2 iPhone simulator
  against 8089: `UITests/BackupLibraryTourTests` (11 simulator photos and a video next to the server's 500; shots
  `ios-fix-shots/r11-backup/tour4-iphone-backup-*.png`). Snapshot, ledger reading (only `uploaded`/`matched` count),
  merge, filters, ids and the "not shown twice before the first check" rule ✅ unit-tested (`DeviceLayerTests`);
  100 000 + 100 000 rows: snapshot 0.14 s, merge 0.24 s off the main thread (debug build).
- ✅ Viewer on a device photo (PhotoKit picture, zoomable) with its state, Back Up Now, Share and Delete from This
  iPhone; Back Up Now uploads it first and the bar turns to "Backed up" (same tour). 🟡 device videos in the viewer,
  Share and Delete (system confirmation) compiled, not run; the grid's context menu for device photos compiled, not run.
- ✅ "Back Up Now" on a selection: the selection goes first and a failed one does not wait for its back-off
  (`BackUpNowTests`, fails without the change); the status names what is uploading (`uploadingIdentifiers`).
- ✅ Backup summary in the account menu ("11 not backed up" → "All backed up" after the pass) and the badge on the
  account button (tour). 🟡 Mac toolbar item and Settings › Backup opening: compiled, not run (enabling backup on this
  Mac would read the owner's Photos library). 🟡 Info panel row "Backed up from this iPhone": compiled, not looked at.
- ✅ Checks of the branch: macOS unit suite green (1644 tests, new: `DeviceLayerTests`, `DeviceLayerStackTests`,
  `BackUpNowTests`); Mac, generic iOS, visionOS, NextcloudPhotosTV and NextcloudPhotosWatch build with
  `PHOTOS_WARNINGS_AS_ERRORS=YES` and no warning; swift-format strict clean; `UITests/SmokeTests` 7 of 7 and
  `BackupLibraryTourTests` on an iPhone 17 Pro simulator (iOS 27.2) against 8089.
- ✅ Settings › Backup › On this iPhone › Show in Library (default on; old settings files keep it on, unit-tested).
- ✅ Fixed on the way: on the Backup screen "Back up now" and "Pause" shared a form row, so tapping "Back up now"
  during a pass also paused it (seen in the tour's log: "paused by the user"); the row's buttons are borderless now.
- ✅ Fixed on the way (combined branch): opening Info on a portrait photo on iPhone kept the main thread busy for ever
  (the info card's placement and the pager's measurement chased each other by fractions of a point; the viewer
  accessibility audits failed with "main thread busy for 30 s"). The placement follows whole points only
  (`ViewerStage.isNewPlacementSize`, unit-tested); both viewer audits passed three times, VerifyTourTests' viewer tests,
  SmokeTests, EditTourTests, EraseTourTests and BackupLibraryTourTests pass (iPhone 17 simulator, 8089).
- ✅ Large videos (≥ 2 GB) against 8089 (NC 36 dev), 8095 (NC 33) and 8096 (NC 34): `LargeUploadIntegrationTests`
  (`PHOTOS_IT_LARGE=1`) send a 2 254 857 830-byte file (> 2³¹; 216 chunks of 10 MiB) twice per server. The app's own
  chunked upload cancelled at a third (kill, network loss): 73 chunks kept, only the other 143 sent again. A real
  background `URLSession` invalidated with its transfers at a third (restart): 72–74 chunks kept, 143–145 requests
  after it (the rest and the MOVE). Each time the server's size is exact, it stored the app's SHA-256 (`oc:checksums`)
  and the file downloaded again has the same SHA-256. Logs: `r11/backup/logs/large-*.log`.
- ✅ The same in the app, iPhone simulator (iOS 27.2) against 8089: a 2 259 807 656-byte H.264 video added with
  `simctl addmedia` is backed up in 216 chunks through the background session; the app killed at 47 chunks (the
  system finished 5 more), relaunched, the simulator shut down and booted at 127 chunks, relaunched: the pass took the
  upload up again and finished 40 s later. One file on the server, SHA-256 identical to the original, no upload folder
  left (`r11/backup/sim-interrupt.sh`, log `logs/sim-interrupt.log`). A first run without interruption: same checksum.
  🟡 On a device (locked phone, Airplane Mode, real restart, a 4K video recorded on it): DEVICE-TEST-PLAN.md D13.
- ⬜ Not done: the ledger trusts an upload once it is recorded; a file deleted on the server later still counts as
  backed up (the backup's daily look at the library does not ask the server again). Plan: let the device layer
  re-check `uploaded` entries whose server file id left the synced index, and mark them pending.

### §21.2 Verification
Round 11 (2026-11-26, SPEC §21.2). Tour `UITests/VerifyTourTests.swift` (18 tests) in the iOS 27.2 simulator (iPhone 17
Pro, iPad Pro 13-inch) against 8089; shots and accessibility trees in `~/aloha-work/photos-tools/ios-fix-shots/r11-verify/`
(prefix = run: `v1`…`v8` iPhone, `p1` iPad). The Mac's screen was locked for most of the round; one Mac item was driven at the end (below).
- Counts in this file outside this section (yellow marks / lines with one): before **246 / 226** (✅ 319, ⬜ 51); after **202 / 190** (✅ 354, ⬜ 77 of which 27 "⬜ device").
  Changed: 35 new ✅ marks seen working (the run and shot named on the line), 27 moved to the device plan
  ("⬜ device D…", DEVICE-TEST-PLAN.md D5/D7/D8/D9/D11 and the new D16), 2 bugs found and fixed (below). Several lines
  keep a yellow mark for the part still not seen (mostly the Mac).
- ✅ iPhone, seen: viewer double tap zoom and pan, swipe up (info) and down (close); Show in folder; Show in library;
  slideshow from the viewer; pull to refresh; square tiles off; photo links (and an unknown id); Add photos to an album
  (server checked) and the album toolbar while selecting; share sheet, Share via Nextcloud, tags and album sharing
  sheets; stacks, bursts, the stack strip and the stacked delete confirmation; memory film/slideshow and the memory menu;
  map clusters and time range; archive with undo; Edit date and location; Recently deleted and app lock behind Face ID.
- ✅ Fixed: sheets with Mac minimum widths were wider than the iPhone (Add photos: 720 pt, Cancel/Add unreachable), 12
  sheets; the iPhone info card did not close when the app closed it, and one swipe down on it closed the viewer.
- ✅ iPad (Pro 13-inch, run `p1`): 10 of 12 tests pass — viewer gestures with the inspector column (a swipe down closes it),
  Show in folder and in library, slideshow, square tiles off, Add photos (the picker is a form sheet now), map, memory
  film and menu, stacks/bursts and the stacked delete, Recently deleted. Not passed: the share/tag test (the share sheet
  is a popover on iPad and stayed over the grid; the sheets themselves are seen on iPhone) and Show in library (the step
  passed, the check asked for an iPhone tab bar; fixed in the tour).
- ✅ Mac (late in the round the screen was unlocked; the `fixr11verify` build driven through the accessibility API only):
  Places map with clusters and a cluster's list. Found: the list's sheet had no Done button (only Escape closed it) — fixed.
- 🟡 Left (how to continue): the other Mac items (drive the `fixr11verify` build through the accessibility API when the owner's
  screen is unlocked — map, stacks, memory slideshow, tags/sharing sheets, Show in library; menus need a focused window,
  so the menu-bar items stay with D16.7); Vision Pro (the visionOS 27.2 simulator runtime is installed now: run
  `SmokeTests` and this tour with `-destination 'platform=visionOS Simulator'` on a simulator of your own); collaborators'
  sharee search (8089 has no second user: use 8091/8093 with their second user); memory menu actions (Save as album,
  Share as link, music); Remove from Album slide; the padlock animation (too fast for a screenshot: use the host frames);
  §15–§20 items not named here, which were left as they were. Backup, search, best shot and the editor were rewritten by
  their packages this round and were not touched.
- Last run on the final commit: `SmokeTests` 7 of 7 and `VerifyTourTests` 18 of 18 on the iPhone (`z1`, app lock again in
  `z2` after the host's Face ID matches were made to wait for the test); macOS unit suite 1630 tests green; Mac, generic
  iOS, visionOS, tvOS and watchOS builds with `PHOTOS_WARNINGS_AS_ERRORS=YES` without a warning.

### §21.3 Search by meaning
- ⬜ **Removed on 2026-11-27** (owner's decision: the app uses only the AI that Apple's frameworks provide and never
  ships, downloads or runs models of its own — SPEC §2 "On-device AI", §21). Round 11 had built it with an image–text
  embedding model of its own through Core ML (229 MB, fetched by a script, Background Assets planned for release); the
  model, its tokenizer, the embedding index and its migration, the "shows" chip, "Best matches first", the Settings ›
  Search section, the background task `com.nextcloud.photos.meaning`, the Licences entry, the fetch and conversion
  scripts, the unit tests and the UI tour were all deleted before the round was released. No OS 27 API embeds pictures and text in one space
  (SDK checked: Vision, Natural Language, Foundation Models, Core Spotlight, Media Intelligence, Visual Intelligence,
  Image Playground), so the feature waits for one.
- ✅ **Search as before round 11**: Vision labels (SR-7), descriptions (§16.2), names, dates, places and text in the
  full-text index; typed sentences read by the parser and, with Apple Intelligence, `NaturalSearchModel` (Foundation
  Models). `SearchScreen` and `NaturalSearch` are back to their round-10 code (round 11 changed them only for search by
  meaning).

### §21.4 Best shot
- ✅ Scoring and reasons (`BestShot`, `BestShotAnalysis`): sharpness of picture and subject (independent of brightness),
  exposure, faces (eyes open, smiling, looking, capture quality, everyone in the picture), Vision aesthetics incl.
  utility pictures; favourites and Pick first, rejects last. 15 + 9 + 3 + 5 unit tests (`BestShotTests`,
  `TimeBurstsTests`, `BestShotStoreTests`, `BestShotMeasureTests`/`BestShotAnalysisTests` with real Vision on the Mac).
  Evaluation on the test library (`BestShotEvaluation`, contact sheet `ios-fix-shots/r11-bestshot/evaluation-contact-sheet.png`):
  the known best frame chosen in 3 of 3 synthetic bursts; plausible choices in 3 real pairs; 70–130 ms per photo on the
  Mac. No model bundled (Apple frameworks only).
- ✅ Clean up › Similar shots analyses the series while open and says why — seen on the Mac test build against 8089:
  "Best shot: Well exposed, best composed." with the steady frame kept in two test bursts
  (`ios-fix-shots/r11-bestshot/mac-similar-shots-1.png`).
- ✅ Show Similar: the moment's shots analysed, reasons under "Best shot" — seen on the Mac (`mac-show-similar.png`).
  Noticed on the way (not changed): the first row of that sheet's grid sits under the header on the Mac.
- ✅ Library bursts: quick runs of alike photos (`TimeBursts`) stacked with the best frame as cover, VoiceOver "Burst of 4
  photos" — seen on the Mac with two uploaded 4-/5-frame bursts (`mac-library-bursts.png`; the blown-out frame of the
  portrait burst was not alike enough and stayed a photo of its own, as intended).
- 🟡 Flag ▸ Pick Best Shots (context menu, selection, Image ▸ Flag): built for all platforms, not run — the Flag menu is
  an advanced feature that is off in the test build; the parts are unit-tested (series, choice), the flagging is the
  existing tested culling path.
- 🟡 Memory covers from the analysis (`LibraryStore.chooseCovers`): unit-tested (`memoryCoversAreTheBestAnalysedPhotos`);
  the strip was seen with covers changed on the Mac, not compared one by one.
- 🟡 Background analysis of series members after the "Show Similar" trickle (`BestShotAnalyzer.run`): built; on the Mac
  test build the Library's trickle did not index during the session (the Similar shots screen did) — not followed up.
- 🟡 Device bursts by PhotoKit `burstIdentifier`: grouping unit-tested; needs the device-photo layer of §21.1 to set
  `burstIdentifier` (backup package), and a device with bursts (`DEVICE-TEST-PLAN.md` candidate). iPhone/iPad: Vision
  cannot run in the simulator, so nothing is analysed there; generic iOS build only.
- ✅ macOS unit suite green (1662 tests); Mac, generic iOS, visionOS, NextcloudPhotosTV and NextcloudPhotosWatch build
  with `PHOTOS_WARNINGS_AS_ERRORS=YES` and no compiler warning; swift-format strict clean; `UITests/SmokeTests` 7 of 7 on an
  iPhone 17 Pro simulator (iOS 27.2) against 8089.

### §21.5 Remove objects
- ✅ **No model of its own** (2026-11-27, owner's decision, SPEC §21 "Apple's AI only"): the LaMa Core ML model (99 MB,
  its loader, its fetch and conversion scripts, the bundling in project.yml, the REUSE annotation) was removed.
  Erase fills with `DiffusionFill` (classic push–pull image processing) and says under the picture "Works best on spots
  and small things."; picking by tap and "Erase N People in the Background" use Vision as before; the recipe's
  `retouch` strokes are unchanged. Nothing in the tool mentions a model or a download any more.
- ✅ **Erase tool on the Mac**: test build against 8089, the editor's Erase tab, "Erase 1 Person in the Background"
  (VoiceOver action on the picture, via AX) removed the man behind the speaker, Done saved the recipe with its `retouch`
  stroke to `.nextcloud-photos/edits/<id>.json`, the viewer showed the photo without him. Shots
  `ios-fix-shots/r11-erase/mac-2-editor.png` … `mac-7-viewer-after-done.png`.
- 🟡 **Fill quality**: the before/after pictures in `ios-fix-shots/r11-erase/` were made with LaMa and no longer show
  what the app does. The basic fill is right for spots and small things on even backgrounds and leaves a soft patch on
  large objects; new evidence with `TEST_RUNNER_PHOTOS_INPAINTING_EVAL` (now the basic fill) is open.
- ✅ **Recipe, geometry, cache, basic fill**: `InpaintingTests` (14 tests: JSON round trip and leniency, run lengths,
  brushed points through every geometry vs. `PhotoEditor.apply`, only the stroke changes, fills reused across undo and
  colour changes, windows, basic fill, `EditRendering` applies strokes, background-people rule).
- ✅ **Brushing on iPhone** (simulator, iOS 27.2, against 8089; run with LaMa then, the tour now also checks the
  "Works best…" note and that no text mentions a model): `UITests/EraseTourTests` opens a photo, picks Erase in
  the tool row, drags over the picture, waits for the fill (Restore All appears), Undo takes it back, Cancel. Shots
  `ios-fix-shots/r11-erase/r11-erase-0*.png`. Tap-to-pick by hand not seen (Vision does not run in the simulator; on the
  Mac picking was seen through the background-people path, which uses the same instance masks).
- 🟡 **iPad, visionOS, devices**: built (generic iOS and visionOS without warnings). Speed and peak memory on devices:
  DEVICE-TEST-PLAN D15.
- ⬜ **Large fills look soft**: the basic fill invents no detail, and objects larger than ~230 px (window > 512 px) are
  filled scaled down. Plan: add grain matched to the surroundings.
- ⬜ **Live Photos**: the removal applies to the still only; the motion still shows the object (Photos turns Live off
  after Clean Up). Plan: offer "Turn Off Live" when a stroke is added to a Live Photo.
- ✅ **With the editing-depth branch merged**: Erase is the third tool (after Adjust and Crop), strokes make a recipe
  version 2, Copy Edits/presets leave them out and Paste keeps the target's (`strokesAreVersion2AndNotPartOfALook`),
  docs/EDIT-FORMAT.md §4.9 describes the field and its rendering for Android and web.

### §21.6 Editing depth
- ✅ Format version 2 (§21.6.7): curves, colour mixer, masks, noise reduction, RAW colour noise/detail in the recipe,
  lowest-version writing, version-3 refusal, unknown mask targets skipped, clamping, 8-mask cap, v1 recipes unchanged:
  unit-tested (`EditDepthTests`, 30 tests). Spec for other apps: docs/EDIT-FORMAT.md.
- ✅ Curves (§21.6.1): monotone spline (no overshoot, through its points, black/white points), channel composition and
  rendering in sRGB unit-tested; editor Curves tool seen on the Mac test build (`~/aloha-work/photos-tools/ios-fix-shots/r11-edit/editor-curves.png`).
- ✅ Colour mixer (§21.6.2): weights, greys unchanged, only the chosen colours change, hue/luminance moves and the LUT
  rendering unit-tested; Color tool seen on the Mac (`editor-color.png`); S curve + mixer on 5 test-library photos (`mask-*-curves-mixer.jpg`).
- ✅ Masks (§21.6.3) on the Mac: sky heuristic (found above a horizon, a blue object not touching the top is no sky),
  mask blending and fingerprints unit-tested; on 5 test-library photos (`EditDepthEvidenceTests`, strips before / mask /
  after in `mask-*.jpg`, timings `mask-timings.txt`): sky found on 3 of 4 photos with sky (cloudy runway, Hôtel de Ville
  with textured clouds, Mekong sunset — its lowest cloud band is left out), missed on a dark black-and-white storm sky
  (Notre-Dame), correctly none on a street scene; subject 2 of 2, people on the wedding photo. Mask time on a 1920 px
  photo: subject 60–260 ms, people 370–550 ms, sky 60–110 ms; cached 0 ms. In the app: Masks ▸ Add Mask ▸ Sky tints the
  sky (`editor-masks-sky.png`) and Done saved a version-2 recipe on 8089 (`recipe-sky.json`, own copy
  `/Photos/r11-edit/r11-edit-sky.jpg`). Not in the simulator (no Vision). ⬜ Sky via `GenerateIterativeSegmentationRequest` seeded by the heuristic (OS 27, downloadable assets):
  plan — when its assets are ready, use the heuristic's sky as the seed scribble and keep the heuristic as fallback;
  compare on 20 landscape photos of the test library.
- ✅ Noise reduction (§21.6.4): colour noise smoothed with luminosity kept, size-relative strength unit-tested; sliders in
  Adjust and the RAW tool (Color Noise, Detail where the decoder supports them) built. 🟡 RAW Detail/Color Noise not run on
  a RAW file.
- 🟡 Copy/Paste Edits, presets, a selection at once (§21.6.5): look/paste rules, clipboard, built-in presets, preset merge
  and file round trip, preset sync between two devices through the in-memory WebDAV server unit-tested; editor Presets
  tool with live previews seen on the Mac (`editor-presets.png`); grid context menu Paste Edits / Apply Preset ▸ with progress built, not run on a selection in
  the app.
- ✅ Apply Edits to the File (§21.6.6): against 8089 (`ApplyEditsToFileIntegrationTests`, own copy
  `/r11-edit/apply-test.jpg`): the original is labelled "Original (Nextcloud Photos)" before the PUT and its bytes are
  identical to the original (SHA-256), a second edit keeps the same labelled version (versions
  `[…157, …152, 1431539165:Original]`), a stale ETag replaces nothing, Restore Original brings back the exact bytes
  (`f68f6cf6…`), a file without versions is not overwritten. Editor option, its confirmation and Restore Original… built, not
  pressed in the app (proof is the integration test).
- ✅ Editor tool bar (icons + names, scrolls sideways; Adjust and Crop first so they fit the narrowest iPhone): iPhone 17
  Pro simulator `EditTourTests` passed (shots `ios-fix-shots/r11-edit/r6-edit-*.png`, the More menu shows Copy Edits and
  Apply Edits to the File), `SmokeTests` 7 of 7; Mac test build `editor-*.png`. macOS unit suite 1659 tests green; Mac,
  generic iOS, visionOS, NextcloudPhotosTV and NextcloudPhotosWatch build with `PHOTOS_WARNINGS_AS_ERRORS=YES`, 0 warnings.
- ✅ "Overwrite Original…" (§16.3.1) now goes through the same path: the original is kept as a labelled version, never
  overwritten without versions (proven by the same integration test). Corrects §16.3.1's "previous version stays in the
  file versions": an unlabelled version could expire; a labelled one does not.

## Prerequisites from SPEC §14 still open
App Group / keychain group provisioning and the Push Notifications capability (table in the README), Apple's notification
filtering entitlement, push proxy topic, notification routing in the notifications app, app icon artwork,
a test server with Recognize and an Assistant provider.

# Testing

| Kind | Where | Needs | Runs in CI |
|---|---|---|---|
| Unit tests | `Packages/PhotosKit/Tests` (Swift Testing) | macOS 27 or an iOS 27 simulator | every pull request (macOS and iOS simulator) |
| Performance tests | `LargeLibraryPerformanceTests` | a few minutes | pushes to `main`, nightly; skipped on pull requests |
| Integration tests | suites named `…Integration…Tests` | a Nextcloud server | nightly |
| UI smoke tests | `UITests/SmokeTests.swift` (XCUITest) | a Nextcloud server, a Debug build | every pull request (iPhone simulator, throw-away server) |
| UI tours | the other `UITests` | a Nextcloud server with the test library, a Debug build | no |
| Device tests | [test-plan.md](test-plan.md) | devices | no |

## Warnings

The code builds without warnings, and CI keeps it so (SPEC §20.5): every job sets `PHOTOS_WARNINGS_AS_ERRORS=YES`. In the
environment it makes PhotosKit treat its warnings as errors (`Package.swift`); as a build setting
(`xcodebuild … PHOTOS_WARNINGS_AS_ERRORS=YES`) it does the same for the app's targets (`Config/Base.xcconfig`,
`project.yml`). Dependencies keep their own settings. `.github/scripts/check-warnings.sh <log>` then fails on any warning
left in the log: the compiler does not turn warnings inside macro expansions (`#expect`) into errors, and other tools
(asset catalogs, the linker) have warnings too. Locally, builds only warn; to build like CI:

```sh
PHOTOS_WARNINGS_AS_ERRORS=YES xcodebuild … PHOTOS_WARNINGS_AS_ERRORS=YES build
```

A deprecation that has no replacement is silenced for that one declaration with `@diagnose(DeprecatedDeclaration, as:
ignored)` and a comment saying why (so far only `UIApplication.canOpenURL` for the Files app check).

## Unit tests

```sh
cd Packages/PhotosKit
swift test                                                                    # or:
xcodebuild test -scheme PhotosKit-Package -destination 'platform=macOS'
```

Environment variables: `swift test` passes your environment on to the tests. **`xcodebuild` does not**; it only hands
over variables whose name starts with `TEST_RUNNER_`, without that prefix. So `PHOTOS_SKIP_PERFORMANCE=1 swift test`, but
`TEST_RUNNER_PHOTOS_SKIP_PERFORMANCE=1 xcodebuild test …`.

Tests that wait for something another task does poll for it with a time limit (the `eventually` helpers of each test
target); suites with such tests have a `.timeLimit`, so a hang fails instead of blocking the run. A fixed
`Task.sleep` is only right for "this must *not* happen within a moment".

## Performance tests

`LargeLibraryPerformanceTests` measure the store on a synthetic library of 100 000 items against the budgets of SPEC §10
and print lines starting with `PERF`. Skip them with `PHOTOS_SKIP_PERFORMANCE=1`; another size:
`PHOTOS_PERFORMANCE_ITEMS=250000`.

The app itself (launch, scrolling, viewer paging, memory) is measured by `UITests/PerformanceTests` in a simulator and,
without XCUITest, on the Mac: `scripts/measure-performance.sh ios <simulator udid>` or `mac <Debug app>`. Method and
baselines: [PERFORMANCE.md](PERFORMANCE.md). `UITests/AppStoreScreenshots` makes the App Store screenshots
(`scripts/app-store-screenshots.sh`, RELEASE-CHECKLIST.md step 7), `UITests/ReadmeScreenshots` those of the README
(`scripts/readme-screenshots.sh`, which also covers Vision Pro, Apple TV and Apple Watch). They need
`PHOTOS_UITEST_LOGIN` like the tours below.

The Mac's README screenshots come without XCUITest (it would take over keyboard and pointer):
`scripts/readme-screenshots-mac.sh <output directory>` builds the Debug app with a bundle id of its own
(`README_SHOTS_BUNDLE_ID`, default `com.nextcloud.photos.shots.mac`; it refuses the official one), launches it once per
shot with `open -n --env …` and launch settings only — never a `nextcloudphotos://` link, which another installation
could answer — waits, captures the window of exactly that process (`screencapture -x -o -l <window id>`, the id from a
small `CGWindowListCopyWindowInfo` helper filtered by PID) and quits that PID. Light mode comes from the launch argument
`-NSRequiresAquaSystemAppearance YES`. Shots: library (the first launch signs in with `PHOTOS_DEBUG_LOGIN` and waits for
the first sync), viewer with its info (`PHOTOS_DEBUG_VIEWER=<index>`, `PHOTOS_DEBUG_VIEWER_INFO=1`), map and albums
(`PHOTOS_DEBUG_DESTINATION`), compare (`PHOTOS_DEBUG_COMPARE=2`), people (`PHOTOS_DEBUG_FACES_NOW=1`: Vision looks at the
library on the Mac, which shows People on a server without Recognize). The app comes to the front while it runs; nothing is
clicked or typed. `README_SHOTS_ONLY="viewer compare"` takes some of them again, `README_SHOTS_SKIP_BUILD=1` keeps the
build. The debug launch settings that open a screen wait a moment after the Library's grid has its photos: on the Mac
the first grid is replaced right after launch, and a request made by it was lost.

The README shows the screenshots framed and its interactions as short videos:

- `swift scripts/frame-screenshots.swift [options] <output.png> <shot>[:phone|tablet|window|plain[:height]] …` draws
  each screenshot with rounded, device-like corners (a thin dark edge for iPhone and iPad), a soft shadow and a light
  (or `--background dark`) card behind them, several side by side; no device artwork from anyone else. Convert the PNG
  with `cwebp -q 82 -alpha_q 90` (WebP keeps the card's rounded corners transparent).
- `scripts/readme-videos.sh record <output> <simulator udid> [test …]` runs `UITests/ReadmeVideos` (Library zoom
  levels, a memory film, the viewer, the editor) and records the simulator's screen (`simctl io recordVideo`) while each
  test plays its part; the test and the script hand over through files in the output folder (`<name>.start`,
  `.recording`, `.stop`, `.done`). `scripts/readme-videos.sh encode <recording> <basename> [kind] [width] [start] [end]
  [speed]` cuts, frames and encodes it as `<basename>.mp4` and an animated `<basename>.webp` (GitHub plays no video
  file from the repository in a README, but it shows animated WebP); keep each WebP under 2.5 MB.
- `UITests/ReadmeWidgets` adds the app's widgets to the iPhone simulator's Home Screen through the system's own widget
  gallery (long press, Edit, Add Widget, search, the size) and takes the Home Screen; the widgets show what the app has
  synced into the App Group, so it needs a build with `PHOTOS_DEBUG_ENTITLEMENTS=YES` and a simulator whose region
  matches the README (`xcrun simctl spawn <udid> defaults write -g AppleLocale en_US`). The widgets pick their photos by
  the hour and the day; the README's set came from photos of the test library copied into a folder of their own,
  dated a year ago and marked as favourites (removed afterwards).
- `UITests/ReadmeScreenshots` `testFirstRun` needs a fresh install (`xcrun simctl uninstall` first); `testCameraChip`
  types a camera of the test library (`PHOTOS_UITEST_SHOT_CAMERA`, default "nikon d50").

## Integration tests

Nine tests talk to a real server. They run when `PHOTOS_IT_SERVER`, `PHOTOS_IT_USER` and `PHOTOS_IT_PASSWORD` are set.

What they expect on the server: Nextcloud 33 or newer with the Photos app; an account whose timeline folder (`/Photos`)
holds at least one photo with a BlurHash and one with a camera-style name (`IMG_0001.jpg`), a capture date and a size.
They create and delete their own folders, files, albums and share links (`photos-ios-sync-test-…`,
`Photos iOS test upload`, …) and change nothing else. **Use a test server**, not your own Nextcloud.

A throw-away server (release archive, SQLite, PHP's built-in web server; tested with PHP 8.3, with the usual Nextcloud
extensions) that has all of this:

```sh
scripts/test-server.sh /tmp/photos-test-server 8089      # installs on first use, then serves until Ctrl-C
```

Then, in another terminal:

```sh
cd Packages/PhotosKit
PHOTOS_IT_SERVER=http://127.0.0.1:8089 PHOTOS_IT_USER=admin PHOTOS_IT_PASSWORD=admin \
  swift test --no-parallel --filter Integration
```

`LargeUploadIntegrationTests` (2 GB videos, SPEC §21.1) also need `PHOTOS_IT_LARGE=1`: they write a 2.1 GB file and
send it twice (with downloads to compare), about four to eight minutes per server.

`UITests/BackupLibraryTourTests` (device photos in the Library, SPEC §21.1) turns backup on in the simulator
(`PHOTOS_DEBUG_BACKUP`, for the account that is logged in, also one an earlier test logged in) into
`PHOTOS_UITEST_BACKUP_FOLDER` (default `/Photos/ui-backup-tour`, removed at the end), and empties the backup's ledger
first (`PHOTOS_DEBUG_BACKUP_RESET`), so it can run again. The app adds four new photos to the simulator's library
(`PHOTOS_DEBUG_BACKUP_SAMPLES=4`, taken now): the simulator's own sample photos may be on the test server already, and
a device photo the server has is shown once, as the server's. Without any photo the test skips and says so. Photo library access is granted by the test (the system's alert) or beforehand with
`xcrun simctl privacy <simulator> grant photos <bundle id>`.

Run them one after the other (`--no-parallel`, with xcodebuild `-parallel-testing-enabled NO`): the suites change the
same account, and one of them counts its files while another uploads. The nightly workflow
(`.github/workflows/nightly.yml`) does exactly this on the macOS runner.

To test the features of newer Photos versions, point the variables at a server that has them; the tests check that
what the app detected matches what the server answers.

**Older Nextcloud versions** (the oldest supported is 33, SPEC §2): the same script with the release archive of that
version and the Photos app it bundles, e.g.

```sh
NEXTCLOUD_ARCHIVE=https://download.nextcloud.com/server/releases/latest-33.tar.bz2 scripts/test-server.sh /tmp/nc33 8095
NEXTCLOUD_ARCHIVE=https://download.nextcloud.com/server/releases/latest-34.tar.bz2 scripts/test-server.sh /tmp/nc34 8096
```

To give such a server a larger library, copy photos into `nextcloud/data/admin/files/Photos/…`, run `occ files:scan
--path=admin/files/Photos` and then `occ metadata:get <fileId> admin --refresh` for each new file (the file ids are in
`oc_filecache` of `nextcloud/data/owncloud.db`). On Nextcloud 33 and 34, `files:scan --generate-metadata` stops after the
first file of a newly copied folder without saying so, and leaves the rest without capture time, place and BlurHash.
SPEC §20.2 lists what differs between the versions.

## UI smoke tests

`UITests/SmokeTests.swift` starts the app, signs in with the debug login and checks: the timeline shows photos; the first
photo opens in the viewer and closes again; the Albums screen opens; and on iPhone the Collections tab, the Settings sheet,
the filter menu (Favorites and its chip) and Clean up with a section's review screen. They only look and navigate.

CI runs them on every pull request (`ui-smoke` in `.github/workflows/ci.yml`): `scripts/test-server.sh` installs the latest
Nextcloud release with the sample photos of a new account, an iPhone simulator boots, and the job keeps the screenshots
(`PHOTOS_UITEST_SHOTS`) and the result bundle as the artifact `ui-smoke`. A skipped test fails the job (it means the login
did not reach the runner). So they must not depend on the day they run nor on the shared test library; a tour that needs
photos of its own uploads them first (`UITests/TestServer.swift`, a folder of its own under `/Photos`, deleted again with
its trash bin entries).

- They need a **Debug** build (the debug login does not exist in Release) and a test server with photos, and run only
  when `PHOTOS_UITEST_LOGIN` holds a login link.
- Build them with **a bundle id of your own** (`PHOTOS_BUNDLE_ID`, on the command line or in `Config/Local.xcconfig`).
  The debug login only signs in when the app has no account yet, so with the official bundle id the tests would drive
  whatever account that installation has; they refuse to run in that case.
- On a Mac the tests take over keyboard and pointer while they run.
- `UITests/IPadTourTests.swift` (iPad simulators only) turns the device (`XCUIDevice.shared.orientation`; `simctl`
  cannot rotate), walks every sidebar row, the tab bar in portrait, the viewer and its inspector, the grid's inspector,
  selection, context menus, "Open in new window", the editor and the share sheet, and types the menu commands' keyboard
  shortcuts on the simulated hardware keyboard. With `TEST_RUNNER_PHOTOS_UITEST_SHOTS=<directory>` it writes a
  screenshot and the accessibility tree of every step there (landscape screenshots are stored rotated, as the screen
  is). The `testWindows…` tests run only with `TEST_RUNNER_PHOTOS_UITEST_WINDOWS=1`, one at a time on a fresh installation
  (`xcrun simctl uninstall`): they open album windows, which the system restores at every later launch in front of the
  library, and switch the simulator to "Windowed Apps" (Settings › Multitasking & Gestures) and back, to make a window
  narrow and to put two windows side by side.
  `testWindowsDragPhotoIntoAlbumWindow` changes the server: it runs only with `TEST_RUNNER_PHOTOS_UITEST_DND_ALBUM=1` and an
  empty own album `r4-ipad-dnd`, and the photo it adds has to be removed again. The system's passcode sheet (Archive)
  belongs to SpringBoard: `XCUIApplication(bundleIdentifier: "com.apple.springboard")`.

```sh
xcodegen generate
# Mac
TEST_RUNNER_PHOTOS_UITEST_LOGIN='nc://login/server:http://127.0.0.1:8089&user:admin&password:admin' \
  xcodebuild test -scheme NextcloudPhotosUITests -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PHOTOS_BUNDLE_ID=com.example.nextcloudphotos.uitest
# iPhone simulator (a server on the Mac is reachable as 127.0.0.1)
TEST_RUNNER_PHOTOS_UITEST_LOGIN='nc://login/server:http://127.0.0.1:8089&user:admin&password:admin' \
  xcodebuild test -scheme NextcloudPhotosUITests -destination 'platform=iOS Simulator,name=iPhone 17' \
  PHOTOS_BUNDLE_ID=com.example.nextcloudphotos.uitest
```

`UITests/FeelTourTests.swift` (iPhone and iPad) tours the Library's zoom levels (picker, taps, pinches in and out of
the grid) and "Show Similar" (context menu, screen, viewer menu), SPEC §15.5. With `TEST_RUNNER_PHOTOS_UITEST_SHOTS`
set to a folder it also saves a screenshot of every step there; `-only-testing:NextcloudPhotosUITests/FeelTourTests`
runs it alone. The simulator cannot run Vision's models, so the app analyses nothing there: to see "Show Similar"
with results, compute prints of the simulator's cached previews on the Mac (Vision's `GenerateImageFeaturePrintRequest`
and `FeatureSketcher` from PhotosDomain) and write them into the `similarity` table of the simulator's account database.

`UITests/VerifyTourTests.swift` (iPhone and iPad, SPEC §21.2) is round 11's proof of the STATUS items that had only been
compiled: viewer gestures (double tap, pan while zoomed, swipe up/down), Show in folder / Show in library, the slideshow,
pull to refresh, square tiles off, photo links, adding photos to an album, the share, tag, Share via Nextcloud and album
sharing sheets, stacks and bursts, the memory slideshow and menu, the map, archive with undo, Edit date and location,
Recently deleted and app lock behind Face ID. What it changes is its own: photos it uploads (`TestServer`) and albums it
creates, removed at the end; Settings it touches are set back. Two helpers run on the Mac next to it: Face ID enrolment
and matches as for `LookTourTests` (held back while the test has written `faceid.hold` into the shots folder, so that
the app lock's cover can be seen before it opens; `testAppLock` runs only with `TEST_RUNNER_PHOTOS_UITEST_FACEID=1`, set
where that helper runs, as without it the lock never opens and the tests after it meet a locked app), and, for moments a test cannot screenshot itself (a gesture in progress), a loop that
takes `xcrun simctl io <udid> screenshot` frames while the test has written `capture.request` into the shots folder
(`captureFrames(_:during:)`). A failed tap inside an `async` test can leave XCTest waiting for ever in the teardown; the
tour checks before it taps.

`UITests/LookTourTests.swift` (iPhone and iPad, SPEC §16.8) opens the album `PHOTOS_UITEST_ALBUM` (default "Lisbon
2025"): its card menu, "Customize Cover…" (cancelled, nothing is saved), the tinted header, Guest Mode from start to end,
and Settings ▸ Appearance. Ending Guest Mode asks for Face ID: enrol it once
(`xcrun simctl spawn <udid> notifyutil -s com.apple.BiometricKit.enrollmentChanged 1` and `-p` the same name) and post
`notifyutil -p com.apple.BiometricKit_Sim.pearl.match` while the test waits. A run that stops in Guest Mode leaves the
app in it (it survives relaunches); the tests end it first.
`UITests/LibraryTourTests.swift` (iPhone and iPad) tours SPEC §16.1: story cards (tap to the next photo, context menu to
the strip), moment titles in the Days level and on the day headers of All Photos (the test library's places give
"Weekend in Lisbon" and others) and the moment screen they open, scrub to peek on a video tile (the library needs a
video: upload one for the test and remove it afterwards) with the context menu still coming when the finger is held
still, and range selection with one finger in the selection mode. XCUITest cannot take a screenshot while a finger is
down: capture the peek from outside, `xcrun simctl io <udid> screenshot` in a loop, during the test's four-second hold.
Playing story cards keep the app from being idle, which slows XCUITest's queries a lot; the tour switches them to the
strip (`-memoriesStyle strip`) for everything but the story test. The simulator refuses the on-device language model,
so it shows the rule titles of moments only.
`UITests/OrganizeTourTests.swift` (iPhone) tours SPEC §16.4: the smart album builder (saves and deletes a smart album
named "UI test smart album", which leaves a tombstone in `/.nextcloud-photos/smart-albums.json`), the batch fixes
sheet of a selection (nothing applied) and Settings › Organize › Folder Rules. `testApplyAndUndoInOwnFolder` changes
files and is opt-in: set `TEST_RUNNER_PHOTOS_UITEST_ORGANIZE_FOLDER` to a folder of your own test photos (e.g.
`Photos/r6-organize-test` with three JPEGs; never the shared test library). It shifts their capture times by an hour
and undoes it, renames them with `{date} {place} {counter}` and undoes it, and opens Folder Rules to run them; check
the server's values while it runs (PROPFIND of `nc:metadata-photos-original_date_time`).

`UITests/GridMotionTourTests.swift` (iPhone) tours SPEC §17.2: the Library edge to edge with its date pill, selecting
tiles, the viewer's zoom out of a tile and back, an album's grid (`TEST_RUNNER_PHOTOS_UITEST_ALBUM`, default
"Lisbon 2025" of the shared test library, only looked at) and a favourite's heart, a delete and its undo on two photos the test uploads first (dated now, so
they are the newest of the library on any day) and removes at the end. `TEST_RUNNER_PHOTOS_UITEST_SHOT_PREFIX` names the screenshots (before/after pairs), and
`TEST_RUNNER_PHOTOS_UITEST_REDUCE_MOTION=1` / `TEST_RUNNER_PHOTOS_UITEST_REDUCE_TRANSPARENCY=1` launch the app with those
settings. For motion, record the simulator meanwhile (`xcrun simctl io <udid> recordVideo --codec h264 <file>`).

The app has no accessibility identifiers yet (apart from `librarySummary`, the zoom levels' scroll view); the tests find elements by role and by their English labels, and start
the app in English. The tours other than `SmokeTests` are not part of CI: they need the shared test library and take
long. They have run in the iOS 27.2 simulator (iPhone).

`UITests/SearchTourTests.swift` (SPEC §16.2) types a search in words and changes a chip, and finds a place in the
command palette by a typo; like the other tours it needs `PHOTOS_UITEST_LOGIN` and a library with favourite photos taken
in Lisbon in 2025 (the local test server on port 8089 has them). Debug builds open the palette at launch with `PHOTOS_DEBUG_PALETTE=<typed words>` and describe the
cached previews once with `PHOTOS_DEBUG_DESCRIBE_NOW=1` (Mac; Vision does not run in the simulator).

`UITests/AmbientUITests.swift` (SPEC §15.4) drives the system around the app, so it only makes sense in a simulator of
its own: `testBackupLiveActivity` and `testControlActions` (iPhone) need backup set up for the test account and new
photos in the simulator's library (`xcrun simctl addmedia`); `testControls` and `testPhotoFrameWidget` add the controls
and widgets through Control Center's and the Home Screen's galleries, as a user would; `testMemoryRoom` (Vision Pro)
opens a memory's room, with `PHOTOS_DEBUG_MEMORY_ROOM_FOCUS=1` bringing the first frame close (XCUITest cannot look and
pinch). With `PHOTOS_UITEST_SHOTS=<folder>` (`TEST_RUNNER_…`) the iPhone tests write their screenshots there; on Vision Pro
`XCUIScreen` captures nothing, take them with `xcrun simctl io <udid> screenshot` while the test runs.

`UITests/MemoryFilmTourTests.swift` (iPhone and iPad) plays a memory as a film (title card, scrubbing, skip, landscape),
exports it as a video, plays a trip and swipes through the year in review; `PHOTOS_UITEST_SHOTS=<directory>` writes a
screenshot and the accessibility tree of each step there, `PHOTOS_UITEST_TRIP=<part of a trip's title>` picks the trip
(one with stops more than 30 km apart shows the map flights). Run in the iOS 27.2 simulator.

`UITests/FilmsTourTests.swift` (iPhone simulator) plays a memory film in every style (SPEC §16.6), tries SharePlay without
a FaceTime call (the explanation), opens the export sheet (its style note) and shows the "Through the years" row of
Memories. The faces of "through the years" need Vision and are checked on the Mac instead: with
`TEST_RUNNER_PHOTOS_FACE_SAMPLES=<folder of portraits>` (and optionally `TEST_RUNNER_PHOTOS_FACE_OUTPUT=<folder>`)
`FaceTimeLapseTests.realFacesAreLinedUp` lines up real faces and writes the aligned frames.

`UITests/ExtrasTourTests.swift` (iPhone simulator) walks through the round-5 extras (SPEC §15.8): Settings › Smart
offline, Make Sticker, a collage of a selection, the sticker book, and a photo of the day notification (the Debug build
schedules one 25 seconds ahead when started with `PHOTOS_DEBUG_PHOTO_OF_THE_DAY_IN=25`; the test accepts the permission
alert). With `TEST_RUNNER_PHOTOS_UITEST_SHOTS=<folder>` the screenshots are also written there. Subject lifting (stickers)
does not work in the simulator; `PhotosMediaTests/StickerSampleTests` lifts real photos on the Mac when run with
`TEST_RUNNER_PHOTOS_STICKER_SAMPLES=<folder of JPEGs>` and writes every sticker style next to them.

`UITests/FamilyTourTests.swift` (iPhone simulator) tours sharing and family (SPEC §16.7): a postcard (styles, back,
sending, the sent state), the weekly prompt (invitation, adding this week's photos, history), the family library
(choosing a shared folder, the suggestion card, Review — nothing is moved) and the Lock Screen album (mirroring into the
simulator's Photos library, then turning it off and accepting the system's deletion alert). It needs test data: a folder
`r6-family-Family` shared with the test user with write permission and an album `r6-family-lockscreen`; the postcard
photo is `PHOTOS_UITEST_POSTCARD_PHOTO` (a file id). Grant Photos access first (`xcrun simctl privacy <udid> grant
photos <bundle id>`). The postcard and prompt tests leave a `/Postcards/…` folder with a public link and a
"Prompt: …" album on the server. `PhotosMediaTests/PostcardRendererTests` writes every style drawn with a real photo
when run with `TEST_RUNNER_PHOTOS_POSTCARD_PHOTO=<jpeg>` and `TEST_RUNNER_PHOTOS_POSTCARD_PREVIEWS=<folder>`.

For other UI work, Debug builds also sign in without a browser when started with
`PHOTOS_DEBUG_LOGIN='nc://login/server:<url>&user:<user>&password:<app password>'`.

`UITests/EraseTourTests.swift` (iPhone) brushes in the editor's Erase tool (SPEC §21.5) and cancels.
`testEraseEvidence` makes before/after pictures of the fill and is opt-in: `TEST_RUNNER_PHOTOS_UITEST_ERASE_EVIDENCE` names a
folder with JPEGs (without EXIF dates, so they are the newest of the library) and `erase-evidence.json`
(`[{"file", "name", "brush", "strokes": [[[x, y], …], …]}]`, brush size and points as fractions; photos of different
aspect ratios, which is how the test tells them apart). It uploads them into `/Photos/erase-evidence-<time>`, brushes each
stroke, writes `<name>-before/-after.png` and the picture's frame (`<name>-frame.txt`) into `PHOTOS_UITEST_SHOTS`,
leaves with Cancel (nothing is saved) and removes the folder and its trash bin entries.

`UITests/AccessibilityAuditTests.swift` (iPhone and iPad, SPEC §20.3) runs Xcode's accessibility audit
(`performAccessibilityAudit`: contrast, hit areas, labels, traits, Dynamic Type, clipped text) on every main screen —
Library, viewer and its info, Collections (the iPad's sidebar), Albums, Settings, Search, Clean up, Memories — and on
Library, Settings, Collections and Search at the largest accessibility text size. A finding fails the test unless
`AccessibilityAuditPolicy.accepts` names it with a reason (a photo's own colours, the system's bars and search field,
the system's secondary text colours at 3:1 or more, content under the tab bar's glass, findings without an element).
White captions on photos (`memory-caption`) are never excused.
With `TEST_RUNNER_PHOTOS_UITEST_SHOTS=<folder>` every screen's screenshot, accessibility tree and findings
(`…-audit.txt`, accepted ones with their reason) are written there; `TEST_RUNNER_PHOTOS_UITEST_A11Y_SURVEY=1` only
writes them, for a look at a new screen. `TEST_RUNNER_PHOTOS_UITEST_LANGUAGE=de` runs the same screens in German with a
German region, `=double` in English with every text doubled (`NSDoubleLocalizedStrings`), to see where longer
translations would be cut off. Every test starts at a destination (`PHOTOS_DEBUG_DESTINATION`), because the app
otherwise reopens the place where the previous test ended.

`UITests/PhoneTourTests.swift` walks through the iPhone screens (library and date scrubber, selection and context menu,
viewer, Collections, Settings, Search, a memory, and every screen a link leads to). It runs only on an iPhone simulator,
needs the same login variable, and attaches a screenshot of every step; with `TEST_RUNNER_PHOTOS_UITEST_SHOTS=<directory>`
it also writes the screenshots and the accessibility tree of each step there.

### Apple TV and Apple Watch (SPEC §15.3)

`UITestsTV/TVTourTests.swift` tours the TV app with the Siri Remote (`XCUIRemote`): Home, a memory, the viewer, a
slideshow, Albums, Settings. Same rules as the smoke tests above; screenshots go to `PHOTOS_SHOTS_DIR` when set. Install
the runtimes once with `xcodebuild -downloadPlatform tvOS` and `… watchOS`.

```sh
xcrun simctl create tv "Apple TV 4K (3rd generation)" com.apple.CoreSimulator.SimRuntime.tvOS-27-2   # prints <udid>
xcrun simctl boot <udid>
TEST_RUNNER_PHOTOS_UITEST_LOGIN='nc://login/server:http://localhost:8089&user:admin&password:admin' \
TEST_RUNNER_PHOTOS_SHOTS_DIR=/tmp/tv-shots \
  xcodebuild test -scheme NextcloudPhotosTV -destination 'platform=tvOS Simulator,id=<udid>' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PHOTOS_DEBUG_ENTITLEMENTS=YES \
  PHOTOS_BUNDLE_ID=com.example.nextcloudphotos.uitest
```

Debug helpers: `PHOTOS_DEBUG_TV_SERVER=<address>` starts the TV's Login Flow at once (the QR code); a test can grant it
with the server's grant page; `PHOTOS_DEBUG_TV_ROUTE=nextcloudphotos://memories/<id>[/play]` (or `…/slideshow`) opens a
Top Shelf link at launch (`simctl openurl` asks "Open in…?", which needs the remote). The Top Shelf (`TopShelf/` in the
App Group container) needs `PHOTOS_DEBUG_ENTITLEMENTS=YES`.

The watch app shows what the iPhone app sends. In a paired iPhone + watch simulator pair (`xcrun simctl pair <watch>
<phone>`; install the iPhone app and `…/Nextcloud Photos.app/Watch/Nextcloud Photos.app` on the watch) the digest
arrives, photo files did not (watchOS 27.2 simulator). For the watch's screens without a phone,
`PHOTOS_DEBUG_WATCH_DIGEST=<folder with digest.json and the JPEGs>` loads a digest at launch (the iPhone app keeps the
last one in `Library/Caches/WatchDigest`), and `PHOTOS_DEBUG_WATCH_PAGE=0|1|2` opens a page.

## Running the app in the iOS simulator

Use a simulator of your own, booted headless (`xcrun simctl boot <UDID>`; Simulator.app is not needed), and a bundle id
of your own. Debug builds need the entitlements switched on (`PHOTOS_DEBUG_ENTITLEMENTS=YES`): without them the keychain
cannot store the login, and the login fails with "Your login could not be saved in the keychain".

```sh
xcodegen generate
xcodebuild -scheme NextcloudPhotos -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath /tmp/photos-dd \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PHOTOS_DEBUG_ENTITLEMENTS=YES \
  PHOTOS_BUNDLE_ID=com.example.nextcloudphotos.sim build
xcrun simctl install <UDID> '/tmp/photos-dd/Build/Products/Debug-iphonesimulator/Nextcloud Photos.app'
SIMCTL_CHILD_PHOTOS_DEBUG_LOGIN='nc://login/server:http://localhost:8089&user:admin&password:admin' \
  xcrun simctl launch <UDID> com.example.nextcloudphotos.sim
xcrun simctl io <UDID> screenshot shot.png
xcrun simctl spawn <UDID> log show --last 2m --predicate 'process == "Nextcloud Photos"'
```

The simulator reaches servers on the Mac as `localhost`. `xcrun simctl openurl` asks "Open in Nextcloud Photos?" first;
UI tests open links without asking (`XCUIApplication.open(_:)`). Appearance and text size:
`xcrun simctl ui <UDID> appearance dark`, `xcrun simctl ui <UDID> content_size extra-extra-large`.

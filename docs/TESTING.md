# Testing

| Kind | Where | Needs | Runs in CI |
|---|---|---|---|
| Unit tests | `Packages/PhotosKit/Tests` (Swift Testing) | macOS 27 or an iOS 27 simulator | every pull request (macOS and iOS simulator) |
| Performance tests | `LargeLibraryPerformanceTests` | a few minutes | pushes to `main`, nightly; skipped on pull requests |
| Integration tests | suites named `…Integration…Tests` | a Nextcloud server | nightly |
| UI smoke tests | `UITests` (XCUITest) | a Nextcloud server, a Debug build | no |
| Device tests | [test-plan.md](test-plan.md) | devices | no |

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

Run them one after the other (`--no-parallel`, with xcodebuild `-parallel-testing-enabled NO`): the suites change the
same account, and one of them counts its files while another uploads. The nightly workflow
(`.github/workflows/nightly.yml`) does exactly this on the macOS runner.

To test the features of newer Photos versions, point the variables at a server that has them; the tests check that
what the app detected matches what the server answers.

## UI smoke tests

`UITests/SmokeTests.swift` starts the app, signs in with the debug login and checks three things: the timeline shows
photos; the first photo opens in the viewer and closes again; the Albums screen opens. They only look and navigate.

- They need a **Debug** build (the debug login does not exist in Release) and a test server with photos, and run only
  when `PHOTOS_UITEST_LOGIN` holds a login link.
- Build them with **a bundle id of your own** (`PHOTOS_BUNDLE_ID`, on the command line or in `Config/Local.xcconfig`).
  The debug login only signs in when the app has no account yet, so with the official bundle id the tests would drive
  whatever account that installation has; they refuse to run in that case.
- On a Mac the tests take over keyboard and pointer while they run.

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

The app has no accessibility identifiers yet; the tests find elements by role and by their English labels, and start
the app in English. They are not part of CI because they need a server. They have run in the iOS 27.2 simulator (iPhone).

`UITests/AmbientUITests.swift` (SPEC §15.4) drives the system around the app, so it only makes sense in a simulator of
its own: `testBackupLiveActivity` and `testControlActions` (iPhone) need backup set up for the test account and new
photos in the simulator's library (`xcrun simctl addmedia`); `testControls` and `testPhotoFrameWidget` add the controls
and widgets through Control Center's and the Home Screen's galleries, as a user would; `testMemoryRoom` (Vision Pro)
opens a memory's room, with `PHOTOS_DEBUG_MEMORY_ROOM_FOCUS=1` bringing the first frame close (XCUITest cannot look and
pinch). With `PHOTOS_UITEST_SHOTS=<folder>` (`TEST_RUNNER_…`) the iPhone tests write their screenshots there; on Vision Pro
`XCUIScreen` captures nothing, take them with `xcrun simctl io <udid> screenshot` while the test runs.

For other UI work, Debug builds also sign in without a browser when started with
`PHOTOS_DEBUG_LOGIN='nc://login/server:<url>&user:<user>&password:<app password>'`.

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

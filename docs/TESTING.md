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

The app has no accessibility identifiers yet; the tests find elements by role and by their English labels, and start
the app in English. They are not part of CI because they need a server and, for now, have only been compiled
(`build-for-testing` for macOS and iOS), not run.

For other UI work, Debug builds also sign in without a browser when started with
`PHOTOS_DEBUG_LOGIN='nc://login/server:<url>&user:<user>&password:<app password>'`.

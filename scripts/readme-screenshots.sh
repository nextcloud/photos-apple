#!/bin/zsh
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
#
# The README's screenshots (docs/screenshots), from the real app against a test server with the sample library.
#
#   scripts/readme-screenshots.sh <output directory> <iphone|ipad|vision|tv|watch> <simulator udid>
#
# Use a simulator of your own (`xcrun simctl create …`): the app is installed, signed in and, on iPhone and iPad,
# uninstalled again after the backup shots. The PNGs land in <output>/<platform>/; pick the best ones, then scale them
# for the README (iPhone 600 px wide, the others at most 1400 px, JPEG quality about 80, each under 400 KB).
#
# - iphone, ipad: `UITests/ReadmeScreenshots` (Library and its zoom levels, viewer and info, editor tools, memories,
#   search, map, albums, backup). The iPad is turned to landscape; XCUITest stores landscape shots rotated, so turn
#   them by 90° before use. Backup shows the device's photos that are not on the server: set README_DEVICE_PHOTOS to
#   a folder of photos without EXIF dates (they are added to the simulator, dated now); without it the app adds four
#   plain coloured ones. Nothing is uploaded during the shots; the app is uninstalled afterwards, because the backup
#   it turned on would upload at the next launch.
# - vision: the Library and the map, each a launch with `simctl` (the visionOS UI tests do not build on their own).
#   Incremental visionOS builds of the app fail with "Cycle inside NextcloudPhotos" (Xcode 27.2): use a new
#   README_SHOTS_DERIVED_DATA folder for each run.
# - tv: `UITestsTV/TVTourTests` (home, a memory, viewer, slideshow, albums, settings).
# - watch: the watch app needs what the iPhone app sends (SPEC §15.3). Set README_WATCH_DIGEST to a folder with
#   `digest.json` and its JPEGs: the iPhone app's outbox (`Library/Caches/WatchDigest` in the app's container on an
#   iPhone simulator paired with a watch), or one made by hand in the same format (`WatchDigest`).
# - Mac: scripts/readme-screenshots-mac.sh (window captures of the Debug app; it comes to the front while it runs).
#
# Environment: README_SHOTS_LOGIN (default the local test server on 8089), README_SHOTS_BUNDLE_ID (default
# com.nextcloud.photos.shots), README_SHOTS_DERIVED_DATA (default /tmp/photos-ios-dd-readme-<platform>),
# PHOTOS_UITEST_SHOT_PHOTO / PHOTOS_UITEST_SHOT_EDIT_PHOTO (file ids of the photos for the viewer and the editor;
# default 3039 and 2806 of the test library), PHOTOS_UITEST_SHOT_SEARCH (default "Lisbon 2025").

set -u
OUT=${1:?usage: $0 <output directory> <iphone|ipad|vision|tv|watch> <simulator udid>}
PLATFORM=${2:?platform}
UDID=${3:?simulator udid}
LOGIN=${README_SHOTS_LOGIN:-'nc://login/server:http://localhost:8089&user:admin&password:admin'}
BUNDLE=${README_SHOTS_BUNDLE_ID:-com.nextcloud.photos.shots}
DD=${README_SHOTS_DERIVED_DATA:-/tmp/photos-ios-dd-readme-$PLATFORM}
ROOT=${0:A:h:h}
DIR=$OUT/$PLATFORM
cd "$ROOT" || exit 1
mkdir -p "$DIR"
xcodegen generate -q >/dev/null

xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" >/dev/null
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 2>/dev/null
xcrun simctl ui "$UDID" appearance light 2>/dev/null

# The app alone, for a simctl launch.
build_app() {
    xcodebuild build -scheme "$1" -destination "id=$UDID" -derivedDataPath "$DD" -jobs 6 PHOTOS_DEBUG_ENTITLEMENTS=YES \
        CODE_SIGN_IDENTITY=- PHOTOS_BUNDLE_ID="$BUNDLE" >"$DIR/build.log" 2>&1 || { echo "build failed: $DIR/build.log"; exit 1; }
    APP=$(ls -d "$DD"/Build/Products/Debug-*/*.app | grep -v Runner | head -1)
    xcrun simctl install "$UDID" "$APP"
}

# One launch, one screenshot after the wait.
launch_and_shoot() { # <bundle id> <name> <seconds> [VAR=value ...]
    local id=$1 name=$2 wait=$3
    shift 3
    xcrun simctl terminate "$UDID" "$id" 2>/dev/null
    sleep 1
    env "${(@)argv/#/SIMCTL_CHILD_}" xcrun simctl launch "$UDID" "$id" -AppleLanguages "(en)" -AppleLocale en_US \
        -albumsSortOrder name -weeklyPromptsInvitationDismissed YES >/dev/null
    sleep "$wait"
    xcrun simctl io "$UDID" screenshot "$DIR/$name.png" >/dev/null 2>&1 && echo "  $name.png"
}

ui_tests() { # <tests…>
    local only=()
    for test in "$@"; do only+=(-only-testing:NextcloudPhotosUITests/ReadmeScreenshots/$test); done
    TEST_RUNNER_PHOTOS_UITEST_LOGIN=$LOGIN TEST_RUNNER_PHOTOS_UITEST_SHOTS=$DIR TEST_RUNNER_PHOTOS_UITEST_SHOT_PREFIX="$PLATFORM-" \
        TEST_RUNNER_PHOTOS_UITEST_SHOT_PHOTO=${PHOTOS_UITEST_SHOT_PHOTO:-3039} \
        TEST_RUNNER_PHOTOS_UITEST_SHOT_EDIT_PHOTO=${PHOTOS_UITEST_SHOT_EDIT_PHOTO:-2806} \
        TEST_RUNNER_PHOTOS_UITEST_SHOT_SEARCH=${PHOTOS_UITEST_SHOT_SEARCH:-Lisbon 2025} \
        TEST_RUNNER_PHOTOS_UITEST_LANDSCAPE=$([[ $PLATFORM == ipad ]] && echo 1 || echo 0) \
        TEST_RUNNER_PHOTOS_UITEST_BACKUP_SAMPLES=$([[ -n ${README_DEVICE_PHOTOS:-} ]] && echo 0 || echo 4) \
        xcodebuild test-without-building -scheme NextcloudPhotosUITests -destination "id=$UDID" -derivedDataPath "$DD" \
        PHOTOS_BUNDLE_ID="$BUNDLE" "${only[@]}" >>"$DIR/xcodebuild.log" 2>&1
    grep -E "Test Case .*(passed|failed)" "$DIR/xcodebuild.log" | tail -n $# | sed 's/^/  /'
}

case $PLATFORM in
iphone | ipad)
    xcodebuild build-for-testing -scheme NextcloudPhotosUITests -destination "id=$UDID" -derivedDataPath "$DD" -jobs 6 \
        PHOTOS_DEBUG_ENTITLEMENTS=YES CODE_SIGN_IDENTITY=- PHOTOS_BUNDLE_ID="$BUNDLE" >"$DIR/build.log" 2>&1 ||
        { echo "build failed: $DIR/build.log"; exit 1; }
    ui_tests testLibrary testViewer testEditor testMemories testSearch testDestinations
    # Last: backup stays on in the app's settings, so the app goes afterwards.
    [[ -n ${README_DEVICE_PHOTOS:-} ]] && xcrun simctl addmedia "$UDID" "$README_DEVICE_PHOTOS"/*(.)
    xcrun simctl privacy "$UDID" grant photos "$BUNDLE" 2>/dev/null
    ui_tests testBackup
    xcrun simctl uninstall "$UDID" "$BUNDLE"
    ;;
vision)
    build_app NextcloudPhotos
    # The first launch signs in and waits for the library; the albums then need less.
    launch_and_shoot "$BUNDLE" vision-albums 90 PHOTOS_DEBUG_LOGIN=$LOGIN PHOTOS_DEBUG_DESTINATION=albums
    launch_and_shoot "$BUNDLE" vision-map 30 PHOTOS_DEBUG_DESTINATION=map
    ;;
tv)
    xcodebuild build-for-testing -scheme NextcloudPhotosTV -destination "id=$UDID" -derivedDataPath "$DD" -jobs 6 \
        CODE_SIGN_IDENTITY=- PHOTOS_BUNDLE_ID="$BUNDLE" >"$DIR/build.log" 2>&1 || { echo "build failed: $DIR/build.log"; exit 1; }
    TEST_RUNNER_PHOTOS_UITEST_LOGIN=$LOGIN TEST_RUNNER_PHOTOS_SHOTS_DIR=$DIR \
        xcodebuild test-without-building -scheme NextcloudPhotosTV -destination "id=$UDID" -derivedDataPath "$DD" \
        PHOTOS_BUNDLE_ID="$BUNDLE" >"$DIR/xcodebuild.log" 2>&1
    grep -E "Test Case .*(passed|failed)" "$DIR/xcodebuild.log" | sed 's/^/  /'
    ;;
watch)
    DIGEST=${README_WATCH_DIGEST:?set README_WATCH_DIGEST to a folder with digest.json and its photos}
    build_app NextcloudPhotosWatch
    for page in 0 1 2; do
        launch_and_shoot "$BUNDLE.watchkitapp" watch-page$page 8 PHOTOS_DEBUG_WATCH_DIGEST=$DIGEST PHOTOS_DEBUG_WATCH_PAGE=$page
    done
    ;;
*)
    echo "unknown platform $PLATFORM"
    exit 1
    ;;
esac
xcrun simctl status_bar "$UDID" clear 2>/dev/null
for file in "$DIR"/*.png(N); do echo "  ${file:t}: $(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}')"; done

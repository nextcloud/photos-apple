#!/bin/zsh
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
#
# App Store screenshots from the real app (SPEC §20.6, docs/RELEASE-CHECKLIST.md).
#
#   scripts/app-store-screenshots.sh <output directory> <simulator udid>...
#
# For every simulator: a clean status bar (9:41, full battery and signal), the app signed in to the test server with
# the sample library (installed fresh with PHOTOS_SHOTS_FRESH=1; otherwise an earlier install and its caches are
# kept), then UITests/AppStoreScreenshots (a warm-up, then one test per screen); the PNGs land in
# <output>/<device name>/. Use the sizes App Store Connect asks for: iPhone 6.9" (iPhone 17 Pro Max, 1320 × 2868),
# iPad 13" (iPad Pro 13-inch, 2064 × 2752) and, for the visionOS app, Apple Vision Pro (3840 × 2160). The Mac's screenshots are window captures
# of the Mac app (docs/RELEASE-CHECKLIST.md).
#
# Environment: PHOTOS_SHOTS_LOGIN (default the local test server on 8089), PHOTOS_SHOTS_BUNDLE_ID (default
# com.nextcloud.photos.shots), PHOTOS_SHOTS_DERIVED_DATA (default /tmp/photos-ios-dd-shots), PHOTOS_UITEST_LANGUAGE /
# PHOTOS_UITEST_LOCALE (default en / en_US), PHOTOS_UITEST_SHOT_PHOTO (the tile the viewer shot opens),
# PHOTOS_UITEST_SHOT_SEARCH (the search text). Needs a Debug build; nothing on the server changes.

set -u
OUT=${1:?usage: $0 <output directory> <simulator udid>...}
shift
LOGIN=${PHOTOS_SHOTS_LOGIN:-'nc://login/server:http://127.0.0.1:8089&user:admin&password:admin'}
BUNDLE=${PHOTOS_SHOTS_BUNDLE_ID:-com.nextcloud.photos.shots}
DD=${PHOTOS_SHOTS_DERIVED_DATA:-/tmp/photos-ios-dd-shots}
ROOT=${0:A:h:h}
cd "$ROOT" || exit 1
xcodegen generate -q >/dev/null

for UDID in "$@"; do
    NAME=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/^ *(.*) \([0-9A-F-]{36}\).*/\1/')
    DIR="$OUT/${NAME// /-}"
    mkdir -p "$DIR"
    xcrun simctl boot "$UDID" 2>/dev/null
    xcrun simctl bootstatus "$UDID" >/dev/null
    xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 2>/dev/null
    xcrun simctl ui "$UDID" appearance light 2>/dev/null
    # A fresh install only when asked: a warm cache (an earlier run) gives sharper first screens.
    [[ ${PHOTOS_SHOTS_FRESH:-0} == 1 ]] && xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null
    TEST_RUNNER_PHOTOS_UITEST_LOGIN=$LOGIN TEST_RUNNER_PHOTOS_UITEST_SHOTS=$DIR \
        TEST_RUNNER_PHOTOS_UITEST_LANGUAGE=${PHOTOS_UITEST_LANGUAGE:-en} TEST_RUNNER_PHOTOS_UITEST_LOCALE=${PHOTOS_UITEST_LOCALE:-en_US} \
        TEST_RUNNER_PHOTOS_UITEST_SHOT_PHOTO=${PHOTOS_UITEST_SHOT_PHOTO:-3} \
        TEST_RUNNER_PHOTOS_UITEST_SHOT_SEARCH=${PHOTOS_UITEST_SHOT_SEARCH:-Lisbon} \
        xcodebuild test -scheme NextcloudPhotosUITests -destination "id=$UDID" -derivedDataPath "$DD" -jobs 4 \
        PHOTOS_DEBUG_ENTITLEMENTS=YES CODE_SIGN_IDENTITY=- PHOTOS_BUNDLE_ID="$BUNDLE" \
        -only-testing:NextcloudPhotosUITests/AppStoreScreenshots >"$DIR/xcodebuild.log" 2>&1
    echo "== $NAME: xcodebuild exit $?"
    grep -E "Test Case .*(passed|failed)" "$DIR/xcodebuild.log" | sed 's/^/  /'
    xcrun simctl status_bar "$UDID" clear 2>/dev/null
    for file in "$DIR"/*.png(N); do echo "  ${file:t}: $(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}')"; done
done

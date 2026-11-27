#!/bin/zsh
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
#
# The README's Mac screenshots (docs/screenshots), from the Debug app against a test server with the sample library.
#
#   scripts/readme-screenshots-mac.sh <output directory>
#
# Builds the Mac app with a bundle id of its own, then launches it once per shot with launch settings only
# (`open -n --env …`; never a nextcloudphotos:// link, which the owner's own installation could answer), waits, captures
# its window (`screencapture -x -o -l <window id>`, the id from CGWindowListCopyWindowInfo for exactly that process) and
# quits that process by its PID. Light mode through `-NSRequiresAquaSystemAppearance YES`. The app comes to the front
# while it runs; nothing is clicked or typed. Nothing on the server changes.
#
# Shots (PNG, in <output>/mac/): library (the first launch signs in and waits for the first sync), viewer with its info
# (PHOTOS_DEBUG_VIEWER, PHOTOS_DEBUG_VIEWER_INFO), map and albums (PHOTOS_DEBUG_DESTINATION), compare
# (PHOTOS_DEBUG_COMPARE), people (on a server without Recognize: the faces Vision finds on this Mac,
# PHOTOS_DEBUG_FACES_NOW). The window keeps the size of the last run: set it once by hand in that installation if needed.
# Then scale them for the README like the other platforms (at most 1400 px wide, JPEG quality about 80).
#
# Environment: README_SHOTS_LOGIN (default the local test server on 8089), README_SHOTS_BUNDLE_ID (default
# com.nextcloud.photos.shots.mac), README_SHOTS_DERIVED_DATA (default /tmp/photos-ios-dd-readme-mac),
# README_SHOTS_VIEWER_INDEX (the Library's n-th photo for the viewer, default 3), README_SHOTS_FIRST_WAIT (seconds for
# the sign-in and first sync, default 90), README_SHOTS_PEOPLE_WAIT (seconds for the faces, default 90),
# README_SHOTS_JOBS (xcodebuild -jobs, default 4), README_SHOTS_SKIP_BUILD=1 (use the app built before),
# README_SHOTS_ONLY (names of the shots to take, e.g. "viewer compare"; the first launch signs in, whichever it is).

set -u
OUT=${1:?usage: $0 <output directory>}
LOGIN=${README_SHOTS_LOGIN:-'nc://login/server:http://localhost:8089&user:admin&password:admin'}
BUNDLE=${README_SHOTS_BUNDLE_ID:-com.nextcloud.photos.shots.mac}
DD=${README_SHOTS_DERIVED_DATA:-/tmp/photos-ios-dd-readme-mac}
# The real path (/tmp is /private/tmp): the PIDs are found by the executable path the process reports.
mkdir -p "$DD"
DD=${DD:A}
VIEWER_INDEX=${README_SHOTS_VIEWER_INDEX:-3}
FIRST_WAIT=${README_SHOTS_FIRST_WAIT:-90}
ROOT=${0:A:h:h}
DIR=$OUT/mac
APP="$DD/Build/Products/Debug/Nextcloud Photos.app"
EXEC="$APP/Contents/MacOS/Nextcloud Photos"
cd "$ROOT" || exit 1
mkdir -p "$DIR"

# The owner's installations hold a real account (the debug login only signs in when there is none).
if [[ $BUNDLE == com.nextcloud.photos || $BUNDLE == com.karlitschek.nextcloudphotos ]]; then
    echo "Refusing $BUNDLE: use a bundle id of your own."
    exit 2
fi

if [[ ${README_SHOTS_SKIP_BUILD:-0} != 1 ]]; then
    xcodegen generate -q >/dev/null
    xcodebuild build -scheme NextcloudPhotos -destination 'platform=macOS' -derivedDataPath "$DD" -jobs "${README_SHOTS_JOBS:-4}" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PHOTOS_BUNDLE_ID="$BUNDLE" >"$DIR/build.log" 2>&1 ||
        { echo "build failed: $DIR/build.log"; exit 1; }
fi
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist") == "$BUNDLE" ]] ||
    { echo "$APP is not built with $BUNDLE"; exit 1; }

# The id of the largest normal window of one process.
HELPER="$DD/window-id"
if [[ ! -x $HELPER ]]; then
    cat >"$DD/window-id.swift" <<'EOF'
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments.dropFirst().first ?? "") ?? 0
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}
let own = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
guard let window = own.max(by: { area($0) < area($1) }), let id = window[kCGWindowNumber as String] as? Int else { exit(1) }
print(id)
EOF
    swiftc -O -o "$HELPER" "$DD/window-id.swift" || { echo "could not build the window helper"; exit 1; }
fi

# PIDs of this build's executable (with whatever arguments).
pids() { ps -axo pid=,command= | while read -r pid command; do [[ $command == "$EXEC"* ]] && echo $pid; done }

# Starts the app with launch settings (VAR=value …); prints the PID of exactly the process it started.
start_app() {
    local before=" $(pids | tr '\n' ' ') " envs=(--env "PHOTOS_DEBUG_LOGIN=$LOGIN") pid=""
    for setting in "$@"; do envs+=(--env "$setting"); done
    open -n -a "$APP" "${envs[@]}" --args -NSRequiresAquaSystemAppearance YES -AppleLanguages "(en)" -AppleLocale en_US \
        -albumsSortOrder name -weeklyPromptsInvitationDismissed YES
    for _ in {1..100}; do
        for candidate in $(pids); do [[ $before == *" $candidate "* ]] || pid=$candidate; done
        [[ -n $pid ]] && break
        sleep 0.1
    done
    echo $pid
}

stop_app() {
    [[ -n $1 ]] || return
    kill "$1" 2>/dev/null
    for _ in {1..100}; do kill -0 "$1" 2>/dev/null || return; sleep 0.1; done
    kill -9 "$1" 2>/dev/null
}

shoot() { # <name> <seconds> [VAR=value …]
    local name=$1 wait=$2
    shift 2
    [[ -z ${README_SHOTS_ONLY:-} || " $README_SHOTS_ONLY " == *" $name "* ]] || return
    local pid=$(start_app "$@")
    [[ -n $pid ]] || { echo "  $name: the app did not start"; return; }
    sleep "$wait"
    # The window is sometimes not listed for a moment (seen once after a launch); look again for a few seconds.
    local window=""
    for _ in {1..20}; do
        window=$("$HELPER" "$pid") && break
        sleep 0.5
    done
    if [[ -n $window ]] && screencapture -x -o -l "$window" "$DIR/mac-$name.png"; then
        echo "  mac-$name.png"
    else
        echo "  $name: no window"
    fi
    stop_app "$pid"
    sleep 2
}

shoot library "$FIRST_WAIT"
shoot viewer 20 PHOTOS_DEBUG_VIEWER=$VIEWER_INDEX PHOTOS_DEBUG_VIEWER_INFO=1
shoot map 30 PHOTOS_DEBUG_DESTINATION=map
shoot albums 25 PHOTOS_DEBUG_DESTINATION=albums
shoot compare 20 PHOTOS_DEBUG_COMPARE=2
# People without Recognize: Apple's Vision looks at the library on this Mac (PHOTOS_DEBUG_FACES_NOW), about a minute.
shoot people "${README_SHOTS_PEOPLE_WAIT:-90}" PHOTOS_DEBUG_DESTINATION=people PHOTOS_DEBUG_FACES_NOW=1
for file in "$DIR"/*.png(N); do echo "  ${file:t}: $(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}')"; done

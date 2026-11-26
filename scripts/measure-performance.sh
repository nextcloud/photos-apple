#!/bin/zsh
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
#
# Measures the SPEC §10 budgets that can be measured without a device (SPEC §20.6, docs/PERFORMANCE.md).
#
#   scripts/measure-performance.sh ios <simulator udid> [output directory]
#       Fresh install on that simulator, then UITests/PerformanceTests: launch (XCTApplicationLaunchMetric), launch to
#       the first tile, Library scrolling (scroll hitch metrics, memory), viewer paging (hitches, memory). Adds the
#       launch milestones of LaunchMetrics from the simulator's log and the viewer/tile times of the cache metrics.
#
#   scripts/measure-performance.sh mac <path to a Debug "Nextcloud Photos.app"> [output directory]
#       Launches that build in the background (never activated) five times: time to the first pictures (LaunchMetrics),
#       memory footprint; then once with PHOTOS_DEBUG_GRID_SCROLL for frame pacing while scrolling, and the viewer's
#       time to a picture (PHOTOS_DEBUG_VIEWER). Build it with a bundle id of your own. The window stays in the
#       background: if other windows cover it, its display link is throttled and the frame pacing says little
#       (scroll-metrics.json: windowVisible).
#
# Environment: PHOTOS_PERF_LOGIN (login link, default the local test server on 8089), PHOTOS_PERF_BUNDLE_ID
# (default com.nextcloud.photos.perf; for `mac` it is read from the app), PHOTOS_PERF_ITERATIONS (default 5),
# PHOTOS_PERF_DERIVED_DATA (iOS build products, default /tmp/photos-ios-dd-perf).
# Needs a Debug build (the debug login and the debug scroll do not exist in Release). Nothing on the server changes.

set -u
MODE=${1:-}
TARGET=${2:-}
OUT=${3:-$PWD/perf-$(date +%Y%m%d-%H%M)}
LOGIN=${PHOTOS_PERF_LOGIN:-'nc://login/server:http://127.0.0.1:8089&user:admin&password:admin'}
ITERATIONS=${PHOTOS_PERF_ITERATIONS:-5}
ROOT=${0:A:h:h}
mkdir -p "$OUT"

summarise_launch() {
    # Median of each milestone over the lines of a log.
    for milestone in picture screen; do
        grep -Eo "Launch: first $milestone after [0-9]+ ms" "$1" | grep -Eo '[0-9]+ ms' | grep -Eo '[0-9]+' | sort -n |
            awk -v m="$milestone" '{v[NR]=$1} END {if (NR) printf "  launch → first %s: median %d ms (n=%d, min %d, max %d)\n", m, v[int((NR+1)/2)], NR, v[1], v[NR]}'
    done
}

summarise_cache_metrics() {
    [[ -f $1 ]] || { echo "  (no cache metrics)"; return; }
    python3 -I - "$1" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
names = {0: "tile", 1: "viewer, first picture", 2: "viewer, 1024 preview"}
for entry in data.get("times", []):
    name = names.get(entry.get("timing"), str(entry.get("timing")))
    print(f"  {name}: p50 {entry.get('p50', 0):.0f} ms, p95 {entry.get('p95', 0):.0f} ms (n={entry.get('count')})")
EOF
}

case $MODE in
ios)
    [[ -n $TARGET ]] || { echo "usage: $0 ios <simulator udid> [output]"; exit 2; }
    BUNDLE=${PHOTOS_PERF_BUNDLE_ID:-com.nextcloud.photos.perf}
    DD=${PHOTOS_PERF_DERIVED_DATA:-/tmp/photos-ios-dd-perf}
    cd "$ROOT" || exit 1
    xcodegen generate -q >/dev/null
    xcrun simctl boot "$TARGET" 2>/dev/null
    xcrun simctl bootstatus "$TARGET" >/dev/null
    xcrun simctl uninstall "$TARGET" "$BUNDLE" 2>/dev/null
    START=$(date '+%Y-%m-%d %H:%M:%S')
    TEST_RUNNER_PHOTOS_UITEST_LOGIN=$LOGIN TEST_RUNNER_PHOTOS_UITEST_ITERATIONS=$ITERATIONS \
        xcodebuild test -scheme NextcloudPhotosUITests -destination "id=$TARGET" -derivedDataPath "$DD" -jobs 4 \
        -resultBundlePath "$OUT/PerformanceTests.xcresult" \
        PHOTOS_DEBUG_ENTITLEMENTS=YES CODE_SIGN_IDENTITY=- PHOTOS_BUNDLE_ID="$BUNDLE" \
        -only-testing:NextcloudPhotosUITests/PerformanceTests >"$OUT/xcodebuild.log" 2>&1
    echo "xcodebuild exit $?"
    xcrun simctl spawn "$TARGET" log show --start "$START" --style compact \
        --predicate 'subsystem == "com.nextcloud.photos" AND category == "performance"' >"$OUT/performance.log" 2>/dev/null
    CONTAINER=$(xcrun simctl get_app_container "$TARGET" "$BUNDLE" data 2>/dev/null)
    [[ -n $CONTAINER ]] && cp "$CONTAINER/Library/Caches/cache-metrics.json" "$OUT/" 2>/dev/null
    echo "load average: $(sysctl -n vm.loadavg)"
    echo "== $(xcrun simctl list devices | grep "$TARGET" | sed 's/^ *//')"
    grep -E "Test Case .*(passed|failed)" "$OUT/xcodebuild.log" | sed 's/^/  /'
    # The simulator reports only the durations of the scroll signposts; hitch time ratio and frame rate need a device.
    grep -E "measured \[" "$OUT/xcodebuild.log" |
        sed -E 's/.*PerformanceTests (test[A-Za-z0-9]+)\]. measured \[([^]]+)\] average: (-?[0-9.]+), relative standard deviation: (-?[0-9.]+%).*/  \1: \2 = \3 (±\4)/'
    summarise_launch "$OUT/performance.log"
    summarise_cache_metrics "$OUT/cache-metrics.json"
    ;;
mac)
    [[ -d $TARGET ]] || { echo "usage: $0 mac <Nextcloud Photos.app> [output]"; exit 2; }
    APP=${TARGET:A}
    BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
    [[ $BUNDLE == com.nextcloud.photos || $BUNDLE == com.karlitschek.nextcloudphotos ]] && {
        echo "Refusing $BUNDLE: its container holds a real account. Build with PHOTOS_BUNDLE_ID of your own."
        exit 2
    }
    EXEC="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
    CACHES=~/Library/Containers/$BUNDLE/Data/Library/Caches
    START=$(date '+%Y-%m-%d %H:%M:%S')
    # Starts the build in the background with the given environment; prints the PID of exactly this executable.
    start_app() {
        local before=$(pgrep -f -x "$EXEC" | tr '\n' ' ')
        open -g -n -a "$APP" --env "PHOTOS_DEBUG_LOGIN=$LOGIN" "$@"
        local pid=""
        for _ in {1..50}; do
            for candidate in $(pgrep -f -x "$EXEC"); do [[ " $before " == *" $candidate "* ]] || pid=$candidate; done
            [[ -n $pid ]] && break
            sleep 0.1
        done
        echo $pid
    }
    stop_app() { [[ -n $1 ]] && kill "$1" 2>/dev/null; for _ in {1..50}; do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done; }
    # Sign-in and first sync.
    PID=$(start_app)
    echo "first launch (sign-in, sync): pid $PID"
    sleep 90
    stop_app "$PID"
    for run in {1..$ITERATIONS}; do
        PID=$(start_app)
        sleep 12
        footprint -p "$PID" 2>/dev/null | grep -E 'phys_footprint:|Footprint' | head -1 | sed "s/^/  run $run: /"
        stop_app "$PID"
        sleep 2
    done | tee "$OUT/footprint.txt"
    PID=$(start_app --env PHOTOS_DEBUG_GRID_SCROLL=4000,8)
    sleep 30
    footprint -p "$PID" 2>/dev/null | grep -E 'phys_footprint:|Footprint' | head -1 | sed 's/^/  after scrolling: /' | tee -a "$OUT/footprint.txt"
    stop_app "$PID"
    cp "$CACHES/scroll-metrics.json" "$OUT/" 2>/dev/null
    # The viewer opens on the 8th photo at launch; the debug scroll at speed 0 only writes the cache metrics.
    PID=$(start_app --env PHOTOS_DEBUG_VIEWER=7 --env PHOTOS_DEBUG_GRID_SCROLL=0,8)
    sleep 40
    stop_app "$PID"
    cp "$CACHES/cache-metrics.json" "$OUT/" 2>/dev/null
    /usr/bin/log show --start "$START" --style compact \
        --predicate 'subsystem == "com.nextcloud.photos" AND category == "performance"' >"$OUT/performance.log" 2>/dev/null
    echo "load average: $(sysctl -n vm.loadavg)"
    echo "== Mac ($BUNDLE)"
    summarise_launch "$OUT/performance.log"
    grep -Eo 'Scroll: .*' "$OUT/performance.log" | sed 's/^/  /'
    cat "$OUT/footprint.txt"
    summarise_cache_metrics "$OUT/cache-metrics.json"
    ;;
*)
    sed -n '5,22p' "$0"
    exit 2
    ;;
esac
echo "Results in $OUT"

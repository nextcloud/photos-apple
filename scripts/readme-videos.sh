#!/bin/zsh
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
#
# The README's short videos (docs/media): the simulator's screen recorded while `UITests/ReadmeVideos` plays an
# interaction, then framed like the screenshots and encoded as an MP4 and an animated WebP (GitHub shows no <video> from
# the repository in a README, but it shows animated WebP).
#
#   scripts/readme-videos.sh record <output directory> <simulator udid> [test …]
#       Runs the tests (default: testLevels testMemory testViewer testEditor; build them before with
#       `xcodebuild build-for-testing -scheme NextcloudPhotosUITests …`, as scripts/readme-screenshots.sh does) and records
#       <output>/<name>.mov for each (`xcrun simctl io <udid> recordVideo`), started and stopped by the test through files
#       in the output directory (see ReadmeVideos).
#   scripts/readme-videos.sh encode <recording.mov> <output basename> [kind] [width] [start] [end] [speed]
#       Cuts the recording to start…end (seconds, default all), plays it `speed` times as fast (default 1), frames it
#       (kind: phone, tablet, plain; scripts/frame-screenshots.swift) at `width` px of screen (default 360) and writes
#       <basename>.mp4 (H.264, 24 fps) and <basename>.webp (animated, 15 fps).
#
# Environment for record: README_SHOTS_LOGIN (default the local test server on 8089), README_SHOTS_BUNDLE_ID (default
# com.nextcloud.photos.shots), README_SHOTS_DERIVED_DATA (default /tmp/photos-ios-dd-readme-iphone), and the tests' own
# PHOTOS_UITEST_* settings with the prefix TEST_RUNNER_ (e.g. TEST_RUNNER_PHOTOS_UITEST_VIDEO_ALBUM=Kyoto).
# Needs ffmpeg and img2webp (libwebp). README_VIDEO_QUALITY: the WebP's quality (default 60).

set -u
ROOT=${0:A:h:h}
MODE=${1:?usage: $0 record <output directory> <udid> [test …] | encode <recording.mov> <output basename> [kind] [width] [start] [end] [speed]}
shift

record() {
    local out=${1:?output directory} udid=${2:?simulator udid}
    shift 2
    local tests=("$@")
    ((${#tests})) || tests=(testLevels testMemory testViewer testEditor)
    local login=${README_SHOTS_LOGIN:-'nc://login/server:http://localhost:8089&user:admin&password:admin'}
    local bundle=${README_SHOTS_BUNDLE_ID:-com.nextcloud.photos.shots}
    local dd=${README_SHOTS_DERIVED_DATA:-/tmp/photos-ios-dd-readme-iphone}
    out=${out:A}
    mkdir -p "$out"
    rm -f "$out"/*.(start|recording|stop|done)(N)
    xcrun simctl boot "$udid" 2>/dev/null
    xcrun simctl bootstatus "$udid" >/dev/null
    xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 2>/dev/null
    xcrun simctl ui "$udid" appearance light 2>/dev/null
    local only=()
    for test in "${tests[@]}"; do only+=(-only-testing:NextcloudPhotosUITests/ReadmeVideos/$test); done
    (cd "$ROOT" && TEST_RUNNER_PHOTOS_UITEST_LOGIN=$login TEST_RUNNER_PHOTOS_UITEST_VIDEOS=$out \
        xcodebuild test-without-building -scheme NextcloudPhotosUITests -destination "id=$udid" -derivedDataPath "$dd" \
        PHOTOS_BUNDLE_ID="$bundle" "${only[@]}" >"$out/xcodebuild.log" 2>&1) &
    local runner=$! recorder="" name=""
    # Answers the test's signals until xcodebuild ends.
    while kill -0 $runner 2>/dev/null; do
        for file in "$out"/*.start(N); do
            name=${file:t:r}
            rm -f "$file"
            # A test that failed while recording left its recorder running.
            if [[ -n $recorder ]]; then
                kill -INT $recorder 2>/dev/null
                wait $recorder 2>/dev/null
            fi
            xcrun simctl io "$udid" recordVideo --codec h264 --force "$out/$name.mov" >/dev/null 2>&1 &
            recorder=$!
            sleep 1.5
            touch "$out/$name.recording"
            echo "  recording $name"
        done
        for file in "$out"/*.stop(N); do
            name=${file:t:r}
            rm -f "$file"
            if [[ -n $recorder ]]; then
                kill -INT $recorder 2>/dev/null
                wait $recorder 2>/dev/null
                recorder=""
            fi
            touch "$out/$name.done"
            echo "  $name.mov"
        done
        sleep 0.2
    done
    [[ -n $recorder ]] && kill -INT $recorder 2>/dev/null
    rm -f "$out"/*.(recording|done)(N)
    xcrun simctl status_bar "$udid" clear 2>/dev/null
    grep -E "Test Case .*(passed|failed)" "$out/xcodebuild.log" | sed 's/^/  /'
}

encode() {
    local input=${1:?recording} base=${2:?output basename} kind=${3:-phone} width=${4:-360} start=${5:-0} end=${6:-} speed=${7:-1}
    local work=$(mktemp -d)
    local cut=(-ss "$start")
    [[ -n $end ]] && cut+=(-to "$end")
    # The screen at its README size, as fast as asked, at a steady frame rate.
    ffmpeg -loglevel error -y "${cut[@]}" -i "$input" \
        -vf "setpts=PTS/${speed},fps=24,scale=${width}:-2:flags=lanczos" -an -c:v libx264 -crf 12 -pix_fmt yuv420p "$work/screen.mp4" || return 1
    ffmpeg -loglevel error -y -i "$work/screen.mp4" -frames:v 1 "$work/first.png" || return 1
    # The frame around it, from the first picture: background with the screen cut out, the screen's mask, its place.
    local screenHeight=$(sips -g pixelHeight "$work/first.png" | awk '/pixelHeight/ {print $2}')
    swift "$ROOT/scripts/frame-screenshots.swift" --height "$screenHeight" --margin 0.06 --template "$work" \
        "$work/frame.png" "$work/first.png:$kind" >/dev/null || return 1
    read -r x y w h <"$work/geometry.txt"
    ffmpeg -loglevel error -y -i "$work/screen.mp4" -i "$work/mask.png" -loop 1 -i "$work/background.png" -filter_complex \
        "[0:v]scale=${w}:${h},format=rgba[s];[1:v]format=gray,scale=${w}:${h}[m];[s][m]alphamerge[r];[2:v][r]overlay=${x}:${y}:shortest=1,format=rgba[v]" \
        -map "[v]" -c:v png -f mov "$work/framed.mov" || return 1
    # MP4 on white (no transparency in H.264); WebP keeps the card's rounded corners transparent.
    ffmpeg -loglevel error -y -i "$work/framed.mov" -filter_complex \
        "color=white,format=rgb24[c];[c][0:v]scale2ref[c][v];[c][v]overlay=shortest=1,format=yuv420p" \
        -c:v libx264 -preset slow -crf 26 -movflags +faststart "$base.mp4" || return 1
    # Animated WebP with img2webp (ffmpeg is often built without libwebp): 15 frames a second (67 ms each).
    mkdir -p "$work/frames"
    ffmpeg -loglevel error -y -i "$work/framed.mov" -vf "fps=15" "$work/frames/%04d.png" || return 1
    img2webp -loop 0 -lossy -q "${README_VIDEO_QUALITY:-60}" -m 6 -d 67 "$work"/frames/*.png -o "$base.webp" >/dev/null 2>&1 || return 1
    rm -rf "$work"
    echo "  ${base:t}.mp4 $(du -k "$base.mp4" | cut -f1) KB, ${base:t}.webp $(du -k "$base.webp" | cut -f1) KB"
}

case $MODE in
record) record "$@" ;;
encode) encode "$@" ;;
*)
    echo "unknown mode $MODE"
    exit 1
    ;;
esac

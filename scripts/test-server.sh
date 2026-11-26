#!/bin/sh
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: MIT
#
# Installs a throw-away Nextcloud (release archive, SQLite, PHP's built-in web server) for the integration and UI tests
# and serves it until it is stopped. The sample photos of a new account are the test library. See docs/TESTING.md.
#
#   scripts/test-server.sh <directory> [port]
#
# Environment: NEXTCLOUD_ARCHIVE (URL of a .tar.bz2 with a top-level "nextcloud" folder; default: latest release),
#              PHP (php binary; default: php). Login: admin / admin. Never expose this server to a network.
set -eu

DIR=${1:?usage: scripts/test-server.sh <directory> [port]}
PORT=${2:-8089}
PHP=${PHP:-php}
ARCHIVE=${NEXTCLOUD_ARCHIVE:-https://download.nextcloud.com/server/releases/latest.tar.bz2}

mkdir -p "$DIR"
DIR=$(cd "$DIR" && pwd)
rm -f "$DIR/ready"
if [ ! -f "$DIR/nextcloud/occ" ]; then
    echo "Downloading $ARCHIVE"
    curl -fsSL "$ARCHIVE" -o "$DIR/nextcloud.tar.bz2"
    tar -xjf "$DIR/nextcloud.tar.bz2" -C "$DIR"
    rm "$DIR/nextcloud.tar.bz2"
fi
cd "$DIR/nextcloud"

# Nextcloud refuses to run on macOS unless CI is set (it is only good enough for tests there).
export CI=1
occ() { "$PHP" -d memory_limit=1G occ "$@"; }

if ! occ status 2>/dev/null | grep -q "installed: true"; then
    occ maintenance:install --database sqlite --admin-user admin --admin-pass admin
    occ app:enable photos
    occ background:cron
fi
occ status

PHP_CLI_SERVER_WORKERS=8 "$PHP" -d memory_limit=1G -S "127.0.0.1:$PORT" -t . &
SERVER=$!
# With PHP_CLI_SERVER_WORKERS the server forks workers that outlive it: stop them first.
trap 'kill $(pgrep -P "$SERVER") "$SERVER" 2>/dev/null || true' EXIT
trap 'exit 130' INT TERM

URL="http://127.0.0.1:$PORT"
TRIES=0
until curl -fs "$URL/status.php" | grep -q '"installed":true'; do
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -gt 60 ]; then
        echo "The server did not start." >&2
        exit 1
    fi
    sleep 1
done

if [ ! -f "$DIR/seeded" ]; then
    FILES="$URL/remote.php/dav/files/admin"
    # The first request of a user copies the sample files (among them the folder "Photos") into the account.
    curl -fsS -o /dev/null -u admin:admin -X PROPFIND -H "Depth: 0" "$FILES/"
    # The backup tests look for a photo named like a camera file.
    curl -fsS -o /dev/null -u admin:admin -X COPY -H "Destination: $FILES/Photos/IMG_0001.jpg" "$FILES/Photos/Frog.jpg"
    # Sizes, dates and BlurHashes are written by the scan and by one background job per file. Only those jobs are run:
    # a full cron run also starts jobs that talk to the internet and may take minutes.
    occ files:scan --all --generate-metadata || true
    JOB='OC\FilesMetadata\Job\UpdateSingleMetadata'
    JOBS=$(occ background-job:list --class "$JOB" --limit 500 --output json | grep -o '"id"' | wc -l)
    while [ "$JOBS" -gt 0 ]; do
        occ background-job:worker --once "$JOB" >/dev/null
        JOBS=$((JOBS - 1))
    done
    touch "$DIR/seeded"
fi

# Scripts that start this server in the background wait for this file.
touch "$DIR/ready"
echo "Ready: $URL (admin / admin). Stop with Ctrl-C."
wait "$SERVER"

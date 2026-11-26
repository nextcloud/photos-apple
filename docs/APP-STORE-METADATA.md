# App Store metadata — draft for 1.0

English (U.S.) texts for App Store Connect. Character limits are Apple's; the counts are of the text as written here.
Everything claimed is built (SPEC §7, §15–§19); features that need something on the server say so. Translations come
through Transifex later (RELEASE-CHECKLIST step 5).

## Name (30) — 16

    Nextcloud Photos

## Subtitle (30) — 30

    Your photos on your own server

## Promotional text (170) — 154

    All your photos and videos from your Nextcloud in a fast native app. Back up your iPhone automatically and keep your
    memories private, on your own server.

## Keywords (100) — 98

    nextcloud,backup,gallery,album,cloud,self-hosted,private,camera upload,memories,sync,storage,photo

(Apple already indexes the name and subtitle, so "photos" and "server" are not repeated; no spaces after commas.)

## Description (4000) — about 2 500

    Nextcloud Photos brings the photos and videos on your Nextcloud to iPhone, iPad, Mac and Apple Vision Pro — fast,
    beautiful and private. Your library stays on the server you trust: no tracking, no ads, no account with us.

    YOUR WHOLE LIBRARY, INSTANTLY
    • Scroll through years of photos without waiting: the library is indexed on your device and previews are cached
      smartly, so the photos that matter are there even offline.
    • Zoom from years to months to days, jump with the date scroller, open photos and videos full screen, play Live
      Photos, zoom into RAW and panoramas.
    • Search by place, date, file name, tag or person, or just type "beach 2024".

    BACK UP WITHOUT DUPLICATES
    • Turn on backup and every new photo and video goes to your Nextcloud, also in the background.
    • Already using the Nextcloud Files app's auto upload? Nextcloud Photos sees what is already there and never
      uploads a photo twice.
    • Originals in full quality, Live Photos with their video, your choice of folder and file names.

    ALBUMS AND SHARING
    • Create albums, share them with people on your server or by link, and see albums shared with you.
    • Keep albums offline for the plane, add photos by drag and drop, share from any app with the share extension.

    MEMORIES AND PLACES
    • Memories, On this day and Year in Review, as stories or as films with music.
    • A map of everywhere you took photos, places by country, and a travel globe.
    • People and faces when your server runs Recognize.

    EDIT AND ORGANIZE
    • Crop, straighten, filters and adjustments, saved without losing the original.
    • Favorites, tags, archive behind Face ID, recently deleted, and Clean Up to find duplicates and free space.
    • Edit date and location of many photos at once.

    MADE FOR EVERY APPLE DEVICE
    • iPhone and iPad with widgets, Lock Screen and StandBy, a Live Activity for the backup, Shortcuts and Siri.
    • A native Mac app with windows, keyboard shortcuts, memory card import and culling for photographers.
    • Apple Vision Pro with an immersive memory room, Apple TV for slideshows, and your favorites on Apple Watch.

    PRIVATE BY DESIGN
    Your photos go only to your Nextcloud. The app has no analytics and no third-party trackers. Optional app lock
    with Face ID, Touch ID or Optic ID.

    Requires a Nextcloud server (version 33 or later) with the Photos app. Some features need newer versions of the
    Photos app or apps like Recognize on your server; the app finds out what your server offers and shows only what
    works.

## What's New

First release: Apple does not show "What's New" for version 1.0. For TestFlight, "What to Test":

    Thank you for testing Nextcloud Photos! Please try:
    • Logging in to your own Nextcloud and browsing your whole library (scrolling, zooming, the viewer).
    • Turning on backup — especially if you also use the Nextcloud Files app's auto upload: tell us if any photo
      ends up twice on your server.
    • Albums, sharing, memories, the map, search, and the widgets.
    Send feedback with a screenshot from TestFlight, or open an issue at https://github.com/nextcloud/photos-ios.

Template for later versions (170 characters show without "more"):

    • <the one change users notice most>
    • <second change>
    • Fixes and speed-ups: <short list>

## URLs and other fields

| Field | Value (to confirm) |
|---|---|
| Support URL | https://help.nextcloud.com/ (or the GitHub issues of nextcloud/photos-ios) |
| Marketing URL | https://nextcloud.com/photos/ |
| Privacy Policy URL | https://nextcloud.com/privacy/ — must say that the app sends a push token to Nextcloud's push proxy |
| Copyright | 2026 Nextcloud GmbH |
| Category | Photo & Video (secondary: Productivity) |
| Age rating | 4+ (no objectionable content; user-generated content is the user's own) |
| Sign-in for review | demo server, user and app password (RELEASE-CHECKLIST step 8) |

## Screenshot captions (optional, if framed)

1. Your whole library, instantly
2. Every photo, full screen
3. Memories that tell a story
4. Albums you can share
5. Everywhere you've been
6. Find any photo in seconds
7. Backup without duplicates

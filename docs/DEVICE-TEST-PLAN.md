# Device test plan — what only real hardware can show

Everything in this app was built and checked on a Mac: unit and integration tests, the Mac app, UI tours in the iPhone
and iPad simulators. What the simulator cannot do — the system's background scheduling, push, the share sheet of other
apps, the 120 Hz display, real memory limits, Face ID, a Watch, a TV, a Vision Pro — is listed here. About two hours
for the iPhone part, one hour each for the rest. The broad functional pass per screen is [test-plan.md](test-plan.md);
this file is the short list that must pass before a TestFlight build goes to outside testers.

## Before you start (10 minutes)

1. **Build:** a TestFlight build, or a Debug build signed with `PHOTOS_DEBUG_ENTITLEMENTS = YES` and a bundle id of your own
   whose App ID has the App Group, keychain group and push (README, "Signing"). Without them D3–D7 fail for the wrong reason.
2. **Server:** a Nextcloud reachable from the device over `https://` with the Photos and Notifications apps. A second
   account on it (for shares). For D5 the push proxy must know the bundle id (`docs/RELEASE-CHECKLIST.md`, step 4).
3. **Library on the iPhone:** at least 500 photos including Live Photos, a few videos (one over 200 MB), screenshots,
   HEIC and edited photos. For D2 some of them already uploaded by the Nextcloud Files app's auto upload.
4. **Record:** open a GitHub issue "Device test <version> (<build>)", paste the table at the end, fill one row per check.
   For every ✗ open a separate issue and link it. Afterwards change the matching STATUS.md lines from 🟡 to ✅ (or ⬜).

Legend: **P** iPhone · **T** iPad · **M** Mac · **V** Vision Pro · **W** Apple Watch · **TV** Apple TV.

## D1 Backup without the Files app (P, T) — STATUS §M3

1. Fresh install, log in, Backup › Turn on, allow **full** photo library access, keep the defaults.
2. Leave the app in the foreground on Wi-Fi and power until the counter says everything is backed up.
3. On the web: count the files in the backup folder; open three photos, one Live Photo, the big video.
4. Take two new photos with the Camera app, come back to Nextcloud Photos.
5. Turn backup off and on again; wait a minute.

**Expected:** the web count equals the app's "backed up" count; originals open in full quality, the Live Photo plays on the
web, the video plays; the two new photos are uploaded within a minute of returning; step 5 uploads **nothing** again.

## D2 Backup next to the Files app's auto upload — duplicates (P) — STATUS §7.18.4/§7.18.5 acceptance test

1. On a device where the **Nextcloud Files app** has auto upload on and has uploaded part of the library: install
   Nextcloud Photos, log in to the **same account**, turn on backup with the **same folder** as the Files app.
2. Let it finish. On the web, sort the folder by name and look for pairs (`IMG_0001.HEIC` and `IMG_0001 (2).HEIC`, or the
   same photo under two names).
3. Repeat with a **different** backup folder than the Files app's.

**Expected:** step 2: no photo exists twice; the Backup screen says how many were already uploaded by the Files app.
Step 3: the app explains that photos already uploaded elsewhere are skipped (or uploads them once — note which). Record
the counts (device photos / already in Files / uploaded by Photos / duplicates found).

## D3 Backup in the background (P, T) — STATUS §7.18.6

1. Start a backup of at least 1 GB (take a 3-minute 4K video if needed). Press the side button to lock the device;
   leave it on power and Wi-Fi for 30 minutes.
2. Unlock, open the app: note the count before you touch anything.
3. Start another large backup, then open several heavy apps (Camera in 4K, a game) for 10 minutes so the system ends
   Nextcloud Photos. Do not force-quit it. Open it again after 30 minutes.
4. Force-quit the app (app switcher, swipe up) during a backup; open it again.
5. Settings › Battery after a day with backup on.

**Expected:** steps 1–2: uploads went on while locked (the web shows files with times during the 30 minutes); the
count is right at once. Step 3: what was handed to the system finished; nothing is uploaded twice. Step 4: no broken
files on the web, the backup continues without duplicates. Step 5: Nextcloud Photos is not among the top consumers
without having uploaded much. Note whether the PhotoKit background-upload extension ran (Console.app with the device connected: process
`BackgroundUpload`; or Settings › Diagnostics › Export diagnostics… and attach the file to the issue).

## D4 Background tasks (P, T)

1. With the app closed for a night (on power, Wi-Fi): the next morning, open the app **in airplane mode**.
2. Settings › Search › on-device labels on; leave the device on power overnight; search for "dog" or "beach".

**Expected:** step 1: the Library shows photos added on the web the evening before (background refresh ran), the On this
day widget shows today. Step 2: results come from labels made overnight (processing task ran). If either did not run,
note how long the app had been closed and whether Low Power Mode was on.

## D5 Push notifications (P, T, M, V) — STATUS §M4 push

1. Allow notifications when asked (after login). Close the app.
2. From the second account on the web: share an album with this account.
3. Tap the notification. Then dismiss a notification on the web.
4. On the web, trigger a notification of another app (e.g. a calendar reminder or a Talk mention).

**Expected:** step 2: a notification within seconds with readable text ("… shared the album …"), also when the app was
not running; step 3: the app opens the shared album; the dismissed notification disappears from the device. Step 4:
**not** shown if Apple granted the notification-filtering entitlement; otherwise note what appears. Repeat step 2 with a
**TestFlight** build: production APNs must work, not only development.

## D6 Share extension (P, T, M)

1. In Apple's Photos app select 1 photo, share › Nextcloud Photos › pick an album › Post.
2. Select 60 photos and a 500 MB video, share › Nextcloud Photos.
3. Turn on the app lock, share again.

**Expected:** step 1 appears on the web and in the album within seconds; step 2: progress, then all items on the
server — the extension does not crash on the big video (its memory limit), the upload finishes even if you leave the
share sheet; step 3: asks for Face ID / Touch ID / the password before it shows anything.

## D7 Widgets, Live Activity, Controls (P, T; widgets also M)

1. Add the "On this day" and "Favorites" widgets in every size, on the Home Screen and the Lock Screen; also StandBy
   (iPhone on its side on a charger).
2. Start a backup of 200+ photos and lock the device.
3. Add the Nextcloud Photos controls (backup on/off, Back Up Now, open the Library) to Control Center and press each.

**Expected:** step 1: each widget shows a photo of the account (never an archived one), tap opens the matching place,
it is legible tinted and in StandBy. Step 2: a Live Activity on the Lock Screen (and the Dynamic Island) counts down and
ends when the backup is done. Step 3: each control does what it names; backup on/off and Back Up Now work without opening the app.

## D8 Feel: 120 Hz, memory pressure, launch (P, T; the budgets of SPEC §10)

1. Kill the app, launch it: count how long until the Library shows photos (or record it with Instruments › App Launch).
2. Scroll the Library fast up and down for a minute, flick hard, scrub with the scroller; zoom levels by pinching.
3. Open a photo and swipe through 200 photos quickly.
4. Instruments (Xcode › Open Developer Tool) › **Animation Hitches** on steps 2–3; **Allocations** on step 3.
5. Open the app, then Camera in 4K, Maps in 3D and a game; come back to Nextcloud Photos.

**Expected** (SPEC §10, simulator numbers in [PERFORMANCE.md](PERFORMANCE.md)): launch to photos under 1 s; scrolling and
paging at 120 Hz without visible stutter, hitch time under 1 ms/s in Instruments (5 ms/s is Apple's "good" limit);
tiles show their blur, then the photo, never stay grey; memory under 300 MB while scrolling and paging; step 5: the app is
where you left it (state restored) or quickly back, never a crash. Record the launch time, the hitch ratios and the peak
memory in the issue.

## D9 Apple Watch (W, with the iPhone)

1. Install the app on the iPhone with the Watch paired; open the Watch app on the watch.
2. Add the complication to a watch face.

**Expected:** today's photos and favourites appear on the watch within a minute (sent by the iPhone, no login on the
watch); the complication shows the photo of the day and opens the app.

## D10 Apple TV (TV)

1. Install the TV app, type the server address; the TV shows a QR code, finish the login on the iPhone.
2. Play a memory and a slideshow with the Siri Remote; add the app to the top row of the Home Screen.

**Expected:** login works without typing a password on the TV; slideshows play smoothly at 4K; the Top Shelf shows recent
memories and opens them.

## D11 Vision Pro (V)

1. Log in; open the Library window, resize it, look at a tile and pinch; open a photo; open a panorama.
2. Open a memory in the memory room (immersive space); leave it with the Digital Crown.

**Expected:** eyes and pinch select tiles and buttons (hover highlight visible); ornaments do not cover the photo; the
panorama wraps around you; the memory room opens and closes without leaving a black space. Optic ID for the app lock.

## D12 Mac (M)

1. Notarized/TestFlight build from App Store Connect; first launch from /Applications.
2. Backup from a Mac's Photos library (if offered), share extension from Finder (Share › Nextcloud Photos),
   memory card import with a real SD card, drag photos from the grid to Finder.

**Expected:** Gatekeeper accepts the build; the sandbox allows the card, the Photos library and the dragged files; no
"wants to access" prompt without a reason text.

## D13 Backup you can see and large videos (P, T) — STATUS §21.1

1. With backup on, take three photos and a short video. Open the Library at once: they are at the top, under today,
   each with a cloud-with-a-slash badge; the account button has a small orange cloud; its menu says "4 not backed up".
   Turn on VoiceOver on one: "…, Not backed up".
2. Open one of them: it zooms like a server photo; the bar says "Not backed up". Tap **Back Up Now**: the badge turns
   into an arrow, then the bar says "Backed up" and, back in the grid, the tile is the server's copy (no duplicate).
3. Select two device photos and a server photo; long-press: Back Up Now, Share, the server photo's actions and Delete
   from This iPhone are offered. Share one by AirDrop/Messages (the original arrives); delete one (the system asks; it
   is in Recently Deleted and gone from the Library).
4. Settings › Backup › On this iPhone › Show in Library off: the device photos leave the Library; on again: back.
5. Record a 4K video of at least 2 GB (about 4–5 minutes at 4K 60 fps HEVC) on Wi-Fi with the device charging. While it
   uploads (arrow badge): (a) force-quit the app, wait a minute, open it; (b) turn on Airplane Mode for two minutes,
   then off; (c) restart the device during the upload, unlock, open the app. Each time note the percentage before and
   after (Backup screen).
6. When it is done: download the video from the web interface and compare its size (Finder › Get Info on a Mac) with
   the device's (Photos › Info), or `shasum -a 256` of both files.

**Expected:** 1–2: device photos in the right place by capture time, honest counts; "All backed up" only once the server
has every file. 3: as described; nothing is deleted from the server. 5: after (a)–(c) the upload continues from where
it was (the percentage does not fall back to 0, except after a restart that took more than a day: the server expires
unfinished uploads after 24 h), and no second copy appears on the server. 6: same size and checksum.

## D14 (removed)

Search by meaning was removed on 2026-11-27 with its model (SPEC §21: the app uses only Apple's AI). The number stays
free so that D15 and D16 keep their references.

## D15 Erase tool (P, T, M) — STATUS §21.5

Any build (Erase needs nothing extra; its fill is classic image processing). On a recent iPhone and iPad (and the
oldest supported iPhone if at hand):
1. Edit a photo with a person or object on a plain background (sky, sand, snow, a wall) › Erase. Under the picture:
   "Works best on spots and small things." Tap the object: Vision picks it and it is filled in from the surroundings,
   no ghost of its outline. Note the time per tap (a stopwatch) and the app's peak memory (Xcode memory gauge).
2. Brush over a small thing (a spot, a bird in the sky) with a finger and with the Pencil (iPad): the red stroke
   follows, lifting fills it.
3. A photo with people behind the subject: "Erase N People in the Background" appears and removes them.
4. Undo, Redo, Restore All, Done; reopen: the strokes are still there; the grid tile shows the erased version; Save as
   Copy writes a full-resolution file without the object.

**Expected:** small things on even backgrounds disappear cleanly; large objects on busy backgrounds leave a soft patch
(that is the basic fill, not a bug); nothing in the tool talks about a model or a download.

## D16 What the simulator could not show (P, T, M; round 11 verification)

The STATUS items round 11 could not prove in the simulator or the (locked) Mac, collected here so that one pass covers
them. Each is marked "⬜ device D16.n" in STATUS.md.

1. **Login (P, T):** Settings › Accounts › Add › "Scan QR code" with the camera on a web login QR code; with a signed
   build, check in Settings › Diagnostics that the app password is a keychain item (no `secrets` file in the container).
2. **Managed configuration (P, T, M):** an MDM profile (Apple Configurator or a test MDM) with `serverUrl`, `username`,
   `disable_multiaccount`, `enforce_passcode_lock`, `disable_log`, `disable_backup`; look at the login page, Settings ›
   Accounts, Privacy, Diagnostics and Backup.
3. **System sheets with real targets (P, T):** share a photo to Messages and Mail from the grid, a memory film to
   Messages, a postcard; AirPlay a slideshow with a video to an Apple TV.
4. **Real input (P, T, M):** shake to undo after a delete; Escape and the arrow keys from a hardware keyboard in the
   iPad grid and viewer; pinch on the Mac trackpad in the viewer; Live Text: select text on a photo with a finger.
5. **Two devices (P + T):** SharePlay a memory film in a FaceTime call; edit the same photo on both (recipe merge);
   folder rules on both (lease).
6. **Spotlight, Siri, Shortcuts (P, M):** with a signed build, search an album name in Spotlight, run "Search photos in
   Nextcloud Photos" from Shortcuts and by Siri; Photo Shuffle Lock Screen with the family album.
7. **Mac only (M, own Mac, screen unlocked):** Continuity Camera import, the menu bar extra, the culling window full
   screen, the desktop picture rotation, Edit With another app, the kiosk guest window, the Mac menus run from the
   menu bar (Rotate Left/Right, Copy, Add to Album ▸ recent albums, Export…).

**Expected:** each does what its STATUS line says; note any difference in the issue.

## D17 Free up space on this device (P, T, M) — STATUS §22.1

Use a library you can afford to thin out (a test iPhone, or a Mac test user's own Photos library — never the owner's).

1. Back up everything (D1). The account menu says "All backed up · Free up …" (from 100 MB); the Backup screen shows the
   card. Note the size.
2. Open it. Compare "Staying on this iPhone" with what you know: favourites, hidden photos, the last 30 days, a photo you
   edited *after* it was backed up ("Edit not backed up"), an iCloud shared album item (never listed as offered).
3. Change the options (Recent photos: None; Favorites off) and see the size change. In the review keep two photos.
4. Free Up: watch "Comparing checksums: n of m", answer the system's question with Delete.
5. In Apple's Photos app: Recently Deleted has exactly the removed photos; the two kept ones and every favourite are still
   in the library. On the web: every removed photo is there, full size. Empty Recently Deleted and compare the free
   storage in Settings › General › Storage with the size the app showed.
6. With iCloud Photos on: the removed photos are gone from the other devices too (the confirmation said so).

**Expected:** nothing is removed that is not on the server with the same size/checksum; the freed storage matches the
size within a few per cent; on the Mac the same with "Optimize Mac Storage" off.

## D20 Faster: tiles, targeted sync, notify_push (P, M; round 12, SPEC §22.4)

1. With a large library (10 000+ photos), use the app for a while (scroll the Library), wait a minute, kill it and launch
   it again: the first screen shows photos at once (no BlurHash squares); fling hard through years of photos and pinch
   out to Months and Years. Instruments › **Animation Hitches** while flinging.
2. On another device or in the web interface, delete a photo and move another one to another folder; launch the app (or
   bring it to the front): both changes show after the first sync. Console.app (subsystem `com.nextcloud.photos`,
   category `sync`, info messages on) shows "targeted walk: N folders listed".
3. A server with the **notify_push** app set up (`occ notify_push:self-test` passes): with the app open, delete a photo
   in the web interface: it disappears within about 5 s without pulling to refresh. Lock and unlock the iPhone, repeat.

**Expected:** 1: pictures in the first frame, flinging without stutter (hitch time under 5 ms/s); the tile cache in the
app's caches (`Previews/<account>/tiles`) at most an eighth of the preview cache limit. 2: one sync, a few hundred
milliseconds more than a sync without changes. 3: the change arrives within seconds, also after the lock; without
notify_push nothing is different from before.

## Results table (copy into the issue)

```
Build:            Server (version / Photos):         Date / tester:
| Check | P | T | M | V | W | TV | Notes / numbers / issue |
|-------|---|---|---|---|---|----|--------------------------|
| D1 Backup                 |   |   | – | – | – | – | |
| D2 Duplicates with Files  |   | – | – | – | – | – | device / in Files / uploaded / duplicates: |
| D3 Background backup      |   |   | – | – | – | – | |
| D4 Background tasks       |   |   | – | – | – | – | |
| D5 Push                   |   |   |   |   | – | – | TestFlight (production APNs): |
| D6 Share extension        |   |   |   | – | – | – | |
| D7 Widgets / Live Activity|   |   |   | – | – | – | |
| D8 Feel and budgets       |   |   |   |   | – | – | launch s / hitch ms/s / peak MB: |
| D9 Watch                  | – | – | – | – |   | – | |
| D10 Apple TV              | – | – | – | – | – |   | |
| D11 Vision Pro            | – | – | – | V | – | – | |
| D12 Mac                   | – | – | M | – | – | – | |
| D13 Backup you can see, 2 GB video |   |   | – | – | – | – | % before/after kill, offline, restart: |
| D15 Erase tool            |   |   |   | – | – | – | s per object / peak MB / quality: |
| D16 Simulator gaps        |   |   |   | – | – | – | |
| D17 Free up space         |   |   |   | – | – | – | size shown / freed: |
| D20 Tiles, targeted sync, notify_push |   | – |   | – | – | – | hitch ms/s, s until a change shows: |
```
Mark each cell ✓, ✗ (with an issue link) or "not tested".

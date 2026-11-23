# Manual test plan for devices

Nothing in this app has run on a device yet: it was developed and checked on a Mac (the Mac app, unit and integration
tests), and the iOS and visionOS code has only been compiled. This plan is the first pass on real hardware. Work
through it per device, note the build number, the OS version and the server, and file an issue for everything that
fails. Update [STATUS.md](STATUS.md) (🟡 → ✅) for what passes.

## Before you start

- A **signed** build: a Release (TestFlight) build, or a Debug build with `PHOTOS_DEBUG_ENTITLEMENTS = YES`. App Group,
  keychain group and push must be provisioned (README, "Release builds"); without them extensions, widgets and push
  cannot work and those sections will fail for the wrong reason.
- Servers: (A) a current Nextcloud with the released Photos app and the Notifications app; (B) the oldest supported
  version, Nextcloud 33; (C) if available, a server with newer Photos features, Recognize and an Assistant provider.
  At least one reachable by `https://` with a public certificate, one with a self-signed certificate, one by `http://`.
- An account with a few thousand photos including videos, Live Photos, panoramas, HEIC, RAW, and photos with location.
- Devices: iPhone, iPad (with keyboard and pointer if possible), Mac, Apple Vision Pro. Each in light and dark
  appearance; one pass with VoiceOver and one with the largest text size.

Legend for the tables: **P** iPhone, **T** iPad, **M** Mac, **V** Vision Pro. Tick each cell that applies.

## 1. Login and accounts

| # | Check | P | T | M | V |
|---|---|---|---|---|---|
| 1.1 | First launch shows the login screen; entering the server address opens the browser login (Login Flow v2) and returns to the app | | | | |
| 1.2 | Login with a QR code / login link (`nc://login/…`): camera permission is asked with the right text, the account is added | | | – | – |
| 1.3 | `http://` server: the warning appears, "Log in anyway" works, cancelling leaves no account | | | | |
| 1.4 | Self-signed certificate: the certificate is shown, trusting it works, it is remembered; a changed certificate asks again | | | | |
| 1.5 | Wrong address, server in maintenance mode, no network: understandable messages, no dead end | | | | |
| 1.6 | Second account: add, switch, the library changes; remove one account, the other stays | | | | |
| 1.7 | Revoke the app password in the server's security settings: the app notices and asks to log in again | | | | |
| 1.8 | Remote wipe from the server: all data of the account is gone from the device | | | | |
| 1.9 | Quit and relaunch: still logged in, last view restored | | | | |

## 2. Timeline

| # | Check | P | T | M | V |
|---|---|---|---|---|---|
| 2.1 | First sync: skeleton, then photos appear; progress is visible; the app stays usable | | | | |
| 2.2 | Scrolling a large library is smooth; previews sharpen; no blank tiles after fast scrolling | | | | |
| 2.3 | Pinch (or zoom slider / menu) changes tile size; days, months, years when zooming out; position is kept | | | | |
| 2.4 | Date scrubber / year index jumps to the right place | | | | |
| 2.5 | Day headers ("Today", "Yesterday", dates, places) are right for the device's region and language | | | | |
| 2.6 | Selection: tap/drag to select, context menu, favourite, delete (confirmation names the trash bin), add to album | | | | |
| 2.7 | A photo added, changed or deleted on the web appears / disappears after a sync (pull to refresh, Sync Now) | | | | |
| 2.8 | Airplane mode: the library is browsable; favourites and deletes made offline are sent when the network returns | | | | |
| 2.9 | Rotation, Split View, Stage Manager, window resize: layout adapts, position is kept | | | | |
| 2.10 | Photos, Videos, Favorites views show the right subsets; empty states read correctly | | | | |
| 2.11 | Keyboard: arrow keys, Return/Space, Escape, the menu commands and their shortcuts | – | | | – |

## 3. Viewer

| # | Check | P | T | M | V |
|---|---|---|---|---|---|
| 3.1 | Tap opens the photo with a zoom transition; swipe (or arrow keys) moves through the library in order | | | | |
| 3.2 | Pinch and double-tap zoom; full resolution loads; panning at the edges does not switch photos by accident | | | | |
| 3.3 | Video plays with sound, scrubbing works; long videos stream instead of downloading first | | | | |
| 3.4 | Live Photo plays on long press; HEIC, RAW, panoramas and GIFs display | | | | |
| 3.5 | Info panel: date, camera, size, location with map, albums; edit date and location | | | | |
| 3.6 | Favourite, share (system share sheet with the original), save to the device's library / export, delete | | | | |
| 3.7 | Close by button, swipe down, Escape; the grid is at the photo that was shown | | | | |
| 3.8 | Editor: crop, rotate, filters, adjustments; save as copy and overwrite; the result appears on the web | | | | |
| 3.9 | Memory: open and swipe through 500 photos; the app is not terminated | | | | |

## 4. Albums and sharing

| # | Check | P | T | M | V |
|---|---|---|---|---|---|
| 4.1 | Albums list with covers and counts; create, rename, delete an album; it matches the web app | | | | |
| 4.2 | Add photos from the timeline, remove from the album (photo itself stays), set the cover | | | | |
| 4.3 | Share an album with another user and by public link; the link opens in a browser | | | | |
| 4.4 | Open a public album link in the app without an account for that server | | | | |
| 4.5 | Shared albums from others appear; permissions are respected (no delete where not allowed) | | | | |
| 4.6 | Make an album available offline; airplane mode; originals open; Wi-Fi-only setting is respected | | | | |
| 4.7 | Places, map, people, tags, folders, memories, On this day, search: each opens and shows plausible content; features the server lacks are hidden | | | | |
| 4.8 | Upload from the app (picker, drag and drop on iPad/Mac): progress, result in the right folder, failures can be retried | | | | |

## 5. Backup (including background)

Use a device with a real photo library. For 5.7 use a device whose photos were partly uploaded by the Nextcloud Files app.

| # | Check | P | T | M | V |
|---|---|---|---|---|---|
| 5.1 | Turning backup on asks for photo library access with the right text; "limited" access is handled | | | | – |
| 5.2 | First run: counts are plausible, uploads start, progress and the current file are shown | | | | – |
| 5.3 | Files arrive in the backup folder with the chosen naming; originals are bit-identical (compare a checksum) | | | | – |
| 5.4 | Live Photos arrive as photo and video and play as Live Photo on the web; edited photos follow the chosen option | | | | – |
| 5.5 | Second run uploads nothing; a new photo taken with the camera is uploaded | | | | – |
| 5.6 | Wi-Fi only, Low Data Mode, Low Power Mode, no network: the backup pauses with the right reason and resumes by itself | | | – | – |
| 5.7 | Coexistence with the Files app's auto upload: **zero duplicates**, all missing photos uploaded | | | – | – |
| 5.8 | **Background:** start a large backup, lock the device, leave it on power and Wi-Fi for an hour: uploads continued; the count in the app is right when it is opened again | | | – | – |
| 5.9 | **Background, app terminated by the system:** as 5.8, but use other heavy apps meanwhile; uploads handed to the system finish, the app records them at the next launch | | | – | – |
| 5.10 | Force-quit by the user during a backup: nothing is corrupted; the backup continues at the next launch without duplicates | | | | – |
| 5.11 | Large video (> 100 MB, chunked): interrupted by airplane mode, continues where it stopped | | | | – |
| 5.12 | Server storage full, login expired, no permission for the folder: the backup stops and names the reason | | | | – |
| 5.13 | Backup belongs to account A while account B is shown: the Backup screen says so; uploads go to A | | | | – |
| 5.14 | "Back up now" from Shortcuts / Siri with the app not running: it runs and reports the result | | | | – |
| 5.15 | Battery and data use over a day with backup on look reasonable (Settings › Battery, › Mobile Data) | | | – | – |

## 6. Share extension

| # | Check | P | T | M | V |
|---|---|---|---|---|---|
| 6.1 | "Nextcloud Photos" appears in the share sheet of Photos and Files for images, videos and files | | | | – |
| 6.2 | Sharing one and many items (50+): upload with progress; they appear on the server and in the app | | | | – |
| 6.3 | Choosing the account and the album / folder works; the extension sees the accounts of the app | | | | – |
| 6.4 | Not logged in: the extension says so instead of failing silently | | | | – |
| 6.5 | Large video: no crash from the extension's memory limit; a failure can be retried | | | | – |
| 6.6 | Server with a user-trusted certificate: the extension uses the app's trust decision | | | | – |

## 7. Push notifications

Needs the push proxy to know the app's bundle id and a server with the Notifications app.

| # | Check | P | T | M | V |
|---|---|---|---|---|---|
| 7.1 | Permission is asked after login (not at first launch); the Notifications switch in Settings turns it off and on | | | | |
| 7.2 | Someone shares an album with the account: a notification arrives with readable (decrypted) text, also when the app is not running | | | | |
| 7.3 | Tapping the notification opens the app at the right place | | | | |
| 7.4 | A notification read or dismissed on the web disappears on the device (silent push) | | | | |
| 7.5 | Notifications that are not about photos (other apps of the server) are **not** shown. Without Apple's notification-filtering entitlement they will appear: note what is shown instead | | | | |
| 7.6 | Two accounts: notifications of both arrive and name the account | | | | |
| 7.7 | After logout no notification for that account arrives any more | | | | |
| 7.8 | A Release / TestFlight build receives pushes (production APNs environment), not only a development build | | | | |

## 8. Widgets

| # | Check | P | T | M | V |
|---|---|---|---|---|---|
| 8.1 | "On this day" and "Favorites" are in the widget gallery with name and description, in every size offered | | | | |
| 8.2 | They show a photo of the account; tapping opens the app in the matching view | | | | |
| 8.3 | Not logged in / no photos: the placeholder text, no empty box | | | | |
| 8.4 | The photo changes over the day; after logout the widget shows no photo of the old account | | | | |
| 8.5 | Archived (hidden) photos never appear in a widget | | | | |
| 8.6 | Lock Screen, StandBy and tinted Home Screen appearances are legible | | | – | – |

## 9. Across everything

| # | Check | P | T | M | V |
|---|---|---|---|---|---|
| 9.1 | App lock: Face ID / Touch ID / Optic ID / passcode after the chosen time; the app switcher shows no photos while locked; Archive always asks | | | | |
| 9.2 | VoiceOver: every screen of sections 1–5 can be used; tiles, buttons and progress have sensible labels | | | | |
| 9.3 | Largest text size, Reduce Motion, Increase Contrast: nothing truncated beyond use, no missing controls | | | | |
| 9.4 | Dark appearance and the app icon in dark / tinted Home Screen modes | | | | |
| 9.5 | A language other than English and a right-to-left language once translations exist; until then dates and numbers follow the region | | | | |
| 9.6 | Slow network (Network Link Conditioner "3G", "Very Bad Network"): loading states appear, nothing hangs forever | | | | |
| 9.7 | Server on Nextcloud 33: everything of sections 1–5 that the server supports works; the rest is hidden | | | | |
| 9.8 | Update over an older build keeps accounts, settings and the backup history | | | | |
| 9.9 | Delete the app: nothing remains in the keychain that signs a fresh install in | | | | |
| 9.10 | Instruments (Time Profiler, Allocations, Hitches) on the oldest supported device against the budgets of SPEC §10: launch, scroll hitch rate, viewer, memory | | | | |
| 9.11 | visionOS: window resizing, ornaments, eye and hand input on grid and viewer | – | – | – | |
| 9.12 | Mac: several windows, the menu bar commands, Settings window, drag photos to Finder, export to a folder | – | – | | – |

# Companion server APIs for Nextcloud Photos (native apps)

Version 1.0 · 2026-11-22 · Status: proposal

Optional additions to the **Photos server app** (github.com/nextcloud/photos), plus two small changes in other server apps. They make the native app (`SPEC.md`) faster, more complete and less hacky. **The app must keep working without them**; every item lists the app's fallback.

Where they live: new code in the Photos app (`lib/Capabilities.php`, controllers under `lib/Controller/`, OCS routes in `appinfo/routes.php`). They ship with Photos 9.x+ (Nextcloud 36+). Servers 33–35 will never get them, so the fallbacks are permanent for those versions.

Work process: follow the Photos repo's `AGENTS.md` — prepare one small branch per item, with tests (PHPUnit + Psalm), no built `js/`/`css/`. A maintainer opens the PRs.

Apps and services touched:

| Where | Items |
|---|---|
| **Photos** (nextcloud/photos) | S1–S9 (all of them; most items only touch Photos) |
| **Notifications** (nextcloud/notifications) | S5: push routing for a `photos` device type |
| **Server core** (nextcloud/server) | Optional: an `IRequest::USER_AGENT_PHOTOS_IOS` constant for S5 (avoidable with a regex in the notifications app) |
| **Recognize** (nextcloud/recognize) | Optional alternative to S4: accept app-password/Bearer requests without the API key |
| **Push proxy** (push-notifications.nextcloud.com, a service, not an app) | APNs topic for the new bundle id (configuration, not code) |

Comments, systemtags, trashbin and files_versions need no changes: Photos only consumes their existing APIs and events.

Priority (value per effort): **S1, S4** → S2, S3 → S5, S7 → S6, S8 → S9.

---

## S1 — `photos` capability and readable user config

**Problem:** the app has no way to learn which Photos features, MIME types and user settings a server has; the web app gets them through HTML initial state. Today the app scrapes `/index.php/apps/photos/` (SPEC §5.3).

**Capability** (`OCP\Capabilities\ICapability`, registered in `Application::register`):

```jsonc
// GET /ocs/v2.php/cloud/capabilities → ocs.data.capabilities.photos
"photos": {
  "version": "9.1.0",
  "apiVersion": 1,
  "features": [
    "config-api",               // S1 read/write endpoint below
    "timeline-days",            // /api/v1/timeline/days
    "album-cover", "album-description", "album-comments", "album-sort-lastmodified",
    "album-filter-tags", "album-change-tag",    // S7
    "place-country", "heif-exif", "metadata-edit",
    "on-this-day-notifications", "album-notifications",   // S5
    "unified-search", "folder-previews",
    "sync-feed",                // S2
    "content-hash",             // S3
    "recognize-key",            // S4
    "video-renditions", "media-duration"        // S6, S8
  ],
  "mimetypes": { "image": ["image/jpeg", "…"], "video": ["video/mp4", "…"] },
  "places": { "enabled": true },
  "captions": { "enabled": true, "searchable": true },
  "videoRenditions": { "enabled": true, "maxSourceSizeMiB": 2048, "rangeRequests": true },
  "previews": { "pregenerated": [64, 256, 1024] },
  "apps": { "recognize": true, "systemtags": true, "trashbin": true, "comments": true }
}
```

Only list a feature when it is actually usable for the current user (e.g. `video-renditions` only when the admin switch is on and ffmpeg is found; `captions.searchable` only once the metadata key is indexed).

**Config API** (OCS, `@NoAdminRequired`):

- `GET /ocs/v2.php/apps/photos/api/v1/config` → `{ "croppedLayout": "false", "gridDensity": "medium", "photosLocation": "/Photos", "photosSourceFolders": "[\"/Photos\"]", "smartAlbums": "[]", "albumsSortOrder": "recent", "albumPhotosSortOrder": "oldest", "onThisDayNotifications": "true", "nomediaPaths": ["/Photos/WhatsApp/.Statuses"] }` (all keys of `UserConfigService::DEFAULT_CONFIGS` plus the computed `.nomedia` list).
- `PUT /ocs/v2.php/apps/photos/api/v1/config/{key}` with `{"value": "<string>"}` — same validation as the existing classic route.

**Fallback:** initial-state scrape, then defaults.

## S2 — Change feed for delta sync

**Problem:** the only change signal is the recursive etag of a folder; finding *what* changed needs a full re-scan, and deletions/moves are only found by reconciliation (SPEC §5.4.4).

**API:** `GET /ocs/v2.php/apps/photos/api/v1/sync?token=<opaque>&limit=1000`

```jsonc
{
  "token": "<new opaque token>",
  "hasMore": false,
  "reset": false,                 // true = token too old/unknown → client must do a full sync
  "upserted": [ { "fileId": 123, "path": "/Photos/2026/11/IMG_1.HEIC", "etag": "…", "mime": "image/heic",
                  "size": 2345678, "mtime": 1795356271, "uploadTime": 1795356300,
                  "captureTime": 1795356271, "width": 4032, "height": 3024,
                  "gps": { "lat": 52.5, "lon": 13.4 }, "place": "Berlin", "placeCountry": "DE",
                  "favorite": false, "livePhotoPeer": 124, "hidden": false, "blurhash": "…",
                  "permissions": "RGDNVW", "mountType": "", "caption": null } ],
  "removed": [ 456, 789 ],        // file ids that left the scope (deleted, moved out, now .nomedia, …)
  "albums": { "changed": ["Lisbon 2025"], "removed": ["Old"] }   // own + shared album ids whose membership/props changed
}
```

- Scope = the user's `photosSourceFolders` + `/.archive`, allowed MIME types, minus `.nomedia` folders.
- Implementation idea: a `photos_changes` table (`user`, `file_id`, `kind` upsert/remove, `seq`) filled by listeners for `NodeWrittenEvent`, `NodeDeletedEvent`, `NodeRenamedEvent`, metadata-updated events (place/caption arrive later), favourite/tag events, share/unshare and album events; the token encodes the last `seq`. Prune entries older than 30 days (`reset: true` for older tokens). Changes inside received shares/group folders need care: fan out by share recipients, or set `reset` for those users and let them reconcile.

**Fallback:** etag check + SEARCH by mtime/upload time + daily reconciliation.

## S3 — Content hashes for duplicate-free backup

**Problem:** the app can only match device photos against the server by capture time, size, name and dimensions (SPEC §7.18.4). An exact content hash would make the match certain.

**Design:**
- Background job computes **SHA-256** of media files (Photos MIME types + RAW) and stores it as indexed file metadata `photos-sha256` (exposed as `nc:metadata-photos-sha256`). Use the `OC-Checksum: SHA256:…` value sent by uploaders when present (verify it on write or trust it for the uploader's own files).
- Lookup endpoint: `POST /ocs/v2.php/apps/photos/api/v1/hashes/lookup` with `{"sha256": ["…", "…"]}` (≤ 500) → `{"found": {"<hash>": [{"fileId": 1, "path": "/Photos/…"}]}}`, scoped to files the user can read. (Searching by the metadata key with SEARCH also works but one query per hash is too slow.)
- Note: the Files app converts HEIC to JPEG by default, so its uploads won't hash-match device originals; time-based matching stays necessary.

**Fallback:** time/size/name reconciliation.

## S4 — Recognize API key for native clients

**Problem:** every request under `/remote.php/dav/recognize/` needs `X-Recognize-Api-Key`, a 24 h token that only the Photos HTML page creates (`photos-server-api.md` §13). Native apps must scrape it.

**API:** `GET /ocs/v2.php/apps/photos/api/v1/recognize/key` (`@NoAdminRequired`) → `{"key": "<encrypted>", "expires": 1795440000}`, generated exactly like `PageController` does (`\OCA\Recognize\Public\ApiKeyManager` if available). 404 when Recognize isn't installed/enabled for the user.

Alternative (Recognize app change, better long-term): accept app-password/Bearer-authenticated requests without the key.

**Fallback:** initial-state scrape `recognizeApiKey`; or the admin setting `recognize/require_api_key=false` (Recognize ≥ 12).

## S5 — Notifications for shared albums (and push app type)

**Problem:** users aren't told when an album is shared with them, when people add photos to a shared album, or when someone comments.

**Photos app:** new notification subjects (app `photos`, object type `album`, object id = album id):
- `album_shared` — "Anna shared the album “Lisbon 2025” with you"
- `album_photos_added` — "Anna added 12 photos to “Lisbon 2025”" (coalesce: at most one per album per user per hour; update the existing notification instead of adding new ones)
- `album_comment` — "Anna commented on “Lisbon 2025”: …"
User config keys to turn each off (`notifyAlbumShared`, `notifyAlbumPhotosAdded`, `notifyAlbumComments`), exposed through S1.

**Notifications app (separate PR there, nextcloud/notifications):** today the proxy-push app type is not a parameter; `PushController::registerDevice` derives it from the user agent (`USER_AGENT_TALK_*` → `talk`, `USER_AGENT_CLIENT_ANDROID/IOS` → `nextcloud`, anything else → `unknown`), and `Push::filterProxyDeviceList` only distinguishes `talk` from everything else: non-Talk devices get **all** non-Talk notifications, and Talk notifications fall back to them when the user has no Talk device. A Photos device would therefore receive Files (and possibly Talk) notifications. Change:
- Recognise the Photos app's user agent (add a constant such as `USER_AGENT_PHOTOS_IOS` to core `OCP\IRequest`, or match a regex inside the notifications app to avoid a core change) and store `apptype = 'photos'`.
- In `filterProxyDeviceList`: `photos` devices receive only notifications with `app === 'photos'`; never use them as the Talk fallback. Decide whether Files devices still receive Photos notifications when the user also has the Photos app (suggestion: yes, unless a `photos` device exists — mirror the Talk logic).
- The web-push path already supports explicit `app_types`; nothing to do there.

The app's user agent (SPEC §5.1.8) must match whatever is chosen here.

**Fallback:** On this day notification only (extended servers); filter in the Notification Service Extension with Apple's filtering entitlement.

## S6 — Video renditions that native players can stream

**Problem:** `GET /apps/photos/api/v1/video/{fileId}` answers with `Accept-Ranges: none`, and a 404 means both "not available" and "queued".

**Change:**
- Serve the rendition with HTTP range support (Sabre-like `206 Partial Content`), and allow it through the DAV direct-download mechanism or a short-lived signed URL so AVPlayer can stream without custom headers.
- `GET /ocs/v2.php/apps/photos/api/v1/video/{fileId}/status` → `{"state": "ready"|"queued"|"converting"|"unsupported"|"disabled", "progress": 0.4}`.
- Also produce renditions for WebM/VP9 when the requesting client says it can't play them (`?for=apple`): AVFoundation can't play WebM.

**Fallback:** download the rendition fully before playing; poll the 404.

## S7 — Album change tags

**Problem:** album collections have no etag, so the app must re-list every album to see if anything changed, and listing is expensive (every album resolves all its files).

**Change:** expose `d:getetag` (or `nc:album-etag`) on album roots (own, shared, public): a hash over album props, collaborators and membership `(fileId, added)` — maintained as a column updated by `AlbumMapper` writes and by the listeners that remove files. Also make `nc:nbItems` and `nc:last-photo` cheap (stored counters).

**Fallback:** time-based refresh of the album list (SPEC §5.4.4).

## S8 — Media metadata for native display

- `photos-duration` (seconds, float) and `photos-video-size` (`width`/`height`) for videos, extracted with ffprobe where available.
- `photos-capture-offset` (EXIF `OffsetTimeOriginal`) as its own indexed key, so the app gets the photo's time zone without downloading full EXIF.
- On servers with `MetadataPropPatchPlugin`, accept `nc:metadata-photos-original_date_time` / `nc:metadata-photos-gps` also as headers on PUT/MOVE of an upload (`X-NC-Photos-Capture-Time`, `X-NC-Photos-GPS`), so a backup client sets them atomically without a second request.

**Fallback:** read duration when played; read offset from EXIF lazily; PROPPATCH after upload.

## S9 — Batch writes (low priority)

`POST /ocs/v2.php/apps/photos/api/v1/batch` with a list of operations (`favorite`, `album-add`, `album-remove`, `face-move`, `metadata`) → per-operation results. Reduces thousands of requests for bulk actions to a few.

**Fallback:** per-item requests with concurrency 5.

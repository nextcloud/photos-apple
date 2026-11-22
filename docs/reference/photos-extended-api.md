# Nextcloud Photos: server-side API added by the unmerged feature branches

Inventory for the spec of a native iOS/macOS "Nextcloud Photos" client.

**Sources**
- Integration branch `deploy/devel-all` at `1e61f4171` ("build deploy/devel-all with the round 2 features"), 120 commits over `master` = upstream `8258010a9`.
- `deploy/devel-all` is **not** a ref in `~/aloha-work/photos`. It only exists in the separate clone `~/aloha-work/photos-wt/deploy`. Every directory under `~/aloha-work/photos-wt/` is its own clone with its own `.git`, not a git worktree. All paths below are relative to that clone, and the diffs were made with `git diff master..deploy/devel-all` / `git diff master...feat/<x>` there.
- The `fix/ui-*` branches live only in their own clones (`photos-wt/fix-ui-*`). They reach `deploy/devel-all` through the integration branches `ui/collections`, `ui/dialogs`, `ui/memories` and `ui/timeline`. `ui/scanfix` only adds `feat(navigation): fold folders, duplicates, archive and recently deleted into an advanced entry`, which is front-end only.
- App version: `appinfo/info.xml` goes from `9.0.0-dev.0` to `9.0.0-dev.1`. Only one migration is added: `Version90000Date20261122120000`, which adds the album `cover` and `description` columns.

**Key finding on detection:** the Photos app has **no `ICapability`**, neither on master nor on any branch. The web front-end finds features through **initial state** (`loadState('photos', …)`), which a native client cannot read. So today a native client can only detect most features by probing (DAV propstat 404, route 404, OCS 404), and some features cannot be detected at all. §3 proposes a `photos` capability.

---

## 1. Summary table

Legend for the **Server** column:
- **API**: new endpoint, DAV property or notification.
- **Behaviour**: server-side change with no new endpoint, such as different data in existing properties, background jobs or occ.
- **FE**: front-end only. The web app does the work over existing APIs.

| # | Feature (branch) | Server | What a client uses | External deps | Runtime detection today |
|---|---|---|---|---|---|
| 1 | archive | FE | WebDAV MOVE into `/.archive/<orig path>` | — | none needed (convention) |
| 2 | recently-deleted-view | FE (+initial state `trashbin`) | `files_trashbin` DAV + `/apps/files_trashbin/preview` | files_trashbin | OCS capability `files.undelete` (core) |
| 3 | duplicates-view | FE | client-side grouping over the whole library | — | n/a (client algorithm) |
| 4 | saved-filter-smart-albums | **API** (user config key `smartAlbums`) | `PUT /apps/photos/api/v1/config/smartAlbums` (write-only) | — | **none**: the value cannot be read back over HTTP |
| 5 | ai-photo-captions | **API + Behaviour** | DAV prop `nc:metadata-photos-caption`; caption search in `nc:metadata-photos-caption` | TaskProcessing `core:analyze-images` provider; admin switch | **none clean**: initial state `caption-search` only |
| 6 | ask-your-photos | FE (+ server `tags` album filter) | OCS TaskProcessing `core:text2text` | Assistant/TaskProcessing text provider | `GET /ocs/v2.php/taskprocessing/tasktypes` has `core:text2text` |
| 7 | shared-album-comments | **API** | comments DAV `/remote.php/dav/comments/photos_album/{albumId}` + DAV prop `nc:album-id` | comments (core) | PROPFIND `nc:album-id` → 200 vs 404 propstat |
| 8 | album-cover-and-description | **API** (DB migration) | DAV props `nc:cover`, `nc:description` (PROPFIND + PROPPATCH) | — | PROPFIND `nc:cover` → 200 vs 404 propstat |
| 9 | album-sort-order | **API + Behaviour** | user config `albumsSortOrder`, `albumPhotosSortOrder`; album `d:getlastmodified` now meaningful | — | none for config; `getlastmodified` ≠ epoch 0 |
| 10 | bulk-edit-date-location | FE | existing PROPPATCH `nc:metadata-photos-original_date_time` / `nc:metadata-photos-gps` | — | n/a (the PROPPATCH plugin is already on master) |
| 11 | capture-local-time | FE | existing `nc:metadata-photos-exif` → `OffsetTimeOriginal` | — | n/a |
| 12 | filter-by-tag | **API** (new album filter id `tags`) | album `nc:filters` JSON `{"tags":[names]}` | systemtags | **none**: an unknown filter id is silently ignored |
| 13 | timeline-day-headers | FE | client day grouping | — | n/a |
| 14 | timeline-days-api | **API** (OCS) | `GET /ocs/v2.php/apps/photos/api/v1/timeline/days` | — | OCS route 200 vs 404 |
| 15 | timeline-full-library-scrubber | FE (uses #14) | days API + month jump | — | via #14 |
| 16 | people-in-photo | FE | Recognize DAV prop `nc:face-detections` | Recognize | PROPFIND `nc:face-detections` → 404 propstat without Recognize |
| 17 | extract-text-action | FE | OCS TaskProcessing `core:image2text:ocr` | OCR provider | tasktypes lists `core:image2text:ocr` |
| 18 | free-up-space | FE (+web route) | DAV SEARCH by name, size and mime; DELETE | (trashbin) | n/a |
| 19 | heic-avif-exif | **Behaviour** | existing `nc:metadata-photos-exif`/`-gps`/`-original_date_time` now filled for HEIC/HEIF/AVIF | — | none (data appears) |
| 20 | hidpi-aware-previews | FE | preview size buckets 64/256/1024/4096 | — | n/a |
| 21 | viewer-info-panel | FE (web sidebar tab) | existing metadata props | files sidebar | n/a |
| 22 | library-wide-photo-views | FE | DAV SEARCH paging, up to 20 000 items | — | n/a |
| 23 | live-photo-playback | FE | core prop `nc:metadata-files-live-photo`; SEARCH by fileid | core ≥ 28 live-photo metadata | prop present |
| 24 | map-search-this-area | FE | client bounds filter | — | n/a |
| 25 | map-marker-clustering | FE | client grid clustering | — | n/a |
| 26 | map-time-slider | FE | client month-range filter | — | n/a |
| 27 | more-media-formats | **Behaviour** | GIF, WebM, M4V and MKV now count as Photos media server-side | — | **none**: the mime list is in initial state only |
| 28 | on-this-day-notification | **API** (notification + bg job + user config) | Notifications OCS: app `photos`, subject `onthisday` | notifications | **none for the feature**; check the `notifications` capability |
| 29 | timeline-memories-strip | FE | existing "On this day" search + client grouping | — | n/a |
| 30 | stack-same-shot-variants | FE | client stacking by name | — | n/a |
| 31 | unified-photo-search | FE (+ #5, #12 server filters) | client suggestion builder over places, tags and albums | — | n/a |
| 32 | places-by-country | **API + Behaviour** | DAV `nc:place-country` on places; file metadata `nc:metadata-photos-place-country`; city attribution changed | — | PROPFIND `nc:place-country` → 200 vs 404 |
| 33 | pregenerate-previews | **Behaviour** (listener + queued job + app config) | none: previews 64/256/1024 just exist sooner | preview providers | none |
| 34 | public-album-slideshow | FE | existing public album DAV | — | n/a |
| 35 | quick-share-selection | FE | existing album MKCOL/COPY/PROPPATCH collaborators (link) | — | n/a |
| 36 | google-takeout-sidecars | **occ** | `occ photos:import-takeout-metadata` | — | admin only |
| 37 | memories-trip-titles | FE | `nc:metadata-photos-place` per photo + client trip clustering | — | n/a |
| 38 | unified-search-provider | **API** (search providers) | OCS unified search `photos_albums`, `photos_places` | — | `GET /ocs/v2.php/search/providers` lists the ids |
| 39 | video-playback-compat | **API + bg job** | `GET /apps/photos/api/v1/video/{fileId}` (MP4 rendition) | ffmpeg/ffprobe; admin switch | **none clean** (404 is ambiguous) |
| 40 | drag-select-and-select-all / shift-click-range-selection / grid-keyboard-navigation | FE | — | — | n/a |
| 41 | fix/ui-folder-previews | **API** (field added to existing JSON) | `GET /apps/photos/api/v1/albums/{path}` folder entries gain `attributes.previews` | — | field present |
| 42 | fix/ui-places-city | **Behaviour** | reverse geocoding attributes to major city + country | — | n/a |
| 43 | other fix/ui-* (actions-button, advanced-navigation, album-from-filters, album-title, collection-covers, empty-states, filters-groups, map-fit, memories-cards, metadata-capture-time, metadata-layout, phone-header, scrubber-years, selection-ring, timeline-day-labels, timeline-month-header) | FE (pure UI) | — | — | n/a |

---

## 2. Complete list of server surface added (deploy/devel-all vs master)

The source is `git diff --stat master..deploy/devel-all -- lib appinfo`: 46 files, +3389/−105.

### 2.1 HTTP routes (`appinfo/routes.php`)
| Route | Type | Branch |
|---|---|---|
| `GET /apps/photos/api/v1/video/{fileId}` (`video#rendition`, `fileId=\d+`) | classic app route, `NoAdminRequired`, `NoCSRFRequired` | video-playback-compat |
| `GET /ocs/v2.php/apps/photos/api/v1/timeline/days` (`timeline#days`) | **OCS** | timeline-days-api |
| `GET /apps/photos/{archive,duplicates,recently-deleted,smartalbums/{path},free-space}` | web page routes only (HTML) | archive, duplicates, recently-deleted, smart-albums, free-up-space |

### 2.2 WebDAV properties (`lib/Sabre/PropFindPlugin.php`), namespace `http://nextcloud.org/ns`
| Property | On | R/W | Value | Branch |
|---|---|---|---|---|
| `nc:cover` | every album root (`AlbumRootBase`: own, shared and public albums) | PROPFIND; PROPPATCH on **own** albums only (`AlbumRoot`); others → 403 Forbidden | int file id picked by owner, `-1` = none. 400 if the file is not in the album | album-cover-and-description |
| `nc:description` | same | same; max 2000 chars (`AlbumMapper::DESCRIPTION_MAX_LENGTH`), 400 above | string, `''` default | album-cover-and-description |
| `nc:album-id` | `AlbumRoot` (own) and `SharedAlbumRoot` (shared with me). **Not** on public albums | read-only | int DB id, used for comments | shared-album-comments |
| `nc:place-country` | place collections (`/photos/{user}/places/{place}`) | read-only | ISO 3166-1 alpha-2, `''` if unknown | places-by-country |
| `nc:last-photo` (existing) | albums | — | now honours the picked `nc:cover` while that photo is still in the album | album-cover-and-description |
| `d:getlastmodified` (existing) | album roots | — | was always `0`. Now `max(created, latest "added" of user-added files)` | album-sort-order |

Files-metadata keys added. Core exposes them automatically as `nc:metadata-<key>` on files, and they can be searched with SEARCH when indexed:
| Key / DAV prop | Type | Indexed | Branch |
|---|---|---|---|
| `photos-caption` → `nc:metadata-photos-caption` | string ≤ 63 chars, one line, may end with `…` | yes, once the first caption is stored | ai-photo-captions |
| `photos-place-country` → `nc:metadata-photos-place-country` | ISO alpha-2 | yes | places-by-country |

### 2.3 Album filter ids (album `nc:filters` JSON, `lib/Filters/*`)
`date-range` (existing, `[{start,end}]` in **ms**, end day inclusive), `places` (existing, `[placeName]`), `name` (existing; now also matches `photos-caption` when that key is indexed), **`tags` (new)**: `[systemTagName]`, OR semantics, matched with an escaped LIKE on `systemtag` and scoped to the tags the user can see.
`FiltersManager::getFilesBasedOnFilters` **silently ignores unknown filter ids**. A tags-only album on an older server therefore comes back empty with no error.

### 2.4 User config keys (`lib/Service/UserConfigService.php`, validated in `lib/Controller/ApiController.php`)
Write: `PUT /apps/photos/api/v1/config/{key}` with body `value=<string>`. Returns 200, or 400 for an unknown key or invalid value.
**There is no read endpoint.** Values reach the web app only as initial state.
| Key | Default | Valid values | Branch |
|---|---|---|---|
| `smartAlbums` | `[]` | JSON list of `{id, name, filters}`, keys exactly these three. `id` matches `^[A-Za-z0-9_-]{1,64}$`, unique. `name` is non-blank, ≤ 255 chars. `filters` is an object `filterId → list` | saved-filter-smart-albums |
| `albumsSortOrder` | `recent` | `recent`, `name`, `date` | album-sort-order |
| `albumPhotosSortOrder` | `oldest` | `oldest`, `newest` | album-sort-order |
| `onThisDayNotifications` | `true` | `true`, `false` | on-this-day-notification |
| `onThisDayLastNotification` | — | internal (IUserConfig `photos`), last `YYYY-MM-DD` notified | on-this-day-notification |

### 2.5 App config (admin; `lib/ConfigLexicon.php` and services)
| Key | Type / default | Meaning |
|---|---|---|
| `ai_captions` | bool, false | turn on AI captions |
| `ai_captions_per_hour` | int, 60 | rate limit |
| `ai_captions_next_slot` | int (internal) | rate-limit cursor |
| `video_renditions_enabled` | bool, false | turn on video conversion (also needs ffmpeg) |
| `video_renditions_max_source_size` | int MiB, 2048 | skip larger originals |
| `pregenerate_previews` | bool, **true** | queue preview generation on upload |

### 2.6 Background jobs, listeners, notifications, search, occ
- `OnThisDayNotificationJob` (TimedJob, 24 h, listed in info.xml)
- `GenerateCaptionJob` (QueuedJob)
- `ConvertVideoJob` (QueuedJob, no parallel runs)
- `PregeneratePreviewsJob` (QueuedJob)
- Listeners:
  - `CaptionMetadataProvider` and `CaptionTaskListener`, on `TaskSuccessfulEvent`
  - `PreviewPregenerationListener`, on `NodeWrittenEvent`
  - `VideoRenditionCleanupListener`, on `NodeDeletedEvent`
  - `AlbumCommentsEntityListener`, on `CommentsEntityEvent`
- Notifier `lib/Notification/Notifier.php` (app id `photos`)
- Unified search providers: `photos_albums`, `photos_places`
- occ command: `photos:import-takeout-metadata`

---

## 3. Recommended detection contract (proposal for the server side)

Today the web app learns its features from initial state:
- `trashbin`, `video-renditions`, `caption-search`, `recognize`, `systemtags` and `maps`
- the `image-mimes` and `video-mimes` lists
- all user config keys

None of this is reachable for a native client. Proposal: add `lib/Capabilities.php` (`OCP\Capabilities\ICapability`), register it with `$context->registerCapability(Capabilities::class)`, and add a read endpoint for user config.

```jsonc
// GET /ocs/v2.php/cloud/capabilities  →  ocs.data.capabilities.photos
"photos": {
  "version": "9.0.0-dev.1",                 // appinfo version, coarse fallback
  "apiVersion": 1,
  "features": [
    "timeline-days",            // OCS /apps/photos/api/v1/timeline/days
    "album-cover",              // nc:cover PROPFIND/PROPPATCH
    "album-description",        // nc:description
    "album-comments",           // nc:album-id + comments/photos_album
    "album-sort-lastmodified",  // album getlastmodified is real
    "album-filter-tags",        // `tags` filter id understood
    "place-country",            // nc:place-country + metadata-photos-place-country
    "heif-exif",
    "on-this-day-notifications",
    "unified-search",           // photos_albums, photos_places providers
    "folder-previews",          // attributes.previews in /api/v1/albums
    "user-config-read"          // proposed GET endpoint below
  ],
  "mimetypes": { "image": [...IMAGE_MIMES], "video": [...VIDEO_MIMES] },
  "captions":  { "enabled": true, "searchable": true, "property": "nc:metadata-photos-caption" },
  "videoRenditions": { "enabled": true, "maxSourceSizeMiB": 2048 },
  "previews":  { "pregenerated": [64, 256, 1024] },
  "userConfigKeys": ["croppedLayout","gridDensity","photosLocation","photosSourceFolders",
                     "smartAlbums","albumsSortOrder","albumPhotosSortOrder","onThisDayNotifications"]
}
```

Missing endpoint to add: `GET /ocs/v2.php/apps/photos/api/v1/config`. It would return `{key: value}` for every key in `UserConfigService::DEFAULT_CONFIGS`, using `getUserConfig()`, which already exists.

The OCS twin `PUT /ocs/v2.php/apps/photos/api/v1/config/{key}` would also help. The current PUT is a classic route, so it needs an app password or basic auth plus the `OCS-APIRequest: true` header to pass the CSRF check. Its docblock has `@NoAdminRequired` but **no** `@NoCSRFRequired`, so this must be verified for native clients.

Without a server change, the client should probe as follows:
1. Fetch capabilities:
   - `files.undelete` tells whether the trash bin is available.
   - `notifications` tells whether notifications are.
2. List the task processing types with `GET /ocs/v2.php/taskprocessing/tasktypes`. Look for:
   - `core:text2text` (Ask your photos)
   - `core:image2text:ocr` (Extract text)
   - `core:analyze-images` (needed server-side for captions; it says nothing about the admin switch)
3. List the search providers with `GET /ocs/v2.php/search/providers`. The ids `photos_albums` and `photos_places` show the unified search providers.
4. Call `GET /ocs/v2.php/apps/photos/api/v1/timeline/days?mediaType=all`. A 404 means the endpoint is absent.
5. Send one PROPFIND Depth 1 on `/remote.php/dav/photos/{user}/albums/` asking for `nc:cover nc:description nc:album-id`. A 404 propstat means the property is not supported.
6. Send one PROPFIND Depth 1 on `/remote.php/dav/photos/{user}/places/` asking for `nc:place-country`. A 404 propstat means the property is not supported.
7. Some features cannot be detected without a server change:
   - video renditions
   - captions on/off and caption searchability
   - the `tags` album filter
   - the smart album, sort order and notification config values
   - the extended mime list

---

## 4. Per-feature details

### 4.1 Features with new server API

#### timeline-days-api (`feat/timeline-days-api`)
**User-visible:** none on its own. It is the data source for the full-library date scrubber.

Files:
- `lib/Controller/TimelineController.php`
- `lib/DB/Timeline/TimelineMapper.php`
- `appinfo/routes.php` (`ocs` block)

Request:
- `GET /ocs/v2.php/apps/photos/api/v1/timeline/days?mediaType=all|photos|videos&format=json` with the `OCS-APIRequest: true` header. `mediaType` defaults to `all`.

Response:
- `ocs.data` = `[{ "day": "YYYY-MM-DD", "count": n }, …]`, newest first. Only days with at least one file are listed.

Errors:
- 400 for an unknown `mediaType`.
- 403 without a user.
- `[]` when the home storage has no id.

Semantics:
- Days are **UTC** calendar days of `photos-original_date_time`, falling back to `mtime`.
- Only files in the user's **own home storage** are counted, under the `photosSourceFolders` user config (default `["/Photos"]`). Shares and group folders are excluded.
- The mimes counted are `Application::IMAGE_MIMES` and/or `VIDEO_MIMES`.

**Caveats for native:**
- The client groups by **local** time, but the server counts in **UTC**, so expect off-by-one days around midnight. The web app only sums days into months (`src/utils/timelineMonths.ts::monthCountsFromDays`) and merges them with the loaded counts using `max` (`mergeMonthCounts`), because neither source alone is a lower bound.
- A native app should treat these counts as estimates for the scrubber or section skeleton, not as exact section sizes.

Detection: a 404 from the OCS route.

#### video-playback-compat (`feat/video-playback-compat`)
**User-visible:** the web app plays videos the browser cannot decode (HEVC, ProRes, MKV) through a server-made H.264/AAC MP4.

Files:
- `lib/Controller/VideoController.php`
- `lib/Service/VideoRenditionService.php`
- `lib/Jobs/ConvertVideoJob.php`
- `lib/Listener/VideoRenditionCleanupListener.php`
- `src/utils/videoPreview.ts`

Request:
- `GET /apps/photos/api/v1/video/{fileId}?etag=<etag>`. The `etag` is only a cache-buster; the server ignores it.

Responses:
- 200 `video/mp4`, served as a full stream with `Content-Length`, **`Accept-Ranges: none`**, and cached privately for 24 h.
- 404 in several cases:
  - feature disabled
  - not a readable video
  - share without download permission
  - no rendition yet (in that case the **request queues the conversion** as a side effect)
  - the video was marked unconvertible

Conversion plan (`ConvertVideoJob::plan`):
- A codec outside `h264, vp8, vp9, av1` is transcoded to libx264 CRF 23, longest side ≤ 1920, HDR tonemapped if `zscale` is available.
- A browser codec in a container outside `video/mp4, video/webm` is remuxed with the video stream copied.
- Otherwise there is nothing to do and the file is marked `.none`.

Renditions are stored in appdata as `video-renditions/<fileId>/<etag>.mp4`.

Dependencies:
- ffmpeg and ffprobe, found through the `preview_ffmpeg_path` and `preview_ffprobe_path` system config or `$PATH`
- app config `video_renditions_enabled=true` (off by default)
- cron for the queued job

**Native relevance:**
- AVPlayer plays HEVC and ProRes natively, so this is mostly not needed.
- It could help for **MKV/H.264**, which is remuxed to MP4.
- It does not help for WebM/VP9, which is marked unconvertible because VP9-in-WebM is "browser playable". AVPlayer cannot play WebM, so the client must download the file and use a 3rd-party decoder, or skip it.
- **`Accept-Ranges: none` breaks AVPlayer HTTP streaming.** AVFoundation needs byte-range support, so the client must download the rendition to a file first.

Detection: none. A 404 is ambiguous. The capability `photos.videoRenditions.enabled` is proposed in §3.

#### ai-photo-captions (`feat/ai-photo-captions`)
**User-visible:**
- A one-line AI description of each photo, used as alt text and shown in the metadata dialog.
- The name search also matches captions.

Files:
- `lib/Service/CaptionService.php`
- `lib/Listener/CaptionMetadataProvider.php`
- `lib/Listener/CaptionTaskListener.php`
- `lib/Jobs/GenerateCaptionJob.php`
- `lib/ConfigLexicon.php`
- `lib/Filters/NameFilter.php`
- `src/utils/photoCaption.ts`
- `src/services/PhotosFilters/nameFilter.ts`

How it works on the server:
1. On the background metadata event for an image without `photos-caption`, the server schedules a TaskProcessing task:
   - type `core:analyze-images`
   - input `{images:[fileId], input:<prompt in the user's language>}`
   - `customId` `caption:<fileId>`
2. Requests are rate-limited to `ai_captions_per_hour`. Overflow goes to `GenerateCaptionJob`.
3. On `TaskSuccessfulEvent`, the output is normalised to one line of ≤ 63 chars, cut at a word boundary with `…`, and stored as indexed metadata `photos-caption`.

Client API:
- Read: `nc:metadata-photos-caption` in PROPFIND or SEARCH. The prop may come back as a number if the caption is numeric, so cast it to a string.
- Search: add `<d:like><d:prop><nc:metadata-photos-caption/></d:prop><d:literal>%term%</d:literal></d:like>` OR'ed with `d:displayname`. **This works only once the key is indexed**, that is once the first caption has been stored anywhere on the instance. Before that, searching the property may fail. The web app gets the flag from initial state `caption-search`.
- Album `name` filters match captions server-side automatically when the key is indexed.

Dependencies:
- Assistant/TaskProcessing with an "Analyze images" provider
- admin `occ config:app:set photos ai_captions --value=true --type=boolean`

Detection: none. `core:analyze-images` in the tasktypes list is necessary but not sufficient. The capability `photos.captions` is proposed.

#### shared-album-comments (`feat/shared-album-comments`)
**User-visible:** a comment thread on own and shared albums.

Files:
- `lib/Listener/AlbumCommentsEntityListener.php`
- `lib/Album/AlbumMapper.php` (`COMMENTS_OBJECT_TYPE = 'photos_album'`; comments are deleted with the album)
- `lib/Sabre/PropFindPlugin.php` (`nc:album-id`)
- `src/services/albumComments.ts`

API (standard core comments DAV):
- Find the album id: PROPFIND `nc:album-id` on `/remote.php/dav/photos/{user}/albums/{name}` or `/sharedalbums/{name}`.
- List: `REPORT /remote.php/dav/comments/photos_album/{albumId}` with body `<oc:filter-comments xmlns:oc="http://owncloud.org/ns"><oc:limit>100</oc:limit><oc:offset>0</oc:offset></oc:filter-comments>`. Each response carries:
  - `oc:id`
  - `oc:actorId`
  - `oc:actorDisplayName`
  - `oc:message`
  - `oc:creationDateTime`
- Post: `POST` the same collection with JSON `{"actorType":"users","verb":"comment","message":"…"}`.
- Delete: `DELETE …/{commentId}`.
- The web app uses only these three calls (list, post, delete). It does not use read markers or unread counts.

Access: only the album owner and user or group collaborators. Public-link visitors are always refused. Other users get 404 or 403 from the comments DAV.

Dependencies: the `comments` app (core, normally enabled).

Detection: `nc:album-id` resolves, or `PROPFIND /remote.php/dav/comments/photos_album/{id}` returns 207.

#### album-cover-and-description (`feat/album-cover-and-description`)
**User-visible:** the owner picks an album's cover photo and adds a description, which is also shown on shared and public albums.

Files:
- `lib/Migration/Version90000Date20261122120000.php`
- `lib/Album/AlbumMapper.php`, `lib/Album/AlbumInfo.php`
- `lib/Sabre/Album/AlbumRoot.php`, `lib/Sabre/Album/AlbumRootBase.php`
- `lib/Sabre/PropFindPlugin.php`
- `src/utils/albumCover.ts`

API (PROPPATCH on `/remote.php/dav/photos/{user}/albums/{name}`, owner only):
```xml
<d:propertyupdate xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
  <d:set><d:prop><nc:cover>12345</nc:cover><nc:description>Summer 2026</nc:description></d:prop></d:set>
</d:propertyupdate>
```
- To reset the cover, set `nc:cover` to `-1`.
- 400 if the cover is not in the album or the description is longer than 2000 chars.
- Shared and public albums return 403 Forbidden on PROPPATCH, but expose both props on PROPFIND.

Cover to display:
- `nc:last-photo` already resolves the picked cover while it is still in the album, otherwise the most recent photo with a preview.
- `nc:cover` is the raw picked value, possibly stale or `-1`.
- The web app's logic (`albumCoverFileId`) uses `cover > 0 ? cover : last-photo`.

Detection: a 404 propstat for `nc:cover`.

#### album-sort-order (`feat/album-sort-order`)
**User-visible:**
- The album lists can be sorted by recently changed, name, or date of photos.
- The photos inside an album can be sorted oldest or newest first.

Server side:
- Two user config keys (§2.4).
- `AlbumRootBase::getLastModified()` now returns `max(album created, max(added) of files with origin "user")`, so `d:getlastmodified` on album collections is meaningful. Before this it was 0.

The sorting itself is client-side (`src/utils/albumSort.ts`):
- `recent`: by `getlastmodified` descending, then by name.
- `date`: by the `end` of `nc:dateRange` descending. The JSON is HTML-escaped with `&quot;`.
- `name`: natural, case-insensitive.
- Photos in an album: by capture timestamp.

Detection: none for the config. The native client can store its own preference locally.

#### filter-by-tag (`feat/filter-by-tag`; also contained in ask-your-photos and unified-photo-search)
**User-visible:** filter the timeline and filter-based albums by system tag. This includes Recognize object and scene tags.

Server: `lib/Filters/TagsFilter.php` registers album filter id `tags` with tag display names, matched by OR.
- `FiltersManager` now passes the user into `SearchQuery`, which scopes systemtags to the visible ones.
- It also deduplicates files that carry several of the searched tags.

Client side: the core Files DAV SEARCH cannot filter on systemtags. The web app does this instead (`src/services/PhotosFilters/tagsFilter.ts`):
1. Fetch each tag's files through `/remote.php/dav/systemtags-relations/files/…` (systemtags store).
2. Add an `<d:or>` of `<d:eq><oc:fileid/>` conditions to the timeline SEARCH.

A native client must do the same, or prefer the core `REPORT oc:filter-files` with `oc:systemtag` on `/remote.php/dav/files/{user}/`.

Dependencies: systemtags. Recognize is optional and is what produces the tags.

Detection: none. An unknown filter id is silently ignored by older servers.

#### saved-filter-smart-albums (`feat/saved-filter-smart-albums`)
**User-visible:** save the current timeline filters as a named "smart album" shown in the navigation.

Storage is the user config key `smartAlbums` (validation in `ApiController::validateSmartAlbums`). The filter values are the same as the client filter values:
- `date-range`: `[{start: ms, end: ms}]`. The end is the start of the last day, and the day is included.
- `places`: `[placeName]`
- `tags`: `[tagName]`
- `name`: `[term]`

Example: `[{"id":"lx3k9a1b2c","name":"Beach","filters":{"places":["Nice"],"tags":["beach"]}}]`.

Opening a smart album runs the **client-side** timeline DAV SEARCH with those filters (`src/store/smartAlbums.ts`, `src/views/TimelineView.vue`). Nothing is evaluated on the server.

Unlike regular "filter albums" (album `nc:filters`), smart albums are per-user and not shareable.

**Gap:** the list cannot be read over HTTP (§3). Detection: none.

#### on-this-day-notification (`feat/on-this-day-notification`)
**User-visible:** a daily notification such as "You have memories from 3 years ago", which opens the "On this day" view.

Files:
- `lib/Jobs/OnThisDayNotificationJob.php`
- `lib/DB/OnThisDay/OnThisDayMapper.php`
- `lib/Notification/Notifier.php`
- `src/components/Settings/OnThisDayNotificationSettings.vue`

Job (runs every 24 h):
1. Walks seen users with `onThisDayNotifications=true` who have not been notified today, using the user's time zone.
2. Counts photos and videos in their home storage source folders taken on today's calendar day in each of the last 20 years. February 29 is skipped in non-leap years.
3. Sends one notification:
   - `app=photos`
   - `object_type=onthisday`
   - `object_id=YYYY-MM-DD`
   - `subject=onthisday`
   - `subjectParameters={years:[yearsAgo…], day:"YYYY-MM-DD"}`

Parsed notification:
- Subject: "You have memories from %n year(s) ago", or "…from %n different years on this day".
- Link: `https://…/apps/photos/thisday`
- Icon: `core/img/places/calendar.svg`

Once the day has passed, the Notifier throws `AlreadyProcessedException` and the notification disappears.

Native client:
- Read it through `GET /ocs/v2.php/apps/notifications/api/v2/notifications`.
- Push delivery requires the app's notifications push registration with the Nextcloud push proxy.
- Map `object_type == "onthisday"` to the in-app "On this day" screen. The years are in `subjectRichParameters`/`subjectParameters` only for the raw `years` list; use `object_id` for the day.
- Opt-out: `PUT /apps/photos/api/v1/config/onThisDayNotifications` with `value=false`.

Dependencies: the notifications app and cron.

Detection: none for the feature. A notification with `app=photos` appears when it is active.

#### unified-search-provider (`feat/unified-search-provider`)
**User-visible:** albums and places appear in Nextcloud's global search.

Files: `lib/Search/AlbumSearchProvider.php`, `lib/Search/PlaceSearchProvider.php`.

API: `GET /ocs/v2.php/search/providers/photos_albums/search?term=…&limit=…&cursor=…` and the same for `photos_places`.
- `photos_albums` entries:
  - `title`: the album name
  - `subline`: the location, or "Shared album"
  - `resourceUrl`: `/apps/photos/albums/<name>` or `/apps/photos/sharedalbums/<name>`
  - `thumbnailUrl`: `/apps/photos/api/v1/preview/<lastAddedPhoto>?x=64&y=64`
  - `attributes.albumId`
- `photos_places` entries have the place name as title and `resourceUrl` `/apps/photos/places/<name>`.
- Matching is a case-insensitive substring match. Pagination uses an integer offset cursor.

Detection: `GET /ocs/v2.php/search/providers`.

**Native note:** for in-app search it is simpler to fetch the album and place collections over DAV and filter locally, as the web app's unified photo search does. Use the providers only for global search.

#### places-by-country (+ `fix/ui-places-city`)
**User-visible:**
- The Places view is grouped by country.
- Place names show as "Paris, France".
- Photos taken in districts or suburbs are attributed to the major city.

Server files:
- `lib/Service/ReverseGeoCoderService.php`: returns `{name, countryCode}`. A "major city" rule applies to places with population ≥ 100 000 that are not of feature code `PPLX`. Their reach is `sqrt(pop / (π·2500))` km, clamped to 5–15 km, and the city must be in the same country as the nearest entry.
- `lib/Service/MediaPlaceManager.php`, `lib/Listener/PlaceMetadataProvider.php`: store the country under metadata key `photos-place-country`.
- `lib/DB/Place/PlaceMapper.php`: a place gets the country holding most of its files.
- `lib/Sabre/PropFindPlugin.php`: `nc:place-country`.

The cached cities file format changed to 7 columns and is rebuilt automatically.

API:
- `nc:place-country` on place collections.
- `nc:metadata-photos-place-country` on files.

Client:
- Group places by country (`src/utils/placeCountry.ts`).
- Get country names from the locale (`Intl.DisplayNames`; on Apple, `Locale.localizedString(forRegionCode:)`).
- Places without a country go under "Other".

Existing photos keep their old place and have no country until re-geocoded (`occ photos:update-1000-cities` / `UpdateReverseGeocodingFilesCommand`, which already exists).

Detection: a 404 propstat for `nc:place-country`.

#### fix/ui-folder-previews
**User-visible:** folders in the Folders view show a mosaic of up to 4 photos.

API: the existing `GET /apps/photos/api/v1/albums/{path}` (`AlbumsController::myAlbums`, also `/api/v1/shared/{path}`). Folder entries now carry `attributes.previews = [{id: "<fileId>", etag: "<etag>"}, …]`, at most 4.
- The photos are taken from the folder itself, or from its first sub-folder that has some (depth ≤ 4).
- Files carry no `previews` key.

Detection: whether the key is present.

### 4.2 Server behaviour only (no new endpoint)

- **heic-avif-exif**: `lib/Service/HeifExifReader.php` and `lib/Listener/ExifMetadataProvider.php` parse the ISOBMFF `meta/iinf/iloc` Exif item of `image/heic|heif|avif`. As a result, `nc:metadata-photos-exif`, `-ifd0`, `-gps` and `-original_date_time` are now filled for iPhone HEICs uploaded by any client. Older files are only updated when the metadata is regenerated (`occ files:scan --generate-metadata`). A native client needs nothing.
- **more-media-formats**: `Application::IMAGE_MIMES` adds `image/gif`. `VIDEO_MIMES` adds `video/webm`, `video/x-m4v` and `video/x-matroska`. RAW stays excluded on purpose. These lists drive the server-side places, timeline days, album filters, on-this-day counts, preview pregeneration and the web timeline SEARCH, which gets them through initial state `image-mimes`/`video-mimes`. **A native client must hard-code the same list** (or use the proposed `photos.mimetypes` capability) to show the same set. The web app adds a placeholder tile for media without a preview (`deead296e`).
- **pregenerate-previews**: on `NodeWrittenEvent` for user files with a Photos mime, `PregeneratePreviewsJob` generates previews of 64×64, 256×256 and 1024×1024 (not cropped, fill mode). It is on by default; app config `pregenerate_previews`. **Native implication:** request the grid previews at exactly these sizes (`/apps/photos/api/v1/preview/{id}?x=256&y=256` or `/index.php/core/preview?fileId=…&x=256&y=256&a=1`) so they hit pregenerated files.
- **google-takeout-sidecars**: `occ photos:import-takeout-metadata <user> <folder> [--force] [--dry-run]` reads Takeout `*.json` sidecars, including the truncated names, `(1)` copy suffixes, and edited/live-photo variants that share a sidecar (`lib/Service/TakeoutSidecarService.php`). It sets `photos-original_date_time` and `photos-gps` and re-derives the place. By default it skips files whose EXIF carries a `DateTimeOriginal`. This is admin only. A native client could do the same at upload time through the existing PROPPATCH; that would be a new client feature.

### 4.3 Front-end only features that call existing (non-Photos) APIs

| Feature | Endpoints used | Notes for native |
|---|---|---|
| **archive** (`src/services/archive.ts`) | WebDAV `MOVE /remote.php/dav/files/{u}/<path>` → `/files/{u}/.archive/<path>` with `Overwrite: F`. On 409, MKCOL the parents and retry | **Convention to copy exactly.** The archive mirrors the original tree under `/.archive`. Unarchive strips the prefix. Only the user's own non-shared files with DELETE permission can be archived (`mount-type == ''`, owner == user). The timeline excludes the archive because `/.archive` lies outside the default source folders. If `photosSourceFolders` contains `/`, the client must filter out paths starting with `/.archive/`. The archive view is a SEARCH scoped to `/.archive`; a 404 there means an empty archive. |
| **recently-deleted-view** (`src/services/trashbin.ts`) | `PROPFIND /remote.php/dav/trashbin/{u}/trash` with `nc:trashbin-filename`, `nc:trashbin-original-location`, `nc:trashbin-deletion-time`. Restore with `MOVE …/trash/<name>` → `/trashbin/{u}/restore/<name>`. Preview: `/index.php/apps/files_trashbin/preview?fileId=&x=&y=&a=1` | Only root items with a Photos mime are shown, newest deletion first. Restore runs with concurrency 5. Detection: capability `files.undelete`. |
| **duplicates-view** (`src/services/duplicates.ts`) | none beyond loading the whole library (see library-wide) | **Client algorithm:** the key is `size + "-" + metadata-photos-original_date_time + "-" + WxH` from `metadata-photos-size`. Files without a size or capture time are skipped. Groups with ≥ 2 members are sorted by path, and the groups wasting the most bytes come first. It finds exact copies only (no perceptual hash). |
| **free-up-space** (`src/utils/cleanup.ts`, `src/views/FreeSpaceView.vue`) | DAV SEARCH. Images: `getcontenttype = image/png` OR displayname LIKE screenshot patterns. Videos: `oc:size > 100 MiB` OR LIKE screen-recording patterns. DELETE | **Client heuristics:** the screenshot and screen-recording name patterns (EN/DE/FR/ES/NL), the PNG phone-screen resolution table, and the 100 MiB large-video threshold. Each file is in one category at most, sorted largest first, and only files with DELETE permission are offered. On Apple, `PHAsset.mediaSubtypes` can do better for local assets, but server files need these heuristics. |
| **ask-your-photos** (`src/services/askPhotos.ts`) | `GET /ocs/v2.php/taskprocessing/tasktypes`; `POST /ocs/v2.php/taskprocessing/schedule` `{type:"core:text2text", appId:"photos", input:{input:<prompt>}}`; poll `GET …/taskprocessing/task/{id}` every 2 s, time out after 3 min; on abort `POST …/tasks/{id}/cancel` | **Client logic:** the prompt includes today's date and the vocabulary of ≤ 500 place names (from the places DAV) and ≤ 500 tag names (systemtags). The LLM must reply with JSON `{dateRange:{start,end YYYY-MM-DD}, places[], tags[], name}`. The parser strips `<think>` blocks, takes the outermost `{…}`, and keeps only names that are in the vocabulary (case-insensitive) and valid dates. The result becomes ordinary filters. Requires a TaskProcessing text provider (Assistant/LLM2/OpenAI); **not** Context Chat. |
| **extract-text-action** (`src/services/textExtraction.ts`) | TaskProcessing `core:image2text:ocr`, input `{input:[fileId]}`, output `{output:[string…]}` joined with blank lines; poll every 2 s, time out after 10 min, report `progress` | Detection: tasktypes. On Apple, Vision `VNRecognizeTextRequest` on-device is an alternative. |
| **people-in-photo** (`src/services/faceDetectionsFetcher.ts`, `src/utils/faceDetections.ts`) | PROPFIND `nc:face-detections` on the file (provided by **Recognize**) | The value is HTML-entity-encoded JSON `[{id, clusterId, title, x, y, width, height}]` with relative 0–1 boxes. Show only detections with `clusterId ≥ 0` and a non-empty `title`, deduplicated by name and ordered left to right. Face crop margin factor: 1.4. Detection: a 404 propstat without Recognize. |
| **bulk-edit-date-location** (`src/utils/dateShift.ts`, `src/services/photoActions.ts`, `src/store/files.ts`) | Per file, the existing `PROPPATCH` `nc:metadata-photos-original_date_time` (unix seconds) and/or `nc:metadata-photos-gps` (`<nc:latitude>`, `<nc:longitude>`), or `<d:remove>` of gps | Modes: keep, **shift** by ±days/hours/minutes (keeps the intervals between photos), or **set** an absolute time. Concurrency 4, failures reported per file. The server re-derives the place from the GPS. The plugin (`lib/Sabre/MetadataPropPatchPlugin.php`) is already on master. |
| **capture-local-time** (`src/utils/dateUtils.ts`) | the existing `nc:metadata-photos-exif` → `OffsetTimeOriginal` | Show the capture time in the photo's own UTC offset ("14 June 2024 at 09:12 (UTC+9)"), falling back to device local time. The offset is parsed as `^[+-]HH:?MM$`, with \|offset\| ≤ 14 h and minutes < 60. |
| **quick-share-selection** (`src/services/quickShare.ts`) | `MKCOL /remote.php/dav/photos/{u}/albums/<name>` → `COPY` each file in → `PROPPATCH nc:collaborators` `[{"id":"","label":"Public link","type":3}]` (the server fills in the token) → PROPFIND `nc:collaborators` and `nc:nbItems`. On failure, `DELETE` the album | The link is `https://host/index.php/apps/photos/public/<token>`. The album is named "Shared on <date>", with " (2)", " (3)" and so on if taken. |
| **public-album-slideshow** | existing `/remote.php/dav/photospublic/{token}` | Web UI only. |
| **live-photo-playback** (`src/utils/livePhoto.ts`) | core files metadata `nc:metadata-files-live-photo` (set by the server's LivePhotos listener on both halves, holding the peer file id); SEARCH `oc:fileid = <id>` under `/files/{u}` to resolve the video | **Client pairing:** the still has `metadata-files-live-photo = <videoId>`. Hide `video/quicktime` files that carry that prop from listings. Play on hover or long press. Native can build a `PHLivePhoto` from the HEIC plus the MOV. |
| **library-wide-photo-views** (`src/composables/useLoadedPhotos.ts`) | DAV SEARCH paged in batches of 500, up to `MAX_PHOTOS = 20000` | Map, Memories and Duplicates run on the whole library loaded client-side. There is no server aggregation endpoint. A native client should keep a local index (sync by etag/SEARCH) instead. |
| **viewer-info-panel** | existing metadata props | Web Files sidebar integration only. |

### 4.4 Front-end only features that are pure client algorithms (reimplement natively)

- **timeline-day-headers** (`src/utils/dayGrouping.ts`; `fix/ui-timeline-day-labels`): photos are grouped by **local** calendar day key `YYYYMMDD`, keeping grid order (newest first), with a per-day "select all" checkbox. Days of one month share grid rows (fix branch).
- **timeline-full-library-scrubber** (`src/components/DateScrubber.vue`, `src/composables/useTimelineJump.ts`, `src/utils/timelineMonths.ts`; `fix/ui-scrubber-years`):
  1. The month list comes from the timeline-days API (UTC days summed per month) merged with the loaded months using `max`.
  2. A jump runs a SEARCH with `original_date_time < endOfMonth(month)` in local time.
  3. If the requested month has nothing loaded, it falls back to the closest older loaded month.
  4. Year labels are drawn on the scrubber.
- **stack-same-shot-variants** (`src/utils/shotVariants.ts`, plus the existing `src/utils/burstClustering.ts`):
  - Shot name: the base name without extension, lower-cased and NFC-normalised. Repeatedly strip the suffixes `(edited)`, `[-_ ]edited|bearbeitet|modifié|editado|modificato|bewerkt`, and `~N`. Map Apple `IMG_E1234` to `IMG_1234`.
  - Group by `dirname + "/" + shotName` across the whole loaded library. This covers RAW+JPEG and original+edited pairs.
  - Leader rank, lower is better: video +4, non-edited +2, non-JPEG +1. Ties keep grid order.
  - Then burst clustering runs over the leaders per month: consecutive photos ≤ 3 s apart (measured against the previous member), minimum 2.
  - `mergeStacks` puts the variants inside the bursts.
- **memories-trip-titles** (`src/services/memories.ts`):
  - Trips: sort by timestamp and split when the gap is > 2 days. Keep clusters of ≥ 8 photos, most recent first.
  - Cover: the photo closest to the trip's middle time.
  - Title: the most frequent `nc:metadata-photos-place`, plus the second place if it has ≥ half the count of the first, formatted as "A & B". Without places, fall back to the date range.
  - Year recap: the newest year with ≥ 30 photos. Pick 60 highlights: favourites first, then a per-month quota spread evenly.
- **timeline-memories-strip** (`src/services/memories.ts::groupByYearsAgo`, `src/components/MemoriesStrip.vue`): uses the existing "On this day" search, which matches a few days around today in past years. Photos are grouped by `round((now − ts) / 365.25 days)`, keeping groups > 0. The cover is the first favourite, else the middle photo. It shows only on the unfiltered "All media" timeline.
- **map-marker-clustering / map-search-this-area / map-time-slider** (`src/utils/mapClusters.ts`, `mapBounds.ts`, `mapTimeRange.ts`; `fix/ui-map-fit`):
  - Clustering: greedy, in input order, on Web-Mercator pixel coordinates at the current zoom. A point joins the nearest seed within `radius` px (Chebyshev distance) in the neighbouring grid cells; otherwise it starts a new cluster. Clusters are drawn at the first item's position as thumbnails.
  - "Search this area": a plain bounds filter, not wrapped across the antimeridian. The matches are shown as a grid.
  - Time slider: filters by an inclusive range of `YYYYMM` month indices (`year*12+month-1`).
  - MapKit has native clustering (`MKClusterAnnotation`) that can replace the first.
- **unified-photo-search** (`src/services/PhotosFilters/searchSuggestions.ts`): one search field builds suggestion groups for Places, Tags, Dates and Albums plus a free-text "name" option.
  - Matching is diacritic- and case-insensitive substring, with prefix matches first and at most 6 per group.
  - Typed years (`2023`) and month names, optionally with a year ("jun 2023"), become `date-range` filters. A month without a year is offered for the last 3 years in which that month has already started.
- **hidpi-aware-previews** (`src/utils/previewSize.ts`): preview edges are bucketed to {64, 256, 1024, 4096}, with the pixel ratio capped at 2 and a 0.8 tolerance. A native client should use the same buckets for cache hits, matching the pregenerated sizes (64/256/1024).
- **album cover fallback** (`src/utils/albumCover.ts`): if the cover has no preview, use the newest photo that has one.
- **selection and keyboard** (drag-select-and-select-all, shift-click-range-selection, grid-keyboard-navigation, `fix/ui-selection-ring`, `fix/ui-actions-button`): UI only.
- **remaining fix/ui-*** (advanced-navigation, album-from-filters, album-title, collection-covers, empty-states, filters-groups, memories-cards, metadata-capture-time, metadata-layout, phone-header, timeline-month-header): layout and UX fixes with no API impact. `fix/ui-advanced-navigation` (and `ui/scanfix`) moves Folders, Duplicates, Archive and Recently deleted under an "Advanced" navigation entry, which is an IA hint for the native app.

---

## 5. External app dependencies

| App / service | Needed by | Detect via |
|---|---|---|
| files_trashbin | recently-deleted, and deletion in free-up-space/duplicates | capability `files.undelete` |
| comments | shared-album-comments | `PROPFIND /remote.php/dav/comments/photos_album/{id}` |
| notifications (+ push proxy) | on-this-day-notification | capability `notifications` |
| TaskProcessing provider `core:text2text` (Assistant / llm2 / integration_openai) | ask-your-photos | `/ocs/v2.php/taskprocessing/tasktypes` |
| TaskProcessing provider `core:image2text:ocr` | extract-text-action | same |
| TaskProcessing provider `core:analyze-images` + admin flag | ai-photo-captions (server-side) | same, but that is not sufficient |
| Recognize | people-in-photo (`nc:face-detections`), and the tags that filter-by-tag and ask-your-photos use | PROPFIND prop 404 propstat; `/remote.php/dav/recognize/{u}/faces/` |
| systemtags | filter-by-tag, ask-your-photos | `/remote.php/dav/systemtags/` |
| ffmpeg/ffprobe on the server + admin flag | video-playback-compat | none (proposal) |
| Context Chat | **not used** by any branch | — |
| Maps app | **not used** by any branch. The map view is Photos' own Leaflet map | — |

---

## 6. Gaps and risks for the native spec

1. **No capabilities.** Add `lib/Capabilities.php` (§3) before relying on these features in a shipped client, or ship with probe-based detection.
2. **User config is write-only over HTTP.** `smartAlbums`, the sort orders and the notification toggle cannot be read back. Add `GET /ocs/v2.php/apps/photos/api/v1/config`. Until then, keep these settings locally on the device and accept that they will not sync with the web app.
3. **Media type list is only in initial state.** Hard-code the 9.0.0-dev.1 list:
   - images: png, jpeg, heic, heif, webp, avif, gif (no tiff, no RAW)
   - videos: webm, mp4, x-m4v, quicktime, x-matroska
4. **Timeline days are UTC and cover the home storage only.** They do not match local-time sections, and they miss shared and group-folder photos.
5. **Video rendition has `Accept-Ranges: none`.** AVPlayer needs range requests, so the client must download the rendition first. WebM/VP9 gets no rendition.
6. **An unknown album filter id is ignored silently.** A `tags` filter on an older server gives an empty or wrong album.
7. **Caption search requires the metadata key to be indexed.** Do not add the caption LIKE to SEARCH unless captions are known to exist.
8. **Album comments** are not available to public-link viewers, and `nc:album-id` is not exposed on public albums.
9. **Archive** is a path convention (`/.archive/<original path>`), not a server concept. The web app and the native app must use exactly the same convention.
10. **Whole-library algorithms** (duplicates, memories, trips, map) run on up to 20 000 items fetched client-side. A native client should maintain a local metadata index. A future server endpoint, for example for duplicates or trips, would be an improvement but does not exist on any branch.

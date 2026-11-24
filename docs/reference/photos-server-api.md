# Nextcloud Photos — server API inventory for a native Apple client

Source of truth: `nextcloud/photos` **master @ 8258010a9** (app version `9.0.0-dev.0`).
Cross-checked against: Nextcloud server master (@ cea3c77bb, `36.0.0 dev`), `nextcloud/recognize` main @ 2fdc5327 (v13.2.0) plus tags v11/v12, and `nextcloud/photos` branches `stable33`/`stable34`/`stable35`.
Sample responses were captured read-only against a local NC 36-dev test instance with Photos installed. Their shape matches the master code paths cited.

Paths in `file:line` form are relative to the photos repo unless prefixed `server:` (server-core) or `recognize:` (recognize main).

---

## 0. TL;DR for the spec

* Almost everything is **WebDAV**:
  * the core files tree `/remote.php/dav/files/<uid>/…`, which also serves `SEARCH` at `/remote.php/dav/`,
  * the Photos trees `/remote.php/dav/photos/<uid>/{albums,sharedalbums,places}` and `/remote.php/dav/photospublic/<token>`,
  * the Recognize tree `/remote.php/dav/recognize/<uid>/{faces,unassigned-faces}`,
  * the core system-tag trees `/remote.php/dav/systemtags*`.
* Photos has only **five non-DAV routes**:
  * `PUT /apps/photos/api/v1/config/{key}`
  * `GET /apps/photos/api/v1/albums/{path}`, which lists folders, and `GET /apps/photos/api/v1/shared/{path}`
  * `GET /apps/photos/api/v1/preview/{fileId}` and `GET /apps/photos/api/v1/publicPreview/{fileId}`
* **Map, Memories (trips and year recap), On-this-day grouping, burst stacking, month sections, date scrubber and "N years ago" headings are all computed client-side.** No server endpoint exists for any of them.
* **No capabilities** are registered by Photos (`lib/AppInfo/Application.php:71-102` has no `registerCapability`).
* The **MIME allow-list, user config and the `.nomedia` exclusion list** reach the web client only as page **initial-state**, with no JSON/OCS read API. See §2.
* **Faces need an `X-Recognize-Api-Key`.** It is an encrypted, 24 h token. Photos embeds it in the HTML page, and there is no API to obtain it. This is the biggest blocker for a native client. See §13.
* **Target NC 33+ caveat:** Photos master declares `nextcloud min-version="36" max-version="36"` (`appinfo/info.xml`).
  * NC 33 runs Photos **6.0 (stable33)**, NC 34 runs 7.0, NC 35 runs 8.0.
  * Several APIs below are master/NC36-only or NC35+. See §17.

---

## 1. Transport, auth, CSRF

| Item | Detail |
|---|---|
| DAV root | `https://<host>/remote.php/dav` (web: `generateRemoteUrl('dav')`, `@nextcloud/files` `getRemoteURL()`). |
| Files root | `/files/<uid>` (`defaultRootPath`). Hrefs in responses are absolute paths, e.g. `/remote.php/dav/files/admin/Photos/x.jpg`. |
| Auth | **Basic with an app password** (Login Flow v2) works for DAV and for the app routes. |
| CSRF on app routes | Photos app routes without `@NoCSRFRequired` fail with **412** for non-browser clients. The affected routes are `AlbumsController::myAlbums/sharedAlbums` and `ApiController::setUserConfig`. Send **`OCS-APIRequest: true`**, which makes `Request::passesCSRFCheck()` return true (`server:lib/private/AppFramework/Http/Request.php:436-438`, `458-467`). Verified: `GET /index.php/apps/photos/api/v1/albums/Photos` returns 412 without the header and 200 with it. |
| Preview routes | `@NoCSRFRequired`, so no header is needed (`lib/Controller/PreviewController.php:45-48`). |
| Web client headers | `X-Requested-With: XMLHttpRequest`, `requesttoken: <csrf>`, plus `X-Recognize-Api-Key` on **every** DAV request (`src/services/DavClient.ts:11-13`, `node_modules/@nextcloud/files/dist/dav/dav.mjs:25-48`). |
| REPORT via patched client | The web client sends REPORT through `getDirectoryContents` with a fake header `method: REPORT`, which a fetch patch turns into the HTTP verb (`dav.mjs:38-45`). A native client simply sends `REPORT`. |

---

## 2. Discovery, feature flags and per-user config

### 2.1 Initial state (web only)
`lib/Controller/PageController.php:83-154` puts these keys in the HTML page:

| Initial-state key | Value | Source |
|---|---|---|
| `image-mimes` | `["image/png","image/jpeg","image/heic","image/heif","image/webp","image/avif"]` | `lib/AppInfo/Application.php:43-54` |
| `video-mimes` | `["video/mp4","video/quicktime"]` | `Application.php:56-64` |
| `maps` | Maps app enabled for user | :90 |
| `recognize` | Recognize enabled for user → Faces menu | :91 |
| `systemtags` | systemtags enabled → Tags menu | :92 |
| `showPeopleMenuEntry` | app config `photos/showPeopleMenuEntry` (default `true`) | :93 |
| `appStoreEnabled` | system `appstoreenabled` | :94 |
| `recognizeApiKey` | **encrypted Recognize key** (only if Recognize is installed) | :96-102 |
| `croppedLayout`, `gridDensity`, `photosLocation`, `photosSourceFolders` | user config, see 2.2 | :105-107 |
| `nomedia-paths` | list of folder paths (relative to user root) that contain a **0-byte** `.nomedia` or `.noimage`. Cached 28 days in distributed cache keyed by `uid:rootEtag`. | :109-134 |

**Native implications**
* **No read API exists for any of these.** Two options:
  * (a) hard-code the MIME lists, discover features by probing DAV roots (2.3), and compute nomedia paths yourself (2.4); or
  * (b) scrape `GET /index.php/apps/photos/` with Basic auth and parse `<input type="hidden" id="initial-state-photos-<key>" value="<base64 JSON>">`. This was verified to work and to expose all the keys above.
* Both options are **companion-API candidates** (a `GET /ocs/v2.php/apps/photos/api/v1/config` plus capabilities).

### 2.2 User config
Defaults are in `lib/Service/UserConfigService.php:17-23`:
`croppedLayout='false'`, `gridDensity='medium'` (master/NC35+), `photosLocation='/Photos'`, `photosSourceFolders='["/Photos"]'`.

**Write:** `PUT /index.php/apps/photos/api/v1/config/{key}` (`appinfo/routes.php`, `ApiController::setUserConfig` `lib/Controller/ApiController.php:41-86`).
* Body: JSON `{"value":"<string>"}`. Non-string values are JSON-stringified by the web (`src/store/userConfig.ts:92-98`).
* Validation:

| key | accepted | 400 otherwise |
|---|---|---|
| `croppedLayout` | `"true"` / `"false"` | ✓ |
| `gridDensity` | `small` / `medium` / `large` (not on NC33/34) | ✓ |
| `photosLocation` | absolute path starting with `/`, no `..` | ✓ |
| `photosSourceFolders` | JSON **list** of such paths, e.g. `"[\"/Photos\",\"/Camera\"]"` | ✓ |

* Response: `200 []`, or `412` when no user, or `400` on validation failure.
* `photosLocation` is the **upload destination** and the target of "upload into album". `photosSourceFolders` are the **SEARCH scopes** of the timeline.

**Read:** none (see 2.1).

### 2.3 Probing optional components (native)
* Photos DAV: `PROPFIND /remote.php/dav/photos/<uid>/` returns 207 when Photos is installed.
* Recognize: `PROPFIND /remote.php/dav/recognize/<uid>/` returns 404 when the app is absent. When it is present but no key is sent, it returns 403 `You must provide a valid X-Recognize-Api-Key`.
* systemtags: `PROPFIND /remote.php/dav/systemtags/`.
* Sharing: core capabilities `files_sharing`. The web gates the collaborator UI on `OC.Share !== undefined` (`src/views/AlbumContent.vue`).

### 2.4 `.nomedia` exclusion (replicate natively)
* The server finds the markers with a query equivalent to `name IN ('.nomedia','.noimage') AND size = 0` over the user folder (`PageController.php:115-127`).
* A DAV equivalent is `SEARCH` with `<d:or><d:eq><d:prop><d:displayname/></d:prop><d:literal>.nomedia</d:literal></d:eq>…</d:or>` plus `<d:eq><d:prop><oc:size/></d:prop><d:literal>0</d:literal></d:eq>`.
* Every listing then drops files whose path starts with one of those folders (`src/store/files.ts:46-56`, `src/store/folders.ts:44-58`). This happens **client-side**: SEARCH still returns those files and they consume page slots.
* The folder JSON endpoint additionally skips subfolders that contain such a marker (`lib/Controller/AlbumsController.php:219-222`).

---

## 3. MIME handling
* **Server allow-list** (`Application.php:43-64`):
  * images: `image/png`, `image/jpeg`, `image/heic`, `image/heif`, `image/webp`, `image/avif`
  * videos: `video/mp4`, `video/quicktime`
  * GIF, BMP, SVG, WebM, MKV, M4V and MPEG are deliberately excluded.
* **Timeline filtering is done in the SEARCH query**: an `<d:or>` of `<d:eq><d:prop><d:getcontenttype/></d:prop><d:literal>MIME</d:literal></d:eq>` (`src/services/PhotoSearch.ts:47-54`).
* The Photos-only view uses image MIMEs. The Videos-only view uses video MIMEs (`src/router/index.ts:63-89`).
* **Other listings filter client-side**:
  * tag REPORT results (`src/services/TaggedImages.ts:43-48`, because the REPORT cannot filter by MIME)
  * the folders JSON (`src/services/FolderContent.ts:92`)
  * Memories/Map (`src/composables/useLoadedPhotos.ts:39-41`)
* **Server-side uses of the list:**
  * folder JSON scanning (`AlbumsController.php:194-201`)
  * smart-album filters (`lib/Filters/FiltersManager.php:126-133`)
  * Places, **images only** (`lib/DB/Place/PlaceMapper.php:36,59,87,121`)
* Album membership is **not** MIME-checked. COPY accepts any file the user owns.
* **Metadata extraction coverage** (important for Apple users):

| Metadata | Which files get it | Source |
|---|---|---|
| EXIF / IFD0 / GPS (`photos-exif`, `photos-ifd0`, `photos-gps`) | **JPEG, TIFF and WebP only** | `lib/Listener/ExifMetadataProvider.php:82-89` |
| Width/height (`photos-size`) | image MIMEs only, via `getimagesizefromstring`, swapped for EXIF orientation ≥5 | `SizeMetadataProvider.php:47-77` |
| Taken date (`photos-original_date_time`) | images and videos | `OriginalDateTimeMetadataProvider.php:59-147` |
| Blurhash | `image/*` | core, `server:lib/private/Blurhash/Listener/GenerateBlurhashMetadata.php:68-84` |

  * **HEIC/HEIF/PNG/AVIF get no EXIF and no GPS**, so they get no Place and their taken date comes from the filename or mtime.
  * Videos get **no** size and no GPS.
  * The taken date is chosen in this order: EXIF `DateTimeOriginal` (+`OffsetTimeOriginal` on NC34+), then a filename regex (`^[A-Z]{3,4}_YYYYMMDD_HHMMSS`, `^YYYY-MM-DD-HH-MM-SS`), then mtime, then upload time.
  * An iPhone `IMG_1234.HEIC` therefore falls back to **mtime**. A native uploader must send `X-OC-MTime: <capture unix time>`. On NC36 it can additionally PROPPATCH the date/GPS (§11).
* **Metadata runs on upload only for local storage.** External or object storage defers EXIF, size, date and place to a background job (`requestBackgroundJob`), so new uploads can briefly lack metadata. Place is **always** background (`PlaceMetadataProvider.php:32-53`).

---

## 4. Common DAV property reference

Namespaces: `d`=`DAV:`, `oc`=`http://owncloud.org/ns`, `nc`=`http://nextcloud.org/ns`, `ocs`=`http://open-collaboration-services.org/ns`, `ns`=`https://github.com/icewind1991/SearchDAV/ns`.

### 4.1 Default prop set used by the web client (`getPropFind()` / SEARCH select)
This is `@nextcloud/files` 4.1.1 `defaultDavProperties` (`node_modules/@nextcloud/files/dist/dav/davProperties.mjs:5-25`) plus the props registered in `src/main.ts:12-18`:
```
d:getcontentlength d:getcontenttype d:getetag d:getlastmodified d:creationdate d:displayname
d:quota-available-bytes d:resourcetype nc:has-preview nc:is-encrypted nc:mount-type
oc:comments-unread oc:favorite oc:fileid oc:owner-display-name oc:owner-id oc:permissions
oc:size nc:upload_time
nc:metadata-photos-size nc:metadata-files-live-photo nc:metadata-blurhash
nc:metadata-photos-original_date_time nc:metadata-photos-gps
```
* The sidebar entry (`src/sidebar.ts:8-11`) adds `nc:metadata-photos-exif`, `nc:metadata-photos-ifd0` and `nc:metadata-photos-place`.
* The photo info dialog fetches those on demand per photo (`src/services/exifFetcher.ts:13-22`).

### 4.2 Photo/metadata props (served by core FilesPlugin on `/files`, and by Photos/Recognize plugins on collection children)
| Prop | Type / wire format | Notes |
|---|---|---|
| `oc:fileid` | int | Primary key everywhere (previews, albums, faces). |
| `d:getetag` | **quoted** on `/files` (`"abc…"`), **unquoted** on `/photos/...` children (`AlbumPhoto::getETag`, `lib/Sabre/CollectionPhoto.php:63-65`) | Strip quotes before comparing. |
| `oc:permissions` | DAV permission letters (`RGDNVW`, …). On album/place children the `R` (share) letter is stripped, and on public-album children `D`, `NV` and `W` are stripped as well (`lib/Sabre/PropFindPlugin.php:98-108`). | |
| `oc:favorite` | `0`/`1` | per account |
| `nc:has-preview` | `true`/`false` | Means "a preview *can* be generated", not that one exists. |
| `nc:hidden` | `true` iff `files-live-photo` is set **and** MIME is `video/quicktime` (`server:apps/dav/lib/Connector/Sabre/FilesPlugin.php:484-488`, mirrored for album children `PropFindPlugin.php:114-117`) | Web drops hidden files client-side (`src/store/files.ts:49`). Hidden MOVs **still occupy SEARCH page slots**. |
| `nc:metadata-photos-original_date_time` | int unix seconds | **Indexed** → searchable and sortable in SEARCH. |
| `nc:metadata-photos-size` | `<width>1920</width><height>1310</height>` (children in **no namespace**) | Images only. Web defaults to 256×256 when missing (`files.ts:58-60`). |
| `nc:metadata-photos-gps` | `<latitude>38.71…</latitude><longitude>-9.13…</longitude>[<altitude>43.4…</altitude>]` (no namespace, decimal degrees as strings) | Not indexed → **cannot be searched**. |
| `nc:metadata-photos-place` | string city name (GeoNames cities1000 nearest neighbour) | Indexed → searchable with `eq`. |
| `nc:metadata-photos-exif`, `nc:metadata-photos-ifd0` | nested elements named after the EXIF tags (non-alpha characters become `_`; non-UTF-8 values become `base64:…`; values >1000 chars are dropped) | Large. Fetch per photo only. |
| `nc:metadata-blurhash` | string | Images only. |
| `nc:metadata-files-live-photo` | string **file id of the paired file** (both halves point at each other) | Set by uploading clients through PROPPATCH (`initMetadata('files-live-photo', STRING, false, EDIT_REQ_WRITE_PERMISSION)`, `server:FilesPlugin.php:746`). Kept in sync on move/copy/delete by `server:apps/files/lib/Listener/SyncLivePhotosListener.php`. |
| `nc:face-detections` | JSON string, see §13 | Recognize, also available on plain `/files` nodes. |
| `nc:mount-type` | `''` = own storage, `shared`, `group`, `external`… | The album picker shows only `mount-type === ''` (`src/components/PhotosPicker.vue:203-205`). |

Sample (album child, captured):
```xml
<d:response><d:href>/remote.php/dav/photos/admin/albums/Lisbon%202025/2984-Lisbon%20(54269600073).jpg</d:href>
<d:propstat><d:prop>
 <d:getcontentlength>568378</d:getcontentlength><d:getcontenttype>image/jpeg</d:getcontenttype>
 <d:getetag>c16cd3f429acdc8de1fe63bf4d98f1e4</d:getetag><d:getlastmodified>Mon, 13 Jan 2025 13:15:00 GMT</d:getlastmodified>
 <d:resourcetype/><nc:metadata-blurhash>LdH:5yIWWXt7X=M{a#j]I^tSoKWC</nc:metadata-blurhash>
 <nc:metadata-photos-size><width>1920</width><height>1310</height></nc:metadata-photos-size>
 <nc:metadata-photos-original_date_time>1736774100</nc:metadata-photos-original_date_time>
 <nc:metadata-photos-gps><latitude>38.717480555556</latitude><longitude>-9.1331722222222</longitude><altitude>43.46990881459</altitude></nc:metadata-photos-gps>
 <nc:metadata-photos-place>Lisbon</nc:metadata-photos-place><nc:has-preview>true</nc:has-preview><nc:hidden>false</nc:hidden>
 <oc:favorite>0</oc:favorite><oc:fileid>2984</oc:fileid><oc:permissions>GDNVW</oc:permissions>
 <nc:photos-album-file-origin>user</nc:photos-album-file-origin>
 <nc:photos-collection-file-original-filename>/Photos/Test library/Travel/Lisbon/Lisbon (54269600073).jpg</nc:photos-collection-file-original-filename>
 <nc:file-name>Lisbon (54269600073).jpg</nc:file-name>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
<d:propstat><d:prop><nc:metadata-files-live-photo/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
```

### 4.3 Collection props (Photos plugin, `lib/Sabre/PropFindPlugin.php:36-47,142-157`)
| Prop | On | Format |
|---|---|---|
| `nc:nbItems` | any `ICollection` in the photos tree (albums home, album, place, …) | int = `count(getChildren())`. Expensive: every child is resolved. |
| `nc:last-photo` | album: cover file id. It prefers the cover photo if it has a preview, else the most-recently-added child with a preview (master only, `:168-213`). Place: first child file id (`PlaceRoot::getFirstPhoto`). | int, `-1` for an empty album |
| `nc:original-name` | album | Real title. Shared albums are listed as `"<title> (<ownerUid>)"`. |
| `nc:location` | album | free text |
| `nc:dateRange` | album | JSON string `{"start":<unix>,"end":<unix>}` computed from child **mtime** (not the taken date!) (`lib/Sabre/Album/AlbumRootBase.php:185-210`). `null`s for an empty album. Not present on places. |
| `nc:collaborators` | album | see §7 |
| `nc:filters` | album | JSON string, smart-album filters, see §6.6 |
| `nc:photos-album-file-origin` | album child | `user` (explicitly added) or `filters` (pulled in by a smart filter, cannot be removed) |
| `nc:photos-collection-file-original-filename` | album child, **only when the current user owns the file** | path relative to the user root, e.g. `/Photos/x.jpg`. The web uses it to build the `/files/...` path for favorite, delete and metadata actions (`src/utils/fileUtils.ts:96-119`). |
| `nc:file-name` | album/place child | bare filename |

* Album collections have **no `getetag`/`getlastmodified`** (404 in PROPFIND), so there is **no cheap change detection** for albums.
* `PhotosHome`/`AlbumsHome` `getLastModified()` returns 0.

---

## 5. Timeline: All media / Photos / Videos / Favorites / On this day

All five views use `getPhotos()` in `src/services/PhotoSearch.ts:32-149`, sent as `SEARCH /remote.php/dav/` with `Content-Type: text/xml`.

### 5.1 Exact request body
```xml
<?xml version="1.0" encoding="UTF-8"?>
<d:searchrequest xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns"
                 xmlns:ns="https://github.com/icewind1991/SearchDAV/ns" xmlns:ocs="http://open-collaboration-services.org/ns">
 <d:basicsearch>
  <d:select><d:prop><!-- §4.1 default prop set --></d:prop></d:select>
  <d:from>
   <!-- one scope per entry of photosSourceFolders, href = /files/<uid><folder> (XML-encoded) -->
   <d:scope><d:href>/files/<uid>/Photos</d:href><d:depth>infinity</d:depth></d:scope>
  </d:from>
  <d:where><d:and>
   <d:or>  <!-- one per allowed MIME of the view -->
    <d:eq><d:prop><d:getcontenttype/></d:prop><d:literal>image/jpeg</d:literal></d:eq> …
   </d:or>
   <!-- Favorites only -->
   <d:eq><d:prop><oc:favorite/></d:prop><d:literal>1</d:literal></d:eq>
   <!-- On this day only, see 5.3 -->
   <!-- extraFilters: timeline filter bar, see 5.4 -->
  </d:and></d:where>
  <d:orderby>
   <d:order><d:prop><nc:metadata-photos-original_date_time/></d:prop><d:descending/></d:order>
   <d:order><d:prop><d:getlastmodified/></d:prop><d:descending/></d:order>
  </d:orderby>
  <d:limit><d:nresults>200</d:nresults><ns:firstresult>0</ns:firstresult></d:limit>
 </d:basicsearch>
</d:searchrequest>
```

### 5.2 Paging
* The timeline uses `nbResults=200` and `firstResult = number of ids fetched so far` (`src/composables/useFetchFiles.ts:26,70-80`). It is done when a page returns fewer than 200 results.
* Other page sizes:
  * Map and Memories fetch a single batch of **500** (`useLoadedPhotos.ts:22,50-54`).
  * The dashboard widget fetches **1** (`src/components/Dashboard/DashboardOnThisDay.vue:52-57`).
  * The album photo picker reuses the timeline call and keeps only `mount-type === ''` and files not already in the album.
* Server behaviour (`server:apps/dav/lib/Files/FileSearchBackend.php`):
  * The default limit is 100 when `nresults` is omitted or 0 (:358-360).
  * There is a hard **100-operator cap** per query (`OPERATOR_LIMIT`, :47, :372-375). On-this-day uses about 61 operators plus the MIME ORs.
  * Several scopes are combined with OR (:171-215) and results are re-sorted.
* **Errors:** a missing source folder returns 404 with body `File with name <path> could not be located`. The web auto-creates it if it equals `photosLocation`, otherwise it tells the user (`useFetchFiles.ts:98-123`).
* **Response:** a standard multistatus with `/remote.php/dav/files/<uid>/…` hrefs (sample in §4.2 / captured).

### 5.3 On this day (`PhotoSearch.ts:65-87`)
* The query covers **20 years back**. For each year `y` in 1…20 it adds the window `[today−3 days 00:00 local, today+3 days 23:59:59.999 local]` of that year. The bounds are compared on `nc:metadata-photos-original_date_time` in **unix seconds** and can be fractional, e.g. `1700000000.5`.
* The windows are joined with `<d:or>`, and each window is `<d:and><d:gt>start</d:gt><d:lt>end</d:lt></d:and>`.
* Grouping into "N years ago" sections is done client-side.

### 5.4 Timeline filter bar → `extraFilters` (`src/services/PhotosFilters/*.ts`, `src/store/filters.ts:13-18`)
* **date-range:** `<d:or>` of `<d:and><d:gt>{start/1000}</d:gt><d:lt>{end/1000 + 86400}</d:lt></d:and>` on `nc:metadata-photos-original_date_time`. Filter values are **milliseconds** (`dateRangeFilter.ts:52-67`).
* **places:** `<d:or>` of `<d:eq><d:prop><nc:metadata-photos-place/></d:prop><d:literal>Paris</d:literal></d:eq>` (`placesFilter.ts:39-48`). The options come from the Places listing (§9).
* **name** (master/NC35+): `<d:and>` of `<d:like><d:prop><d:displayname/></d:prop><d:literal>%term%</d:literal></d:like>`. LIKE wildcards are escaped with `\` and the term is XML-escaped (`nameFilter.ts:21-53`). The server ORs `name` with `mount_point_name` (`FileSearchBackend.php:460-475`).

### 5.5 Client-side post-processing a native client must replicate
* Drop `nc:hidden=true` items and files under nomedia paths.
* `timestamp = original_date_time || mtime || now`, then group by month and day (`files.ts:62-66`).
* **Burst stacking:** consecutive photos ≤3 s apart, runs of ≥2 (`src/utils/burstClustering.ts:20-33`, master/NC35+).
* Live photo: a still whose `metadata-files-live-photo` is set is shown with a play badge (`FileComponent.vue:45`). The paired MOV is the file with that id. Resolve it with SEARCH on `oc:fileid` (§15).

---

## 6. Albums (own)

Root: `/remote.php/dav/photos/<uid>/albums/` (`lib/Sabre/PhotosHome.php:77-97`, `lib/Sabre/Album/AlbumsHome.php`).
Albums are DB rows (`photos_albums`, `photos_albums_files`, `photos_albums_collabs`), not folders.

### 6.1 List albums
* Request: `PROPFIND /remote.php/dav/photos/<uid>/albums/` with `Depth: 1` (`src/services/collectionFetcher.ts:35-47,113-133`).
* Body:
```xml
<d:propfind …><d:prop><nc:last-photo/><nc:nbItems/><nc:location/><nc:dateRange/><nc:collaborators/><nc:filters/></d:prop></d:propfind>
```
  The extra props come from `albumsExtraProps`, `src/store/albums.ts:32-37`. The album picker uses the same call (`AlbumPicker.vue:96-97`).
* Response (captured):
```xml
<d:response><d:href>/remote.php/dav/photos/admin/albums/Lisbon%202025/</d:href><d:propstat><d:prop>
 <nc:last-photo>2991</nc:last-photo><nc:nbItems>10</nc:nbItems><nc:location>Lisbon</nc:location>
 <nc:dateRange>{"start":1736768973,"end":1736776600}</nc:dateRange><nc:collaborators/>
 <nc:filters>{"name":[],"date-range":[],"places":[]}</nc:filters><nc:original-name>Lisbon 2025</nc:original-name>
</d:prop>…
```
* The album name is the last href segment, which is `basename(title)`.
* Cover thumbnail: `/apps/photos/api/v1/preview/<last-photo>?x=512&y=512` (`src/views/AlbumsView.vue:108`).

### 6.2 Album detail and content
* Album props: `PROPFIND …/albums/<name>` with `Depth: 0` (`collectionFetcher.ts:86-104`).
* Album content: `PROPFIND …/albums/<name>` with `Depth: 1` and this body (`collectionFetcher.ts:53-77,182-206`):
```xml
<d:prop><d:getcontentlength/><d:getcontenttype/><d:getetag/><d:getlastmodified/><d:resourcetype/>
<nc:metadata-blurhash/><nc:metadata-photos-size/><nc:metadata-photos-original_date_time/><nc:metadata-files-live-photo/>
<nc:has-preview/><nc:hidden/><oc:favorite/><oc:fileid/><oc:permissions/>
<nc:photos-album-file-origin/><nc:photos-collection-file-original-filename/></d:prop>
```
  The last two props come from `albumFilesExtraProps` and `collectionFilesExtraProps` (`src/store/albums.ts:39`, `src/store/collections.ts:18`).
* Children are named **`<fileid>-<filename>`** (`CollectionPhoto::getName`, `lib/Sabre/CollectionPhoto.php:28-30`).
* Entries whose file can no longer be resolved are dropped (`AlbumRootBase.php:135-141`).
* `GET` on a child streams the original (`AlbumPhoto::get`).
* Hero cover: `/apps/photos/api/v1/preview/<id>?x=1024&y=1024` plus the cover blurhash (`src/components/AlbumHero.vue:78-82`).
* There is **no pagination**: the whole album is returned in one PROPFIND.

### 6.3 Create, rename, delete
| Op | Request | Server |
|---|---|---|
| Create | `MKCOL /remote.php/dav/photos/<uid>/albums/<name>` | `AlbumsHome::createDirectory` → `AlbumMapper::create` (`AlbumsHome.php:70-73`). Sabre returns 405 if the name exists. |
| Set props after create | PROPPATCH, see 6.5 | Web: `src/components/Albums/AlbumForm.vue:197-244` |
| Rename | `MOVE …/albums/<old>` with `Destination: <abs-url>/remote.php/dav/photos/<uid>/albums/<new>` and `Overwrite: F` (`collections.ts:202-220`) | `AlbumRoot::setName` → `AlbumMapper::rename` (`AlbumRoot.php:23-26`) |
| Delete | `DELETE …/albums/<name>` (`collections.ts:279-313`) | `AlbumRoot::delete` deletes the files links, the collaborators and the album row (`AlbumMapper.php:145-169`) |

### 6.4 Add and remove photos
* **Add:** `COPY /remote.php/dav/files/<uid>/<path/to/file>` with `Destination: <abs-url>/remote.php/dav/photos/<uid>/albums/<name>/<basename>` (`collections.ts:122-151`). The web batches 5 concurrent requests.
  * Server: `AlbumRoot::copyInto` → `copyIntoAlbum` (`AlbumRootBase.php:103-116`).
  * The source must be a files-DAV `File` **owned by the current user**, otherwise 403 `Can't add file to album, only files from <uid> can be added`.
  * An already-present file returns **409**, which the web treats as success.
  * The target name is ignored.
  * Adding sets the album's `last_added_photo` (`AlbumMapper.php:230-251`).
* **Remove:** `DELETE /remote.php/dav/photos/<uid>/albums/<name>/<fileid>-<filename>` (`collections.ts:159-182`). This unlinks only; the file is not deleted (`AlbumPhoto::delete`, `lib/Sabre/Album/AlbumPhoto.php:41-44`).
  * Photos with `photos-album-file-origin=filters` cannot be removed. The web hides the action for them (`AlbumContent.vue` `removableSelectedFiles`).
* **Upload straight into an album:** `PUT /remote.php/dav/photos/<uid>/albums/<name>/<filename>` (`AlbumRootBase::createFileInCurrentUserFolder`, `:68-101`).
  * It writes into `photosLocation`, creating the folder if needed and renaming on conflict, then adds the file to the album.
  * The response carries an `OC-FileId` header and the ETag.
  * It is refused if `photosLocation` is a received share.
  * The web does **not** use this. It uploads into `photosLocation` and then COPYs.
  * Chunked upload cannot target this path (**unverified**).

### 6.5 Album PROPPATCH (`PropFindPlugin::handleUpdateProperties`, `:215-245`; web `collections.ts:226-274`)
```xml
<?xml version="1.0"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
 <d:set><d:prop>
  <nc:location>Lisbon</nc:location>
  <nc:collaborators>[{"id":"bob","label":"Bob","type":0},{"id":"","label":"Public link","type":3}]</nc:collaborators>
  <nc:filters>{"date-range":[{"start":1735689600000,"end":1738281600000}],"places":["Lisbon"],"name":["beach"]}</nc:filters>
 </d:prop></d:set>
</d:propertyupdate>
```
* `nc:collaborators` and `nc:filters` are **JSON text inside XML**.
* The web does **not** XML-escape values and joins elements with `,` (`collections.ts:232-244`). A native client must XML-escape properly.
* `location` may arrive as complex XML, in which case the server takes its inner XML (`PropFindPlugin.php:218-223`).
* Shared and public albums reject all three props with 403 (`AlbumRootBase.php:221-235`).

### 6.6 Smart-album filters (`lib/Filters/*`)
* Stored as a JSON object on the album. Keys:
  * `date-range`: list of `{start,end}` in **ms**. The end gets +1 day. `start`/`end` must be ints.
  * `places`: list of place names.
  * `name`: list of substrings (master/NC35+).
* The files are resolved by a server-side search over the album **owner's** `photosSourceFolders` and allowed MIMEs, capped at **1000 results** (`FiltersManager.php:48-94,113-135`).
* Files from received shares without download permission are excluded.
* These files appear as children with `origin=filters`.

---

## 7. Sharing albums (collaborators) and public links

### 7.1 Model (`lib/Album/AlbumMapper.php:25-28,334-457`)
* Collaborator `type` values mirror `IShare`: `0` user, `1` group, `3` public link.
* PROPFIND `nc:collaborators` on an **own** album returns all collaborators (`AlbumRoot::getCollaborators`):
```xml
<nc:collaborators>
 <nc:collaborator><id>bob</id><label>Bob Example</label><type>0</type></nc:collaborator>
 <nc:collaborator><id>family</id><label>Family</label><type>1</type></nc:collaborator>
 <nc:collaborator><id>Ab12…32chars</id><label>Public link</label><type>3</type></nc:collaborator>
</nc:collaborators>
```
  * Inner elements are in **no namespace**.
  * A single collaborator is not wrapped in an array. The web normalises 0, 1 or n entries (`collectionFetcher.ts:141-150`).
* **Set:** PROPPATCH the full desired list as JSON.
  * The server diffs it against the stored list. Link entries are keyed by type only, so only one link is possible.
  * It validates that users and groups exist and **generates a 32-char `[A-Za-z0-9]` token** for a new link entry (`AlbumMapper.php:398-457`). Send `{"id":"","type":3}`.
  * Read the token back with a fresh PROPFIND (web: `CollaboratorsSelectionForm.vue:288-295`).
  * Removing a user collaborator also **removes every photo that user added** (`deleteUserFromAlbumCollaboratorsList`, `:565-575`).
* **Sharee search:** `GET /ocs/v2.php/core/autocomplete/get?search=<q>&itemType=share-recipients&shareTypes[]=0&shareTypes[]=1` with `OCS-APIRequest: true` (`CollaboratorsSelectionForm.vue:218-227`). It uses `ocs.data[].{id,label,source:'users'|'groups'}`. The minimum length comes from the sharing config `minSearchStringLength`.
* **Public link URL shown to users:** `https://<host>/index.php/apps/photos/public/<token>` (`CollaboratorsSelectionForm.vue:190`; the route `publicAlbum#get`).
* Server-side cleanup (`lib/Listener/AlbumsManagementEventListener.php`):
  * user deleted → their albums are deleted and they are removed from shared albums;
  * a user leaves a group → their photos are removed from that group's albums;
  * group deleted → its collaborator rows are removed;
  * share revoked → files of that share are removed from the receiver's albums.

### 7.2 Albums shared with me (`/remote.php/dav/photos/<uid>/sharedalbums/`, `lib/Sabre/Album/SharedAlbumsHome.php`)
* List with the same PROPFIND as §6.1 (`src/views/SharedAlbums.vue:88`).
* Contains albums shared with the user directly and with any of the user's groups, de-duplicated (`SharedAlbumsHome.php:56-80`).
* **Name** is `"<title> (<ownerUid>)"` (`AlbumMapper.php:527-529`). `nc:original-name` gives the same suffixed string, so the web strips the suffix with a regex (`SharedAlbumContent.vue` `albumOriginalName`).
* `nc:collaborators` returns **only the owner**: `{id: ownerUid, label: displayName, type: 0|1}`, where `type` is how you received the album (`SharedAlbumRoot.php:60-69`).
* Operations:

| Op | Behaviour |
|---|---|
| Content | Same as §6.2 |
| Add photos | COPY of **your own** files only (`SharedAlbumRoot.php:43-55`) |
| Remove photos | DELETE child, as in §6.4. Permissions are those of the file owner. |
| Rename | 403 |
| Set location, collaborators or filters | 403 |
| Create (MKCOL) | 403 |
| DELETE album | **leave** the album and also drop every photo you added (`SharedAlbumRoot.php:18-21`) |

* Previews of photos owned by others **must** use `/apps/photos/api/v1/preview/<fileId>`, because `/core/preview` cannot see files outside your user folder (§12).
* Favoriting an album child through PROPPATCH on the album path is owner-only (`PropFindPlugin.php:235-244`).

### 7.3 Public album, anonymous (`lib/Sabre/PublicRootCollection.php`, `PublicAlbumAuthBackend.php`)
* DAV root: **`/remote.php/dav/photospublic/<token>/`**.
  * The auth backend accepts **any** request whose path starts with `photospublic/` (`SabrePluginAuthInitListener.php:33-39`, `PublicAlbumAuthBackend.php:45-48`).
  * The web sends `Authorization: Basic base64("<token>:")` (`src/views/PublicAlbumContent.vue:121-123`). The empty password makes the core backend skip any login attempt (`server:apps/dav/lib/Connector/Sabre/Auth.php:85-87`), so there is no browser prompt, no session user and no brute-force penalty.
  * An unknown token triggers **brute-force throttling** (`publicphotos_webdav_auth`) and returns 404 (`PublicRootCollection.php:64-88`).
* Album props: `PROPFIND /photospublic/<token>` with `Depth: 0`, requesting the album props plus `nc:original-name`.
  * The name is **not** suffixed with the owner.
  * `nc:collaborators` is empty.
* Content: `PROPFIND /photospublic/<token>` with `Depth: 1`, with the same file props as §6.2 plus the album props.
  * Permissions are stripped of `R`, `D`, `NV` and `W`.
  * Children are streamable by `GET`.
  * DELETE, PUT, COPY into, MKCOL, rename and PROPPATCH all return 403 (`PublicAlbumRoot.php`, `PublicAlbumPhoto.php`).
* Public previews: `/index.php/apps/photos/api/v1/publicPreview/<fileId>?x=…&y=…&token=<token>`, with an optional `etag=` cache-buster. The viewer uses `x=y=4096` (`PublicAlbumContent.vue:155`); grid tiles use 64/256/1024 (`FileComponent.vue:358-364`).
* Public upload is **not implemented** (`PublicAlbumContent.vue:69`).
* The HTML page `/index.php/apps/photos/public/<token>` exposes initial state with maps, recognize and systemtags all `false` (`lib/Controller/PublicAlbumController.php:34-52`).

---

## 8. Folders view and "Shared with you"

* Requests (both need `OCS-APIRequest: true` for native clients):
  * Folders view: `GET /index.php/apps/photos/api/v1/albums/<path>`
  * Shared with you: `GET /index.php/apps/photos/api/v1/shared/<path>`
  * Web: `src/services/FolderContent.ts:69-99`; server: `lib/Controller/AlbumsController.php:46-246`.
* Response is a JSON array. The **first element is the folder itself**, followed by:
  * subfolders that contain an allowed-MIME file within **4 levels**, have no `.nomedia`/`.noimage`, and match the shared/non-shared mode;
  * allowed-MIME files.
* The `shared` flag means "storage is `ISharedStorage` or a GroupFolder". `/albums` returns only non-shared content and `/shared` only shared content.
* Master (NC36) entry shape (captured):
```json
{"id":"2677","filename":"/Photos","mtime":1795356271,"mime":"httpd/unix-directory","size":328209680,"type":"dir",
 "permissions":"RGDNVCK","owner":"admin",
 "attributes":{"etag":"6b02f66f8b182","hasPreview":false,"favorite":0,"metadata-photos-size":{…},"metadata-photos-original_date_time":…}}
```
  `attributes` carries every stored `metadata-*` key (`AlbumsController.php:83-175`).
* **Older shape (stable33/34/35):** `{basename, etag, fileid(int), filename, lastmod, mime, size, type, permissions:"CKGWDR"-style, hasPreview}`, with no favorite and no metadata.
* The folder `404`s if the path does not exist.
* **Cost:** the server recursively scans the directory on every call. There is no caching or etag.
* Folder cover: `/core/preview?fileId=<id>&c=<etag>&x=250&y=250&forceIcon=0&a=0` (`src/components/FolderTagPreview.vue:67-73`).
* Uploading in a folder uses the core uploader into the current folder (§14). The new node is then refreshed with a PROPFIND using the §4.1 props (`FoldersView.vue:309-319`, `src/services/fileFetcher.ts`).
* A native client could equally do `PROPFIND Depth:1` on `/files/<uid>/<path>` and filter by MIME. Only the "folder contains media within 4 levels" pruning is unique to this endpoint.

---

## 9. Places

* Root: `/remote.php/dav/photos/<uid>/places/` (`lib/Sabre/Place/*`).
* Enabled unless system `has_internet_connection=false` or app config `photos/disable_places=1` (`ReverseGeoCoderService::arePlacesEnabled`).
* **List:** `PROPFIND …/places/` with `Depth: 1` and `<nc:last-photo/><nc:nbItems/>` (`src/views/PlacesView.vue:78`). Captured:
```xml
<d:response><d:href>/remote.php/dav/photos/admin/places/Potsdam/</d:href><d:propstat><d:prop><nc:last-photo>2679</nc:last-photo><nc:nbItems>8</nc:nbItems></d:prop>…
```
  * There is no `dateRange`, coordinates, country or hierarchy; the place is only a city-name string.
  * Two same-named cities in different countries **merge**.
  * The cover thumbnail is `/apps/photos/api/v1/preview/<last-photo>?x=512&y=512`. The filter chips use 64.
* **Content:** `PROPFIND …/places/<name>` with `Depth: 1`, using the §6.2 file props (`src/views/PlaceContent.vue:91-95`). Children are `<fileid>-<name>`. DELETE, PUT and MKCOL return 403.
* **Scope limits** (`lib/DB/Place/PlaceMapper.php:30-151`):
  * **image MIMEs only**;
  * **only the user's home storage** (`file.storage = home storage id`), so received shares, group folders and external storage are excluded;
  * ignores `photosSourceFolders`.
* The place value is derived from `photos-gps` on the background job using the GeoNames `cities1000` nearest neighbour (`lib/Service/MediaPlaceManager.php:35-49`).

---

## 10. Map and Memories (client-side only)

* **Map** (`src/views/MapView.vue`, master/NC35+):
  * Data comes from `useLoadedPhotos()`: the photos already in the store, or a **single SEARCH of 500** newest items (§5).
  * The view keeps photos with finite non-0/0 `metadata-photos-gps`, centres on the mean of the first 200, and draws one marker per photo.
  * Tiles: `https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png` with `referrerPolicy: strict-origin-when-cross-origin`. The CSP allows `*.tile.openstreetmap.org` (`lib/Listener/CSPListener.php`).
  * There is **no server-side geo query, bbox or clustering**, so older photos beyond the 500 are never on the map. A native client would page the whole library via SEARCH (GPS is selectable but not searchable).
* **Memories** (`src/services/memories.ts`, `src/views/MemoriesView.vue`, master/NC35+). Computed over the same ≤500 photos:
  * **Trips:** sort by timestamp; a new trip starts at a gap > **2 days**; keep runs ≥ **8** photos; the cover is the photo closest to the temporal midpoint; trips are listed newest first (`memories.ts:35-59,176-196`).
  * **Year recap:** the most recent year with ≥ **30** photos. It holds 60 highlights: favorites first, then a per-month quota spread evenly; the cover is the middle highlight (`:85-140`).
  * Cover previews use `getPreviewUrl(photo, 1024)` for the recap and 512 for trips.
* **On this day**: §5.3. Dashboard widget: §16.

---

## 11. Photo actions on `/files`

The `davPath` is `/files/<uid>/<path>`. For album, place and face children it is rebuilt from `nc:photos-collection-file-original-filename` or `nc:realpath` (`src/utils/fileUtils.ts:96-119`).

| Action | Request | Notes |
|---|---|---|
| Favorite / unfavorite | `PROPPATCH <davPath>` with `<d:set><d:prop><oc:favorite>1|0</oc:favorite></d:prop></d:set>` (`src/services/photoActions.ts:73-85`; bulk `src/store/files.ts:220-257`, 5 concurrent) | Per-account, so it works on shared files. On album children PROPPATCH `oc:favorite` is owner-only. |
| Delete (to trash) | `DELETE <davPath>` (`photoActions.ts:93-95`, `files.ts:186-212`) | The server removes the file from all albums (`AlbumsManagementEventListener`). A live-photo peer is handled by core `SyncLivePhotosListener` (BeforeNodeDeleted). |
| Download one | `GET <davPath>`; the web does a `HEAD` first (`src/services/downloadFiles.ts:19-27`) | |
| Download many | `GET <common-parent-dir>/?accept=zip&files=["a.jpg","b/c.jpg"]` (`downloadFiles.ts:60-90`) | Core ZipFolderPlugin. Alternatives are the `Accept: application/zip` header and repeated `X-NC-Files` headers (`server:apps/dav/lib/Connector/Sabre/ZipFolderPlugin.php:32-33,100-130`). |
| Edit taken date / GPS (**master and NC35+ only**) | see below | `lib/Sabre/MetadataPropPatchPlugin.php`. Needs `isUpdateable()`, otherwise 403. |
| Read EXIF on demand | `PROPFIND Depth:0 <davPath>` requesting `nc:metadata-photos-exif`, `nc:metadata-photos-ifd0`, `nc:metadata-photos-gps`, `nc:metadata-photos-place` and `nc:metadata-photos-original_date_time` (`src/services/exifFetcher.ts:13-55`) | |

Edit taken date / GPS request body:
```xml
<d:propertyupdate xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
 <d:set><d:prop>
  <nc:metadata-photos-original_date_time>1736774100</nc:metadata-photos-original_date_time>
  <nc:metadata-photos-gps><nc:latitude>38.7174</nc:latitude><nc:longitude>-9.1331</nc:longitude></nc:metadata-photos-gps>
 </d:prop></d:set>
 <!-- to clear GPS instead: -->
 <d:remove><d:prop><nc:metadata-photos-gps/></d:prop></d:remove>
</d:propertyupdate>
```
* Coordinates are decimal degrees, \|lat\|≤90 and \|lon\|≤180, otherwise 400. The children may be in any namespace or none. The altitude is dropped.
* An empty date value resets it to the extracted value.
* Changing GPS recomputes `photos-place`.
* Values are stored as metadata only; the file is not modified.
* The plugin is registered at priority 90 on `propPatch` (`:59-70`). On stable33/34 core rejects these keys as not editable.
* The edit dialog uses `src/components/PhotoMetadataEditDialog.vue`.

---

## 12. Previews

| Endpoint | Params | Used for | Server |
|---|---|---|---|
| **`GET /index.php/apps/photos/api/v1/preview/{fileId}`** | `x`, `y` (default 32; 0 → 400), `etag` (ignored, cache-buster only) | All grid tiles, covers and slideshow for authenticated users | `lib/Controller/PreviewController.php:52-176` |
| **`GET /index.php/apps/photos/api/v1/publicPreview/{fileId}`** | `x`, `y`, `token` (required, else 403), `etag` | Public albums | `PublicPreviewController.php:26-50`. Only files of the album with that link token, including smart-filter files. |
| `GET /index.php/core/preview` | `fileId`, `x`, `y`, `a` (1 = keep aspect, 0 = crop), `forceIcon` (default **1**; web passes 0), `mode` (`fill`\|`cover`), `mimeFallback`, `c` (etag cache-buster) | Tag covers (`x=y=512&forceIcon=0&a=1`, `src/components/TagCover.vue:55`) and folder covers (`x=y=250&a=0`) | `server:core/Controller/PreviewController.php:104-185`. Only files visible in **your** user folder. Shares with "hide download" return 403 unless `X-NC-Preview: true`. |

**Photos preview controller behaviour:**
* It looks the file up in your folder, excluding shares whose attribute `permissions.download === false`.
* It falls back to your own albums, then albums shared with you as a user, then albums shared with your groups, then resolves the file in the **owner's** folder.
* So it is the only way to preview photos of shared albums owned by others.
* The preview is **not cropped** (`getPreview($node, $x, $y)`, default crop=false, mode fill).
* Response: `200` image with `Cache-Control` private, 24 h, immutable. `404` when there is no preview or no access, `403` when the file is unreadable.

**Sizes the web requests** (`x=y`):

| Size | Used for |
|---|---|
| 64 | tile low-res, album picker, place chips |
| 256 / 1024 | tile hi-res (mobile / desktop, `src/components/FileComponent.vue:229-231`) |
| 512 | album, place, shared-album and face covers; trips |
| 1024 | album hero, year recap |
| 2048 | slideshow (`PhotoSlideshow.vue:77`) |
| 4096 | public viewer |
| 250 | folder covers (core) |

**Server bucketing:**
* Non-max sizes are rounded **up to the next power of 4**, with a minimum of 64 (64 / 256 / 1024 / 4096).
* Sizes are capped by system `preview_max_x`/`preview_max_y` (default 4096) (`server:lib/private/Preview/Generator.php:376-377,465-535`).
* Request 64/256/1024/4096 to hit cached files exactly.

**Other notes:**
* `nc:has-preview=false` means "no provider". HEIC needs `OC\Preview\HEIC` (Imagick with libheif) and video needs `OC\Preview\Movie` (ffmpeg). Neither is enabled by default. A native client can decode HEIC/MOV originals itself via `GET` on the DAV path.
* Blurhash (`nc:metadata-blurhash`) is rendered under the previews.
* The web Service Worker caches previews under the name `images` (`src/services/PreviewService.ts`). This is web-only.
* The full-size viewer is the separate Viewer app (`@nextcloud/viewer`). It streams the original from the DAV `source` URL; videos play through `<video src=DAV URL>`, and QuickTime is not inline-previewed in browsers (`src/utils/videoPreview.ts:18`).
* There is no server-side video duration; the web reads it from video metadata in the browser (`fileUtils.ts:121-147`).

---

## 13. Faces (Recognize app)

Root: `/remote.php/dav/recognize/<uid>/` → `faces/` and `unassigned-faces/` (`recognize:lib/Dav/RecognizeHome.php:59-87`).

### 13.1 API key (blocker)
* Every request whose path starts with `recognize` needs **`X-Recognize-Api-Key`** (`recognize:lib/Dav/Faces/PropFindPlugin.php:213-248`).
* The value is `ICrypto::encrypt(json_encode({"type":"recognize-api-key","version":1,"timestamp":<now>}))`, encrypted with the **instance secret** and **valid 24 h** (`recognize:lib/Public/ApiKeyManager.php:27-29`, `API_KEY_TIMEOUT`).
* Photos generates it server-side on page render and puts it in initial state `recognizeApiKey` (`PageController.php:96-102`). The web sends it on all DAV requests (`src/services/DavClient.ts:11-13`).
* Recognize ≥12 (NC34+) allows an admin to disable the check with app config `recognize/require_api_key=false`. **Recognize 11.x (NC33) always enforces it.**
* **Native options today:**
  * scrape `/index.php/apps/photos/` every <24 h (initial-state `recognizeApiKey`, base64 JSON string); or
  * ask admins to set `require_api_key=false` (NC34+).
* `nc:face-detections` on **`/files/...` nodes** is served by the same Recognize plugin **without** the key, because the check is path-based. Per-photo face boxes are therefore readable from the timeline SEARCH or PROPFIND by adding `<nc:face-detections/>`.

### 13.2 Requests used by the web (`src/composables/useFetchFaces.ts`, `src/store/faces.ts`)
Extra props: `<nc:face-detections/><nc:face-preview-image/><nc:realpath/><nc:nbItems/>` on top of the §4.1 default set (`useFetchFaces.ts:24-29`).

| Op | Request | Server |
|---|---|---|
| List people | `PROPFIND /recognize/<uid>/faces/` with `Depth: 1` (`:99-103`) | `FacesHome::getChildren`: clusters with ≥1 detection. The **name is the cluster title, or its numeric id if untitled** (`FaceRoot::getName`). Props: `nc:nbItems`, `nc:face-preview-image` = JSON `{"fileid":123,"detection":{id,userId,fileId,x,y,height,width,clusterId,threshold}}`. x, y, width and height are **fractions 0–1** of the image (`FaceRoot.php:159-165`). The web zooms the cover with them (`src/composables/useFaceCover.ts:43-65`) and loads the cover via `/apps/photos/api/v1/preview/<fileid>?x=512&y=512`. Sorted client-side by `nbItems` desc. |
| Person content | `PROPFIND /recognize/<uid>/faces/<name>` with `Depth: 1` (`:139-143`) | One child per **detection**, named **`<detectionId>-<filename>`** (`FacePhoto::getName`). Props: `oc:fileid`, `d:getetag`, `nc:file-name`, `nc:realpath` = `/<uid>/files/<path>` (the web rewrites it to `/files/<uid>/<path>`, `useFetchFaces.ts:44-58`), `oc:favorite`, `nc:has-preview`, `oc:permissions` (minus R), all `nc:metadata-*`, and `nc:face-detections` = JSON array of **all** detections on that file for the user: `[{"id":…,"userId":…,"fileId":…,"x":…,"y":…,"height":…,"width":…,"clusterId":…|null,"title":"…"}]` (`recognize:…/PropFindPlugin.php:146-171`). |
| Unassigned | `PROPFIND /recognize/<uid>/unassigned-faces` with `Depth: 1` (`:184-188`) | Detections with `clusterId = -1` ("rejected"). The same file can appear once per face. |
| Unassigned count | `PROPFIND /recognize/<uid>/unassigned-faces` with `Depth: 0`, reading `nc:nbItems` (`:212-222`) | Counts every child. |
| Rename person | `MOVE /recognize/<uid>/faces/<old>` with `Destination: …/faces/<new>` (`faces.ts:223-242`) | `FaceRoot::setName`. 403 on a duplicate title (`beforeMove`, `PropFindPlugin.php:194-211`). Numeric-only names are rejected only on create. |
| Merge A into B | MOVE each detection of A to B, then `DELETE /faces/A` (`FaceContent.vue:318-322`) | |
| Move photo(s) to a person, or assign unassigned | `MOVE /recognize/<uid>/faces/<from>/<detId>-<file>`, or `/unassigned-faces/<detId>-<file>`, with `Destination: …/faces/<to>/<detId>-<file>` (`faces.ts:148-183`, 5 concurrent) | `FaceRoot::moveInto` sets the detection's cluster (`FaceRoot.php:132-142`). **The target person must exist** (Sabre 409 otherwise). |
| Create person | *(not used by web)* `MKCOL /recognize/<uid>/faces/<name>` | `FacesHome::createDirectory`: no duplicates, not purely numeric (`FacesHome.php:52-63`) |
| Remove photo from person ("not this person") | `DELETE /recognize/<uid>/faces/<name>/<detId>-<file>` (`faces.ts:191-216`) | Unclusters the detection and stores a distance threshold so it is not re-added (`FacePhoto.php:48-59`). Unassigned photos cannot be deleted (403). |
| Delete person | `DELETE /recognize/<uid>/faces/<name>` (`faces.ts:247-255`) | Deletes the cluster row. |
| Favorite / delete / download from face views | via the `/files` path from `nc:realpath` | |

**Pitfall:** addressing a face child by bare filename returns 404. The detection id must be the prefix, and the web finds it in `face-detections` by matching `title || clusterId` (`faces.ts:53-62`).

---

## 14. Upload

* **Destination:** `photosLocation`, default `/Photos`. The web resolves it with `PROPFIND Depth:0` using `getDefaultPropfind()`, and **creates it with MKCOL if it is a 404** (`src/store/userConfig.ts:28-53`). The photo picker warns when the folder's `owner-id ≠ current user`.
* **Mechanism:** `@nextcloud/files/upload` uploader (`NcUploadPicker` in `src/components/PhotosPicker.vue:52-58` and `FoldersView.vue:30-36`). This is standard core upload:
  * **Small file:** `PUT /remote.php/dav/files/<uid>/<dest>/<name>` with `X-OC-Mtime: <file lastModified seconds>`.
  * **Chunked (v2):**
    1. `MKCOL /remote.php/dav/uploads/<uid>/<random>` with `Destination: <final url>`.
    2. `PUT …/<random>/<n>` for each chunk, with `Destination` and `OC-Total-Length`.
    3. `MOVE …/<random>/.file` with `Destination: <final url>`, `OC-Total-Length` and `X-OC-Mtime`.
  * Chunk size defaults to 10 MiB, with a minimum of 5 MiB or `fileSize/10000`. It follows server appconfig `files.max_chunk_size`. Parallelism comes from capability `files.chunked_upload.max_parallel_count` (default 5) (`node_modules/@nextcloud/files/dist/upload/utils/config.mjs`, `uploader/UploadFile.mjs:90-130`).
  * The picker passes `accept = allMimes`.
* **Timeline upload is a TODO** in master (`TimelineView.vue:37`); uploads happen from the Add-photos picker and the Folders view.
* **After upload:**
  * The Folders view re-PROPFINDs the new node.
  * The picker re-runs the timeline SEARCH from offset 0 (`PhotosPicker.vue:200-202`).
  * Metadata (EXIF, date, size, blurhash) is extracted synchronously for local storage; place is always async.
* **Live photos:** after uploading both halves, set `nc:metadata-files-live-photo` on **each** to the other's file id. Use `PROPPATCH <path>` with `<nc:metadata-files-live-photo>12345</nc:metadata-files-live-photo>` (core edit permission `EDIT_REQ_WRITE_PERMISSION`). The web never uploads live pairs.
* **Album-targeted upload:** see §6.4 (PUT into the album path).

---

## 15. Tags (systemtags)

| Purpose | Request | Code |
|---|---|---|
| Tag list for the Tags view | `PROPFIND /remote.php/dav/systemtags-assigned/image` with `Depth: 1` and `<oc:id/><oc:display-name/><oc:user-visible/><oc:user-assignable/><oc:can-assign/><nc:files-assigned/><nc:reference-fileid/>` | `src/services/SystemTags.ts:18-47`. Server `SystemTagsInUseCollection` (`server:apps/dav/lib/SystemTag/SystemTagsInUseCollection.php`) returns only tags used on files whose MIME starts with `image` in the user's folder. `files-assigned` = count, `reference-fileid` = a cover file. The first row is the collection itself (filter it out). Cover: `/core/preview?fileId=<reference-fileid>&x=512&y=512&forceIcon=0&a=1`. |
| Photos of a tag | `REPORT /remote.php/dav/files/<uid>` with `<oc:filter-files …><d:prop>{§4.1}</d:prop><oc:filter-rules><oc:systemtag>{id}</oc:systemtag></oc:filter-rules></oc:filter-files>` | `src/services/TaggedImages.ts:20-49`. **No paging, no MIME filter** (client-side), not limited to source folders. Sorted client-side favorites first. |
| All assignable tags (tag picker) | `PROPFIND /remote.php/dav/systemtags` with `Depth: 1`, props `oc:id`, `oc:display-name`, `oc:user-visible`, `oc:user-assignable`, `oc:can-assign`; keep visible and assignable ones | `src/services/PhotoTagService.ts:77-87` (master/NC35+ UI; the API is core) |
| Tags of a file | `PROPFIND /remote.php/dav/systemtags-relations/files/<fileId>` with `Depth: 1` | `:94-104` |
| Assign | `PUT /remote.php/dav/systemtags-relations/files/<fileId>/<tagId>` with `Content-Type: application/json` and body `{"id":…,"name":…,"userVisible":…,"userAssignable":…,"canAssign":…}`. 409 means already assigned. | `:113-134` |
| Unassign | `DELETE /remote.php/dav/systemtags-relations/files/<fileId>/<tagId>`. 404 means not assigned. | `:143-153` |
| Create tag | `POST /remote.php/dav/systemtags` with JSON `{"name":…,"userVisible":true,"userAssignable":true,"canAssign":true}`. Returns 201; the new id is in the `Content-Location: …/systemtags/<id>` header. 409 means the name is taken. | `:173-190` |

Photos also clears a local cache `photos:tag-counts` on tag assign/unassign events (`lib/Listener/TagListener.php`). The cache is not exposed through any API.

---

## 16. Misc endpoints

* `GET /index.php/apps/photos/service-worker.js` serves the web service worker. Irrelevant for native.
* The Dashboard widget `photos-onthisday` is a single SEARCH with `nbResults=1, onThisDay=true` (`lib/Dashboard/OnThisDay.php`, `DashboardOnThisDay.vue:52-57`). It links to `/apps/photos/thisday`.
* `occ` commands (`photos:albums:create`, `photos:albums:add`, `photos:update-1000-cities`) are admin-only and not an API.

---

## 17. Nextcloud-version dependence (target: server 33+)

| Server | Photos branch | Notable API differences vs master |
|---|---|---|
| **33** | stable33 → **6.0.x** | No `MetadataPropPatchPlugin`: **no taken-date or GPS editing**, and core rejects those keys. No `name` smart filter. No `gridDensity` config (PUT returns 400). Folder JSON uses the **old shape** (`fileid` int, `lastmod`, `etag` top-level, `permissions` as `CKGWDR` letters, no favorite or metadata). `nc:last-photo` = raw last-added id, even without a preview. No EXIF `OffsetTimeOriginal` handling. No web Map, Memories or burst UI, but those are client-side so the data is available anyway. Recognize **11.x**: API key **always** required. |
| 34 | stable34 → 7.0.x | As 33, plus `OffsetTimeOriginal`. Recognize 12: admin can disable the API key. |
| 35 | stable35 → 8.0.x | Has MetadataPropPatchPlugin, name filter, gridDensity, Map, Memories, burst and cover-with-preview. Still the **old folder JSON shape**. |
| 36 | master → 9.0.0-dev | Everything in this document. `info.xml` pins `min=max=36`. |

Other version notes:
* SEARCH on `nc:metadata-*` requires indexed metadata (NC28+). `photos-original_date_time` and `photos-place` are indexed; `photos-gps` is not.
* `nc:hidden`, `files-live-photo` sync, blurhash, and ZipFolderPlugin `accept=zip&files=` are all present in NC 33.
* The Photos DAV tree, album sharing, public albums and places are unchanged in path and format across 33–36, except for the cover logic.

---

## 18. Gaps that are hard for a native client (companion-API candidates)

1. **No delta sync or change feed.**
   * The timeline is offset-paged SEARCH (`firstresult`), which is unstable under inserts and deletes and has no cursor and no total count.
   * The cheapest change signal is the **recursive etag of each `photosSourceFolders` root** (`PROPFIND Depth:0`, `d:getetag` changes when anything below changes). It still needs a full re-scan to diff.
   * Albums, places, faces and tags collections expose **no etag or ctag**.
   * Candidate: a `sync-token`/`since=<ts>` feed of added, changed and removed media ids, with album membership changes.
2. **No total counts or month histogram.** The web builds month sections and the date scrubber from loaded pages only. Candidate: `GET …/timeline/buckets` returning per-month counts per view and filter.
3. **No server-side geo query.** GPS is non-indexed metadata and the Map only sees the newest 500 items. Candidate: bbox or cluster endpoint, and indexed lat/lon.
4. **Memories, trips, recap, on-this-day and bursts are client heuristics** over at most 500 items. Candidate: server-computed memories.
5. **Config, MIME list, feature flags, nomedia paths and the Recognize key are HTML-initial-state only.** There are no capabilities. Candidate: an OCS `GET /apps/photos/api/v1/config` and capabilities (`photos: {version, imageMimes, videoMimes, places, features[]}`).
6. **Faces require a 24 h encrypted key** minted only by the Photos HTML page; it cannot be minted on NC33. Candidate: an OCS endpoint to mint a key for app-password or Bearer sessions, or exempt non-browser auth.
7. **Album and place listings are expensive and unpaged.**
   * `nbItems`, `dateRange` and `last-photo` resolve every member file per album; smart filters re-run a search capped at 1000.
   * There is no per-album etag.
   * `dateRange` uses **mtime**, not the taken date.
8. **HEIC/PNG/AVIF get no EXIF, GPS, taken date or place**, and videos get no size or duration. Apple-originated libraries will be mostly undated (mtime) and absent from Places and the Map.
   * Mitigation on 36: an upload client sets `X-OC-Mtime` = capture time and PROPPATCHes date/GPS.
   * On 33 there is no way to set them. Candidate: client-supplied capture metadata on upload, or server-side HEIC EXIF extraction.
9. **No content hash or dedup** in Photos. Core offers `oc:checksums` only if the uploader sets `OC-Checksum`, and nothing to query by hash. Candidate: hash index for backup-style "already uploaded?" checks.
10. **Hidden live-photo MOVs and nomedia files still count toward SEARCH page sizes.** Pages can come back short even though more results exist. Rely on `< nresults` as the end-signal only if hidden items are counted.
11. **Places:**
    * home storage and images only;
    * a name-only key with collisions;
    * no coordinates or country;
    * ignore source folders.
12. **Tags REPORT has no paging or MIME filter.** Folder JSON recursively scans on every call.
13. **Shared-album photo previews** need the Photos preview route, because `/core/preview` cannot see them.
14. **There is no fileId→path lookup** besides SEARCH. This matters for live-photo pairs, faces `realpath`, and the cover ids in `last-photo` and `reference-fileid`. Look a file up with:
    `SEARCH` with `<d:where><d:eq><d:prop><oc:fileid/></d:prop><d:literal>123</d:literal></d:eq></d:where>`, scope `/files/<uid>`, depth infinity. `oc:fileid` is searchable (`FileSearchBackend.php:98`).
15. **Writes are one request per item**: favorites, album add/remove and face moves. The web throttles to 5 concurrent. Candidate: batch endpoints.

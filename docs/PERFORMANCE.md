# Performance: how it is measured, baselines

SPEC §10 sets the budgets on devices (iPhone 15, M1 iPad Air, M1 MacBook Air, 100 000 photos). Until someone runs
DEVICE-TEST-PLAN D8 on hardware, these are the numbers we have: the store on a synthetic 100 000-item library (unit
tests), and the app itself in the iPhone simulator and on the Mac against the local test server (504 photos). Simulator
numbers are **indicative only**: it runs on the Mac's CPU and GPU, has no 120 Hz display and no memory limit like a
phone's. A regression of a baseline matters more than its distance to the budget.

## How

| What | Where | Tool |
|---|---|---|
| Store queries, search, map clustering, sync bookkeeping at 100 000 items | `LargeLibraryPerformanceTests` (unit tests, `PERF` lines) | Swift Testing, wall clock |
| Launch, scrolling, viewer paging, memory (iPhone, iPad) | `UITests/PerformanceTests` via `scripts/measure-performance.sh ios <udid>` | `XCTApplicationLaunchMetric`, `XCTOSSignpostMetric.scrollDecelerationMetric` / `scrollDraggingMetric` (hitch time ratio, frame rate), `XCTMemoryMetric`, `XCTClockMetric` |
| Launch → first pictures (every platform) | `LaunchMetrics` (PhotosMedia): log lines "Launch: first picture / first screen after N ms", time since the **process start** (kernel) | `log show`, collected by the script |
| Tile and viewer time to show | `CacheMetrics` (SPEC §18.1.3): Settings › Server › Cache performance, written to `Library/Caches/cache-metrics.json` | collected by the script |
| Mac scrolling | `PHOTOS_DEBUG_GRID_SCROLL` (Debug builds): the grid scrolls itself frame by frame with the window's display link; `FramePacing` records late frames | `scripts/measure-performance.sh mac <app>` |
| Mac memory | `footprint -p <pid>` (physical footprint, what the system's memory limits count) | the script |

The Mac is measured without XCUITest: XCUITest on macOS takes over the real pointer and keyboard. The script launches
the build in the background (`open -g`), never activates it, and stops only the process it started.

"First screen" is the 24th tile with a real picture — about the first screen of an iPhone at the default zoom; a Mac or
iPad window shows more tiles, so there it comes a little before the window is complete. The cached launch is what
SPEC §10 budgets ("cold launch → cached timeline visible"): the app was signed in and the previews were cached by a
previous run; the process is new.

## Baselines

Round 10, 2026-11-26, Mac with 18 cores (Apple silicon), Xcode 27, iOS 27.2 simulator, local test server
(Nextcloud 36 dev, 504 photos). **The Mac was heavily overloaded during these runs** (load average 600–840 on 18 cores:
six agents building and testing at once, three PHP test servers): every number below is several times what an idle
machine gives, and launch numbers most of all. They are a record of this run, not a verdict; repeat them on an idle Mac
before using them as a baseline (the round-4 store numbers on an idle Mac are in STATUS.md, §10 line).

### Store, 100 000 items (unit tests, Debug build, unoptimised)

| Budget (SPEC §10) | Measured | |
|---|---|---|
| Local search/filter < 100 ms | text search 0.2–45 ms (place, caption, file names, folder, two letters); place/month/tag filters 2–60 ms; a text that matches every row 952 ms | ✅ except the degenerate query |
| (filter as grid rows) | photos only 611 ms, whole timeline as grid rows 582 ms, as lightweight rows 184 ms | ⚠️ Debug and load; 58 ms in a Release build on an idle Mac (round 4) |
| Map: clustering < 200 ms per region change | cells world/Europe/city 4–19 ms, cells for MapKit 19–40 ms, a cluster's first page 13–70 ms, overview 51 ms | ✅ |
| Initial index of 100 000 items, complete < 10 min | 69 s for the store side (1000-row pages 602–620 ms) | ✅ store side; the network side needs a real 100 000-photo server |
| Incremental sync, no changes, < 500 ms | key scan 61 ms, favourite ids 0.5 ms, recent uploads due 21 ms (store side; one request per root by design, §5.4.4) | ✅ store side |
| Memories | on this day 7 ms; on this day + trips + year in review 503 ms (background) | ✅ |

### iPhone 17 Pro Max simulator (`PerformanceTests`, 5 iterations, load average 600–840)

| Budget (SPEC §10) | Measured | |
|---|---|---|
| Cold launch → cached timeline visible < 1.0 s | `XCTApplicationLaunchMetric` (first responsive frame) 41–96 s, mean 62 s; `LaunchMetrics` launch → first picture median 36.8 s (12–96 s, n=17), → first screen 38.5 s; XCUITest launch → first tile 19–61 s | ⚠️ not judgeable: `sample` shows the main thread in dyld loading (3 s of the first 8 s) and then in the **first** Core Animation commit (SwiftUI's first layout, toolbar bridging) for over 10 s — the whole Mac was 40× oversubscribed. Repeat on an idle Mac; D8 on a device |
| Scroll: no hitches at 120 Hz (< 1 ms/s) | the simulator reports only the signpost durations: deceleration of two fast flicks 2.43 s (±0.6 %), dragging 0.15 s; no hitch ratio, no frame rate | ⬜ needs a device (D8); the test is ready and reports hitches there |
| Fast scrolling shows BlurHash, then the preview | "Tile" signpost intervals while scrolling 0.1–0.2 ms (pictures from the memory/disk cache); time to show of the first screen's tiles in a new process p50 925 ms, p95 1 010 ms (n=40) | ✅ while scrolling; the launch figure is the load |
| Tap → viewer shows the 1024 preview, cached < 150 ms | cache metrics over 7 pages: first picture p95 0.01 ms (the tile's picture), 1024 preview p50 0.02 ms (prefetched neighbour), p95 125 ms; paging deceleration 0.33 s | ✅ |
| Memory while scrolling < 300 MB | scrolling: peak 99 MB, 83 MB after; viewer paging: peak 109 MB, 98 MB after; after launch 75–85 MB, but the **peak during launch** 77–383 MB (mean 196 MB, ±59 %) | ✅ scrolling and viewer; ⚠️ the launch peak varies a lot — look at it with Allocations on a device (D8) |

### iPhone 17 Pro Max simulator, second run (3 iterations, load average 20–110)

The same tests an hour later, when most other agents had finished:

| Budget | Measured | |
|---|---|---|
| Cold launch < 1.0 s | first responsive frame 9.5–14.0 s (mean 11.4 s); `LaunchMetrics` first picture median 9.5 s (7.2–30 s, n=13); XCUITest launch → first tile 11.5–16.8 s | ⚠️ **still ten times the budget with little load** — the most important open performance question. In the simulator the app is a 90 MB Debug dylib and the earlier `sample` showed the main thread in dyld and then for seconds in the first SwiftUI commit (`MediaGridScreen.body`, toolbar bridging, protocol-conformance lookups). Next step: Instruments › App Launch with a **Release** build on a device (D8); if it is still slow there, profile the first commit of the Library |
| Viewer 1024 preview, cached < 150 ms | p50 0.02 ms, p95 50 ms (n=5) | ✅ |
| Memory < 300 MB | after launch 72–74 MB, launch peak 73–99 MB; scrolling peak 95 MB; viewer peak 107 MB | ✅ (the 383 MB launch peak of the first run did not come back) |
| Scroll | deceleration 2.43 s, dragging 0.15 s (as before; no hitch numbers in the simulator) | ⬜ device |
| Tiles of the first screen in a new process | p50 676 ms, p95 733 ms (n=40) | ⚠️ part of the launch question |

### Mac (Debug build, `measure-performance.sh mac`, load average 150–450)

| Budget (SPEC §10) | Measured | |
|---|---|---|
| Cold launch → cached timeline visible < 1.0 s | `LaunchMetrics` launch → first picture median 2.2 s (1.9–3.7 s, n=7); sign-in + first sync 16 s to the first picture. The 24-tile "first screen" mark is not reached at launch (the restored window shows fewer tiles), only while scrolling (7.0 s) | ⚠️ over budget under this load; repeat idle (and in Release) |
| Scroll: no hitches | 16 s of debug scrolling at 4 000 pt/s: 28 fps, every frame late (766 ms/s) — **but the window was covered** (`windowVisible: 0`): macOS throttles the display link of a covered window, and the script may not bring it to the front | ⬜ not measurable this way; D8 on a Mac with the window in front, or the same script on a Mac nobody is using |
| Tap → viewer shows the 1024 preview (cached) < 150 ms | 51 ms (n=1, `PHOTOS_DEBUG_VIEWER=7`) | ✅ |
| Memory | 196–222 MB after launch (5 runs), 316 MB after scrolling the whole library twice | — (the 300 MB budget is the iPhone's) |

### Launch, round 10 phase 2 (what the time is spent on, and what was changed)

`LaunchMetrics` now also logs the steps on the way ("Launch: app code / app model / main view / library data after N
ms"), so a slow launch shows where the time went. Evidence from `xcrun xctrace record --template 'Time Profiler'`
(simulator: `--device <udid> --launch`; Mac: `--all-processes` while the build is opened in the background), `sample`
of all threads during the gaps, and those steps:

1. **Before `main` (simulator only).** 1.8–2.2 s of a 2.5–3.5 s simulator launch, Debug *and* Release builds: the main
   thread is in `dyld4::prepareSim` loading about 1 600 images (`DYLD_PRINT_LIBRARIES`; 78 linked directly, from
   SwiftUI, MapKit, AVKit, Vision and GroupActivities down) without a cached launch closure. On the Mac the app's code
   runs 115–130 ms after the process starts. Not something the app's code does; a device has prebuilt loaders for the
   OS's frameworks — measure it there (D8) before thinking about linking fewer frameworks.
2. **The Library's data came after the first frame.** The grid asked the store only from its `.task`, which runs after
   the window's whole first update *and* layout (`NSHostingView.layout`, toolbar layout: the main actor is not free
   before). So the first frame had no photos, and a second full update with the grid followed: 0.6–1.7 s later on the
   Mac under load, 0.1–9 s in the simulator under load (the store read itself takes 5 ms for 504 photos). Fixed:
   `LibraryLaunchPrefetch` reads the Library's first items (and the memories strip) off the main thread as soon as the
   root view is built, keeps them behind a lock (the main actor is busy), and the Library takes them in `onAppear`, so
   the grid and its cells are part of the first commit ("library data" now 0–90 ms after "main view").
3. **The memories strip arrived in its own update**, and in about half of the simulator launches the tiles' pictures
   then waited a second behind the strip's first layout. Fixed with the same prefetch.
4. **The diagnostics log was copied at launch**: `Diagnostics.persistLog` reads `OSLogStore`, a synchronous call to the
   log daemon that held a thread of the concurrency pool for about a second while the first screen loaded. The first
   copy now happens after 60 s (then every 5 minutes, as before).
5. **What is left on the main thread** (simulator, Debug): the first SwiftUI update and layout of the window (tab bar,
   toolbar, `MediaGridScreen`'s long modifier chain, the grid's cells) 0.5–1 s, of it about a third in Swift runtime
   type and protocol-conformance lookups that happen once per type (much less in Release); the grid header is measured
   again on every update of the Library (`PhotoGridController.updateGridHeaderHeight`, ~7 % of that update, in a file
   being split in phase 2 — left for later); BlurHash decoding of the first tiles on the main thread (~2 %).

Before/after, same method, alternating the two builds (base = `feat/r10-combined`), launches of a signed-in test build
with cached previews against 8089, Mac with 18 cores:

| | Base | With the fixes | Load average |
|---|---|---|---|
| iPhone 17 Pro Max simulator, Debug, launch → first picture (n=6 each) | 3.22–3.55 s, median 3.42 s | 2.64–3.35 s, median 3.06 s (pre-`main` 1.9–2.2 s of it) | 6–8 |
| iPhone simulator, Release (n=6 each, grid prefetch only) | 2.62–3.55 s, median 3.17 s | 2.48–3.49 s, median 3.0 s (pre-`main` 1.8–2.0 s) | 6–8 |
| Mac, Debug (n=8 each; the first launch of a build not counted) | 0.89–1.12 s, median 0.97 s | 0.88–1.20 s, median 0.93 s — within the noise ("main view" and "library data" both at 0.38 s) | 7–15 |
| Mac, Debug, under load | "main view" → "library data" 1.2–1.7 s | 0 ms | 100–150 |
| `PerformanceTests` with the fixes (iPhone simulator, 5 iterations) | (round-10 run at load 20–110: first responsive frame 9.5–14.0 s) | first responsive frame 5.3 s (±9 %), XCUITest launch → first tile 8.3 s; memory after launch 72 MB, scrolling peak 95 MB; all passed | 8–11 |

The first numbers of this round (9.5 s in the simulator, 2.2 s on the Mac) were taken at load 20–450; at low load the
base was already 3.4 s / 0.97 s. With the fixes the simulator spends two thirds of its launch before `main`, and the
rest is the first commit of the window. On an idle Mac the Library is complete about 0.9 s after the process started.

**Device measurement (D8).** Release build from Xcode on an iPhone 15 (or newer) with the 100 000-photo test account:
Instruments › App Launch, five cold launches after a reboot and five warm ones; Console.app filtered to subsystem
`com.nextcloud.photos`, category `performance` gives the same "Launch: …" steps per launch. Record pre-`main` (dyld),
"main view", "library data" and "first picture"; the budget is < 1.0 s to the cached timeline. If pre-`main` is above
~300 ms there, try weak-linking the frameworks only rare screens use; if the first commit dominates, profile it with the
SwiftUI instrument.

### Round 12 (speed, SPEC §22.4): tile cache, targeted sync, HEIC previews

2026-11-27, the same Mac (18 cores), load average 20–130 (five agents). Before/after in the same build where a switch
exists, alternating the two.

**Tile cache, per tile** (`TileCacheTests.measureLookups`, `PHOTOS_TILE_PERF=1`, Debug build, 100 000 synthetic
photos in 250 month files of 525 MB, 5 000 random photos, every month file opened on first use):

| | per tile |
|---|---|
| Disk cache: open the 256 px file, read, decode at 231 px (what a cell waits for today) | 0.608 ms |
| Tile cache: index lookup in the mapped month file, decode the 128 px tile | 0.177 ms |

A test library photo's tile is 9 KB (JPEG 0.7, 171×128); decoding one alone (-O build) 0.14 ms; wrapping raw pixels
would be 0.001 ms but cost 87 KB a tile on disk (SPEC §22.4.1).

**Tile cache, launch** (Mac, Debug, 8089, signed in, previews and tiles of the first screen cached; alternating
`PHOTOS_DEBUG_NO_TILES=1`, n=8 each; LaunchMetrics, ms since the process started):

| | With tiles | `PHOTOS_DEBUG_NO_TILES=1` |
|---|---|---|
| "first picture" (the first cell with a picture) | median 1499 ms (1225–2373) | median 1574 ms (1156–2595) |
| "first screen" (24 cells with pictures) | **median 1552 ms** (1273–2424) | median 1958 ms (1596–3416) |
| first picture → first screen | **median 50 ms** (40–90) | median 463 ms (294–821) |
| "library data" (the grid has its items) | 483–634 ms | 459–607 ms |

With the tiles the whole first screen comes with the first picture (the cells take their tiles while they are
configured); without them each cell shows its BlurHash and waits for the pipeline's disk read and decode. The first
picture itself is not earlier: the grid configures its cells about 0.7 s after it has its items (the window's first
layout, round 10's open question), on both sides. Load average 25–320 during these runs (other agents).

**Tile cache, launch, iPhone 17 Pro Max simulator** (iOS 27.2, Debug, 8089, the same alternation with
`SIMCTL_CHILD_PHOTOS_DEBUG_NO_TILES=1`, `simctl launch`, n=6 with tiles, n=5 without; load average 100–160):

| | With tiles | Without |
|---|---|---|
| "library data" | median 2488 ms (1748–3011) | median 2620 ms (1696–3356) |
| "first picture" | **median 2671 ms** (1882–3248) | median 4067 ms (3221–4308) |
| "first screen" | **median 2712 ms** (1915–3311) | median 4069 ms (3225–4311) |

Here the cells are configured soon after the grid has its items (about 180 ms), and with the tiles they have their
pictures then; without them the first pictures waited 1.4 s more for the pipeline under this load. (The UI tour
`TileCacheTourTests` takes a screenshot of each launch once the first cell exists; at that moment both already showed
pictures, so the screenshots do not show the difference, the log does.)

**Targeted sync** (`TargetedSyncIntegrationTests.measureWalks`, 20 160 photos in 261 folders, user `r12-speed` on
8093, Nextcloud 36 stock):

| | time |
|---|---|
| Launch, nothing changed (root PROPFIND, favourites SEARCH) | 0.43 s |
| Launch after one delete elsewhere, **targeted walk** (4 folders listed, 83 files; delta, by-id check, favourites) | **1.29 s** |
| The same delete with a **full walk** ("Sync now", 11 SEARCH pages of 2000) | 6.27–6.45 s |
| Initial sync and its first full walk (these synthetic files have no capture time: fetched by id) | 84–89 s |

The full walk grows with the library (about 0.3 s per 1000 photos here, so about 30 s for 100 000); the targeted walk
with the change (one listing per changed folder: the path from the root down). With the fake server, 40 rounds of
random changes (adds, deletes, moves, edits, renamed and removed folders, files outside the timeline) on 120 photos in 7
folders: 184–191 listings in all, the index equal to the server's after every round (`TargetedSyncTests`).

**HEIC instead of PNG for 1024/4096 px previews** (`PreviewCompactionTests.measureServerPreviews`, 12 PNG screenshots
uploaded to 8093, their server previews at 1024 and 4096 px; HEIC quality 0.7):

| | PNG (server) | HEIC | |
|---|---|---|---|
| Size, 24 previews | 35.3 MB | 3.2 MB | 9 % |
| Size, 1024 px | 69 KB – 859 KB | 14 KB – 152 KB | |
| Size, 4096 px | 249 KB – 4.9 MB | 43 KB – 545 KB | |
| Decode at 1024 px, 1024 px file | 2.9–8.8 ms | 8.3–11.9 ms | +3–8 ms |
| Decode at 1024 px, 4096 px file | 16.5–51.4 ms | 26.9–52.5 ms | ±, faster for the largest |
| Decode, all 24 | 403 ms | 551 ms | |

## Re-running

```sh
xcodegen generate
scripts/measure-performance.sh ios <simulator udid> /tmp/perf-ios      # about 20 minutes on an idle Mac
xcodebuild -scheme NextcloudPhotos -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= PHOTOS_BUNDLE_ID=com.example.photos.perf -derivedDataPath /tmp/dd-perf build
scripts/measure-performance.sh mac "/tmp/dd-perf/Build/Products/Debug/Nextcloud Photos.app" /tmp/perf-mac
```

Xcode's own performance baselines (`xcbaselines`) live in the generated project, which is not committed; compare with
the tables here instead, and update them in the same change when a number moves for a known reason.

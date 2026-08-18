# Jellyfin MySweetPea Nordic Theme

Premium dark-nordic theme for Jellyfin 10.11, matching the Moonfin `mysweetpea_nordic`
theme and the portfolio site branding (bg `#0C1316`, surface `#1B2B31`, gold `#D9A86C`,
teal `#5EB8A8`, text `#F2F6F4`).

## Files

| File | Purpose |
|---|---|
| `elegantfin-v26.06.06.min.css` | Vendored ElegantFin v26.06.06 (pinned commit `c8ef5af7`) — the modern UI base |
| `mysweetpea-nordic.css` | Brand overlay: palette variables, Fraunces display font, gold/teal accents, premium card hovers, styled login/dialogs/scrollbar |
| `combined-theme.css` | ElegantFin + nordic overlay concatenated (what actually gets served) |
| `branding.json` | The exact payload POSTed to `/System/Configuration/Branding` (CustomCss + LoginDisclaimer + SplashscreenEnabled) |
| `mysweetpea-logo-dark.svg/.png` | Dark-nordic logo variant (gold/teal flower on transparent) |
| `mysweetpea-splashscreen.png` | 1920×1080 branded splashscreen (dark gradient + logo) |
| `make-splash.py` | Regenerates the splashscreen (PIL) |
| `render-logo.html` | Helper to rasterize the SVG via headless Edge |

## How it's applied (Jellyfin 10.11+)

Jellyfin 10.11 moved branding to `POST /System/Configuration/Branding`
(the old `/Branding/Configuration` POST returns 405). The `CustomCss` field is
served at `/Branding/Css.css` and injected into every page.

```bash
# From the master node, with the Jellyfin API key:
curl -X POST http://localhost:8096/System/Configuration/Branding \
  -H "Content-Type: application/json" \
  -H "X-Emby-Token: <API_KEY>" \
  --data-binary @branding.json
```

Splashscreen upload expects a **base64-encoded** body (raw binary → HTTP 500):

```bash
base64 mysweetpea-splashscreen.png > /tmp/splash.b64
curl -X POST http://localhost:8096/Branding/Splashscreen \
  -H "Content-Type: image/png" -H "X-Emby-Token: <API_KEY>" \
  --data-binary @/tmp/splash.b64
```

## Re-applying after a fresh install / config reset

1. `kubectl exec -n private deploy/jellyfin -- sh -c 'cat > /tmp/branding.json' < branding.json`
2. POST it as above (204 = success)
3. Upload splashscreen (base64)
4. Hard-refresh browser (Ctrl+F5) — the web UI caches aggressively

## Efficiency tuning (Aug 18 2026)

Gelato on-demand streaming causes latency when Jellyfin "grabs" remote content. Applied:

- **Gelato.xml**: `FFmpegAnalyzeDuration` 5M→**1M**, `FFmpegProbeSize` 40M→**8M** (probe remote debrid streams faster)
- **Disabled scheduled tasks** (0 triggers) that hammer 14,630 virtual items:
  Detect and Analyze Media Segments, Download missing subtitles, Extract Chapter Images,
  Extract Subtitles, Generate Trickplay Images, Media Segment Scan
- **Library auto-refresh off**: `AutomaticRefreshIntervalDays=0` in
  `/config/root/default/{Movies,TV Shows}/options.xml` (was 1 = daily re-fetch of all Gelato metadata)
- Gelato README also suggests lowering AIOStreams addon timeouts to ~5s — AIOStreams config is **encrypted in its SQLite DB, web-UI only** (container is exec-less): set per-addon timeouts to 3s for chronically-slow addons (Knaben RD, MediaFusion P2P, AnimeTosho RD, Zilean RD, SubSource), 5s for Comet + Cinemeta at http://192.168.20.222:3000/stremio/configure
- **AIOStreams stream/pipeline cache enabled via env** (values.yaml): `STREAM_CACHE_TTL=86400` + `PIPELINE_CACHE_TTL=86400` — the web UI does NOT expose these fields (schema has them, UI doesn't render them), but env vars override DB config (source-verified in settings-store.ts: env > database > default). Verified: stream fetch 3.3s miss → 0.017s hit. Matches Gelato StreamTTL=86400.
- **Import Catalogs scheduled daily 6am** (DailyTrigger 216000000000 ticks) — keeps Popular/TopRated/NewReleases fresh
- AIOStreams manifest exposes only 3 catalogs (Popular/TopRated/NewReleases + Search); no anime/upcoming/genre catalogs
  (Gelato provider only supports search/skip extras — no genre filtering). Anime streams DO resolve if items are in
  the library (AIOStreams supports mal/kitsu/anilist IDs). User's AIOStreams config imported via web UI at
  http://192.168.20.222:3000/stremio/configure (Real-Debrid on).

## Performance tuning (Aug 18 2026)

Applied for "faster than Netflix" feel:

- **Transcodes in RAM**: `persistence.transcodes` = emptyDir Memory 2Gi → `/transcodes` tmpfs (was Longhorn network storage). Playback starts near-instant.
- **CPU guarantees**: requests 2 cores / 1Gi, limits 6 cores / 4Gi (was unset — other pods could starve Jellyfin).
- **encoding.xml**: `EncoderPreset=veryfast` (faster transcode start), `EnableThrottling=true` + `ThrottleDelaySeconds=30` (frees CPU when paused), `EnableSubtitleExtraction=false` (no remote fetches on Gelato virtual items), `EnableSegmentDeletion=true`, `TranscodingTempPath=/transcodes`.
- **network.xml**: `EnableResponseCompression` is a 10.8-era option — **inert in 10.11** (Brotli+Gzip are unconditionally on via `AddResponseCompression()` in Startup.cs; the file is kept only for `EnableHttp2`).
- **Media Bar**: MaxItems 50→10, MaxMovies/MaxTvShows 15→5, PreloadCount 1→0, ShuffleInterval 12s→30s, LoadingCheckInterval 100ms→500ms, EnableTrailers=false (poster/backdrop only).
- **Gelato.xml**: FFmpegAnalyzeDuration 5M→1M, FFmpegProbeSize 40M→8M.
- **Scheduled tasks disabled** (6 heavy ones: media segments, subtitles, chapter images, trickplay, etc.) + library auto-refresh off. ⚠️ Do NOT disable "Optimize database" (runs every 6h: wal_checkpoint + PRAGMA optimize + VACUUM) — verify its IntervalTrigger survives any task-disabling session.
- **Import Catalogs daily 6am** keeps Recently Added fresh.
- **CacheSize 20000** in `system.xml` (default = cores×100 = 800 entries) — the in-memory item LRU now holds the whole library (15k+ items) instead of constant eviction + DB re-reads on every home row render.
- **SQLite page cache 32 MiB** via `database.xml` → `CustomProviderOptions.Options` → `cacheSize=-32768` (KiB) — DB reads served from page cache instead of Longhorn network storage; `pooling=True` (same as default, explicit). Backups: `system.xml.bak-perf`, `database.xml.bak-perf`.
- **ParallelImageEncodingLimit 4** (default 0 = unlimited = 8 concurrent encodes on 8 cores) — leaves CPU headroom for API/UI work during row scrolls.
- ⚠️ Row-latency gotcha: after a Jellyfin restart, one-time Gelato startup tasks (SyncSeriesTrees, SyncReleaseDates, CDN refresh) peg CPU for 1–2 min — home rows take 2–6s until they settle, then drop to ~0.25s. Not a regression.

## Notes

- **ElegantFin updates**: re-vendor from
  `https://raw.githubusercontent.com/lscambo13/ElegantFin/<commit>/Theme/ElegantFin-jellyfin-theme-build-latest-minified.css`
  (pin a commit, not `main`), re-concatenate with `mysweetpea-nordic.css`, re-POST.
- ⚠️ **Moonfin theme registry can be wiped** (plugin update/config reset) while the theme JSON survives on disk at
  `/config/plugins/configurations/Moonfin/themes/mysweetpea_nordic.json` — if `GET /Moonfin/Admin/Themes` returns
  `{"items":[]}` but `visualTheme=custom` + `customThemeId=mysweetpea_nordic` are set, re-upload the JSON via
  `POST /Moonfin/Admin/Themes` (Content-Type: application/json, body = the file). Verified: re-upload persists to
  `Moonfin.Server.xml` `UploadedThemes` and serves at `/Moonfin/Themes/mysweetpea_nordic` (200).
- ⚠️ **Moonfin "Since You Watched" rows need played items**: the rows query `Filters=IsPlayed` (DatePlayed desc,
  limit 30) as base items, then match genres/tags/people against the library. Partial plays (PlayedPercentage)
  do NOT count — mark items played via `POST /Users/{id}/PlayedItems/{itemId}` to seed the rows. LocalRecs
  virtual libraries are symlinks-to-URLs (jackettio playback links) that Jellyfin CANNOT index as media — do not
  create them as Jellyfin libraries (empty forever).
- **Spoiler Guard** (Jellyfin-Enhanced) blurs unwatched posters — that's intended.
- The `sweetpea` user and all future LDAP users get Movies + TV Shows libraries
  automatically via the LDAP-Auth plugin `EnabledFolders` setting.

## Gelato (on-demand streaming) — operational notes

- **Catalogs**: `Gelato.xml` has the **4 importable catalogs** (Popular +
  Featured, movie + series) `Enabled=true` with `MaxItems=250` each, and
  `EnableJavaScriptInjection=true` (stream buttons in web UI). ⚠️ **Catalog
  constraint**: Gelato's `CatalogService` rebuilds the catalog list from the
  AIOStreams manifest on **every import**, keeping only `IsImportable()`
  catalogs (no required extras). The `year`/`last-videos`/`calendar-videos`
  catalogs have required extras and get **wiped on every import** — don't add
  them. MaxItems **does** persist through rebuilds (verified).
- **Stream TTL**: `StreamTTL=86400` (24h) — stream syncs happen once/day/item
  instead of on every view (was 3600 = 1h, caused 7–14s syncs while browsing).
- **Import Catalogs** scheduled daily 6am (`345218a7c524815276c66422a3923758`)
  paginates with `skip` and dedupes by meta.Id → continuous library growth.
  With MaxItems=250 the library holds ~400 movies / 175 series / 15k episodes.
- **Manifest URL self-healing**: `gelato/gelato-url-watcher.sh` runs on the
  master via cron every 5 min. If the manifest URL in `Gelato.xml` stops
  returning a valid manifest (e.g. after an AIOStreams re-import that created a
  NEW config UUID), it alerts Gotify; if `/root/gelato-url.txt` contains a
  working URL it auto-updates `Gelato.xml` + restarts Jellyfin. **Workflow**:
  always use AIOStreams "Save & Install → Update user" (same UUID, same URL) —
  "Create Configuration" makes a new UUID and breaks Gelato until the URL is
  updated.
- **TMDb Box Sets scan is DISABLED** (triggers emptied): it wipes manual links to
  Gelato virtual items (`gelato://stub/...`) because it counts only real files
  ("only 1 movie" per collection → unlink). Box sets were linked manually via
  `POST /Collections/{boxsetId}/Items?ids=...` (9 box sets, 10 Spider-Man movies).
- **Seerr search results disabled** in Jellyfin-Enhanced (`JellyseerrShowSearchResults=false`)
  — Gelato makes requests unnecessary; Seerr rows on the home screen are
  request-only by design (they're not library items).
- **CollectionSections rows render empty** for Gelato items: the plugin's
  `GetChildren` reads the AncestorIds index, which library scans don't rebuild for
  virtual items. Rows are registered and will populate when items are real files.
- **Streaming works**: Gelato resolves debrid streams on demand (5-27 per item),
  Jellyfin probes + transcodes via FFmpeg. Verified live: Project Runway S01E01
  played end-to-end.

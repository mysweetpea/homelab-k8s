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
- Gelato README also suggests lowering AIOStreams addon timeouts to ~5s (not yet done — container is exec-less)
- **Import Catalogs scheduled daily 6am** (DailyTrigger 216000000000 ticks) — keeps Popular/TopRated/NewReleases fresh
- AIOStreams manifest exposes only 3 catalogs (Popular/TopRated/NewReleases + Search); no anime/upcoming/genre catalogs
  (Gelato provider only supports search/skip extras — no genre filtering). Anime streams DO resolve if items are in
  the library (AIOStreams supports mal/kitsu/anilist IDs). User's AIOStreams config imported via web UI at
  http://192.168.20.222:3000/stremio/configure (Real-Debrid on).

## Notes

- **ElegantFin updates**: re-vendor from
  `https://raw.githubusercontent.com/lscambo13/ElegantFin/<commit>/Theme/ElegantFin-jellyfin-theme-build-latest-minified.css`
  (pin a commit, not `main`), re-concatenate with `mysweetpea-nordic.css`, re-POST.
- **Spoiler Guard** (Jellyfin-Enhanced) blurs unwatched posters — that's intended.
- The `sweetpea` user and all future LDAP users get Movies + TV Shows libraries
  automatically via the LDAP-Auth plugin `EnabledFolders` setting.

## Gelato (on-demand streaming) — operational notes

- **Catalogs**: `Gelato.xml` must have the 3 catalogs (Popular / Top Rated / New
  Releases) `Enabled=true` with `MaxItems=100`, and `EnableJavaScriptInjection=true`
  (stream buttons in web UI). A config reset silently disables them — re-enable
  and re-run the "Import Catalogs" scheduled task (`345218a7c524815276c66422a3923758`).
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

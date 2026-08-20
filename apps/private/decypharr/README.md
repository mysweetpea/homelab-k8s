# Decypharr — Debrid → STRM gateway

Decypharr v2.5 turns Real-Debrid into a **zero-storage library source** for the
Arr stack: Radarr/Sonarr see it as a qBittorrent client, it adds magnets to RD,
and writes tiny `.strm` files (URL pointers) that the arrs import into the
library. Jellyfin scans the `.strm` files as real items — real metadata, real
home rows, fast media bar — while bytes stream from RD on demand.

## Architecture

```
Seerr → Radarr/Sonarr → Decypharr (fake qBittorrent, port 8282)
  → magnet → Real-Debrid (instant cache)
  → .strm file → /data/decypharr-downloads/<category>/<release>/
  → arr imports .strm into /data/media/{movies,tv}
  → Jellyfin scans real files (NFO + poster.jpg from arr metadata consumer)
  → playback: Jellyfin → .strm URL → Decypharr WebDAV → RD CDN (Range requests)
```

- **No FUSE, no privileged pods** — `mount.type: none` (WebDAV only)
- **No RD IP-pinning** — Decypharr proxies all RD traffic server-side; strm
  URLs never expose RD CDN links
- **No URL rot** — links are fetched on demand and cached (24h expiry)
- **strm URLs** point at `http://decypharr.private.svc.cluster.local:8282/webdav/stream/__all__/<folder>/<file>`

## Key config (configmap.yaml + sealed secret)

| Setting | Value | Why |
|---|---|---|
| `default_download_action` | `strm` | Write URL pointers, not files |
| `mount.type` | `none` | WebDAV only — no FUSE |
| `app_url` | `http://decypharr.private.svc.cluster.local:8282` | Cluster DNS for strm URLs |
| `enable_webdav_auth` | `false` | strm URLs carry no token; internal network only |
| `workers` | `25` | Cap below the 50 default (issue #282 OOM) |
| `download_uncached` | `false` | Only grab instant-cache releases |
| `repair.enabled` | `false` | Community reports auto-repair deletes files |
| `queue_cleanup` | failed→blacklist_research etc. | Auto-resolve stuck queue items |

**Sealed secret keys** (`sealed-secrets/private/decypharr-secrets.yaml`):
`DECYPHARR_DEBRIDS__0__API_KEY`, `DECYPHARR_ARRS__0__TOKEN`,
`DECYPHARR_ARRS__1__TOKEN`, plus (phase 2 usenet, populated when the user
subscribes): `DECYPHARR_USENET__0__USERNAME`, `DECYPHARR_USENET__0__PASSWORD`
(primary provider), `DECYPHARR_USENET__1__USERNAME`,
`DECYPHARR_USENET__1__PASSWORD` (backup block provider).

⚠️ **Env override gotcha (source-verified)**: Decypharr's env overrides need the
`DECYPHARR_` prefix AND a `NAME` trigger (`DECYPHARR_DEBRIDS__0__NAME` must be
set or the API_KEY override is skipped). Worse, `setDefaults()` runs **before**
`applyEnvOverrides()` and pre-computes `DownloadAPIKeys` from the (then-empty)
`APIKey` — so env-only keys leave the account manager with `[""]` → account
disabled → "No active accounts available". **Fix**: the init container injects
the key into `/app/config.json` via sed (file-based, survives the ordering).
The usenet creds follow the same pattern (`DECYPHARR_USENET__0__*` placeholders
in configmap.yaml → sed → `/app/config.json`).

## Usenet (phase 2 — RD expiry Sep 17 2026)

Decypharr v2.5 has **direct NNTP streaming** built in — no SABnzbd container.
Arrs submit NZBs to the SABnzbd-compatible API at `/sabnzbd/api` on port 8282;
Decypharr parses the NZB, streams segments from the NNTP provider on demand
(STRM mode — zero storage).

Provider config is **staged in configmap.yaml** with placeholder tokens
(`__EWEKA_USER__` etc.) — the init container injects the real creds from the
sealed secret. Until the secret is populated, the providers are inert (empty
username/password, no crash).

**Recommended provider layout** (user buys):
- **Primary**: Eweka (Omicron backbone, EU, 12+ yr retention, DMCA-resistant)
- **Backup block**: UsenetExpress or NewsGroupDirect (different backbone,
  block account as fallback) — Decypharr skips same-backbone providers after
  423/430 responses when `backbone` matches.
- Decypharr usenet tuning: `read_ahead: 16MB` prefetch for smooth playback,
  `conn_idle_timeout: 5m` warm NNTP pool, `availability_sample_percent: 10`
  import gate, `disk_buffer_path: /cache/usenet` (emptyDir, 4Gi).

**SABnzbd API auth**: query params `ma_username` = `http://<arr>:<port>`
(the arr's own URL), `ma_password` = arr API key, `category` = `Sonarr`/`Radarr`
(case-sensitive — matches the arr names in `arrs` config). Verified live
(200 + valid SABnzbd queue JSON).

**Download client config in arrs** (already added, id 3 in both):
Sabnzbd, host `decypharr.private.svc.cluster.local`, port 8282, URL base
`/sabnzbd`, username `http://sonarr:8989`/`http://radarr:7878`, password =
arr API key, category `Sonarr`/`Radarr`, priority 2 (below the RD client at 1 —
usenet takes over when RD expires). Both test 200.

## Arr wiring

- **Radarr/Sonarr → Settings → Download Clients**: qBittorrent, host
  `decypharr.private.svc.cluster.local`, port 8282, username
  `http://<arr>:<port>` (the arr's own URL), password = arr API key, category
  `radarr`/`sonarr`, Remove Completed = Yes.
- Old qBittorrent client **disabled** (firewalled, no longer used).
- **Metadata**: Kodi/Emby metadata consumer enabled in both arrs → writes
  `movie.nfo`/`episode.nfo` + `poster.jpg`/`fanart.jpg` next to every imported
  .strm. Jellyfin reads them locally (no per-item scraping).

## Known issues

- **RD 451 "infringing_file"** (issue #379): RD blocks some releases (e.g. YTS
  copies of Dune Part Two). Decypharr flattens this to a generic 400 → arr
  re-grabs a different release. Not a bug in our config; pick a different
  release or accept the re-grab loop.
- **RAR-packed RD torrents** (issue #365): virtual members start with RAR
  header → black screen. Avoid RAR releases.
- **ffprobe noise on .strm import**: expected; current arr builds skip probing
  streaming extensions (Sonarr PR #8730, Radarr #11544).

## Ops

- UI: `http://192.168.20.215:8282` (admin / password in auth.json — bcrypt
  hash in configmap; API token auto-generated on first run, stored in
  `/app/auth.json`)
- Config edits: the UI writes `/app/config.json` (emptyDir — survives restarts
  but NOT pod recreation; the init container re-seeds from the ConfigMap on
  every start, so **edit the ConfigMap + redeploy** for durable changes)
- Restart: `kubectl rollout restart deploy/decypharr -n private`
- Logs: `kubectl logs -n private deploy/decypharr -f`

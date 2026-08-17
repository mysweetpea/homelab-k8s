# Media Stack — The Full Pipeline

The media stack is the busiest part of the cluster: a fully automated
**request → download → organize → watch** pipeline.

## The pipeline

```
Seerr (request) ──► Radarr/Sonarr (manage) ──► qBittorrent (download)
                                                        │
Jellyfin (watch) ◄── media-storage (200Gi) ◄────────────┘
        ▲
        └── Bazarr (subtitles) · Prowlarr (indexers) · AIOStreams (streaming)
```

1. **Seerr** — users browse and request movies/TV (it's the Netflix-style
   discovery front door).
2. **Radarr / Sonarr** — library managers: they watch for requests, find the
   best release via indexers, and hand it to the download client.
3. **Prowlarr** — manages the indexers (torrent + usenet) that Radarr/Sonarr
   query.
4. **qBittorrent** — the download client. Downloads land in
   `/data/downloads` on the shared media volume.
5. **Radarr/Sonarr** — import the finished download into the library
   (`/data/media/movies` and `/data/media/tv`), rename it, and organize it.
6. **Jellyfin** — serves the library to users (with Moonfin UI + 34 plugins:
   intro skipping, recommendations, trailers, watch stats, and more).
7. **Bazarr** — fetches subtitles for the library automatically.
8. **AIOStreams** — a Stremio-style aggregator that streams from debrid
   services directly (no download needed) for on-demand browsing.

## Storage

All media lives on a **shared 200Gi Longhorn volume** (`media-storage/`),
mounted at `/data` in qBittorrent, Radarr, Sonarr, and Jellyfin. One volume
means:

- Downloads and library are on the same filesystem — imports are instant
  renames, not copies.
- Every service sees the same files (no per-service PVCs to reconcile).

## Key configuration details

- **qBittorrent save path**: `/data/downloads` (temp: `/data/downloads/temp`)
  — set via API and persisted in `qBittorrent.conf`.
- **Radarr root folder**: `/data/media/movies`
- **Sonarr root folder**: `/data/media/tv`
- **Jellyfin libraries**: Movies + TV Shows pointed at `/data/media/*`
- **Download client tests**: Radarr→qBittorrent and Sonarr→qBittorrent both
  verified working (categories `radarr` / `tv-sonarr`).

## The Seerr connection

Seerr talks to Radarr/Sonarr over the cluster network (see the
`allow-seerr-*` NetworkPolicies). Its settings live in a persistent volume
with a patch script that normalizes the arr base URLs — a fix for a
double-slash bug that broke the download tracker (documented in the Seerr
app config).

## Why this design?

- **Automation** — the whole loop runs unattended: request tonight, watch
  tomorrow.
- **Quality** — Radarr/Sonarr enforce release profiles (HD-1080p etc.) so
  the library stays consistent.
- **Single source of truth** — one shared volume, one pipeline, no drift
  between services.

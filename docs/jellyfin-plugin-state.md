# Jellyfin plugin state (Aug 20 2026) — Decypharr/STRM architecture

## Installed this session
- **SeerrFin 1.6.6.0** (repo: https://raw.githubusercontent.com/varunaditya-plus/SeerrFin/main/manifest.json)
  - Seerr URL: http://seerr.dmz.svc.cluster.local:5055 (external: https://request.mysweetpea.cc)
  - Radarr: http://radarr.private.svc.cluster.local:7878 (key f09e78…)
  - Sonarr: http://sonarr.private.svc.cluster.local:8989 (key aee91c…)
  - AddSeerrResultsInSearch=true (in-Jellyfin search + request)
  - Prereq: File Transformation 2.5.11.0 (already installed)
- **JellySTRMprobe 1.2.0.0** (repo: https://firestaerter3.github.io/jellyfin-plugin-repo/manifest.json)
  - Scheduled task "Probe STRM Media Info" (daily 4am, 5 parallel probes)
  - Catch-Up mode on: auto-probes new strm items 30s after library scan

## Toggled this session
- Jellyfin Enhanced 12.2.0.0: JellyseerrShowSearchResults=true (was false)
  → Seerr results now appear in Jellyfin search, request button on every card.

## Note
- Seerr has NO TMDB key setting — the key is hardcoded in its bundle
  (431a8708161bcd1f1fbe7536137e61ed in /app/dist/api/themoviedb/index.js,
  same design as upstream Overseerr). Do NOT try to set one via API
  (PUT=405, POST=400 'apiKey is read-only').
- TMDB v3 key 2dfbe5c2efb2436c489e834f8b55d7a5 added to SeerrFin
  (TmdbApiKey) + Jellyfin Enhanced (TMDB_API_KEY) Aug 20 2026.

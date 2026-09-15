# strm-repair-bridge — design + operations

## The problem it closes

Dead `.strm` entries 404 at playback **forever** in this stack. Root cause chain:

1. Decypharr's native repair worker (`repair` config) can *detect* broken
   entries for our zero-storage strm setup (`source: managed` probes every
   managed entry's provider link — 3,461 candidates).
2. Its built-in repair cannot reach the Arrs for strm libraries:
   `collectArrFiles()` resolves Arr file paths via `readSymlinkTarget()`
   (v2.5, `pkg/manager/repair_sweep.go`) and strm files aren't symlinks →
   broken files never get Arr file IDs → **no blocklist, no re-search**.
   `source: arr` therefore enumerates 0 candidates for our library.
   (Beta v2.5.1 adds a file-size fallback, but arr sees ~181-byte strm
   sizes vs Decypharr's real media sizes — still no match.)
3. JellySTRMprobe only deletes (and skips when a full probe wave fails, by
   design) — it cannot trigger a replacement grab.

## How the bridge works

Daily CronJob (`30 6 * * *`, after the 05:30 Decypharr sweep) —

1. Reads Decypharr `GET /api/repair/health` (broken entries + reasons).
2. **Scans strm contents** for the entry mapping: every strm's first line is
   `http://decypharr.../webdav/stream/__all__/<URL-ENCODED ENTRY>/<file>`, so
   entry→strm is exact (no name fuzziness). 4,729/4,730 joins verified.
3. Joins strm absolute path → Radarr `movieFile.path` / Sonarr
   `episodeFile.path` (both in-container `/data/media/...` absolute).
4. Executes the arr remediation:
   - `DELETE /api/v3/{movie,episode}file/{id}` — remove the dead pointer
   - `POST /api/v3/history/failed/{historyId}` — blocklist the grab
     (arrs have `autoRedownloadFailed=true` → auto re-search)
   - `POST /api/v3/command` `{MoviesSearch, movieIds}` /
     `{EpisodeSearch, episodeIds}` — explicit re-search
5. Writes a ledger at `/decy-state/strm-repair-ledger.json` (on the
   decypharr-state-lh PVC).

## Safety rails

| Rail | Behavior |
|---|---|
| Dry-run default | `--execute` required to act |
| Provider-down guard | If the freshest sweep has ≥20 probed and ≥90% broken, skip (mass failure = outage, not per-release death) |
| Action cap | `--limit` (25/run) bounds first burn-in |
| Settle cooldown | Entries not re-processed within `ARR_SETTLE_HOURS` (6h) |
| Re-fail-only | After acting, an entry is only re-acted when its `last_failed_at` is NEWER than our action (prevents blocklist churn on unrepairable titles) |

## ⚠️ Ownership prerequisite (2026-09-15 incident)

Sonarr's process runs as **uid 1000 (hotio)**, but 271 legacy strm files +
62 dirs were **root-owned** (created by Decypharr's init container in an
older era). Deletion failed with `UnauthorizedAccessException` → the whole
repair chain silently no-op'd (`DELETE ... -> False`). Fixed live with
`chown -R 1000:1000 /data/media/{tv,movies}`.

**If arr deletes start failing again, check ownership first:**
`find /data/media -name "*.strm" -printf "%u\n" | sort | uniq -c`
— anything not `hotio` breaks the chain. New strm files are created by
Decypharr (runs as 1000:1000, `PUID/PGID` env), so the fix is stable unless
an old-style writer returns.

## Verification evidence (2026-09-15)

- Path joins: **4,729/4,730 strms**.
- Adventure Time dead pack (252 files): deleted + 15 blocklist records +
  SeasonSearch → replacement `Adventure.Time.S01...RCVR[UTR]` imported →
  **S01E26 strm plays HTTP 206 in 1.4s**.

## Manual runs

```bash
kubectl create job -n private --from=cronjob/strm-repair-bridge strm-repair-bridge-manual
kubectl logs -n private job/strm-repair-bridge-manual
```

Dry-run outside the cluster (against LB IPs + a strm index file):
`--strm-index <{path: entry}.json> --dry-run`

#!/usr/bin/env python3
"""Universal strm generator: Real-Debrid torrent -> Decypharr webdav -> Jellyfin library.

The Adventure Time pipeline (Aug 20 2026) distilled into a reusable tool.
Runs INSIDE the sonarr pod (it has python3 + can write the shared media PVC):

  kubectl exec -n private deploy/sonarr -i -- python3 - --torrent-id <RD_ID> \
      --title "Show Name" --kind tv \
      < strm-generator.py

Requires RD_API_KEY in the pod env (or --rd-key). Output: one .strm per video
file at /data/media/{tv,movies}/<Title>/[Season N]/<basename>.strm, each
containing the FLATTENED Decypharr webdav URL:
  http://decypharr.private.svc.cluster.local:8282/webdav/stream/__all__/
      <FULL TORRENT NAME>/<basename>

PITFALLS THIS SCRIPT IS DESIGNED AROUND (verified Aug 20 2026):
  * Decypharr webdav is FLATTENED: only full-torrent-name + basename works.
    Per-season folder paths 404. (webdav/stream/__all__/<name>/<file>)
  * Sonarr's own strm import fails on pack folder-name mismatch and
    Decypharr queue_cleanup then DELETES the strms -> write them manually.
  * Real-Debrid 451s single-episode grabs (infringing_file); complete season
    packs pass. Grab PACKS, not episodes.
  * Jellyfin picks strm files up via EnableRealtimeMonitor (no manual scan).
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RD = "https://api.real-debrid.com/rest/1.0"
WEBDAV = "http://decypharr.private.svc.cluster.local:8282/webdav/stream/__all__"
VIDEO_EXT = (".mkv", ".mp4", ".avi", ".webm", ".m4v", ".ts", ".wmv")


def rd_get(path, token, timeout=60):
    req = urllib.request.Request(RD + path,
                                 headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--torrent-id", required=True,
                    help="Real-Debrid torrent id (from /torrents or the grab log)")
    ap.add_argument("--title", required=True,
                    help="Library folder name, e.g. 'Adventure Time'")
    ap.add_argument("--kind", choices=["tv", "movie"], default="tv")
    ap.add_argument("--rd-key", default=os.environ.get("RD_API_KEY", ""))
    ap.add_argument("--specials", action="store_true",
                    help="also write Season 0 specials (default: skip)")
    ap.add_argument("--probe", type=int, default=3,
                    help="how many URLs to spot-check (0 to disable)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not args.rd_key:
        sys.exit("FATAL: no RD API key (set RD_API_KEY env or pass --rd-key)")

    info = rd_get("/torrents/info/" + args.torrent_id, args.rd_key)
    tname = info.get("filename") or info.get("original_filename") or args.title
    print("torrent :", tname[:80])
    print("files   :", len(info.get("files", [])))

    root = "/data/media/" + ("tv" if args.kind == "tv" else "movies")
    show_dir = os.path.join(root, args.title)
    written = skipped = 0
    sample = []  # (basename, url) for spot checks

    for f in info.get("files", []):
        path = f.get("path", "")
        base = os.path.basename(path)
        if not base.lower().endswith(VIDEO_EXT):
            continue

        if args.kind == "tv":
            m = re.search(r"/(?:Season|Season\s+|S)?(\d{1,2})\s*[^/]*/", path)
            if not m:
                skipped += 1
                continue
            season = int(m.group(1))
            if season == 0 and not args.specials:
                skipped += 1
                continue
            dest_dir = os.path.join(show_dir, f"Season {season}")
        else:
            dest_dir = show_dir

        url = (WEBDAV + "/" + urllib.parse.quote(tname)
               + "/" + urllib.parse.quote(base))
        if args.dry_run:
            print("would:", os.path.join(dest_dir, base + ".strm"))
            written += 1
            continue
        os.makedirs(dest_dir, exist_ok=True)
        with open(os.path.join(dest_dir, base + ".strm"), "w") as fh:
            fh.write(url)
        written += 1
        if len(sample) < 3:
            sample.append((os.path.join(dest_dir, base + ".strm"), url))

    print("strm written:", written, "| skipped:", skipped)
    if args.dry_run:
        return

    # Spot-check: HEAD/Range request straight to Decypharr webdav
    for i, (spath, url) in enumerate(sample, 1):
        req = urllib.request.Request(url, headers={"Range": "bytes=0-99"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                print(f"  probe {i}: {spath.split('/')[-1][:40]} -> {r.status} OK")
        except urllib.error.HTTPError as e:
            print(f"  probe {i}: {spath.split('/')[-1][:40]} -> ERR {e.code}")
        except Exception as e:
            print(f"  probe {i}: {spath.split('/')[-1][:40]} -> {e}")
        if args.probe and i >= args.probe:
            break
        time.sleep(1)

    print("DONE. Jellyfin realtime monitor picks new .strm files up automatically;")
    print("if not within ~2 min: POST /Library/Refresh (or restart jellyfin).")


if __name__ == "__main__":
    main()

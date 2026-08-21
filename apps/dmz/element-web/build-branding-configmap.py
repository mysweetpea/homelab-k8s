#!/usr/bin/env python3
"""Generate element-web-branding ConfigMap from assets/.

Usage: python build-branding-configmap.py
Output: branding-configmap.yaml (committed; ArgoCD does NOT track this CM —
apply manually with kubectl apply, like the disclaimer/home CMs).

Contents:
- vector-icons/*.png — MySweetPea badge icons (mounted over /app/vector-icons/)
- manifest.json — branded PWA manifest (name, icons, theme_color)
"""
import base64
import json
import pathlib
import yaml

HERE = pathlib.Path(__file__).parent
OUT = HERE / "branding-configmap.yaml"
ASSETS = HERE / "assets"

SIZES = [24, 120, 144, 152, 180, 512]

binary_data = {}
for size in SIZES:
    p = ASSETS / f"icon-{size}.png"
    # Flat keys (ConfigMap keys cannot contain '/'); mounted via subPath
    binary_data[f"icon-{size}.png"] = base64.b64encode(p.read_bytes()).decode("ascii")

manifest = {
    "name": "MySweetPea Chat",
    "short_name": "MySweetPea",
    "display": "standalone",
    "theme_color": "#5EB8A8",
    "background_color": "#0C1316",
    "start_url": "index.html",
    "icons": [
        {"src": f"/vector-icons/{size}.png", "sizes": f"{size}x{size}", "type": "image/png"}
        for size in SIZES
    ],}

cm = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {
        "name": "element-web-branding",
        "namespace": "dmz",
        "labels": {
            "app.kubernetes.io/name": "element-web",
            "app.kubernetes.io/part-of": "homelab",
        },
    },
    "data": {
        "manifest.json": json.dumps(manifest, indent=2),
    },
    "binaryData": binary_data,
}

OUT.write_text(
    yaml.safe_dump(cm, sort_keys=False, default_flow_style=False, width=1000),
    encoding="utf-8",
)
print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")

#!/usr/bin/env python3
"""Generate vaultwarden-branding ConfigMap from branding/ source files.

Usage: python build-branding-configmap.py
Output: branding-configmap.yaml (committed; ArgoCD does NOT track this CM —
apply manually with kubectl apply, like the disclaimer CM).

The logo PNGs go in binaryData (ConfigMap data is strings only).
"""
import base64
import pathlib
import yaml

HERE = pathlib.Path(__file__).parent
OUT = HERE / "branding-configmap.yaml"

TEXT_FILES = {
    "user.vaultwarden.scss.hbs": HERE / "branding" / "user.vaultwarden.scss.hbs",
    "email_header.hbs": HERE / "branding" / "email_header.hbs",
    "email_footer.hbs": HERE / "branding" / "email_footer.hbs",
    "manifest.json": HERE / "branding" / "manifest.json",
}

BINARY_FILES = {
    "mysweetpea-logo.png": HERE / "assets" / "mysweetpea-logo.png",
    "mysweetpea-logo-email.png": HERE / "assets" / "mysweetpea-logo-email.png",
    # Branded favicons (sweetpea flower on dark circle, from portfolio icon-192)
    "favicon-16x16.png": HERE / "assets" / "favicon-16x16.png",
    "favicon-32x32.png": HERE / "assets" / "favicon-32x32.png",
    "apple-touch-icon.png": HERE / "assets" / "apple-touch-icon.png",
    # PWA icons (branded manifest.json references these)
    "android-chrome-192x192.png": HERE / "assets" / "android-chrome-192x192.png",
    "android-chrome-512x512.png": HERE / "assets" / "android-chrome-512x512.png",
}

data = {key: path.read_text(encoding="utf-8") for key, path in TEXT_FILES.items()}
binary_data = {
    key: base64.b64encode(path.read_bytes()).decode("ascii")
    for key, path in BINARY_FILES.items()
}

cm = {
    "apiVersion": "v1",
    "kind": "ConfigMap",
    "metadata": {
        "name": "vaultwarden-branding",
        "namespace": "dmz",
        "labels": {
            "app.kubernetes.io/name": "vaultwarden",
            "app.kubernetes.io/part-of": "homelab",
        },
    },
    "data": data,
    "binaryData": binary_data,
}

OUT.write_text(
    yaml.safe_dump(cm, sort_keys=False, default_flow_style=False, width=1000),
    encoding="utf-8",
)
print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")

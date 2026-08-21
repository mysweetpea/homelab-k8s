#!/usr/bin/env python3
"""Build the affine-branding ConfigMap (manual apply — ArgoCD does not track it).

Generates apps/dmz/affine/branding-configmap.yaml from assets/:
  - favicon-{36,48,72,96,144,192}.png  (badge logo, replaces stock AFFiNE icons)
  - manifest.json                       (MySweetPea Notes branding, teal theme)
  - disclaimer.html                     (login disclaimer snippet, spliced by init container)

Usage: python build-branding-configmap.py
Then:  kubectl apply -f branding-configmap.yaml (on master)
"""
import base64
import json
import os
import pathlib

HERE = pathlib.Path(__file__).parent
ASSETS = HERE / "assets"
OUT = HERE / "branding-configmap.yaml"

FAVICON_SIZES = [36, 48, 72, 96, 144, 192]

MANIFEST = {
    "name": "MySweetPea Notes",
    "short_name": "Notes",
    "description": "MySweetPea Notes — AFFiNE workspace: docs, whiteboards and databases.",
    "start_url": "/?source=pwa",
    "background_color": "#0C1316",
    "theme_color": "#5EB8A8",
    "display": "standalone",
    "scope": "/",
    "icons": [
        {"src": f"/favicon-{s}.png", "sizes": f"{s}x{s}", "type": "image/png"}
        for s in FAVICON_SIZES
    ],
}

DISCLAIMER = """<div id="mysweetpea-login-disclaimer" style="display:none;position:fixed;bottom:0;left:0;right:0;z-index:9999;background:rgba(16,16,16,0.94);color:rgba(255,255,255,0.85);text-align:center;padding:10px 18px;font-family:'Segoe UI','Helvetica Neue',sans-serif;font-size:13px;line-height:1.45;border-top:1px solid rgba(255,255,255,0.12);backdrop-filter:blur(4px);">Sign in with your MySweetPea account (Authentik SSO). Use the same username and password as Vaultwarden, AFFiNE, and the other services.</div><script>
(function () {
  function isLoginPage() {
    var p = location.pathname.toLowerCase();
    return p.indexOf('/sign-in') !== -1 || p.indexOf('/signin') !== -1 || p === '/';
  }
  function update() {
    var el = document.getElementById('mysweetpea-login-disclaimer');
    if (el) el.style.display = isLoginPage() ? 'block' : 'none';
  }
  update();
  setInterval(update, 1500);
})();
</script>
"""


def build() -> None:
    data: dict[str, str] = {}

    for size in FAVICON_SIZES:
        png = ASSETS / f"favicon-{size}.png"
        if not png.exists():
            raise SystemExit(f"missing {png}")
        data[f"favicon-{size}.png"] = base64.b64encode(png.read_bytes()).decode()

    data["manifest.json"] = base64.b64encode(
        json.dumps(MANIFEST, indent=2).encode()
    ).decode()
    data["disclaimer.html"] = base64.b64encode(DISCLAIMER.encode()).decode()

    doc = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": "affine-branding",
            "namespace": "dmz",
            "labels": {
                "app.kubernetes.io/name": "affine",
                "app.kubernetes.io/part-of": "homelab",
            },
        },
        "binaryData": data,
    }

    OUT.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
    total = sum(len(v) for v in data.values())
    print(f"wrote {OUT} ({total} bytes binaryData, {len(data)} keys)")


if __name__ == "__main__":
    build()

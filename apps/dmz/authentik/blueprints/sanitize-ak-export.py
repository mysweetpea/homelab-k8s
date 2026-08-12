#!/usr/bin/env python3
"""
sanitize-ak-export.py — sanitize the full `export_blueprint` output of Authentik 2026.5.6.

The export contains plaintext `client_secret` values (128 chars) for every OAuth2
provider. This script replaces each with `!Env AUTHENTIK_BP_<NAME>_CLIENT_SECRET`,
writes `<in>.sanitized.yaml`, and prints the env-var -> value mapping for the
authentik-blueprint-env Secret.

In the export, attrs are alphabetical, so `client_id` appears immediately before
`client_secret` in the same entry — map by client_id (public, safe to commit).

Usage:
    python3 sanitize-ak-export.py <export>.yaml
"""
import re
import sys
from pathlib import Path

# client_id -> short name (matches existing authentik-blueprint-env key convention)
CLIENT_ID_MAP = {
    "NyZpb2hoH5rdXMdc3hOiaHTQnMxv3AgnuhtoKgti": "VAULTWARDEN",
    "BBpDTNkeVT6UmagzF3OrDkPo9sIx6pj1tx5IcdlZ": "AFFINE",
    "XJuKW3wdSxsKeb2jK63bihOSu8MpMbE0ENMmFnwM": "MATRIX_SYNAPSE",
    "FmxfSIcs2A5dPUQxfeaYhFfbdwytpjFMS1YHtWGh": "NEXTCLOUD",
    "btMjOfSZ7uyBIz4SA5ZyLJdmzarWhMt6ZESFTGgT": "IMMICH",
    "jJ8Fgd0aq3qHuLG5MT0kRTXDYiSxTx4a4442rvPj": "KOALASYNC",
    "54tyLzMXZcuocUdTDWYR8YxU0T0fAguTVTF14kOp": "OPEN_WEBUI",
}


def sanitize(text: str) -> tuple[str, dict[str, str]]:
    out: list[str] = []
    env_map: dict[str, str] = {}
    last_client_id: str | None = None

    for line in text.splitlines():
        m = re.match(r"^(\s*)([a-z_]+):\s*(.*)$", line)
        if not m:
            out.append(line)
            continue
        indent, key, value = m.group(1), m.group(2), m.group(3).strip()

        # Entry boundaries reset per-entry state
        if key == "model" or (key == "attrs" and value == ""):
            last_client_id = None

        if key == "client_id" and value:
            last_client_id = value

        if key == "client_secret" and value and not value.startswith("!"):
            base = CLIENT_ID_MAP.get(last_client_id or "", "OBJECT")
            env_name = f"AUTHENTIK_BP_{base}_CLIENT_SECRET"
            env_name = re.sub(r"_+", "_", env_name).strip("_")
            env_map[env_name] = value
            out.append(f"{indent}client_secret: !Env {env_name}")
        else:
            out.append(line)

    return "\n".join(out), env_map


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    for arg in sys.argv[1:]:
        p = Path(arg)
        if not p.exists():
            print(f"SKIP: {p} does not exist")
            continue
        new_text, env_map = sanitize(p.read_text(encoding="utf-8"))
        out_path = p.with_name(p.stem + ".sanitized.yaml")
        out_path.write_text(new_text, encoding="utf-8")
        print(f"=== {p.name} -> {out_path.name} ===")
        if env_map:
            for env, val in env_map.items():
                print(f"  {env} = {val}")
        else:
            print("  (no client_secret values found)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
sanitize-blueprints.py
======================
Sanitize Authentik blueprints exported from the UI before committing to Git.

Authentik's UI "Export as Blueprint" (the `{ }` icon in the top-right of each
object's detail page) produces YAML with plaintext secrets embedded (client
secrets, outpost tokens, passwords, etc.). This script rewrites those values
to Authentik's `!Env` tag so the blueprint can be committed safely and the
real values injected at runtime from the cluster Secret.

Usage:
    python3 sanitize-blueprints.py <input.yaml> [<input2.yaml> ...]

Output:
    Writes sanitized files alongside the originals with a `.sanitized.yaml`
    suffix, and prints a mapping of secret field -> env var name so you can
    populate the corresponding Kubernetes Secret.

Env var naming convention:
    AUTHENTIK_BP_<OBJECT_ID>_<FIELD>
    e.g. AUTHENTIK_BP_VAULTWARDEN_CLIENT_SECRET

Secret fields detected (case-insensitive substring match on the YAML key):
    secret, token, password, api_key, private_key
"""

import re
import sys
from pathlib import Path

# Keys whose values are secrets and should be replaced with !Env tags.
SECRET_KEY_PATTERNS = [
    r"secret",
    r"token",
    r"password",
    r"api_key",
    r"private_key",
]

# Keys that are NOT secrets even though they match a pattern above.
NON_SECRET_KEYS = {
    "token_identifier",
    "client_id",
    "username",
    "user",
    "name",
    "slug",
    "group",
    "groups",
    "url",
    "redirect_uris",
    "signing_key",
}


def is_secret_key(key: str) -> bool:
    """Return True if the YAML key looks like a secret."""
    k = key.strip().lower()
    if k in NON_SECRET_KEYS:
        return False
    return any(re.search(p, k) for p in SECRET_KEY_PATTERNS)


def sanitize_yaml(text: str) -> tuple[str, dict]:
    """Rewrite secret values to !Env tags. Returns (new_text, env_map)."""
    lines = text.splitlines()
    out = []
    env_map = {}  # field -> env var name
    current_id = None  # the blueprint entry's `id` field
    in_attrs = False  # whether we're inside an `attrs:` block

    for line in lines:
        m = re.match(r"^(\s*)([^:#]+?):\s*(.*)$", line)
        if not m:
            out.append(line)
            continue

        indent, key, value = m.group(1), m.group(2).strip(), m.group(3).strip()

        # Track the entry `id` for a clean env var prefix
        if key == "id" and value and not value.startswith("!"):
            current_id = re.sub(r"[^a-zA-Z0-9]", "_", value).upper()
        if key == "attrs":
            in_attrs = True
            out.append(line)
            continue
        if key == "entries":
            in_attrs = False
            out.append(line)
            continue

        # Skip non-scalar values (nested maps/lists) - nothing to sanitize
        if value == "" or value.startswith(("|", ">", "-", "&", "*")):
            out.append(line)
            continue

        if in_attrs and is_secret_key(key):
            prefix = current_id or "OBJECT"
            env_name = f"AUTHENTIK_BP_{prefix}_{re.sub(r'[^a-zA-Z0-9]', '_', key).upper()}"
            env_name = re.sub(r"_+", "_", env_name).strip("_")
            env_map[key] = env_name
            out.append(f"{m.group(1)}{key}: !Env {env_name}")
        else:
            out.append(line)

    return "\n".join(out), env_map


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    for arg in sys.argv[1:]:
        path = Path(arg)
        if not path.exists():
            print(f"SKIP: {path} does not exist")
            continue

        text = path.read_text()
        new_text, env_map = sanitize_yaml(text)

        out_path = path.with_suffix(path.suffix + ".sanitized.yaml")
        out_path.write_text(new_text)

        print(f"\n=== {path.name} -> {out_path.name} ===")
        if env_map:
            for field, env in env_map.items():
                print(f"  {field:20s} -> {env}")
        else:
            print("  (no secrets detected)")


if __name__ == "__main__":
    main()

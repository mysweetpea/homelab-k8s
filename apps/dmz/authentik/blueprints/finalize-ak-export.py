#!/usr/bin/env python3
"""Finalize ak-full-export.yaml: drop entries Authentik refuses to import.

Strips:
  - authentik_core.user with type == internal_service_account (outpost SA users;
    Authentik: "Can't modify internal service account users" — auto-recreated)
  - authentik_crypto.certificatekeypair with managed startswith goauthentik.io/outpost/
    (auto-generated outpost JWT certs; exports empty, fail validation, auto-recreated)
  - authentik_tasks_schedules.schedule (default system schedules; rel_obj_id refs
    fail validation; auto-created on fresh install)
  - ANY entry with attrs.path startswith migrations/ (one-off upgrade migration
    records; export with mismatched model + empty content; not user config)
  - ANY entry with attrs.managed startswith goauthentik.io/ (system-managed objects:
    default property mappings, default flows/stages, notification rules... they export
    incomplete and are auto-recreated by Authentik on fresh install). User-created
    objects (apps, providers, bindings, groups, roles, custom flows) have no managed.
Keeps: user-created configuration only.
"""
import sys
import yaml

SRC = "ak-full-export.yaml"
DST = "ak-full-export.yaml"


class EnvLoader(yaml.SafeLoader):
    pass


EnvLoader.add_constructor("!Env", lambda loader, node: "ENV_TAG")

with open(SRC, encoding="utf-8") as f:
    doc = yaml.load(f, Loader=EnvLoader)

entries = doc.get("entries", [])
kept, dropped = [], []
for e in entries:
    model = e.get("model", "")
    attrs = e.get("attrs", {}) or {}
    if model == "authentik_core.user" and attrs.get("type") == "internal_service_account":
        dropped.append((attrs.get("username"), attrs.get("name")))
        continue
    if model == "authentik_crypto.certificatekeypair" and str(attrs.get("managed", "")).startswith("goauthentik.io/outpost/"):
        dropped.append((attrs.get("managed"), attrs.get("name")))
        continue
    if model == "authentik_tasks_schedules.schedule":
        dropped.append((attrs.get("crontab"), attrs.get("paused")))
        continue
    if str(attrs.get("managed", "")).startswith("goauthentik.io/"):
        dropped.append((attrs.get("managed"), attrs.get("name")))
        continue
    if str(attrs.get("path", "")).startswith("migrations/"):
        dropped.append((attrs.get("path"), attrs.get("name")))
        continue
    kept.append(e)

doc["entries"] = kept
with open(DST, "w", encoding="utf-8") as f:
    yaml.dump(doc, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

print(f"kept {len(kept)} entries, dropped {len(dropped)} internal service accounts:")
for u, n in dropped:
    print(f"  - {u} ({n})")

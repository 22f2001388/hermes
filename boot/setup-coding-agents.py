#!/usr/bin/env python3
"""Seed Claude Code + opencode config for headless operation.

Env: CODING_HOME — home directory to seed into.
     OC_MODEL    — opencode model override (default: opencode/mimo-v2.5-free).
"""
import json, os, pathlib

home = pathlib.Path(os.environ["CODING_HOME"])

(home / ".claude").mkdir(parents=True, exist_ok=True)
sjson = home / ".claude" / "settings.json"
try:
    s = json.loads(sjson.read_text())
    if not isinstance(s, dict):
        s = {}
except Exception:
    s = {}
perms = s.setdefault("permissions", {})
if isinstance(perms, dict):
    perms.setdefault("defaultMode", "bypassPermissions")
env = s.setdefault("env", {})
if isinstance(env, dict):
    env.setdefault("DISABLE_AUTOUPDATER", "1")
sjson.write_text(json.dumps(s, indent=2))
gjson = home / ".claude.json"
try:
    g = json.loads(gjson.read_text())
    if not isinstance(g, dict):
        g = {}
except Exception:
    g = {}
g["hasCompletedOnboarding"] = True
gjson.write_text(json.dumps(g, indent=2))

ocdir = home / ".config" / "opencode"
ocdir.mkdir(parents=True, exist_ok=True)
ocjson = ocdir / "opencode.json"
try:
    cfg = json.loads(ocjson.read_text())
    if not isinstance(cfg, dict):
        cfg = {}
except Exception:
    cfg = {}
cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg.setdefault("autoupdate", False)
perm = cfg.setdefault("permission", {})
if isinstance(perm, dict):
    perm.setdefault("edit", "allow")
    perm.setdefault("bash", "allow")
    perm.setdefault("webfetch", "allow")
model = os.environ.get("OC_MODEL", "").strip()
if model:
    cfg.setdefault("model", model)
ocjson.write_text(json.dumps(cfg, indent=2))
print(f"coding-agent setup: claude + opencode config seeded (opencode model: {model or 'default'})")

#!/usr/bin/env python3
"""Read known_marketplaces.json and print URLs of missing marketplace clones.

Args: argv[1] = path to known_marketplaces.json
      argv[2] = path to marketplaces directory
"""
import json, os, sys

km, mdir = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(km))
except Exception:
    sys.exit(0)
entries = data.get("marketplaces", data) if isinstance(data, dict) else {}
if not isinstance(entries, dict):
    sys.exit(0)
for name, meta in entries.items():
    if not isinstance(meta, dict):
        continue
    src = meta.get("source") or meta.get("repo") or meta.get("url")
    if src and not os.path.isdir(os.path.join(mdir, name)):
        print(src)

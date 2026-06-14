#!/usr/bin/env python3
"""POST a restart notification to the configured webhook URL.

Env: WEBHOOK_URL        — URL to POST to.
     MODEL_FOR_CONFIG   — model name to include in the payload.
"""
import json
import os
import urllib.request

body = json.dumps({
    "event": "restart",
    "status": "success",
    "message": "Hermes WebUI has started.",
    "model": os.environ.get("MODEL_FOR_CONFIG", ""),
}).encode()
req = urllib.request.Request(os.environ["WEBHOOK_URL"], data=body, method="POST",
                             headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=10) as r:
    r.read()

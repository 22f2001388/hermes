#!/usr/bin/env python3
"""Clear a registered Telegram webhook so getUpdates can take over.

Env: TELEGRAM_API_BASE — e.g. "https://api.telegram.org/bot" or proxy base.
     TELEGRAM_BOT_TOKEN — bot token from @BotFather.
"""
import json
import os
import urllib.request

base = os.environ["TELEGRAM_API_BASE"]
token = os.environ["TELEGRAM_BOT_TOKEN"]
req = urllib.request.Request(f"{base}{token}/deleteWebhook", headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req, timeout=15) as resp:
    data = json.loads(resp.read())
assert data.get("ok"), data.get("description", "unknown error")

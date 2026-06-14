#!/usr/bin/env python3
"""Generate a hex webhook secret for Telegram webhook validation."""
import secrets
print(secrets.token_hex(32))

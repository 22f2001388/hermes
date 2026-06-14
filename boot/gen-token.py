#!/usr/bin/env python3
"""Generate a URL-safe random token for GATEWAY_TOKEN / API_SERVER_KEY."""
import secrets
print(secrets.token_urlsafe(32))

#!/usr/bin/env python3
"""Front datacenter-IP-blocked providers with ONE allowlisted CF Worker
and repoint stored credentials at it.

Some providers reject calls from datacenter/VPS IPs at their edge:
Gemini returns FAILED_PRECONDITION "User location is not supported";
NVIDIA returns nginx 403. CF Workers egress from trusted ranges, so a
pass-through worker bypasses the block.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API_BASE = "https://api.cloudflare.com/client/v4"
DEFAULT_WORKER_NAME = "hermes-gemini-proxy"
# Per-user state; /tmp fallback for standalone runs only (root-owned files block the service user).
ENV_FILE = Path(os.environ.get("GEMINI_PROXY_ENV_FILE") or "/tmp/hermes-gemini-proxy.env")
HTTP_TIMEOUT = 15
PROBE_MODEL = "gemini-flash-lite-latest"

GEMINI_HOST = "generativelanguage.googleapis.com"
NVIDIA_HOST = "integrate.api.nvidia.com"

# Providers commonly edge/geo-blocked on datacenter IPs. `kind` selects how a
# block is recognised: gemini returns a JSON location error; openai-compat
# providers are stopped at the edge with a non-JSON (nginx/HTML) response.
PROXIED = [
    {"slug": "gemini", "host": GEMINI_HOST, "direct": f"https://{GEMINI_HOST}/v1beta", "kind": "gemini"},
    {"slug": "nvidia", "host": NVIDIA_HOST, "direct": f"https://{NVIDIA_HOST}/v1", "kind": "openai"},
]
ALLOWED_HOSTS = [p["host"] for p in PROXIED]

WORKER_JS = """addEventListener("fetch", (e) => {
  const ALLOWED = [__ALLOWED__];
  const url = new URL(e.request.url);
  const parts = url.pathname.slice(1).split("/");
  const host = parts.shift();
  if (!ALLOWED.includes(host)) {
    e.respondWith(new Response("proxy: host not allowed", {status: 403}));
    return;
  }
  const rest = parts.length ? "/" + parts.join("/") : "";
  const target = "https://" + host + rest + url.search;
  const headers = new Headers(e.request.headers);
  for (const h of ["host", "cf-connecting-ip", "cf-ray", "cf-visitor", "x-real-ip", "x-forwarded-for"]) {
    headers.delete(h);
  }
  e.respondWith(fetch(target, {
    method: e.request.method,
    headers,
    body: e.request.body,
    redirect: "follow",
  }));
});""".replace("__ALLOWED__", ", ".join(json.dumps(h) for h in ALLOWED_HOSTS))


def cf_request(method: str, path: str, token: str, body: bytes | None = None,
               content_type: str = "application/json"):
    req = urllib.request.Request(
        API_BASE + path,
        data=body,
        method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": content_type},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    if not payload.get("success"):
        errors = payload.get("errors") or [{}]
        raise RuntimeError(errors[0].get("message", "Unknown Cloudflare API error"))
    return payload["result"]


def resolve_account_and_subdomain(api_token: str) -> tuple[str, str]:
    account_id = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "").strip()
    if not account_id:
        accounts = cf_request("GET", "/accounts", api_token)
        if not accounts:
            raise RuntimeError("No Cloudflare account is available for this token.")
        account_id = accounts[0]["id"]
    subdomain_info = cf_request("GET", f"/accounts/{account_id}/workers/subdomain", api_token)
    subdomain = (subdomain_info or {}).get("subdomain", "").strip()
    if not subdomain:
        raise RuntimeError("Cloudflare Workers subdomain is not configured. Enable workers.dev first.")
    return account_id, subdomain


def gemini_api_keys() -> list[str]:
    """Env fallback for gemini probing. GEMINI_API_KEYS is a JSON array or
    comma-separated (same formats keys-sync.py accepts)."""
    raw = os.environ.get("GEMINI_API_KEYS", "").strip()
    keys: list[str] = []
    if raw:
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, list):
                keys = [str(k).strip() for k in parsed if str(k).strip()]
        except ValueError:
            keys = [p.strip() for p in raw.split(",") if p.strip()]
    single = os.environ.get("GEMINI_API_KEY", "").strip()
    if single and single not in keys:
        keys.append(single)
    return keys


def keys_from_auth(slug: str, auth_path: Path | None) -> list[str]:
    """Probe keys from the stored credentials (uniform across providers).
    Runs after keys-sync each boot, so the pool is populated."""
    if not auth_path or not auth_path.is_file():
        return []
    try:
        data = json.loads(auth_path.read_text(encoding="utf-8"))
    except ValueError:
        return []
    out: list[str] = []
    for entry in data.get("credential_pool", {}).get(slug, []):
        if not isinstance(entry, dict):
            continue
        for field in ("access_token", "api_key", "apiKey", "key", "token", "value"):
            val = entry.get(field)
            if isinstance(val, str) and val.strip():
                out.append(val.strip())
                break
    return out


def probe_gemini(base_url: str, api_key: str) -> str:
    """'ok' | 'geo-blocked' | 'unreachable'. Any HTTP response that is not the
    location error counts as reachable — a bad key or model still proves the
    network path works, and a proxy would not help those."""
    body = json.dumps({"contents": [{"parts": [{"text": "ping"}]}],
                       "generationConfig": {"maxOutputTokens": 1}}).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/models/{PROBE_MODEL}:generateContent?key={api_key}",
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT):
            return "ok"
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        if "location is not supported" in detail.lower():
            return "geo-blocked"
        return "ok"
    except Exception:
        return "unreachable"


def probe_openai(base_url: str, api_key: str) -> str:
    """'ok' if the provider's app layer answers (JSON, any status), 'blocked'
    if an edge/WAF stops us with a non-JSON page (e.g. nginx 403 on a
    datacenter IP), 'unreachable' on a network error.
    ponytail: JSON-vs-HTML is the heuristic — an app-layer JSON error (bad key,
    rate-limit) is still 'reachable'; upgrade to a per-provider signal only if a
    provider ever edge-blocks WITH a JSON body."""
    req = urllib.request.Request(
        f"{base_url}/models",
        headers={"Authorization": f"Bearer {api_key}", "User-Agent": "Mozilla/5.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT):
            return "ok"
    except urllib.error.HTTPError as exc:
        body = exc.read(200).decode("utf-8", "replace").lstrip()
        return "ok" if body[:1] in ("{", "[") else "blocked"
    except Exception:
        return "unreachable"


def provider_status(kind: str, base_url: str, keys: list[str]) -> str:
    """'ok' | 'blocked' | 'unreachable'. The block is per-IP, so it trumps any
    single key's result; probe a few in case one key is simply bad."""
    sample = keys[:3]
    if kind == "gemini":
        statuses = {probe_gemini(base_url, k) for k in sample}
        if "geo-blocked" in statuses:
            return "blocked"
        return "ok" if "ok" in statuses else "unreachable"
    statuses = {probe_openai(base_url, k) for k in sample}
    if "ok" in statuses:
        return "ok"
    return "blocked" if "blocked" in statuses else "unreachable"


def worker_is_live(base_url: str) -> bool:
    """A live worker forwards to the upstream, which answers JSON even without a
    key; a missing workers.dev route answers a Cloudflare HTML error page."""
    req = urllib.request.Request(f"{base_url}/models",
                                 headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return resp.read(1).startswith(b"{")
    except urllib.error.HTTPError as exc:
        return exc.read(1).startswith(b"{")
    except Exception:
        return False


def deploy_worker(api_token: str, account_id: str, worker_name: str) -> None:
    cf_request(
        "PUT",
        f"/accounts/{account_id}/workers/scripts/{worker_name}",
        api_token,
        body=WORKER_JS.encode("utf-8"),
        content_type="application/javascript",
    )
    cf_request(
        "POST",
        f"/accounts/{account_id}/workers/scripts/{worker_name}/subdomain",
        api_token,
        body=json.dumps({"enabled": True, "previews_enabled": True}).encode("utf-8"),
    )


def write_env(base_url: str) -> None:
    ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
    ENV_FILE.write_text(f'export GEMINI_BASE_URL="{base_url}"\n', encoding="utf-8")
    ENV_FILE.chmod(0o600)


def repoint_credentials(slug: str, base_url: str, auth_path: Path | None) -> int:
    """Point every stored credential of `slug` at base_url. Runs after keys-sync
    each boot, so credentials (re-)added with the baked-in default get healed
    even when a restored backup lands stale entries. Atomic tmp+replace."""
    if not auth_path or not auth_path.is_file():
        return 0
    data = json.loads(auth_path.read_text(encoding="utf-8"))
    changed = 0
    for entry in data.get("credential_pool", {}).get(slug, []):
        if isinstance(entry, dict) and entry.get("base_url") != base_url:
            entry["base_url"] = base_url
            changed += 1
    if changed:
        tmp = auth_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
        tmp.chmod(0o600)
        tmp.replace(auth_path)
    return changed


def main() -> int:
    hermes_home = os.environ.get("HERMES_HOME", "").strip()
    auth_path = Path(hermes_home) / "auth.json" if hermes_home else None
    preset = os.environ.get("GEMINI_BASE_URL", "").strip().rstrip("/")
    api_token = os.environ.get("CLOUDFLARE_WORKERS_TOKEN", "").strip()
    force = os.environ.get("GEMINI_FORCE_PROXY", "").strip().lower() in ("1", "true", "yes")
    worker_name = os.environ.get("CLOUDFLARE_GEMINI_WORKER_NAME", "").strip() or DEFAULT_WORKER_NAME

    if not preset:
        # A previous boot's gemini decision must not leak into this one.
        ENV_FILE.unlink(missing_ok=True)

    cache: dict[str, str] = {}

    def ensure_worker() -> str | None:
        """Deploy (idempotent PUT) the allowlisted worker once, return its root
        URL. Always redeploys so the allowlist stays current across upgrades."""
        if "root" in cache:
            return cache["root"]
        if not api_token:
            return None
        account_id, subdomain = resolve_account_and_subdomain(api_token)
        root = f"https://{worker_name}.{subdomain}.workers.dev"
        deploy_worker(api_token, account_id, worker_name)
        canary = f"{root}/{GEMINI_HOST}/v1beta/models"
        for _ in range(12):
            if worker_is_live(canary):
                break
            time.sleep(5)
        else:
            print(f"Proxy worker not live yet after deploy: {root}", file=sys.stderr)
        print(f"Proxy worker deployed (allowlist: {', '.join(ALLOWED_HOSTS)}): {root}")
        cache["root"] = root
        return root

    for prov in PROXIED:
        slug, host, direct, kind = prov["slug"], prov["host"], prov["direct"], prov["kind"]
        suffix = direct.split(host, 1)[1]

        if slug == "gemini" and preset:
            desired = preset                                  # explicit override, no probe
        else:
            keys = keys_from_auth(slug, auth_path)
            if slug == "gemini" and not keys:
                keys = gemini_api_keys()
            force_this = force and slug == "gemini"            # GEMINI_FORCE_PROXY scopes to gemini
            if not (force_this or keys):
                continue                                       # nothing to probe or repoint
            status = "blocked" if force_this else provider_status(kind, direct, keys)
            if status == "unreachable":
                print(f"{slug}: API unreachable (not a block) — leaving credentials as-is", file=sys.stderr)
                continue
            if status == "ok":
                desired = direct                               # heal back to direct
            else:
                print(f"{slug}: edge/geo-blocked from this host — routing via Cloudflare proxy")
                root = ensure_worker()
                if not root:
                    print(f"{slug}: CLOUDFLARE_WORKERS_TOKEN missing — cannot deploy proxy", file=sys.stderr)
                    continue
                desired = f"{root}/{host}{suffix}"
                if keys and provider_status(kind, desired, keys[:1]) == "blocked":
                    print(f"WARNING: {slug} still blocked through the proxy", file=sys.stderr)

        if slug == "gemini":
            write_env(desired)
        changed = repoint_credentials(slug, desired, auth_path)
        if changed:
            verb = "repointed" if "workers.dev" in desired else "healed"
            print(f"{slug}: {verb} {changed} credential(s) -> {desired}")

    return 0


def self_test() -> int:
    import tempfile

    assert "__ALLOWED__" not in WORKER_JS
    for h in ALLOWED_HOSTS:
        assert json.dumps(h) in WORKER_JS
    assert "parts.shift()" in WORKER_JS
    for prov in PROXIED:
        suffix = prov["direct"].split(prov["host"], 1)[1]
        assert suffix.startswith("/") and prov["host"] not in suffix

    os.environ["GEMINI_API_KEYS"] = '["k1", "k2"]'
    os.environ["GEMINI_API_KEY"] = "k3"
    assert gemini_api_keys() == ["k1", "k2", "k3"]
    os.environ["GEMINI_API_KEYS"] = "k4, k5"
    assert gemini_api_keys() == ["k4", "k5", "k3"]
    os.environ["GEMINI_API_KEYS"] = ""
    assert gemini_api_keys() == ["k3"]

    for kind in ("gemini", "openai"):
        assert provider_status(kind, "https://x", []) == "unreachable"

    with tempfile.TemporaryDirectory() as td:
        auth = Path(td) / "auth.json"
        auth.write_text(json.dumps({
            "credential_pool": {
                "gemini": [{"base_url": f"https://{GEMINI_HOST}/v1beta", "access_token": "a"},
                           {"base_url": "https://proxy/x/v1beta", "access_token": "b"}],
                "nvidia": [{"base_url": f"https://{NVIDIA_HOST}/v1", "access_token": "n1"}],
                "openrouter": [{"base_url": "https://openrouter.ai/api/v1"}],
            },
            "other": True,
        }))
        assert keys_from_auth("gemini", auth) == ["a", "b"]
        assert keys_from_auth("nvidia", auth) == ["n1"]
        assert repoint_credentials("gemini", "https://proxy/x/v1beta", auth) == 1
        assert repoint_credentials("gemini", "https://proxy/x/v1beta", auth) == 0
        assert repoint_credentials("nvidia", "https://proxy/nv/v1", auth) == 1
        data = json.loads(auth.read_text())
        assert all(e["base_url"] == "https://proxy/x/v1beta" for e in data["credential_pool"]["gemini"])
        assert data["credential_pool"]["nvidia"][0]["base_url"] == "https://proxy/nv/v1"
        assert data["credential_pool"]["openrouter"][0]["base_url"] == "https://openrouter.ai/api/v1"
        assert data["other"] is True
        assert repoint_credentials("gemini", "x", Path(td) / "missing.json") == 0

    print("self-test OK")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        raise SystemExit(self_test())
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Proxy setup failed: {exc}", file=sys.stderr)
        raise SystemExit(1)

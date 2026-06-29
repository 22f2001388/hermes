#!/usr/bin/env python3
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

SINGULAR_PROVIDERS = {
    "OPENROUTER_API_KEY": "openrouter",
    "ANTHROPIC_API_KEY": "anthropic",
    "OPENAI_API_KEY": "openai",
    "DEEPSEEK_API_KEY": "deepseek",
    "KIMI_API_KEY": "moonshot",
    "KIMI_CN_API_KEY": "moonshot-cn",
    "MINIMAX_API_KEY": "minimax",
    "MINIMAX_CN_API_KEY": "minimax-cn",
    "XAI_API_KEY": "xai",
    "NVIDIA_API_KEY": "nvidia",
    "OLLAMA_API_KEY": "ollama-cloud",
    "KILOCODE_API_KEY": "kilocode",
    "GLM_API_KEY": "zai",
    "ARCEEAI_API_KEY": "arcee",
    "DASHSCOPE_API_KEY": "alibaba",
    "GMI_API_KEY": "gmi",
    "TOKENHUB_API_KEY": "tencent-tokenhub",
    "GROQ_API_KEY": "custom:groq",
    "GOOGLE_API_KEY": "google",
    "OPENCODE_API_KEY": "opencode",
    "CLAUDE_CODE_OAUTH_TOKEN": "claude-code",
    "HF_TOKEN": "huggingface",
    "AI_GATEWAY_API_KEY": "ai-gateway",
    "CUSTOM_API_KEY": "custom",
}

POOL_VARS = {
    "OPENROUTER_API_KEYS": "OPENROUTER_API_KEY",
    "ANTHROPIC_API_KEYS":  "ANTHROPIC_API_KEY",
    "OPENAI_API_KEYS":     "OPENAI_API_KEY",
    "DEEPSEEK_API_KEYS":   "DEEPSEEK_API_KEY",
    "KIMI_API_KEYS":       "KIMI_API_KEY",
    "MINIMAX_API_KEYS":    "MINIMAX_API_KEY",
    "NVIDIA_API_KEYS":     "NVIDIA_API_KEY",
    "OLLAMA_API_KEYS":     "OLLAMA_API_KEY",
    "XAI_API_KEYS":        "XAI_API_KEY",
    "KILOCODE_API_KEYS":   "KILOCODE_API_KEY",
    "GLM_API_KEYS":        "GLM_API_KEY",
    "ARCEEAI_API_KEYS":    "ARCEEAI_API_KEY",
    "DASHSCOPE_API_KEYS":  "DASHSCOPE_API_KEY",
    "GMI_API_KEYS":        "GMI_API_KEY",
    "TOKENHUB_API_KEYS":        "TOKENHUB_API_KEY",
    "GROQ_API_KEYS":            "GROQ_API_KEY",
    "GOOGLE_API_KEYS":          "GOOGLE_API_KEY",
    "OPENCODE_API_KEYS":        "OPENCODE_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKENS": "CLAUDE_CODE_OAUTH_TOKEN",
}

HERMES_HOME = Path(os.environ["HERMES_HOME"])
STATE_FILE = HERMES_HOME / ".hermes" / "keys-state.json"

# Providers without a native hermes_cli entry — `hermes auth add` needs a
# providers.<name> config.yaml entry to resolve a custom slug's base_url.
CUSTOM_PROVIDERS = {
    "groq": "https://api.groq.com/openai/v1",
}
for _name, _base_url in CUSTOM_PROVIDERS.items():
    if subprocess.run(
        ["hermes", "config", "set", f"providers.{_name}.api", _base_url],
        capture_output=True,
    ).returncode != 0:
        sys.stderr.write(
            f"WARN: `hermes config set providers.{_name}.api` failed; "
            f"`hermes auth add custom:{_name}` will fail until it succeeds\n"
        )

STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
try:
    keys_state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    if not isinstance(keys_state, dict):
        keys_state = {}
except Exception:
    keys_state = {}
keys_state.setdefault("schema", 1)
applied = keys_state.setdefault("applied", {})
first_run = not keys_state.get("first_run_done")


def parse_pool(raw):
    """Parse a pool var as a JSON array first (back-compat with Gemini), else
    comma-separated. Returns a list of non-empty trimmed keys."""
    raw = (raw or "").replace("\x00", "").replace("\x1f", "").strip()
    if not raw:
        return []
    try:
        v = json.loads(raw)
        if isinstance(v, list):
            return [str(k).strip() for k in v if str(k).strip()]
    except Exception:
        pass
    return [p.strip() for p in raw.split(",") if p.strip()]


def parse_gemini_keys():
    keys = parse_pool(os.environ.get("GEMINI_API_KEYS", ""))
    if keys:
        return keys
    single = os.environ.get("GEMINI_API_KEY", "").strip()
    return [single] if single else []


registry = {}
gemini_keys = parse_gemini_keys()
if gemini_keys:
    norm = "\n".join(sorted(gemini_keys))
    registry["gemini:pool"] = (
        "pool", "gemini", gemini_keys,
        hashlib.sha256(norm.encode("utf-8")).hexdigest(),
    )

pooled_singulars = set()
for pool_var, singular_var in POOL_VARS.items():
    slug = SINGULAR_PROVIDERS.get(singular_var)
    if not slug:
        continue
    keys = parse_pool(os.environ.get(pool_var, ""))
    if not keys:
        continue
    pooled_singulars.add(singular_var)
    norm = "\n".join(sorted(keys))
    registry[f"{slug}:pool"] = (
        "pool", slug, keys,
        hashlib.sha256(norm.encode("utf-8")).hexdigest(),
    )

for env_var, slug in SINGULAR_PROVIDERS.items():
    if env_var in pooled_singulars:
        continue
    val = os.environ.get(env_var, "").strip()
    if not val:
        continue
    registry[f"{slug}:{env_var}"] = (
        "single", slug, val,
        hashlib.sha256(val.encode("utf-8")).hexdigest(),
    )


def unset_provider(provider):
    """Clear a provider's credential pool via the CLI — schema-agnostic, no
    config.yaml parse. Remove index 1 repeatedly until the pool is empty
    (rc != 0). Hard-capped so a misbehaving CLI can't loop forever."""
    for _ in range(100):
        if subprocess.run(
            ["hermes", "auth", "remove", provider, "1"],
            capture_output=True,
        ).returncode != 0:
            break


def add_pool(provider, keys):
    """Add every pool key; return True only if all succeeded. A pool has no env
    auto-discovery fallback, so a partial failure must NOT record the hash —
    leave it unrecorded to retry next boot."""
    ok = True
    for key in keys:
        if subprocess.run(
            ["hermes", "auth", "add", provider, "--type", "api-key", "--api-key", key],
            capture_output=True,
        ).returncode != 0:
            ok = False
    if len(keys) > 1:
        subprocess.run(
            ["hermes", "config", "set", f"credential_pool_strategies.{provider}", "round_robin"],
            capture_output=True,
        )
    if not ok:
        sys.stderr.write(
            f"WARN: one or more `hermes auth add {provider}` failed; pool hash not recorded (retry next boot)\n"
        )
    return ok


def add_single(slug, value):
    """Add one credential. A NATIVE slug's failed add still works via env
    auto-discovery (the var is exported and hermes reads it at runtime), so it
    counts as success — record the hash. A `custom:<name>` slug has NO such
    runtime fallback, so a failed add must NOT record the hash: return the real
    result to retry next boot (same contract as add_pool)."""
    is_custom = slug.startswith("custom:")
    rc = subprocess.run(
        ["hermes", "auth", "add", slug, "--type", "api-key", "--api-key", value],
        capture_output=True,
    ).returncode
    if rc != 0:
        detail = "retry next boot" if is_custom else "relying on env auto-discovery"
        sys.stderr.write(f"WARN: `hermes auth add {slug}` failed (rc={rc}); {detail}\n")
    return rc == 0 or not is_custom


synced = 0
skipped = 0
for key_id, (kind, provider, payload, h) in registry.items():
    if not first_run and applied.get(key_id) == h:
        skipped += 1
        continue
    unset_provider(provider)
    ok = add_pool(provider, payload) if kind == "pool" else add_single(provider, payload)
    if ok:
        applied[key_id] = h
        synced += 1

for stale in [k for k in applied if k not in registry]:
    del applied[stale]
    sys.stderr.write(f"WARN: {stale} removed from env; dropped from state (pool left intact)\n")

keys_state["first_run_done"] = True
STATE_FILE.write_text(json.dumps(keys_state, indent=2), encoding="utf-8")
STATE_FILE.chmod(0o600)

print(f"Key sync: synced {synced} new, skipped {skipped}, first_run={str(first_run).lower()}")

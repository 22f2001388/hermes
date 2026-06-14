#!/bin/bash
set -euo pipefail

umask 0077

# ── Logging functions ──────────────────────────────────────────────────────
log() { echo "$*"; }
warn() { echo "WARN: $*" >&2; }
die() {
	echo "FATAL: $*" >&2
	exit 1
}

echo ""
echo " ╔══════════════════════════════════════════╗"
echo " ║                Hermes                    ║"
echo " ╚══════════════════════════════════════════╝"
echo ""

APP_DIR="${HERMES_APP_DIR:-/opt/hermes}"
WEBUI_REPO="${HERMES_WEBUI_REPO:-/opt/hermes-webui}"
HERMES_DATA_ROOT="${HERMES_HOME:-/opt/data}"

# Exported: hermes-sync.py scopes the backup root + bucket prefix per agent.
export AGENT_NAME="${AGENT_NAME:-primary}"
# Agent home = a normal user-home layout: state in ~/.hermes, work in ~/workspace.
AGENT_HOME="${HERMES_DATA_ROOT}/${AGENT_NAME}"
HERMES_HOME="${AGENT_HOME}/.hermes"
WORKSPACE_HOME="${AGENT_HOME}/workspace"
# Friendly home alias; symlinked to AGENT_HOME below (cwd = $WORKSPACE_LINK/workspace).
WORKSPACE_LINK="/home/${AGENT_NAME}"
STARTUP_FILE="$WORKSPACE_HOME/startup.sh"
# Back up the whole agent home (state + work). Exported for hermes-sync.py.
export HERMES_BACKUP_ROOT="$AGENT_HOME"

log "Agent: $AGENT_NAME"
log "State: $HERMES_HOME"

# ── Platform detection ────────────────────────────────────────────────────────
if [ -n "${SPACE_ID:-}" ]; then
	PLATFORM="hf"
elif [ -n "${RENDER:-}" ]; then
	PLATFORM="render"
else
	PLATFORM="local"
fi
log "Detected platform: $PLATFORM"

# Cloud blocks api.telegram.org; disable IP-fallback so the client honors base_url.
if [ "$PLATFORM" = "hf" ] || [ "$PLATFORM" = "render" ]; then
	export HERMES_TELEGRAM_DISABLE_FALLBACK_IPS=true
	log "Telegram IP-fallback disabled (base_url-only routing on $PLATFORM)"
fi

PUBLIC_PORT="${PORT:-7861}"
GATEWAY_API_PORT="${API_SERVER_PORT:-8642}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
TELEGRAM_WEBHOOK_PORT="${TELEGRAM_WEBHOOK_PORT:-8765}"
WEBUI_PORT="${HERMES_WEBUI_PORT:-8787}"

SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
# Back up .env into the bucket (plaintext secrets — accepted tradeoff). Exported for hermes-sync.py.
export SYNC_INCLUDE_ENV="${SYNC_INCLUDE_ENV:-1}"
# Shared bucket; each agent backs up under its AGENT_NAME prefix. Exported for hermes-sync.py.
export BACKUP_BUCKET_NAME="${BACKUP_BUCKET_NAME:-hermes-backup}"
BACKUP_BUCKET="$BACKUP_BUCKET_NAME"
BACKUP_DATASET="${BACKUP_DATASET_NAME:-hermes-backup}"
CF_PROXY_ENV_FILE="/tmp/hermes-cloudflare-proxy.env"

export HERMES_HOME
export API_SERVER_ENABLED="${API_SERVER_ENABLED:-true}"
export API_SERVER_HOST="${API_SERVER_HOST:-127.0.0.1}"
export API_SERVER_PORT="$GATEWAY_API_PORT"
export GATEWAY_HEALTH_URL="${GATEWAY_HEALTH_URL:-http://127.0.0.1:${GATEWAY_API_PORT}}"
export TELEGRAM_WEBHOOK_PORT
export HERMES_WEBUI_PORT="$WEBUI_PORT"

# ── Unified auth: GATEWAY_TOKEN drives everything ─────────────────────
if [ -z "${API_SERVER_KEY:-}" ]; then
	if [ -n "${GATEWAY_TOKEN:-}" ]; then
		export API_SERVER_KEY="$GATEWAY_TOKEN"
	else
		API_SERVER_KEY="$(
			python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
		)"
		export API_SERVER_KEY
		echo "GATEWAY_TOKEN not set - generated an ephemeral token for this boot."
	fi
fi

# Same token becomes Hermes WebUI's login password (unified auth).
if [ -n "${GATEWAY_TOKEN:-}" ]; then
	export HERMES_WEBUI_PASSWORD="${HERMES_WEBUI_PASSWORD:-$GATEWAY_TOKEN}"
fi

# ── Setup state dirs ──────────────────────────────────────────────────
# Created after the restore barrier — restore may seed an old-layout workspace to migrate first.
mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,home,plugins,webui}

# Idempotently seed gateway hooks from repo (overwrite to stay current).
if [ -d "$APP_DIR/hooks" ]; then
	cp -a "$APP_DIR/hooks/." "$HERMES_HOME/hooks/"
	echo "Gateway hooks seeded to $HERMES_HOME/hooks/."
fi

# Rotate logs >5MB to .1 at boot — tee -a appends forever and bloats the backup.
if [ -d "$HERMES_HOME/logs" ]; then
	for f in "$HERMES_HOME/logs"/*.log; do
		[ -f "$f" ] || continue
		sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
		if [ "$sz" -gt 5242880 ]; then
			mv -f "$f" "${f}.1"
			: >"$f"
			echo "rotated $(basename "$f") ($sz bytes -> .1)"
		fi
	done
fi

# Expose hermes CLI to login shells
mkdir -p "$HERMES_HOME/.local/bin"
ln -sfn /opt/hermes/.venv/bin/hermes "$HERMES_HOME/.local/bin/hermes"

# Re-home to /home/<agent> (symlink to AGENT_HOME) so ~/.hermes + dotfiles persist;
# only once the symlink exists, else keep the passwd home.
if mkdir -p "$(dirname "$WORKSPACE_LINK")" 2>/dev/null \
	&& { [ -L "$WORKSPACE_LINK" ] || [ ! -e "$WORKSPACE_LINK" ]; } \
	&& ln -sfn "$AGENT_HOME" "$WORKSPACE_LINK" 2>/dev/null; then
	export HOME="$WORKSPACE_LINK"
	log "Home: $HOME -> $AGENT_HOME"
	# Login shells read the passwd home, not this env — shim them there to
	# self-correct; resolve $AGENT_NAME at eval time so it's race-safe across agents.
	if [ "$HERMES_DATA_ROOT" != "$AGENT_HOME" ]; then
		printf '%s\n' \
			'# hermes: re-home login shells to the per-agent friendly home' \
			'[ -d "/home/${AGENT_NAME:-primary}" ] && export HOME="/home/${AGENT_NAME:-primary}"' \
			> "$HERMES_DATA_ROOT/.zshenv" 2>/dev/null || true
		printf '%s\n' \
			'# hermes: re-home login shells to the per-agent friendly home' \
			'if [ -d "/home/${AGENT_NAME:-primary}" ]; then' \
			'  export HOME="/home/${AGENT_NAME:-primary}"' \
			'  [ -f "$HOME/.profile" ] && . "$HOME/.profile"' \
			'fi' \
			> "$HERMES_DATA_ROOT/.profile" 2>/dev/null || true
	fi
else
	warn "could not re-home to $WORKSPACE_LINK; keeping HOME=$HOME"
fi

# Redirect plugin dir into the volume — skip when ~/.hermes already IS HERMES_HOME
# (re-homed), else the link would point to itself and the rm would wipe plugins.
if [ ! -L "${HOME}/.hermes/plugins" ] && ! [ "${HOME}/.hermes" -ef "$HERMES_HOME" ]; then
	mkdir -p "${HOME}/.hermes"
	rm -rf "${HOME}/.hermes/plugins"
	ln -sfn "$HERMES_HOME/plugins" "${HOME}/.hermes/plugins"
fi

# ── Restore state from HF Storage Bucket (async, gated) ───────────────
# Async so the Cloudflare setup below overlaps the download; a wait barrier
# (HERMES_RESTORE_PID, joined after Cloudflare) gates every reader of restored
# state. Non-fatal — degrades to fresh state.
HERMES_RESTORE_PID=""
if [ -n "${HF_TOKEN:-}" ]; then
	echo "Restoring Hermes state from HF bucket ${BACKUP_BUCKET}/${AGENT_NAME}"
	python3 "$APP_DIR/hermes-sync.py" restore &
	HERMES_RESTORE_PID=$!
else
	echo "HF_TOKEN not set - bucket persistence is disabled."
fi

# ── Cloudflare proxy (optional) ──
CLOUDFLARE_WORKERS_TOKEN="${CLOUDFLARE_WORKERS_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
export CLOUDFLARE_WORKERS_TOKEN
if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ] || [ -n "${CLOUDFLARE_PROXY_URL:-}" ]; then
	export CLOUDFLARE_PROXY_DEBUG="${CLOUDFLARE_PROXY_DEBUG:-false}"
	echo "Preparing Cloudflare Telegram proxy"
	python3 "$APP_DIR/cloudflare-proxy-setup.py" || true
	if [ -f "$CF_PROXY_ENV_FILE" ]; then
		. "$CF_PROXY_ENV_FILE"
	fi
fi

if [ -n "${CLOUDFLARE_WORKERS_TOKEN:-}" ]; then
	echo "Preparing Cloudflare Keepalive worker"
	python3 "$APP_DIR/cloudflare-keepalive-setup.py" || true
fi

# Join the async restore before anything reads $HERMES_HOME. Non-fatal.
if [ -n "$HERMES_RESTORE_PID" ]; then
	wait "$HERMES_RESTORE_PID" || true
	echo "HF restore complete."
fi

# Old-layout restore seeds .hermes/workspace — migrate up now (target-absent guard
# avoids clobber); create fresh only when nothing's pending so a failed mv retries.
if [ -d "$HERMES_HOME/workspace" ] && [ ! -e "$WORKSPACE_HOME" ]; then
	mv "$HERMES_HOME/workspace" "$WORKSPACE_HOME" \
		&& log "Migrated workspace -> $WORKSPACE_HOME" \
		|| log "WARN: workspace migration failed; data left at $HERMES_HOME/workspace"
fi
[ -d "$HERMES_HOME/workspace" ] || mkdir -p "$WORKSPACE_HOME"

# ── Memory-OS: seed consolidation skill + cron job (additive, idempotent) ──
# Tiered memory: working = state.db + capped MEMORY.md/USER.md; long-term =
# memories/longterm/* (durable). A cron agent distills sessions into durable memory.
# Post-restore so it never clobbers restored memory or user cron jobs.
if [ -d "$APP_DIR/skills" ]; then
	cp -a "$APP_DIR/skills/." "$HERMES_HOME/skills/"
	echo "Assistant skills seeded to $HERMES_HOME/skills/."
fi
mkdir -p "$HERMES_HOME/memories/longterm" "$HERMES_HOME/memories/.backups"
# One-time snapshot of pre-existing memory before the consolidator first runs.
if [ ! -f "$HERMES_HOME/memories/.backups/initial-seed.done" ]; then
	for mf in MEMORY.md USER.md; do
		[ -f "$HERMES_HOME/memories/$mf" ] && cp -a "$HERMES_HOME/memories/$mf" "$HERMES_HOME/memories/.backups/$mf.initial" || true
	done
	touch "$HERMES_HOME/memories/.backups/initial-seed.done"
fi
# Register the consolidation cron job once (additive; never clobber user jobs).
HERMES_BIN="/opt/hermes/.venv/bin/hermes"
if [ -x "$HERMES_BIN" ]; then
	# Capture separately: under `set -o pipefail` a non-zero `cron list`
	# (slow-starting daemon) would mask a match and re-create a duplicate job.
	cron_jobs="$("$HERMES_BIN" cron list --all 2>/dev/null || true)"
	if printf '%s\n' "$cron_jobs" | grep -q "memory-os-consolidation"; then
		echo "memory-os cron job already present."
	elif "$HERMES_BIN" cron create "every 360m" \
		"Run the memory-os consolidation pass now. Load and follow the memory-os skill end to end: back up memory, read new sessions from state.db since the watermark, distill durable facts, append them to the long-term archive, then refresh MEMORY.md and USER.md within their char caps. Additive and lossless; never delete existing memory; never store secrets or PII." \
		--name "memory-os-consolidation" \
		--deliver local \
		--skill memory-os >/dev/null 2>&1; then
		echo "memory-os cron job registered (every 360m)."
	else
		echo "memory-os cron registration skipped (non-fatal)."
	fi
fi

# ── Taste capture: seed preferences hook + skill + cron job (additive) ──
# Taste capture: a session:end hook queues correction signals; this cron distills
# them into a confidence-gated profile and a marked USER.md block. Files + cron
# init here (hook/skill seeded above). Cadence 730m offset from memory-os's 360m
# because both do lockless full-file writes to USER.md — coincident runs clobber.
for tf in TASTE-ledger.md TASTE-signals.md; do
	[ -f "$HERMES_HOME/memories/longterm/$tf" ] || : >"$HERMES_HOME/memories/longterm/$tf"
done
if [ -x "$HERMES_BIN" ]; then
	taste_jobs="$("$HERMES_BIN" cron list --all 2>/dev/null || true)"
	if printf '%s\n' "$taste_jobs" | grep -q "taste-capture"; then
		echo "taste-capture cron job already present."
	elif "$HERMES_BIN" cron create "every 730m" \
		"Run the taste-capture consolidation pass now. Load and follow the taste-capture skill end to end: read the queued correction signals (fall back to recent sessions if empty), distill durable confidence-gated preferences, append them with provenance to the long-term taste ledger, then refresh only the marked taste block in USER.md within its char cap. Additive and lossless; preserve all non-taste memory; never store secrets or PII; shape output, never erase personality." \
		--name "taste-capture" \
		--deliver local \
		--skill taste-capture >/dev/null 2>&1; then
		echo "taste-capture cron job registered (every 730m)."
	else
		echo "taste-capture cron registration skipped (non-fatal)."
	fi
fi

# ── Telegram env normalisation (aliases + webhook URL + secret) ───────
if [ -n "${TELEGRAM_USER_IDS:-}" ] && [ -z "${TELEGRAM_ALLOWED_USERS:-}" ]; then
	export TELEGRAM_ALLOWED_USERS="$TELEGRAM_USER_IDS"
elif [ -n "${TELEGRAM_USER_ID:-}" ] && [ -z "${TELEGRAM_ALLOWED_USERS:-}" ]; then
	export TELEGRAM_ALLOWED_USERS="$TELEGRAM_USER_ID"
fi

# ── Telegram home channel auto-seed ───────────────────────────────────
# Without TELEGRAM_HOME_CHANNEL the gateway nags "/sethome" each boot. Seed it
# once from the first allowed user (DM chat_id == user id) so cron/cross-platform
# delivery has a target; only when absent, so a later /sethome always wins.
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
	HERMES_ENV_FILE="$HERMES_HOME/.env"
	if [ -f "$HERMES_ENV_FILE" ] && grep -q '^TELEGRAM_HOME_CHANNEL=' "$HERMES_ENV_FILE"; then
		: # already set (prior /sethome, Env tab, or restored backup) — leave it
	else
		TG_HOME="${TELEGRAM_HOME_CHANNEL:-}"
		if [ -z "$TG_HOME" ] && [ -n "${TELEGRAM_ALLOWED_USERS:-}" ]; then
			TG_HOME="${TELEGRAM_ALLOWED_USERS%%,*}"
		fi
		TG_HOME="$(printf '%s' "$TG_HOME" | tr -d '[:space:]')"
		if [ -n "$TG_HOME" ]; then
			touch "$HERMES_ENV_FILE"
			chmod 600 "$HERMES_ENV_FILE"
			# Don't glue onto a no-trailing-newline last line (corrupts that entry).
			[ -s "$HERMES_ENV_FILE" ] && [ -n "$(tail -c1 "$HERMES_ENV_FILE")" ] && printf '\n' >>"$HERMES_ENV_FILE"
			printf 'TELEGRAM_HOME_CHANNEL=%s\n' "$TG_HOME" >>"$HERMES_ENV_FILE"
			export TELEGRAM_HOME_CHANNEL="$TG_HOME"
			echo "Telegram home channel seeded to $TG_HOME (run /sethome in another chat to change)."
		fi
	fi
fi

# Explicit polling wins over an inherited webhook URL (prior deploy / restored .env)
# — Hermes long-polls whenever TELEGRAM_WEBHOOK_URL is empty.
if [ "${TELEGRAM_MODE:-}" = "polling" ] && [ -n "${TELEGRAM_WEBHOOK_URL:-}" ]; then
	log "TELEGRAM_MODE=polling — ignoring TELEGRAM_WEBHOOK_URL"
	unset TELEGRAM_WEBHOOK_URL
fi

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${SPACE_HOST:-}" ] && [ -z "${TELEGRAM_WEBHOOK_URL:-}" ]; then
	if [ "${TELEGRAM_MODE:-webhook}" != "polling" ]; then
		export TELEGRAM_WEBHOOK_URL="https://${SPACE_HOST}/telegram"
	fi
fi

if [ -n "${TELEGRAM_WEBHOOK_URL:-}" ] && [ -z "${TELEGRAM_WEBHOOK_SECRET:-}" ]; then
	SECRET_FILE="$HERMES_HOME/.hermes-telegram-webhook-secret"
	if [ -f "$SECRET_FILE" ]; then
		TELEGRAM_WEBHOOK_SECRET="$(cat "$SECRET_FILE")"
	else
		TELEGRAM_WEBHOOK_SECRET="$(
			python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
		)"
		printf '%s' "$TELEGRAM_WEBHOOK_SECRET" >"$SECRET_FILE"
		chmod 600 "$SECRET_FILE"
	fi
	export TELEGRAM_WEBHOOK_SECRET
fi

# ── Provider-prefix mapping (Hermes convention) ───────────────────
MODEL_INPUT="${HERMES_MODEL:-${LLM_MODEL:-}}"
MODEL_FOR_CONFIG="$MODEL_INPUT"
PROVIDER_FOR_CONFIG="${HERMES_INFERENCE_PROVIDER:-auto}"
LLM_API_KEY="${LLM_API_KEY:-}"

if [ -n "$MODEL_INPUT" ]; then
	MODEL_PREFIX="${MODEL_INPUT%%/*}"
else
	MODEL_PREFIX=""
fi

case "$MODEL_PREFIX" in
openrouter)
	[ -n "$LLM_API_KEY" ] && export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$LLM_API_KEY}"
	[ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="openrouter"
	MODEL_FOR_CONFIG="${MODEL_INPUT#openrouter/}"
	;;
huggingface | hf)
	[ -n "$LLM_API_KEY" ] && export HF_TOKEN="${HF_TOKEN:-$LLM_API_KEY}"
	[ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="huggingface"
	MODEL_FOR_CONFIG="${MODEL_INPUT#huggingface/}"
	;;
vercel-ai-gateway | ai-gateway)
	[ -n "$LLM_API_KEY" ] && export AI_GATEWAY_API_KEY="${AI_GATEWAY_API_KEY:-$LLM_API_KEY}"
	[ "$PROVIDER_FOR_CONFIG" = "auto" ] && PROVIDER_FOR_CONFIG="ai-gateway"
	MODEL_FOR_CONFIG="${MODEL_INPUT#*/}"
	;;
anthropic)
	[ -n "$LLM_API_KEY" ] && export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$LLM_API_KEY}"
	;;
openai | openai-codex)
	[ -n "$LLM_API_KEY" ] && export OPENAI_API_KEY="${OPENAI_API_KEY:-$LLM_API_KEY}"
	;;
google | gemini)
	[ -n "$LLM_API_KEY" ] && export GOOGLE_API_KEY="${GOOGLE_API_KEY:-$LLM_API_KEY}" GEMINI_API_KEY="${GEMINI_API_KEY:-$LLM_API_KEY}"
	PROVIDER_FOR_CONFIG="gemini"
	MODEL_FOR_CONFIG="${MODEL_INPUT#*/}"
	;;
deepseek)
	[ -n "$LLM_API_KEY" ] && export DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-$LLM_API_KEY}"
	;;
kimi-coding | moonshot)
	[ -n "$LLM_API_KEY" ] && export KIMI_API_KEY="${KIMI_API_KEY:-$LLM_API_KEY}"
	;;
kimi-coding-cn | moonshot-cn | kimi-cn)
	[ -n "$LLM_API_KEY" ] && export KIMI_CN_API_KEY="${KIMI_CN_API_KEY:-$LLM_API_KEY}"
	;;
minimax)
	[ -n "$LLM_API_KEY" ] && export MINIMAX_API_KEY="${MINIMAX_API_KEY:-$LLM_API_KEY}"
	;;
minimax-cn)
	[ -n "$LLM_API_KEY" ] && export MINIMAX_CN_API_KEY="${MINIMAX_CN_API_KEY:-$LLM_API_KEY}"
	;;
xiaomi)
	[ -n "$LLM_API_KEY" ] && export XIAOMI_API_KEY="${XIAOMI_API_KEY:-$LLM_API_KEY}"
	;;
zai | z-ai | z.ai | glm)
	[ -n "$LLM_API_KEY" ] && export GLM_API_KEY="${GLM_API_KEY:-$LLM_API_KEY}"
	;;
arcee | arcee-ai | arceeai)
	[ -n "$LLM_API_KEY" ] && export ARCEEAI_API_KEY="${ARCEEAI_API_KEY:-$LLM_API_KEY}"
	;;
gmi | gmi-cloud | gmicloud)
	[ -n "$LLM_API_KEY" ] && export GMI_API_KEY="${GMI_API_KEY:-$LLM_API_KEY}"
	;;
alibaba | alibaba-coding-plan | alibaba_coding)
	[ -n "$LLM_API_KEY" ] && export DASHSCOPE_API_KEY="${DASHSCOPE_API_KEY:-$LLM_API_KEY}"
	;;
tencent-tokenhub | tencent | tokenhub | tencentmaas)
	[ -n "$LLM_API_KEY" ] && export TOKENHUB_API_KEY="${TOKENHUB_API_KEY:-$LLM_API_KEY}"
	;;
nvidia)
	[ -n "$LLM_API_KEY" ] && export NVIDIA_API_KEY="${NVIDIA_API_KEY:-$LLM_API_KEY}"
	;;
xai | grok)
	[ -n "$LLM_API_KEY" ] && export XAI_API_KEY="${XAI_API_KEY:-$LLM_API_KEY}"
	;;
kilocode)
	[ -n "$LLM_API_KEY" ] && export KILOCODE_API_KEY="${KILOCODE_API_KEY:-$LLM_API_KEY}"
	;;
opencode-zen)
	[ -n "$LLM_API_KEY" ] && export OPENCODE_ZEN_API_KEY="${OPENCODE_ZEN_API_KEY:-$LLM_API_KEY}"
	;;
opencode-go)
	[ -n "$LLM_API_KEY" ] && export OPENCODE_GO_API_KEY="${OPENCODE_GO_API_KEY:-$LLM_API_KEY}"
	;;
ollama-cloud | ollama)
	[ -n "$LLM_API_KEY" ] && export OLLAMA_API_KEY="${OLLAMA_API_KEY:-$LLM_API_KEY}"
	;;
esac

if [ -n "${CUSTOM_BASE_URL:-}" ]; then
	PROVIDER_FOR_CONFIG="${CUSTOM_PROVIDER:-custom}"
	[ -n "$LLM_API_KEY" ] && export OPENAI_API_KEY="${OPENAI_API_KEY:-$LLM_API_KEY}"
fi

export MODEL_FOR_CONFIG PROVIDER_FOR_CONFIG
export CUSTOM_BASE_URL="${CUSTOM_BASE_URL:-}"
export CUSTOM_API_KEY="${CUSTOM_API_KEY:-${LLM_API_KEY:-}}"
export CUSTOM_MODEL_CONTEXT_LENGTH="${CUSTOM_MODEL_CONTEXT_LENGTH:-131072}"
export CUSTOM_MODEL_MAX_TOKENS="${CUSTOM_MODEL_MAX_TOKENS:-8192}"
export TELEGRAM_BASE_URL="${TELEGRAM_BASE_URL:-}"
export TELEGRAM_BASE_FILE_URL="${TELEGRAM_BASE_FILE_URL:-}"

if [ -n "${CLOUDFLARE_PROXY_URL:-}" ] && [ -z "$TELEGRAM_BASE_URL" ]; then
	CLOUDFLARE_PROXY_URL="${CLOUDFLARE_PROXY_URL%/}"
	export TELEGRAM_BASE_URL="${CLOUDFLARE_PROXY_URL}/bot"
	export TELEGRAM_BASE_FILE_URL="${CLOUDFLARE_PROXY_URL}/file/bot"
fi

# ── Shell capture wrappers ─────────────────────────────────────────────────
# Written to ~/.bashrc so terminal installs are recorded in workspace/startup.sh
# and replayed on next boot — packages survive Space restarts.
if [ ! -f "$STARTUP_FILE" ]; then
	mkdir -p "$WORKSPACE_HOME"
	touch "$STARTUP_FILE"
	chmod +x "$STARTUP_FILE"
	echo "Created workspace/startup.sh"
fi
cat > "$HOME/.bashrc" << 'BASHRC'
export PATH="/opt/hermes/.venv/bin:/opt/data/.local/bin:$PATH"
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
if [ -z "${PS1:-}" ] || [ "$PS1" = "$ " ]; then
  export PS1="\u@\h:\w\$ "
fi
case $- in *i*)
  if [ -d "$HOME/workspace" ] && [ "$PWD" != "$HOME/workspace" ]; then
    _pp=$(pwd -P 2>/dev/null); _hp=$(cd "$HOME" 2>/dev/null && pwd -P)
    { [ "$_pp" = "$_hp" ] || [ "$_pp" = "$_hp/workspace" ]; } && cd "$HOME/workspace"
    unset _pp _hp
  fi ;;
esac

_hm_append() {
  [ "${HERMES_CAPTURE_DISABLE:-0}" = "1" ] && return 0
  local line="$*"
  mkdir -p "$(dirname "$STARTUP_FILE")"
  touch "$STARTUP_FILE"
  chmod +x "$STARTUP_FILE" 2>/dev/null || true
  grep -qxF "$line" "$STARTUP_FILE" 2>/dev/null || echo "$line" >> "$STARTUP_FILE"
}
_hm_quote_args() {
  local quoted=()
  local arg
  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    quoted+=("$arg")
  done
  printf '%s' "${quoted[*]}"
}
_hm_append_cmd() {
  local cmd="$1"
  shift
  local args
  args=$(_hm_quote_args "$@")
  if [ -n "$args" ]; then
    _hm_append "$cmd $args"
  else
    _hm_append "$cmd"
  fi
}
_hm_args_without_flags() {
  local out=()
  for arg in "$@"; do
    case "$arg" in
      ''|-|--*|-*) ;;
      *) out+=("$arg") ;;
    esac
  done
  printf '%s\n' "${out[@]}"
}
_hm_has_install_targets() {
  local item
  while IFS= read -r item; do
    [ -n "$item" ] && return 0
  done <<EOF
$(_hm_args_without_flags "$@")
EOF
  return 1
}
_hm_has_arg() {
  local needle="$1"
  shift
  for arg in "$@"; do
    [ "$arg" = "$needle" ] && return 0
  done
  return 1
}
pip() {
  command pip "$@"
  local rc=$?
  if [ $rc -eq 0 ] && [ "${1:-}" = "install" ] \
      && ! _hm_has_arg -r "${@:2}" && ! _hm_has_arg --requirement "${@:2}" \
      && _hm_has_install_targets "${@:2}"; then
    _hm_append_cmd "pip install" "${@:2}"
  fi
  return $rc
}
pip3() {
  command pip3 "$@"
  local rc=$?
  if [ $rc -eq 0 ] && [ "${1:-}" = "install" ] \
      && ! _hm_has_arg -r "${@:2}" && ! _hm_has_arg --requirement "${@:2}" \
      && _hm_has_install_targets "${@:2}"; then
    _hm_append_cmd "pip install" "${@:2}"
  fi
  return $rc
}
uv() {
  command uv "$@"
  local rc=$?
  if [ $rc -eq 0 ] && [ "${1:-}" = "pip" ] && [ "${2:-}" = "install" ] \
      && ! _hm_has_arg -r "${@:3}" && ! _hm_has_arg --requirements "${@:3}" \
      && _hm_has_install_targets "${@:3}"; then
    _hm_append_cmd "uv pip install" "${@:3}"
  fi
  return $rc
}
npm() {
  command npm "$@"
  local rc=$?
  if [ $rc -eq 0 ] && { [ "${1:-}" = "install" ] || [ "${1:-}" = "i" ]; } && { [ "${2:-}" = "-g" ] || [ "${2:-}" = "--global" ]; } && _hm_has_install_targets "${@:3}"; then
    _hm_append_cmd "npm install -g" "${@:3}"
  fi
  return $rc
}
hermes() {
  command hermes "$@"
  local rc=$?
  if [ $rc -eq 0 ] && [ "${1:-}" = "plugins" ] && [ "${2:-}" = "install" ] && _hm_has_install_targets "${@:3}"; then
    _hm_append_cmd "hermes plugins install" "${@:3}"
  fi
  return $rc
}
BASHRC
# Bake the resolved path; the interactive shell may not inherit WORKSPACE_HOME and
# a wrong base silently breaks capture/replay.
printf 'STARTUP_FILE=%q\n' "$STARTUP_FILE" >> "$HOME/.bashrc"
cat > "$HOME/.profile" << 'PROFILE'
[ -n "${BASH_VERSION:-}" ] && [ -f ~/.bashrc ] && . ~/.bashrc
PROFILE
echo "Shell capture wrappers ready."

# ── zsh interactive config (oh-my-zsh + powerlevel10k + private dotfiles) ──────
# zsh is the login shell (tmate + in-app terminal). OMZ/p10k/plugins are image-baked;
# personal dotfiles ride the HF bucket under $HERMES_HOME and load each boot
# (p10k.zsh -> ~/.p10k.zsh, zshrc sourced by the generated ~/.zshrc).
if [ -f "$HERMES_HOME/p10k.zsh" ]; then
	cp -f "$HERMES_HOME/p10k.zsh" "$HOME/.p10k.zsh"
fi

# Bake the resolved per-agent paths: the interactive shell can't re-derive them
# ($WORKSPACE_HOME is unexported); a wrong base would split history / miss the config.
{
	printf 'HISTFILE=%q\n' "$HERMES_HOME/.zsh_history"
	printf 'HERMES_PERSONAL_ZSHRC=%q\n' "$HERMES_HOME/zshrc"
} > "$HOME/.zshrc"
cat >> "$HOME/.zshrc" << 'ZSHRC'
# Personal config (theme/aliases/p10k) from the HF bucket; absent -> bare shell.
[ -r "$HERMES_PERSONAL_ZSHRC" ] && source "$HERMES_PERSONAL_ZSHRC"

[[ -o interactive && -d $HOME/workspace && $PWD != $HOME/workspace && ( ${PWD:A} == ${HOME:A} || ${PWD:A} == ${HOME:A}/workspace ) ]] && cd "$HOME/workspace"

# ── Install-capture wrappers (zsh-native mirror of the bash set in .bashrc) ──
# Record interactive package installs into $STARTUP_FILE so they replay on the
# next boot and survive Space restarts. STARTUP_FILE is baked below this heredoc.
_hm_append() {
  [ "${HERMES_CAPTURE_DISABLE:-0}" = "1" ] && return 0
  local line="$*"
  mkdir -p "${STARTUP_FILE:h}"
  touch "$STARTUP_FILE"
  chmod +x "$STARTUP_FILE" 2>/dev/null || true
  grep -qxF -- "$line" "$STARTUP_FILE" 2>/dev/null || print -r -- "$line" >> "$STARTUP_FILE"
}
_hm_quote_args() { print -rn -- "${(j: :)${(@q)@}}"; }
_hm_append_cmd() {
  local cmd="$1"; shift
  local args; args="$(_hm_quote_args "$@")"
  if [ -n "$args" ]; then _hm_append "$cmd $args"; else _hm_append "$cmd"; fi
}
_hm_args_without_flags() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      ''|-|--*|-*) ;;
      *) print -r -- "$arg" ;;
    esac
  done
}
_hm_has_install_targets() {
  local item out
  out="$(_hm_args_without_flags "$@")"
  while IFS= read -r item; do
    [ -n "$item" ] && return 0
  done <<< "$out"
  return 1
}
_hm_has_arg() {
  local needle="$1"; shift
  local arg
  for arg in "$@"; do [ "$arg" = "$needle" ] && return 0; done
  return 1
}
pip() {
  command pip "$@"; local rc=$?
  local -a rest; rest=("${(@)argv[2,-1]}")
  if [ $rc -eq 0 ] && [ "${1:-}" = "install" ] \
      && ! _hm_has_arg -r "$rest[@]" && ! _hm_has_arg --requirement "$rest[@]" \
      && _hm_has_install_targets "$rest[@]"; then
    _hm_append_cmd "pip install" "$rest[@]"
  fi
  return $rc
}
pip3() {
  command pip3 "$@"; local rc=$?
  local -a rest; rest=("${(@)argv[2,-1]}")
  if [ $rc -eq 0 ] && [ "${1:-}" = "install" ] \
      && ! _hm_has_arg -r "$rest[@]" && ! _hm_has_arg --requirement "$rest[@]" \
      && _hm_has_install_targets "$rest[@]"; then
    _hm_append_cmd "pip install" "$rest[@]"
  fi
  return $rc
}
uv() {
  command uv "$@"; local rc=$?
  local -a rest; rest=("${(@)argv[3,-1]}")
  if [ $rc -eq 0 ] && [ "${1:-}" = "pip" ] && [ "${2:-}" = "install" ] \
      && ! _hm_has_arg -r "$rest[@]" && ! _hm_has_arg --requirements "$rest[@]" \
      && _hm_has_install_targets "$rest[@]"; then
    _hm_append_cmd "uv pip install" "$rest[@]"
  fi
  return $rc
}
npm() {
  command npm "$@"; local rc=$?
  local -a rest; rest=("${(@)argv[3,-1]}")
  if [ $rc -eq 0 ] && { [ "${1:-}" = "install" ] || [ "${1:-}" = "i" ]; } \
      && { [ "${2:-}" = "-g" ] || [ "${2:-}" = "--global" ]; } \
      && _hm_has_install_targets "$rest[@]"; then
    _hm_append_cmd "npm install -g" "$rest[@]"
  fi
  return $rc
}
hermes() {
  command hermes "$@"; local rc=$?
  local -a rest; rest=("${(@)argv[3,-1]}")
  if [ $rc -eq 0 ] && [ "${1:-}" = "plugins" ] && [ "${2:-}" = "install" ] \
      && _hm_has_install_targets "$rest[@]"; then
    _hm_append_cmd "hermes plugins install" "$rest[@]"
  fi
  return $rc
}
ZSHRC
# Pin capture target to the exact boot-resolved path (interactive shell may not
# inherit WORKSPACE_HOME); mirrors the .bashrc bake above.
printf 'STARTUP_FILE=%q\n' "$STARTUP_FILE" >> "$HOME/.zshrc"
echo "zsh interactive config ready ($HOME/.zshrc)."

# ── Pool key promotion ──
# Mirror the first pool key into the singular env var Hermes providers read.
# Accepts comma-separated or JSON-array form (like parse_pool below). Gemini
# excluded — its JSON-array round-robin is richer.
promote_first_pool_key() {
	local singular_var="$1"
	local pool_var="$2"
	local singular_val="${!singular_var:-}"
	local pool_val="${!pool_var:-}"
	[ -n "$singular_val" ] && return 0
	[ -n "$pool_val" ] || return 0
	local first
	# Strip an optional surrounding JSON array (`[ ... ]`), split on comma, take
	# the first non-empty field, then strip surrounding whitespace and quotes.
	first=$(printf '%s' "$pool_val" \
		| sed -e 's/^[[:space:]]*\[//' -e 's/\][[:space:]]*$//' \
		| tr ',' '\n' \
		| sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
		| awk 'NF{print; exit}' \
		| sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")
	[ -n "$first" ] || return 0
	export "${singular_var}=$first"
}

promote_first_pool_key "OPENROUTER_API_KEY"   "OPENROUTER_API_KEYS"
promote_first_pool_key "ANTHROPIC_API_KEY"    "ANTHROPIC_API_KEYS"
promote_first_pool_key "OPENAI_API_KEY"       "OPENAI_API_KEYS"
promote_first_pool_key "GOOGLE_API_KEY"       "GOOGLE_API_KEYS"
promote_first_pool_key "DEEPSEEK_API_KEY"     "DEEPSEEK_API_KEYS"
promote_first_pool_key "KIMI_API_KEY"         "KIMI_API_KEYS"
promote_first_pool_key "MINIMAX_API_KEY"      "MINIMAX_API_KEYS"
promote_first_pool_key "NVIDIA_API_KEY"       "NVIDIA_API_KEYS"
promote_first_pool_key "XAI_API_KEY"          "XAI_API_KEYS"
promote_first_pool_key "KILOCODE_API_KEY"     "KILOCODE_API_KEYS"
promote_first_pool_key "GLM_API_KEY"          "GLM_API_KEYS"
promote_first_pool_key "ARCEEAI_API_KEY"      "ARCEEAI_API_KEYS"
promote_first_pool_key "DASHSCOPE_API_KEY"    "DASHSCOPE_API_KEYS"
promote_first_pool_key "GMI_API_KEY"          "GMI_API_KEYS"
promote_first_pool_key "TOKENHUB_API_KEY"     "TOKENHUB_API_KEYS"
promote_first_pool_key "OLLAMA_API_KEY"       "OLLAMA_API_KEYS"
promote_first_pool_key "CLAUDE_CODE_OAUTH_TOKEN" "CLAUDE_CODE_OAUTH_TOKENS"

# ── Coding-agent CLIs (claude-code + opencode) headless setup ───────────────
# Seed config so unattended tasks run claude/opencode non-interactively. Defaults
# merged not clobbered (operator edits survive). Model override: CODING_AGENT_OPENCODE_MODEL.
setup_coding_agents() {
	local oc_model="${CODING_AGENT_OPENCODE_MODEL:-opencode/mimo-v2.5-free}"
	CODING_HOME="$HOME" OC_MODEL="$oc_model" python3 - <<'PY' || echo "coding-agent setup: skipped (python error)"
import json, os, pathlib

home = pathlib.Path(os.environ["CODING_HOME"])

# Claude Code: seed bypass-permissions + onboarding ack; merge so absent keys
# only, preserving operator edits.
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

# opencode: keys from env; merge defaults (absent keys only).
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
print("coding-agent setup: claude + opencode config seeded "
      f"(opencode model: {model or 'default'})")
PY
}
setup_coding_agents

# ── Claude Code plugin marketplaces: re-add missing clones at boot ────────────
restore_claude_marketplaces() {
	command -v claude >/dev/null 2>&1 || return 0
	local km="$HOME/.claude/plugins/known_marketplaces.json"
	[ -f "$km" ] || return 0
	export CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE=1
	local src
	while IFS= read -r src; do
		[ -n "$src" ] || continue
		if claude plugin marketplace add "$src" >/dev/null 2>&1; then
			log "Re-added Claude marketplace: $src"
		else
			warn "Claude marketplace re-add failed: $src"
		fi
	done < <(python3 - "$km" "$HOME/.claude/plugins/marketplaces" <<'PY'
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
PY
	)
}
restore_claude_marketplaces

# ── Hermes config setup (via CLI, not YAML) ───────────────────────────────
log "Configuring Hermes via CLI"

# ── hermes update on rerun (every boot after the first) ───────────────
if python3 - <<'PY'
import json, os, sys
from pathlib import Path
state = Path(os.environ["HERMES_HOME"]) / ".hermes" / "keys-state.json"
try:
    done = json.loads(state.read_text(encoding="utf-8")).get("first_run_done") is True
except Exception:
    done = False
sys.exit(0 if done else 1)
PY
then
	log "Re-run detected — running hermes update"
	hermes update >/dev/null 2>&1 || warn "hermes update failed (continuing)"
fi

# ── Idempotent API-key sync (pools + singular provider keys) ────────────────
log "Syncing API keys (idempotent)"
python3 - <<'PYKEYS' || warn "key sync failed (continuing)"
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
    "TOKENHUB_API_KEYS":   "TOKENHUB_API_KEY",
}

HERMES_HOME = Path(os.environ["HERMES_HOME"])
STATE_FILE = HERMES_HOME / ".hermes" / "keys-state.json"

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
    """A failed singular add still works via env auto-discovery (var already
    exported), so it counts as success — record the hash to avoid re-adding."""
    rc = subprocess.run(
        ["hermes", "auth", "add", slug, "--type", "api-key", "--api-key", value],
        capture_output=True,
    ).returncode
    if rc != 0:
        sys.stderr.write(
            f"WARN: `hermes auth add {slug}` failed (rc={rc}); relying on env auto-discovery\n"
        )
    return True


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
PYKEYS

# ── Set model + provider via CLI (more reliable than YAML) ───────────────────
hermes config set model "$MODEL_FOR_CONFIG" &&
	log "✓ Model: $MODEL_FOR_CONFIG" ||
	warn "Failed to set model (continuing)"

hermes config set provider "$PROVIDER_FOR_CONFIG" &&
	log "✓ Provider: $PROVIDER_FOR_CONFIG" ||
	warn "Failed to set provider (continuing)"

# ── Custom endpoint support ────────────────────────────────────────────────────
if [ -n "${CUSTOM_BASE_URL:-}" ]; then
	hermes config set model.base_url "${CUSTOM_BASE_URL}" &&
		log "✓ Custom base_url: $CUSTOM_BASE_URL" ||
		warn "Failed to set custom base_url"

	[ -n "${CUSTOM_API_KEY:-}" ] &&
		hermes config set model.api_key "${CUSTOM_API_KEY}" 2>/dev/null || true
fi

# ── Terminal/workspace ────────────────────────────────────────────────────────
mkdir -p "$WORKSPACE_HOME"
# Skip aliasing if a real path already occupies the link (don't clobber).
if [ -e "$WORKSPACE_LINK" ] && [ ! -L "$WORKSPACE_LINK" ]; then
	warn "$WORKSPACE_LINK exists as a real path; using $WORKSPACE_HOME"
	AGENT_WORKSPACE="$WORKSPACE_HOME"
else
	if mkdir -p "$(dirname "$WORKSPACE_LINK")" 2>/dev/null \
		&& ln -sfn "$AGENT_HOME" "$WORKSPACE_LINK" 2>/dev/null; then
		AGENT_WORKSPACE="$WORKSPACE_LINK/workspace"
	else
		warn "could not create $WORKSPACE_LINK (permission?); using $WORKSPACE_HOME"
		AGENT_WORKSPACE="$WORKSPACE_HOME"
	fi
fi
export TMATE_CWD="$AGENT_WORKSPACE"
hermes config set terminal.cwd "$AGENT_WORKSPACE" 2>/dev/null || true
TMUX_CONF="$HOME/.tmux.conf"
if ! grep -qxF 'set -g mouse on' "$TMUX_CONF" 2>/dev/null; then
	cat >> "$TMUX_CONF" <<'TMUXCONF'
set -g mouse on
bind c new-window -c "#{pane_current_path}"
bind '"' split-window -v -c "#{pane_current_path}"
bind % split-window -h -c "#{pane_current_path}"
TMUXCONF
fi
hermes config set compression.enabled true 2>/dev/null || true
hermes config set security.redact_secrets true 2>/dev/null || true
hermes config set display.background_process_notifications "${HERMES_BACKGROUND_NOTIFICATIONS:-result}" 2>/dev/null || true

# ── Telegram platform config (augments CLI-written config.yaml) ───────────────
# `hermes config set` covers scalars; the telegram platform needs nested keys and
# an allow_from list, so inject them straight into config.yaml after the CLI runs.
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
	log "Configuring Telegram platform"
	python3 - <<'PY'
import os
from pathlib import Path

import yaml

path = Path(os.environ["HERMES_HOME"]) / "config.yaml"
try:
    config = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
except FileNotFoundError:
    config = {}

telegram = config.setdefault("platforms", {}).setdefault("telegram", {})
telegram.setdefault("enabled", True)
extra = telegram.setdefault("extra", {})
if os.environ.get("TELEGRAM_BASE_URL"):
    # Overwrite, never setdefault: the proxy worker URL is derived fresh each boot
    # (per SPACE_HOST), but config.yaml is persisted across boots. setdefault would
    # pin whatever URL was first written — so a stale/renamed/broken worker URL
    # survives forever and the gateway keeps dialing a dead proxy (placeholder 404
    # → InvalidToken). Re-sync to the current proxy every boot.
    extra["base_url"] = os.environ["TELEGRAM_BASE_URL"]
    extra["base_file_url"] = os.environ.get("TELEGRAM_BASE_FILE_URL") or os.environ["TELEGRAM_BASE_URL"]
if os.environ.get("TELEGRAM_ALLOWED_USERS"):
    config.setdefault("telegram", {}).setdefault("allow_from", [
        item.strip()
        for item in os.environ["TELEGRAM_ALLOWED_USERS"].split(",")
        if item.strip()
    ])

path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
path.chmod(0o600)
PY
fi

# Re-enable Telegram reactions on every boot (persisted config may omit it)
hermes config set telegram.reactions true &&
	log "✓ Telegram reactions enabled" ||
	warn "Failed to set telegram.reactions (continuing)"

# On cloud, sed-patch Telegram proxy into Hermes source to catch IP-fallback path
if [ "$PLATFORM" = "hf" ] || [ "$PLATFORM" = "render" ]; then
	if [ -n "${TELEGRAM_BASE_URL:-}" ]; then
		PROXY_HOST="${TELEGRAM_BASE_URL#*://}"
		PROXY_HOST="${PROXY_HOST%%/*}"
		if [ -n "$PROXY_HOST" ] && [ "$PROXY_HOST" != "api.telegram.org" ]; then
			SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "/usr/local/lib/python3.14/site-packages")
			find "$SITE_PACKAGES" -path "*/hermes*" -type f \( -name "*.py" -o -name "*.json" \) \
				-exec sed -i "s/api.telegram.org/$PROXY_HOST/g" {} + 2>/dev/null || true
			log "✓ Telegram proxy (sed-patch) -> $PROXY_HOST"
		fi
	fi

	# A lagging Cloudflare edge serves the placeholder page on first getMe; PTB
	# parses it as InvalidToken, which the connect-retry loop doesn't catch — so
	# Telegram dies on a transient. Widen the retry to cover InvalidToken. Patches
	# the editable source the gateway imports; idempotent.
	TG_FILE=$(python3 -c "import gateway.platforms.telegram as t; print(t.__file__)" 2>/dev/null || true)
	if [ -n "$TG_FILE" ] && [ -f "$TG_FILE" ]; then
		sed -i \
			-e 's/from telegram.error import NetworkError, TimedOut$/from telegram.error import NetworkError, TimedOut, InvalidToken/' \
			-e 's/except (NetworkError, TimedOut, OSError) as init_err:/except (NetworkError, TimedOut, OSError, InvalidToken) as init_err:/' \
			"$TG_FILE" 2>/dev/null &&
			log "✓ Telegram connect-retry hardened (sed-patch: retry InvalidToken)" ||
			warn "Failed to harden Telegram connect-retry (continuing)"
	fi

	# The retry loop above needs ~60s to ride out propagation, but the gateway's
	# default ~30s connect timeout kills it mid-retry. Widen it; honor an override.
	export HERMES_GATEWAY_PLATFORM_CONNECT_TIMEOUT="${HERMES_GATEWAY_PLATFORM_CONNECT_TIMEOUT:-180}"
	log "✓ Telegram connect timeout -> ${HERMES_GATEWAY_PLATFORM_CONNECT_TIMEOUT}s"
fi

# ── Polling mode: clear any stale webhook so getUpdates can take over ──────────
# A stale registered webhook makes getUpdates return 409 until removed, so a
# webhook→polling switch silently fails without this. Idempotent; keeps pending
# updates. Routed via TELEGRAM_BASE_URL since HF/Render block api.telegram.org.
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -z "${TELEGRAM_WEBHOOK_URL:-}" ]; then
	if [ -z "${TELEGRAM_BASE_URL:-}" ] && { [ "$PLATFORM" = "hf" ] || [ "$PLATFORM" = "render" ]; }; then
		warn "Polling on $PLATFORM without a Telegram proxy (set CLOUDFLARE_PROXY_URL or TELEGRAM_BASE_URL) — outbound api.telegram.org is blocked; getUpdates will hang"
	else
		TELEGRAM_API_BASE="${TELEGRAM_BASE_URL:-https://api.telegram.org/bot}" \
			python3 - <<'PY' && log "Telegram webhook cleared (polling mode)" || warn "deleteWebhook failed (continuing; polling may 409 if a webhook is still registered)"
import json
import os
import urllib.request

base = os.environ["TELEGRAM_API_BASE"]
token = os.environ["TELEGRAM_BOT_TOKEN"]
# A browser User-Agent is mandatory when routed through the Cloudflare proxy:
# its bot firewall 403s the default Python-urllib UA ("error code: 1010"), which
# would silently fail the clear and leave a webhook active → getUpdates Conflict.
req = urllib.request.Request(f"{base}{token}/deleteWebhook", headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req, timeout=15) as resp:
    data = json.loads(resp.read())
# Telegram answers HTTP 200 with {"ok": false, ...} for API-level failures, so a
# non-2xx exception alone is not enough — assert ok so a soft failure reaches warn.
assert data.get("ok"), data.get("description", "unknown error")
PY
	fi
fi

# ── SSH Debug Access (tmate) ──────────────────────────────────────────────────
# Reuse the on-demand pool manager so the boot session is listed by tmate-ls,
# killable via tmate-kill, opens in the workspace, and notifies the channel.
if command -v tmate >/dev/null 2>&1 && command -v tmate-new >/dev/null 2>&1; then
	echo "set -g mouse off" >"$HOME/.tmate.conf"
	SSH_URL=$(tmate-new boot 2>/dev/null | sed -n 's/^ssh:[[:space:]]*//p') || true
	[ -n "${SSH_URL:-}" ] && log "SSH access: $SSH_URL" || log "tmate unavailable for SSH debugging"
fi

# ── Startup summary ────────────────────────────────────────────────────────────
log ""
log "╔════════════════════════════════════════════════════════════════╗"
log "║  Summary                                                       ║"
log "╚════════════════════════════════════════════════════════════════╝"
log "Primary UI : ${PRIMARY_UI:-webui}"
log "Model      : ${MODEL_FOR_CONFIG:-unset}"
log "Provider   : ${PROVIDER_FOR_CONFIG:-unset}"
log "Agent      : $AGENT_NAME"
log ""
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
	log "Telegram   : enabled"
else
	log "Telegram   : not configured"
fi
[ -n "${HF_TOKEN:-}" ] &&
	log "Backup     : enabled (bucket ${BACKUP_BUCKET:-hermes-backup}/${AGENT_NAME})" ||
	log "Backup     : disabled"
[ -n "${CLOUDFLARE_PROXY_URL:-}" ] &&
	log "CF Proxy   : ${CLOUDFLARE_PROXY_URL}"
log ""
log "Router     : 0.0.0.0:${PUBLIC_PORT}"
log "WebUI      : 127.0.0.1:${WEBUI_PORT}"
log "Gateway    : 127.0.0.1:${GATEWAY_API_PORT}"
log "Dashboard  : 127.0.0.1:${DASHBOARD_PORT}"
log ""

# ── Process launchers ─────────────────────────────────────────────────
# Supervisor loop restarts dead services via these launchers.
start_health() {
	node "$APP_DIR/health-server.js" &
	HEALTH_PID=$!
}

start_dashboard() {
	echo "Launching Hermes dashboard on 127.0.0.1:${DASHBOARD_PORT}"
	(hermes dashboard --host 127.0.0.1 --insecure 2>&1 | tee -a "$HERMES_HOME/logs/dashboard.log") &
	DASHBOARD_PID=$!
}

start_gateway() {
	echo "Launching Hermes gateway"
	(hermes gateway run 2>&1 | tee -a "$HERMES_HOME/logs/gateway.log") &
	GATEWAY_PID=$!
}

start_webui() {
	echo "Launching Hermes WebUI on 127.0.0.1:${WEBUI_PORT}"
	(cd "$WEBUI_REPO" &&
		"$HERMES_WEBUI_PYTHON" "$WEBUI_REPO/server.py" 2>&1 |
		tee -a "$HERMES_HOME/logs/webui.log") &
	WEBUI_PID=$!
}

# Kept alive by supervisor; silent death = silent data loss.
SYNC_LOOP_PID=""
start_sync_loop() {
	[ -n "${HF_TOKEN:-}" ] || return 0
	if [ -n "${SYNC_LOOP_PID:-}" ] && kill -0 "$SYNC_LOOP_PID" 2>/dev/null; then
		return 0
	fi
	python3 -u "$APP_DIR/hermes-sync.py" loop &
	SYNC_LOOP_PID=$!
}

# No-op without HF_TOKEN.
sync_now() {
	[ -n "${HF_TOKEN:-}" ] || return 0
	python3 "$APP_DIR/hermes-sync.py" sync-once || echo "Warning: state sync failed."
}

# notify_online() — migrated to gateway:startup hook (hooks/hermes-online).


# Returns 0 on connect or if pid dies/timeout.
wait_port_ready() {
	local port="$1" timeout="$2" pid="$3" i
	for ((i = 0; i < timeout; i++)); do
		if (echo >"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
			return 0
		fi
		if ! kill -0 "$pid" 2>/dev/null; then
			return 1
		fi
		sleep 1
	done
	return 1
}

kill_tree() {
	local pid="$1" child
	[ -n "$pid" ] || return 0
	if [ -r "/proc/$pid/task/$pid/children" ]; then
		for child in $(cat "/proc/$pid/task/$pid/children" 2>/dev/null); do
			kill_tree "$child"
		done
	fi
	kill -TERM "$pid" 2>/dev/null || true
}

# ── Graceful shutdown ─────────────────────────────────────────────────
graceful_shutdown() {
	trap '' SIGTERM SIGINT # ignore repeat signals so the final sync isn't interrupted
	echo "Shutting down"
	sync_now
	for pid in "${WEBUI_PID:-}" "${GATEWAY_PID:-}" "${DASHBOARD_PID:-}" "${HEALTH_PID:-}" "${SYNC_LOOP_PID:-}"; do
		kill_tree "$pid"
	done
	kill $(jobs -p) 2>/dev/null || true
	exit 0
}
trap graceful_shutdown SIGTERM SIGINT

# ── WebUI runtime env (static; exported once) ─────────────────────────
# Agent venv paths; state backed up from $HERMES_HOME/webui.
export HERMES_WEBUI_AGENT_DIR="/opt/hermes"
export HERMES_WEBUI_PYTHON="/opt/hermes/.venv/bin/python"
export HERMES_WEBUI_HOST="127.0.0.1"
export HERMES_WEBUI_PORT
export HERMES_WEBUI_STATE_DIR="${HERMES_WEBUI_STATE_DIR:-$HERMES_HOME/webui}"
export HERMES_WEBUI_DEFAULT_WORKSPACE="${HERMES_WEBUI_DEFAULT_WORKSPACE:-$WORKSPACE_HOME}"
export HERMES_WEBUI_AUTO_INSTALL="0"
mkdir -p "$HERMES_WEBUI_STATE_DIR"

# Gateway opens its API port within ~8s of launch in boot tests; 90s keeps a
# wide margin while failing a wedged gateway sooner. Override to raise.
GATEWAY_READY_TIMEOUT="${GATEWAY_READY_TIMEOUT:-90}"
WEBUI_READY_TIMEOUT="${WEBUI_READY_TIMEOUT:-60}"

# ── Initial boot ──────────────────────────────────────────────────────
start_health

if [ -n "${WEBHOOK_URL:-}" ]; then
	python3 - <<'PY' >/dev/null 2>&1 &
import json, os, urllib.request
body = json.dumps({
    "event": "restart",
    "status": "success",
    "message": "Hermes WebUI has started.",
    "model": os.environ.get("MODEL_FOR_CONFIG", ""),
}).encode()
req = urllib.request.Request(os.environ["WEBHOOK_URL"], data=body, method="POST",
                             headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=10).read()
PY
fi

# ── Optional boot-time package installs (HF Variables/Secrets) ────────────────
# Declarative installs so deps survive restarts without a custom Dockerfile.
# Best-effort, never fatal. apt degrades to a logged skip (no root under USER hermes).
HM_STARTUP_FAILURES=0

if [ -n "${HERMES_APT_PACKAGES:-}" ]; then
	echo "Installing apt packages from HERMES_APT_PACKAGES..."
	read -r -a HM_APT_PACKAGES <<<"$HERMES_APT_PACKAGES"
	if command -v sudo >/dev/null 2>&1; then
		if sudo apt-get update && sudo apt-get install -y "${HM_APT_PACKAGES[@]}"; then
			echo "HERMES_APT_PACKAGES install complete."
		else
			HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
			echo "ERROR: HERMES_APT_PACKAGES install failed: ${HERMES_APT_PACKAGES}" >&2
		fi
	elif [ "$(id -u)" -eq 0 ]; then
		if apt-get update && apt-get install -y "${HM_APT_PACKAGES[@]}"; then
			echo "HERMES_APT_PACKAGES install complete."
		else
			HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
			echo "ERROR: HERMES_APT_PACKAGES install failed: ${HERMES_APT_PACKAGES}" >&2
		fi
	else
		HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
		echo "ERROR: root/sudo unavailable; HERMES_APT_PACKAGES skipped" >&2
	fi
fi

if [ -n "${HERMES_PIP_PACKAGES:-}" ]; then
	echo "Installing Python packages from HERMES_PIP_PACKAGES..."
	read -r -a HM_PIP_PACKAGES <<<"$HERMES_PIP_PACKAGES"
	if /opt/hermes/.venv/bin/pip install "${HM_PIP_PACKAGES[@]}"; then
		echo "HERMES_PIP_PACKAGES install complete."
	else
		HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
		echo "ERROR: HERMES_PIP_PACKAGES install failed: ${HERMES_PIP_PACKAGES}" >&2
	fi
fi

if [ -n "${HERMES_NPM_PACKAGES:-}" ]; then
	echo "Installing npm packages from HERMES_NPM_PACKAGES..."
	read -r -a HM_NPM_PACKAGES <<<"$HERMES_NPM_PACKAGES"
	if npm install -g "${HM_NPM_PACKAGES[@]}"; then
		echo "HERMES_NPM_PACKAGES install complete."
	else
		HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
		echo "ERROR: HERMES_NPM_PACKAGES install failed: ${HERMES_NPM_PACKAGES}" >&2
	fi
fi

# Arbitrary startup script (HERMES_RUN): plain bash, or base64:/b64: prefixed.
hm_run_startup() {
	local payload="$1"
	[ -n "$payload" ] || return 0
	local script_file
	script_file=$(mktemp "/tmp/hermes-startup.XXXXXX.sh")
	{
		echo 'export HERMES_CAPTURE_DISABLE=1'
		echo '[ -f ~/.bashrc ] && . ~/.bashrc'
		if [[ "$payload" == base64:* ]] || [[ "$payload" == b64:* ]]; then
			printf '%s' "${payload#*:}" | base64 -d
		else
			printf '%s\n' "$payload"
		fi
	} > "$script_file"
	chmod 700 "$script_file"
	echo "[startup:HERMES_RUN] running script"
	set +e
	bash "$script_file"
	local rc=$?
	set -e
	rm -f "$script_file"
	if [ "$rc" -eq 0 ]; then
		echo "[startup:HERMES_RUN] ok"
	else
		HM_STARTUP_FAILURES=$((HM_STARTUP_FAILURES + 1))
		echo "ERROR: HERMES_RUN script failed (exit ${rc})" >&2
	fi
}

if [ -n "${HERMES_RUN:-}" ]; then
	hm_run_startup "$HERMES_RUN"
fi

if [ "$HM_STARTUP_FAILURES" -gt 0 ]; then
	echo "Warning: ${HM_STARTUP_FAILURES} startup step(s) failed. Check logs above." >&2
fi

# ── Run workspace startup script ──
# Replays install commands recorded by the shell wrappers from previous sessions.
if [ -s "$STARTUP_FILE" ]; then
	echo "Running workspace/startup.sh..."
	set +e
	HERMES_CAPTURE_DISABLE=1 bash -l "$STARTUP_FILE"
	set -e
	echo "Workspace startup script complete."
fi

# Private; no readiness gate.
start_dashboard

# Launch concurrently; gateway waited first (fatal), WebUI after (non-fatal) by
# which point it had the gateway's window to come up.
start_gateway
start_webui

# Fatal on first boot; no gateway = useless container.
if ! wait_port_ready "$GATEWAY_API_PORT" "$GATEWAY_READY_TIMEOUT" "$GATEWAY_PID"; then
	echo ""
	echo "Hermes gateway failed to expose the API health port. Last 40 log lines:"
	echo "----------------------------------------"
	tail -40 "$HERMES_HOME/logs/gateway.log" || true
	exit 1
fi

# Verify model was set (hermes config commands succeeded)
if [ -z "$MODEL_FOR_CONFIG" ]; then
	die "CRITICAL: No model configured. Ensure LLM_MODEL is set."
fi
log "✓ Model configured: $MODEL_FOR_CONFIG"

# Start persistence before state mutations.
start_sync_loop

# Non-fatal; router shows it as down.
if wait_port_ready "$WEBUI_PORT" "$WEBUI_READY_TIMEOUT" "$WEBUI_PID"; then
	echo "Hermes WebUI is up."
else
	echo "Warning: Hermes WebUI not ready within ${WEBUI_READY_TIMEOUT}s. Last 20 log lines:"
	tail -20 "$HERMES_HOME/logs/webui.log" || true
fi

# Boot greeting now handled by gateway:startup hook (hooks/hermes-online).

# ── Service restart loop (self-healing) ───────────────────────────────────────
# Restart services if they die. On cloud, exit and let orchestrator restart container.
SUPERVISOR_POLL_INTERVAL="${SUPERVISOR_POLL_INTERVAL:-10}"
SUPERVISOR_MAX_RESTARTS="${SUPERVISOR_MAX_RESTARTS:-0}" # 0 = unlimited
GATEWAY_RESTART_COUNT=0

log "Starting service monitor loop (restart on crash)"

while true; do
	sleep "$SUPERVISOR_POLL_INTERVAL"

	# Check gateway
	if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
		# Bail past the cap so the platform recreates a fresh container instead of
		# us respawning a crash-looping gateway forever. 0 (default) = unlimited.
		if [ "$SUPERVISOR_MAX_RESTARTS" != "0" ] && [ "$GATEWAY_RESTART_COUNT" -ge "$SUPERVISOR_MAX_RESTARTS" ]; then
			warn "Hermes gateway exceeded SUPERVISOR_MAX_RESTARTS ($SUPERVISOR_MAX_RESTARTS) — syncing and exiting for a clean restart"
			sync_now
			exit 1
		fi
		GATEWAY_RESTART_COUNT=$((GATEWAY_RESTART_COUNT + 1))
		warn "Hermes gateway died (PID $GATEWAY_PID). Respawning in 5s (restart $GATEWAY_RESTART_COUNT)"
		sleep 5
		start_gateway
		if wait_port_ready "$GATEWAY_API_PORT" "$GATEWAY_READY_TIMEOUT" "$GATEWAY_PID"; then
			log "Gateway restarted successfully"
		else
			warn "Gateway failed to restart — continuing anyway"
		fi
		sync_now
	fi

	# Check WebUI
	if ! kill -0 "$WEBUI_PID" 2>/dev/null; then
		warn "Hermes WebUI died (PID $WEBUI_PID). Respawning in 5s"
		sleep 5
		start_webui
		if wait_port_ready "$WEBUI_PORT" "$WEBUI_READY_TIMEOUT" "$WEBUI_PID"; then
			log "WebUI restarted successfully"
		fi
		sync_now
	fi

	# Check health server
	if ! kill -0 "$HEALTH_PID" 2>/dev/null; then
		warn "Health server died. Respawning"
		start_health
	fi

	# Check dashboard (non-fatal)
	if ! kill -0 "$DASHBOARD_PID" 2>/dev/null; then
		warn "Dashboard died. Respawning"
		start_dashboard
	fi

	# Check sync loop (if enabled)
	if [ -n "${HF_TOKEN:-}" ] && { [ -z "${SYNC_LOOP_PID:-}" ] || ! kill -0 "$SYNC_LOOP_PID" 2>/dev/null; }; then
		warn "Backup sync loop died. Respawning"
		SYNC_LOOP_PID=""
		start_sync_loop
	fi
done

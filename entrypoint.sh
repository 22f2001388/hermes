#!/bin/bash
set -euo pipefail
umask 077

# Start health check FIRST, before anything else
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'OK')
    def log_message(self, *args): pass
HTTPServer(('0.0.0.0', 7860), H).serve_forever()
" &

echo "✓ Health check server up on port 7860"

echo "Initializing Hermes Agent..."

if [ -n "${SPACE_ID:-}" ]; then
	PLATFORM="hf"
elif [ -n "${RENDER:-}" ]; then
	PLATFORM="render"
else
	PLATFORM="local"
fi
echo "Detected platform: $PLATFORM"

PORT="${PORT:-7860}"

PERSIST_DIR="/data"

# AGENT_NAME guard: required for cloud deployments, random fallback for local
if [ "$PLATFORM" = "hf" ] || [ "$PLATFORM" = "render" ]; then
	if [ -z "${AGENT_NAME:-}" ]; then
		echo "FATAL: AGENT_NAME is required on $PLATFORM. Set it via Space secrets or environment variable."
		exit 1
	fi
else
	AGENT_NAME="${AGENT_NAME:-$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])" 2>/dev/null || echo "agent-$$")}"
fi
echo "Agent instance: $AGENT_NAME"

HERMES_DATA="/data/${AGENT_NAME}/.hermes"
WORKSPACE_DATA="/data/${AGENT_NAME}/workspace"

command -v hermes >/dev/null 2>&1 || {
	echo "hermes binary not found"
	exit 1
}

# Stash baked souls before /data symlink shadows $HOME/.hermes
if [ -d "$HOME/.hermes/souls" ]; then
	cp -r "$HOME/.hermes/souls" /tmp/souls 2>/dev/null || true
fi

if [ -d "$HOME/.hermes" ] && [ ! -L "$HOME/.hermes" ]; then
	echo "Bind-mounted .hermes detected at $HOME/.hermes — syncing live with host"
	SKIP_HERMES_INIT=1
	cd "$HOME/app"
elif [ -d "$PERSIST_DIR" ]; then
	echo "Persistent storage found at $PERSIST_DIR"
	mkdir -p "$HERMES_DATA" "$WORKSPACE_DATA"
	if [ ! -L "$HOME/.hermes" ]; then
		rm -rf "$HOME/.hermes"
		ln -s "$HERMES_DATA" "$HOME/.hermes"
	fi
	cd "$WORKSPACE_DATA"
else
	echo "No /data found -- running on ephemeral storage"
	mkdir -p "$HOME/.hermes"
	cd "$HOME/app"
fi

# Select SOUL for this agent from baked souls
SOUL_FILE="/tmp/souls/${AGENT_NAME}.soul"
if [ -f "$SOUL_FILE" ]; then
	cp "$SOUL_FILE" "$HOME/.hermes/SOUL.md"
	echo "Loaded SOUL: ${AGENT_NAME}.soul"
else
	echo "FATAL: No soul file found for AGENT_NAME=$AGENT_NAME (expected /tmp/souls/${AGENT_NAME}.soul)"
	exit 1
fi

if [ "$PLATFORM" = "local" ]; then
	ENV_FILE="$HOME/.hermes/.env"
	if [ -n "${SKIP_HERMES_INIT:-}" ] && [ -f "$ENV_FILE" ]; then
		echo "Using existing .env from bind-mounted .hermes"
	elif [ -f ".env" ]; then
		cp .env "$ENV_FILE"
		echo "Credentials loaded from .env file"
	else
		cat <<EOF >"$ENV_FILE"
HF_TOKEN=${HF_TOKEN:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
GEMINI_API_KEY=${GEMINI_API_KEY:-}
GEMINI_API_KEY_1=${GEMINI_API_KEY_1:-}
GEMINI_API_KEY_2=${GEMINI_API_KEY_2:-}
GEMINI_API_KEY_3=${GEMINI_API_KEY_3:-}
GEMINI_API_KEY_4=${GEMINI_API_KEY_4:-}
GATEWAY_ALLOW_ALL_USERS=true
EOF
		echo "Credentials loaded from environment variables"
	fi
	chmod 600 "$ENV_FILE"
	set -a && source "$ENV_FILE" && set +a
fi

# Tmate (SSH access)
mkdir -p "$HOME/.ssh"
[ -f "$HOME/.ssh/id_rsa" ] || ssh-keygen -q -t rsa -N "" -f "$HOME/.ssh/id_rsa"
echo "set -g mouse on" >"$HOME/.tmate.conf"
tmate -S /tmp/tmate.sock new-session -d 2>/dev/null
for i in 1 2 3 4 5; do
	SSH_URL=$(tmate -S /tmp/tmate.sock display -p '#{tmate_ssh}' 2>/dev/null)
	[ -n "$SSH_URL" ] && break
	sleep 1
done
echo "SSH: ${SSH_URL:-tmate failed to connect}"

if [ -n "${HF_TOKEN:-}" ]; then
	hermes model set-provider hf --default || echo "Warning: HF provider config failed (continue)"
fi
hermes config set providers.gemini.credentials \
	'[{"env":"GEMINI_API_KEY"},{"env":"GEMINI_API_KEY_1"},{"env":"GEMINI_API_KEY_2"},{"env":"GEMINI_API_KEY_3"},{"env":"GEMINI_API_KEY_4"}]' ||
	echo "Warning: Gemini credentials config failed (continue)"
hermes config set providers.gemini.strategy round-robin ||
	echo "Warning: Gemini strategy config failed (continue)"
hermes config set model gemini-flash-lite-latest ||
	echo "Warning: Default model config failed (continue)"

if [ -n "${TELEGRAM_PROXY_HOST:-}" ]; then
	SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "/usr/local/lib/python3.11/site-packages")
	find "$SITE_PACKAGES" -path "*/hermes*" -type f \( -name "*.py" -o -name "*.json" \) \
		-exec sed -i "s/api.telegram.org/$TELEGRAM_PROXY_HOST/g" {} + 2>/dev/null || true
	echo "Telegram proxy configured: $TELEGRAM_PROXY_HOST"
fi

# Per-agent config injection from environment
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
	hermes config set telegram.token "$TELEGRAM_BOT_TOKEN" || echo "Warning: telegram.token config failed (continue)"
fi
if [ -n "${TELEGRAM_ALLOWED_CHATS:-}" ]; then
	hermes config set telegram.allowed_chats "$TELEGRAM_ALLOWED_CHATS" || echo "Warning: telegram.allowed_chats config failed (continue)"
fi
if [ -n "${AGENT_PERSONALITY:-}" ]; then
	hermes config set display.personality "$AGENT_PERSONALITY" || echo "Warning: display.personality config failed (continue)"
fi

echo "Starting Hermes gateway (autonomous mode)..."
while true; do
	if hermes gateway run; then
		echo "Hermes exited cleanly."
		exit 0
	else
		echo "Hermes crashed (exit $?). Respawning in 5s..."
		sleep 5
	fi
done

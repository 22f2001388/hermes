#!/bin/bash
# install-vps.sh — one-time bare-metal Hermes provisioner
# Run as root once before first systemctl start hermes
# Then set /etc/hermes.env (GATEWAY_TOKEN, LLM_MODEL, provider keys)
# Then: systemctl enable --now hermes

set -euo pipefail

# ── Root check ────────────────────────────────────────────────────────────
if [ "$(id -u)" != 0 ]; then
  echo "ERROR: install-vps.sh must run as root"
  exit 1
fi

echo "Hermes bare-metal provisioner"
echo ""

# ── Create hermes system user/group if missing ────────────────────────────
if ! id hermes >/dev/null 2>&1; then
  echo "Creating hermes system user and group..."
  groupadd -r hermes || true
  useradd -r -g hermes -d /opt/data -s /bin/bash -m hermes || true
else
  echo "hermes user already exists."
fi

# ── Pre-flight: packages needed before mise can install runtimes ───────────
echo "Installing pre-flight dependencies..."
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg libatomic1

# ── Install mise system-wide (runtime version manager) ───────────────────
echo "Installing mise system-wide..."
export MISE_INSTALL_PATH=/usr/local/bin/mise
export MISE_DATA_DIR=/opt/mise
mkdir -p "$MISE_DATA_DIR"
curl -fsSL https://mise.run | sh
eval "$(mise activate bash)"

# ── Install runtimes via mise ─────────────────────────────────────────────
echo "Installing runtimes via mise (into $MISE_DATA_DIR)..."
mise use -g python@latest
mise use -g node@latest
mise use -g uv@latest
mise use -g bun@latest
eval "$(mise activate bash)"

# ── apt dependencies (from Dockerfile lines 10-17) ────────────────────────
echo "Installing system dependencies..."
apt-get install -y --no-install-recommends \
  jq git chromium zsh fzf \
  zoxide bat eza neovim ffmpeg poppler-utils libnss3 libatk1.0-0 \
  libatk-bridge2.0-0 libdrm2 libgbm1 libxcomposite1 libxdamage1 libxrandr2 \
  libxkbcommon0 libx11-6 libxext6 libxfixes3 fonts-dejavu-core fonts-liberation \
  fonts-noto-color-emoji

# Fallback for libasound2 (may be libasound2t64 on newer systems)
apt-get install -y --no-install-recommends libasound2 2>/dev/null \
  || apt-get install -y --no-install-recommends libasound2t64 2>/dev/null \
  || echo "WARNING: libasound2/libasound2t64 not available; continuing"

# ── Create venv dir ───────────────────────────────────────────────────────
echo "Creating venv directory..."
mkdir -p /opt/hermes
mkdir -p /opt/data

# ── Create Python venv with uv (managed by mise) ──────────────────────────
echo "Creating Python virtual environment..."
uv venv --python python3 /opt/hermes/.venv

# ── Install hermes-agent from source ────────────────────────────────────────
# ponytail: assumes repo URL https://github.com/NousResearch/hermes-agent
# and standard pyproject.toml-based install. Confirm URL/method if pip install fails.
echo "Installing hermes-agent from source..."
HERMES_AGENT_TMPDIR=$(mktemp -d)
trap "rm -rf $HERMES_AGENT_TMPDIR" EXIT

git clone --depth 1 https://github.com/NousResearch/hermes-agent.git "$HERMES_AGENT_TMPDIR"
uv pip install --python /opt/hermes/.venv/bin/python --no-cache-dir "$HERMES_AGENT_TMPDIR"

# Install hermes-specific deps (from Dockerfile line 18)
echo "Installing hermes runtime dependencies..."
uv pip install --python /opt/hermes/.venv/bin/python --no-cache-dir \
  "huggingface_hub>=1.18.0" hf_transfer pyyaml

# ── GitHub CLI (from Dockerfile lines 20-26) ──────────────────────────────
echo "Installing GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /usr/share/keyrings/githubcli-archive-keyring.gpg
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  >/etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y --no-install-recommends gh
rm -rf /var/lib/apt/lists/*

# ── npm global config and tools (from Dockerfile lines 28-41) ──────────────
echo "Setting up npm global..."
eval "$(mise activate bash)"
export NPM_CONFIG_PREFIX=/opt/hermes/npm-global
mkdir -p /opt/hermes/npm-global

export UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin

echo "Installing global Node tools..."
npm install -g opencode-ai@latest npm@latest
npm cache clean --force

# Optional: Claude CLI + code-review-graph (non-fatal per Dockerfile)
# ponytail: these are optional coding-agent features; marked non-fatal to allow provisioning
# even if claude.ai or uv tool install are unreachable
echo "Installing optional coding-agent tools (non-fatal)..."
export HOME=/opt/claude-home
mkdir -p "$HOME"
if curl -fsSL https://claude.ai/install.sh | bash; then
  ln -sf "$HOME/.local/bin/claude" /usr/local/bin/claude || true
  ln -sfn "$HOME/.local/share/claude" /usr/local/share/claude || true
  chmod -R a+rX /opt/claude-home/.local || true
  uv tool install code-review-graph >/dev/null 2>&1 || \
    echo "WARNING: code-review-graph install failed (continuing)"
else
  echo "WARNING: Claude CLI install failed (continuing)"
fi

# ── Skip oh-my-zsh/p10k (YAGNI for headless server) ──────────────────────
# The Dockerfile lines 43-53 install oh-my-zsh + powerlevel10k + plugins.
# For a headless VPS, these are unnecessary cosmetics; skipped.

# ── Clone hermes-webui (from Dockerfile lines 55-59) ────────────────────────
echo "Cloning hermes-webui..."
WEBUI_REF="v0.51.549"
if [ -d /opt/hermes-webui/.git ]; then
  echo "hermes-webui already present; skipping clone (re-run safe)."
else
  git clone --depth 1 --branch "$WEBUI_REF" https://github.com/nesquena/hermes-webui.git /opt/hermes-webui
fi

if [ -f /opt/hermes-webui/requirements.txt ]; then
  echo "Installing WebUI requirements..."
  uv pip install --python /opt/hermes/.venv/bin/python --no-cache-dir -r /opt/hermes-webui/requirements.txt
fi

# ── Copy app files (from Dockerfile lines 61-67) ───────────────────────────
echo "Copying Hermes app files..."
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$REPO_ROOT/start.sh" ] || { echo "ERROR: start.sh not found in $REPO_ROOT"; exit 1; }

cp "$REPO_ROOT/start.sh" /opt/hermes/start.sh
[ -f "$REPO_ROOT/.env" ] && cp -a "$REPO_ROOT/.env" /opt/hermes/.env || true
[ -d "$REPO_ROOT/shell" ] && cp -a "$REPO_ROOT/shell/" /opt/hermes/shell/ || true
[ -d "$REPO_ROOT/hooks" ] && cp -a "$REPO_ROOT/hooks/" /opt/hermes/hooks/ || true
[ -d "$REPO_ROOT/sync" ] && cp -a "$REPO_ROOT/sync/" /opt/hermes/sync/ || true
[ -d "$REPO_ROOT/network" ] && cp -a "$REPO_ROOT/network/" /opt/hermes/network/ || true
[ -d "$REPO_ROOT/server" ] && cp -a "$REPO_ROOT/server/" /opt/hermes/server/ || true
[ -d "$REPO_ROOT/boot" ] && cp -a "$REPO_ROOT/boot/" /opt/hermes/boot/ || true

# ── chmod +x scripts (from Dockerfile lines 69-71) ────────────────────────
echo "Setting execute permissions..."
chmod +x /opt/hermes/start.sh
[ -f /opt/hermes/sync/hermes-sync.py ] && chmod +x /opt/hermes/sync/hermes-sync.py || true
[ -f /opt/hermes/network/cloudflare-proxy-setup.py ] && chmod +x /opt/hermes/network/cloudflare-proxy-setup.py || true
[ -f /opt/hermes/network/cloudflare-keepalive-setup.py ] && chmod +x /opt/hermes/network/cloudflare-keepalive-setup.py || true
chmod +x /opt/hermes/boot/*.py 2>/dev/null || true

# ── Run boot patches (from Dockerfile lines 76-77, non-fatal) ───────────────
echo "Running boot patches..."
python3 /opt/hermes/boot/patch-kanban-db.py 2>/dev/null || echo "WARNING: patch-kanban-db.py failed (continuing)"
python3 /opt/hermes/boot/patch-quiet-poll.py 2>/dev/null || echo "WARNING: patch-quiet-poll.py failed (continuing)"

# ── Ownership ──────────────────────────────────────────────────────────────
echo "Setting ownership..."
chown -R hermes:hermes /opt/hermes
chown -R hermes:hermes /opt/hermes-webui
chown -R hermes:hermes /opt/data
chown -R hermes:hermes /opt/mise
[ -d /opt/uv-tools ] && chown -R hermes:hermes /opt/uv-tools || true
# Dockerfile:73 — start.sh symlinks /home/$AGENT_NAME; hermes must own /home to create it
chown hermes:hermes /home

# ── Systemd env file helper (not exec'd here; for /etc/hermes.env) ────────
# The runtime environment vars from Dockerfile lines 79-84 will be set via
# EnvironmentFile=/etc/hermes.env in systemd unit (see hermes.service).
# Create a PATH wrapper so venv + npm-global are available at runtime.
cat >/etc/profile.d/hermes-venv.sh <<'VENVPATH'
export MISE_DATA_DIR=/opt/mise
export PATH="/opt/hermes/.venv/bin:/opt/hermes/npm-global/bin:/opt/data/.local/bin:/opt/mise/shims:$PATH"
eval "$(mise activate bash)"
VENVPATH
chmod 644 /etc/profile.d/hermes-venv.sh

# ── Install systemd unit + env file ────────────────────────────────────────
# Without this, `systemctl enable --now hermes` (the final step below) fails:
# the unit was never placed and EnvironmentFile=/etc/hermes.env must exist.
echo "Installing systemd unit..."
install -m 644 "$REPO_ROOT/hermes.service" /etc/systemd/system/hermes.service
if [ ! -f /etc/hermes.env ]; then
  echo "Creating /etc/hermes.env template (edit before starting)..."
  install -m 600 -o root -g root "$REPO_ROOT/hermes.env.example" /etc/hermes.env
fi
systemctl daemon-reload

# ── Verification ──────────────────────────────────────────────────────────
echo ""
echo "Verifying installation..."
if ! /opt/hermes/.venv/bin/hermes --version >/dev/null 2>&1; then
  echo "ERROR: hermes binary not callable. Check git clone / pip install."
  exit 1
fi

if ! node --version >/dev/null 2>&1; then
  echo "ERROR: node binary not found."
  exit 1
fi

echo "✓ hermes version: $(/opt/hermes/.venv/bin/hermes --version 2>/dev/null || echo 'unknown')"
echo "✓ node version: $(node --version)"
echo ""
echo "Provisioning complete."
echo ""
echo "Next steps:"
echo "  1. Edit /etc/hermes.env (created from template) — set at minimum:"
echo "       GATEWAY_TOKEN=your-secret-token-here"
echo "       LLM_MODEL=provider/model-name"
echo "       OPENAI_API_KEY=sk-..."
echo "       HF_TOKEN=hf_... (optional, for HuggingFace backup)"
echo "  2. systemctl enable --now hermes"

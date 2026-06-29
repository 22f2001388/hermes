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

# ── Layout: everything under the hermes user's home (mise stays shared) ────
HERMES_USER_HOME=/home/hermes
HERMES_APP="$HERMES_USER_HOME/app"
HERMES_VENV="$HERMES_USER_HOME/.venv"
NPM_GLOBAL="$HERMES_USER_HOME/npm-global"

# ── Create hermes user/group + login password if missing ───────────────────
if ! id hermes >/dev/null 2>&1; then
  echo "Creating hermes user and group..."
  useradd -m -U -d "$HERMES_USER_HOME" -s /bin/bash hermes
  if [ -t 0 ]; then
    echo "Set a login password for the hermes user:"
    passwd hermes || echo "WARNING: password not set; run 'passwd hermes' later"
  else
    echo "WARNING: non-interactive install; set the hermes password later with: passwd hermes"
  fi
else
  echo "hermes user already exists."
fi

# ── System packages (single apt pass) ───────────────────────────────────
# GH keyring must be registered before apt-get update so gh installs in one pass.
# ca-certificates/curl/gnupg: pre-flight deps for mise's installer.
echo "Installing system packages..."
if [ ! -f /usr/share/keyrings/githubcli-archive-keyring.gpg ]; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    >/etc/apt/sources.list.d/github-cli.list
fi
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg libatomic1 \
  jq git gh zsh fzf \
  zoxide bat eza neovim ffmpeg poppler-utils \
  libnss3 libatk1.0-0 libatk-bridge2.0-0 libdrm2 libgbm1 \
  libxcomposite1 libxdamage1 libxrandr2 libxkbcommon0 \
  libx11-6 libxext6 libxfixes3 \
  libasound2t64 \
  fonts-dejavu-core fonts-liberation fonts-noto-color-emoji
rm -rf /var/lib/apt/lists/*

# ── Install mise system-wide (runtime version manager) ───────────────────
export MISE_INSTALL_PATH=/usr/local/bin/mise
export MISE_DATA_DIR=/opt/mise
mkdir -p "$MISE_DATA_DIR"
if [ ! -x /usr/local/bin/mise ]; then
  echo "Installing mise system-wide..."
  curl -fsSL https://mise.run | sh
else
  echo "mise already installed; skipping."
fi
eval "$(mise activate bash)"

# ── Install runtimes via mise ─────────────────────────────────────────────
# `mise use -g` is idempotent: installs the runtime if absent, no-op if already
# at latest. Left unguarded on purpose so re-runs also keep the global default set.
echo "Installing runtimes via mise (into $MISE_DATA_DIR)..."
mise use -g python@latest
mise use -g node@latest
mise use -g uv@latest
mise use -g bun@latest
eval "$(mise activate bash)"

# ── Create app dir ────────────────────────────────────────────────────────
echo "Creating app directory..."
mkdir -p "$HERMES_APP"

# ── Create Python venv with uv (managed by mise) ──────────────────────────
if [ -x "$HERMES_VENV/bin/python" ]; then
  echo "Python venv already exists; skipping."
else
  echo "Creating Python virtual environment..."
  uv venv --python python3 "$HERMES_VENV"
fi

# ── Install hermes-agent from source ────────────────────────────────────────
# ponytail: assumes repo URL https://github.com/NousResearch/hermes-agent
# and standard pyproject.toml-based install. Confirm URL/method if pip install fails.
if "$HERMES_VENV/bin/hermes" --version >/dev/null 2>&1; then
  echo "hermes-agent already installed; skipping."
else
  echo "Installing hermes-agent from source..."
  HERMES_AGENT_TMPDIR=$(mktemp -d)
  trap "rm -rf $HERMES_AGENT_TMPDIR" EXIT
  git clone --depth 1 https://github.com/NousResearch/hermes-agent.git "$HERMES_AGENT_TMPDIR"
  uv pip install --python "$HERMES_VENV/bin/python" --no-cache-dir "$HERMES_AGENT_TMPDIR"
fi

# Install hermes-specific deps (from Dockerfile line 18)
if "$HERMES_VENV/bin/python" -c "import huggingface_hub, hf_transfer, yaml" >/dev/null 2>&1; then
  echo "hermes runtime dependencies already present; skipping."
else
  echo "Installing hermes runtime dependencies..."
  uv pip install --python "$HERMES_VENV/bin/python" --no-cache-dir \
    "huggingface_hub>=1.18.0" hf_transfer pyyaml
fi

# ── npm global config and tools (from Dockerfile lines 28-41) ──────────────
echo "Setting up npm global..."
eval "$(mise activate bash)"
export NPM_CONFIG_PREFIX="$NPM_GLOBAL"
mkdir -p "$NPM_GLOBAL"

export UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin

echo "Installing global Node tools..."
npm install -g npm@latest  # self-update; idempotent no-op when already current
[ -x "$NPM_GLOBAL/bin/opencode" ] || npm install -g opencode-ai@latest
[ -x "$NPM_GLOBAL/bin/agent-browser" ] || npm install -g agent-browser@latest
npm cache clean --force

# playwright install is idempotent (skips already-downloaded browsers). Non-fatal so
# a chromium download hiccup can't kill provisioning under `set -e` (the original bug).
echo "Installing Playwright Chromium (idempotent)..."
npx --yes playwright install chromium || echo "WARNING: playwright chromium install failed (continuing)"

# Optional: Claude CLI + code-review-graph (non-fatal per Dockerfile)
# ponytail: these are optional coding-agent features; marked non-fatal to allow provisioning
# even if claude.ai or uv tool install are unreachable
echo "Installing optional coding-agent tools (non-fatal)..."
if [ -x /usr/local/bin/claude ]; then
  echo "Claude CLI already installed; skipping."
else
  export HOME=/opt/claude-home
  mkdir -p "$HOME"
  if curl -fsSL https://claude.ai/install.sh | bash; then
    ln -sf "$HOME/.local/bin/claude" /usr/local/bin/claude || true
    ln -sfn "$HOME/.local/share/claude" /usr/local/share/claude || true
    chmod -R a+rX /opt/claude-home/.local || true
  else
    echo "WARNING: Claude CLI install failed (continuing)"
  fi
fi
if uv tool list 2>/dev/null | grep -q code-review-graph; then
  echo "code-review-graph already installed; skipping."
else
  uv tool install code-review-graph >/dev/null 2>&1 || \
    echo "WARNING: code-review-graph install failed (continuing)"
fi

# ── Skip oh-my-zsh/p10k (YAGNI for headless server) ──────────────────────
# The Dockerfile lines 43-53 install oh-my-zsh + powerlevel10k + plugins.
# For a headless VPS, these are unnecessary cosmetics; skipped.

# ── WebUI intentionally not installed on VPS ────────────────────────────
# ponytail: VPS runs headless (gateway + dashboard + Telegram only). The
# Docker/HF images still ship hermes-webui; add the clone+install back here
# (see git history / Dockerfile lines 55-59) if VPS ever needs it.

# ── Copy app files (from Dockerfile lines 61-67) ───────────────────────────
echo "Copying Hermes app files..."
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$REPO_ROOT/start.sh" ] || { echo "ERROR: start.sh not found in $REPO_ROOT"; exit 1; }

cp "$REPO_ROOT/start.sh" "$HERMES_APP/start.sh"
[ -f "$REPO_ROOT/.env" ] && install -m 600 "$REPO_ROOT/.env" "$HERMES_APP/.env" || true
[ -d "$REPO_ROOT/shell" ] && cp -a "$REPO_ROOT/shell/" "$HERMES_APP/shell/" || true
[ -d "$REPO_ROOT/hooks" ] && cp -a "$REPO_ROOT/hooks/" "$HERMES_APP/hooks/" || true
[ -d "$REPO_ROOT/sync" ] && cp -a "$REPO_ROOT/sync/" "$HERMES_APP/sync/" || true
[ -d "$REPO_ROOT/network" ] && cp -a "$REPO_ROOT/network/" "$HERMES_APP/network/" || true
[ -d "$REPO_ROOT/server" ] && cp -a "$REPO_ROOT/server/" "$HERMES_APP/server/" || true
[ -d "$REPO_ROOT/boot" ] && cp -a "$REPO_ROOT/boot/" "$HERMES_APP/boot/" || true

# ── chmod +x scripts (from Dockerfile lines 69-71) ────────────────────────
echo "Setting execute permissions..."
chmod +x "$HERMES_APP/start.sh"
[ -f "$HERMES_APP/sync/hermes-sync.py" ] && chmod +x "$HERMES_APP/sync/hermes-sync.py" || true
[ -f "$HERMES_APP/network/cloudflare-proxy-setup.py" ] && chmod +x "$HERMES_APP/network/cloudflare-proxy-setup.py" || true
[ -f "$HERMES_APP/network/cloudflare-keepalive-setup.py" ] && chmod +x "$HERMES_APP/network/cloudflare-keepalive-setup.py" || true
chmod +x "$HERMES_APP"/boot/*.py 2>/dev/null || true

# ── Run boot patches (from Dockerfile lines 76-77, non-fatal) ───────────────
echo "Running boot patches..."
HERMES_APP_DIR="$HERMES_APP" python3 "$HERMES_APP/boot/patch-kanban-db.py" 2>/dev/null || echo "WARNING: patch-kanban-db.py failed (continuing)"

# ── Ownership ──────────────────────────────────────────────────────────────
echo "Setting ownership..."
chown -R hermes:hermes "$HERMES_USER_HOME"
chown -R hermes:hermes /opt/mise
[ -d /opt/uv-tools ] && chown -R hermes:hermes /opt/uv-tools || true

# ── mise global for the hermes SERVICE user ────────────────────────────────
# `mise use -g` above wrote ROOT's config; this writes the hermes user's copy.
# Without it, node shim is unresolvable and the :7861 router never binds.
echo "Setting mise global runtimes for the hermes user..."
su - hermes -c 'MISE_DATA_DIR=/opt/mise /usr/local/bin/mise use -g python@latest node@latest uv@latest bun@latest'

# ── Profile.d PATH wrapper (not exec'd; for interactive logins) ────────
# systemd uses EnvironmentFile=/etc/hermes.env, not /etc/profile.d.
# This wrapper covers direct `su - hermes` logins.
cat >/etc/profile.d/hermes-venv.sh <<'VENVPATH'
export MISE_DATA_DIR=/opt/mise
export PATH="/home/hermes/.venv/bin:/home/hermes/npm-global/bin:/home/hermes/.local/bin:/opt/mise/shims:$PATH"
eval "$(mise activate bash)"
VENVPATH
chmod 644 /etc/profile.d/hermes-venv.sh

# ── agent-browser one-time setup ───────────────────────────────────────
# Run as hermes user so config lands in /home/hermes, not /root. Non-fatal.
su - hermes -c 'command -v agent-browser >/dev/null 2>&1 && agent-browser install' \
  >/dev/null 2>&1 || echo "WARNING: agent-browser setup failed (continuing)"

# ── Install systemd unit + env file ────────────────────────────────────
# Both must exist before `systemctl enable --now hermes` at the end.
echo "Installing systemd unit..."
install -m 644 "$REPO_ROOT/hermes.service" /etc/systemd/system/hermes.service
if [ ! -f /etc/hermes.env ]; then
  echo "Creating /etc/hermes.env template (edit before starting)..."
  install -m 600 -o root -g root "$REPO_ROOT/hermes.env.example" /etc/hermes.env
fi
systemctl daemon-reload
systemctl enable hermes  # boot persistence; `start` still manual until /etc/hermes.env is set

# ── Verification ──────────────────────────────────────────────────────────
echo ""
echo "Verifying installation..."
if ! "$HERMES_VENV/bin/hermes" --version >/dev/null 2>&1; then
  echo "ERROR: hermes binary not callable. Check git clone / pip install."
  exit 1
fi

# Per-user mise global — root-only check passes while systemd still fails.
if ! su - hermes -c 'node --version' >/dev/null 2>&1; then
  echo "ERROR: node not resolvable for the hermes service user — mise global unset."
  echo "       The :7861 router would fail to start. Check 'su - hermes -c \"mise ls\"'."
  exit 1
fi

echo "✓ hermes version: $("$HERMES_VENV/bin/hermes" --version 2>/dev/null || echo 'unknown')"
echo "✓ node version (hermes user): $(su - hermes -c 'node --version' 2>/dev/null || echo 'unknown')"

# ── Completion stamp ───────────────────────────────────────────────────────
# Reaching here means every required step passed (set -e aborts before this on any
# hard failure; optional tools are non-fatal). start.sh re-runs this installer until
# this file exists, so a partial install self-heals on the next boot. `rm` it to
# force a full re-provision.
touch /home/hermes/.hermes-provisioned
chown hermes:hermes /home/hermes/.hermes-provisioned

echo ""
echo "Provisioning complete."
echo ""
echo "Next steps:"
echo "  1. Edit /etc/hermes.env (created from template) — set at minimum:"
echo "       GATEWAY_TOKEN=your-secret-token-here"
echo "       LLM_MODEL=provider/model-name"
echo "       OPENAI_API_KEY=sk-..."
echo "       HF_TOKEN=hf_... (optional, for HuggingFace backup)"
echo "  2. systemctl start hermes   (already enabled at boot)"

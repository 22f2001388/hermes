
ARG HERMES_AGENT_VERSION=latest
# Pin by digest for reproducible builds; layer cache busts only on deliberate base bump.
ARG HERMES_AGENT_REF=nousresearch/hermes-agent@sha256:e51ed1bbd9a6f6c260a61f8401b6f7ffc9356cfed20b88f387521f9739eff166
FROM ${HERMES_AGENT_REF}

ARG WEBUI_REF=v0.51.369

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    git \
    python3 \
    nodejs \
     npm \
     chromium \
     tmate \
     tmux \
     zsh \
     fzf \
     zoxide \
     bat \
     eza \
     gnupg \
     neovim \
     libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libdrm2 \
    libgbm1 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libxkbcommon0 \
    libx11-6 \
    libxext6 \
    libxfixes3 \
    fonts-dejavu-core \
    fonts-liberation \
    fonts-noto-color-emoji \
    && (apt-get install -y --no-install-recommends libasound2 2>/dev/null || apt-get install -y --no-install-recommends libasound2t64 2>/dev/null || true) \
    && rm -rf /var/lib/apt/lists/* \
    && uv pip install --python /opt/hermes/.venv/bin/python --no-cache-dir \
        "huggingface_hub>=1.18.0" hf_transfer pyyaml

# Separate RUN keeps third-party apt source + lists isolated from main system-deps layer.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g opencode-ai \
 && npm cache clean --force

RUN export HOME=/opt/claude-home \
 && mkdir -p "$HOME" \
 && curl -fsSL https://claude.ai/install.sh | bash \
 && ln -sf  "$HOME/.local/bin/claude"   /usr/local/bin/claude \
 && ln -sfn "$HOME/.local/share/claude" /usr/local/share/claude \
 && chmod -R a+rX /opt/claude-home/.local \
 && claude --version

ENV UV_TOOL_DIR=/opt/uv-tools \
    UV_TOOL_BIN_DIR=/usr/local/bin
RUN uv tool install code-review-graph \
 && code-review-graph --help >/dev/null

# OMZ in /opt for image-immutable location; bat→batcat symlink; chsh for tmate/terminal.
RUN export ZSH=/opt/oh-my-zsh \
 && sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc \
 && git clone --depth 1 https://github.com/romkatv/powerlevel10k.git        "$ZSH/custom/themes/powerlevel10k" \
 && git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions     "$ZSH/custom/plugins/zsh-autosuggestions" \
 && git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH/custom/plugins/zsh-syntax-highlighting" \
 && git clone --depth 1 https://github.com/zsh-users/zsh-completions         "$ZSH/custom/plugins/zsh-completions" \
 && git clone --depth 1 https://github.com/Aloxaf/fzf-tab                    "$ZSH/custom/plugins/fzf-tab" \
 && chown -R hermes:hermes "$ZSH" \
 && ln -sf /usr/bin/batcat /usr/local/bin/bat \
 && grep -qxF /usr/bin/zsh /etc/shells 2>/dev/null || echo /usr/bin/zsh >> /etc/shells \
 && usermod -s /usr/bin/zsh hermes

# system pip needed — base image venv may not exist yet.
RUN git clone --depth 1 --branch ${WEBUI_REF} \
        https://github.com/nesquena/hermes-webui.git /opt/hermes-webui \
 && ( [ -f /opt/hermes-webui/requirements.txt ] \
      && /opt/hermes/.venv/bin/pip install --no-cache-dir -r /opt/hermes-webui/requirements.txt \
      || true ) \
 && chown -R hermes:hermes /opt/hermes-webui

COPY --chown=hermes:hermes start.sh                       /opt/hermes/start.sh
COPY --chown=hermes:hermes health-server.js               /opt/hermes/health-server.js
COPY --chown=hermes:hermes hermes-sync.py                 /opt/hermes/hermes-sync.py
COPY --chown=hermes:hermes tmate-tools.sh                 /opt/hermes/tmate-tools.sh
COPY --chown=hermes:hermes cloudflare-proxy-setup.py      /opt/hermes/cloudflare-proxy-setup.py
COPY --chown=hermes:hermes cloudflare-keepalive-setup.py  /opt/hermes/cloudflare-keepalive-setup.py
COPY --chown=hermes:hermes env-builder.html               /opt/hermes/env-builder.html
COPY --chown=hermes:hermes env-builder.js                 /opt/hermes/env-builder.js
COPY --chown=hermes:hermes hooks/                         /opt/hermes/hooks/

RUN chmod +x \
    /opt/hermes/start.sh \
    /opt/hermes/hermes-sync.py \
    /opt/hermes/tmate-tools.sh \
    /opt/hermes/cloudflare-proxy-setup.py \
    /opt/hermes/cloudflare-keepalive-setup.py

RUN ln -sf /opt/hermes/tmate-tools.sh /usr/local/bin/tmate-new \
 && ln -sf /opt/hermes/tmate-tools.sh /usr/local/bin/tmate-ls \
 && ln -sf /opt/hermes/tmate-tools.sh /usr/local/bin/tmate-kill

# Idempotent: ALTER TABLE ADD COLUMN wrapped in try/except to tolerate existing column or upstream fix.
RUN python3 - <<'PY'
import sys
try:
    from pathlib import Path

    p = Path("/opt/hermes/hermes_cli/kanban_db.py")
    if not p.exists():
        print("kanban patch: file not found, skipping")
        sys.exit(0)

    src = p.read_text(encoding="utf-8", errors="replace")
    sentinel = "# hermes-webui: idempotent-alter"
    if sentinel in src:
        print("kanban patch: already applied, skipping")
        sys.exit(0)

    old = (
        '    conn.execute(\n'
        '        "ALTER TABLE tasks ADD COLUMN consecutive_failures "\n'
        '        "INTEGER NOT NULL DEFAULT 0"\n'
        '    )'
    )
    new = (
        f'    try:  {sentinel}\n'
        '        conn.execute(\n'
        '            "ALTER TABLE tasks ADD COLUMN consecutive_failures "\n'
        '            "INTEGER NOT NULL DEFAULT 0"\n'
        '        )\n'
        '    except Exception:\n'
        '        pass'
    )

    if old not in src:
        print("kanban patch: pattern not found, may be fixed upstream, skipping")
        sys.exit(0)

    p.write_text(src.replace(old, new), encoding="utf-8")
    print("kanban patch: applied")
except Exception as e:
    print(f"kanban patch: error ({e}), skipping", file=sys.stderr)
PY

# Suppress 2xx poll paths to keep HF Logs tab readable; errors/streaming still log.
RUN python3 - <<'PY'
# Re-applies on every image build against the pinned WEBUI_REF. Marker-based:
# anchors only on log_request's signature (stable across releases) and injects a
# quiet-poll early-return as the method's first statements, so upstream rewrites
# of the log body (e.g. the remote/forwarded_for fields added in newer releases)
# do not break it. Idempotent via sentinel; loud, non-fatal skip if anchor moves.
from pathlib import Path
import sys

p = Path("/opt/hermes-webui/server.py")
if not p.exists():
    print("webui quiet-poll patch: server.py absent, skipping")
    sys.exit(0)
src = p.read_text(encoding="utf-8")
sentinel = "# hermes-webui: quiet-poll-paths"
if sentinel in src:
    print("webui quiet-poll patch: already applied")
    sys.exit(0)

anchor = "    def log_request(self, code: str='-', size: str='-') -> None:\n"
if anchor not in src:
    print("webui quiet-poll patch: anchor not found (log_request signature changed) "
          "-- SKIPPING; webui logs will be noisy until the patch is re-anchored")
    sys.exit(0)

inject = (
    anchor +
    "        " + sentinel + "\n"
    "        _quiet_paths = {\n"
    "            '/api/health/agent', '/api/dashboard/status', '/api/dashboard/config',\n"
    "            '/api/sessions', '/api/profiles', '/api/profile/active',\n"
    "            '/api/onboarding/status', '/api/insights', '/api/system/health',\n"
    "            '/api/settings', '/api/projects', '/api/reasoning', '/api/models',\n"
    "            '/api/chat/stream/status', '/api/git-info', '/sw.js', '/health',\n"
    "        }\n"
    "        _quiet_prefixes = ('/static/', '/session/static/', '/assets/')\n"
    "        try:\n"
    "            _st = int(code) if str(code).isdigit() else 0\n"
    "        except Exception:\n"
    "            _st = 0\n"
    "        _qp = (getattr(self, 'path', '') or '').split('?', 1)[0]\n"
    "        if 200 <= _st < 400:\n"
    "            if _qp in _quiet_paths:\n"
    "                return\n"
    "            for _pref in _quiet_prefixes:\n"
    "                if _qp.startswith(_pref):\n"
    "                    return\n"
)
p.write_text(src.replace(anchor, inject, 1), encoding="utf-8")
print("webui quiet-poll patch: applied")
PY

# hermes user needs write access for auto-updates.
RUN chown -R hermes:hermes /opt/hermes/.venv

RUN chown hermes:hermes /home

RUN echo 'export PATH="/opt/hermes/.venv/bin:/opt/data/.local/bin:$PATH"' \
    > /etc/profile.d/hermes-venv.sh

ENV HERMES_HOME=/opt/data \
    HERMES_APP_DIR=/opt/hermes \
    HERMES_WEBUI_REPO=/opt/hermes-webui \
    HERMES_AGENT_VERSION=${HERMES_AGENT_VERSION} \
    HERMES_WEBUI_TRUST_FORWARDED_HOST=1 \
    PYTHONUNBUFFERED=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium \
    SHELL=/usr/bin/zsh \
    DISABLE_AUTOUPDATER=1

EXPOSE 7861

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s \
  CMD curl -fsS http://localhost:7861/health || exit 1

USER hermes
ENTRYPOINT ["/opt/hermes/start.sh"]

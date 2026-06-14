"use strict";

const config = require("./config");
// auth side of the auth<->views cycle; accessed via namespace at call time.
const auth = require("./auth");

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderPrivateRedirect(targetUrl) {
  const safeUrl = escapeHtml(targetUrl);
  return `<!doctype html><html lang="en"><head>
  <meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>Hermes — Private Space</title>
  <style>
    :root{color-scheme:dark}
    body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
         font-family:Inter,ui-sans-serif,system-ui,-apple-system,sans-serif;
         background:#08080f;color:#f6f4ff;text-align:center;padding:24px}
    .card{border:1px solid #26243a;background:#12111b;border-radius:14px;padding:36px 32px;max-width:440px}
    h1{margin:0 0 12px;font-size:1.5rem}
    p{color:#b8b3d7;line-height:1.6;margin:0 0 24px}
    .btn{display:inline-flex;align-items:center;justify-content:center;
         background:#fff;color:#000;font-weight:850;font-size:.95rem;
         border-radius:8px;padding:12px 28px;text-decoration:none;transition:opacity .15s}
    .btn:hover{opacity:.85}
    .sub{color:#7f7a9e;font-size:.78rem;margin-top:16px}
  </style></head><body>
  <div class="card">
    <h1>🔒 Private Space</h1>
    <p>This HuggingFace Space is private. You need to be logged in to <strong>huggingface.co</strong> to access it.<br><br>Redirecting you now&hellip;</p>
    <a class="btn" href="${safeUrl}" target="_top">Open on Hugging Face →</a>
    <div class="sub">Redirecting&hellip;</div>
  </div>
  <script>
    // Auto-redirect only when NOT inside an iframe — navigating an iframe to
    // huggingface.co is blocked by X-Frame-Options and shows "refused to connect".
    // Framed users must click the button (target="_top" breaks out to the top window).
    const _inFrame = (() => { try { return window.top !== window.self; } catch { return true; } })();
    if (!_inFrame) {
      setTimeout(() => { window.location.replace(${JSON.stringify(targetUrl)}); }, 100);
    } else {
      const _sub = document.querySelector(".sub");
      if (_sub) _sub.textContent = "Click the button above to continue.";
    }
  </script>
</body></html>`;
}

function isDashboardAssetPath(path) {
  return (
    path.startsWith("/assets/") ||
    path.startsWith("/ds-assets/") ||
    path.startsWith("/dashboard-plugins/") ||
    path.startsWith("/api/") ||
    path === "/favicon.ico" ||
    /\.[a-z0-9]{1,6}$/i.test(path)
  );
}

function renderLoginPage(nextPath, errorMessage = "") {
  const safeNext = auth.sanitizeNext(nextPath, "/");
  const errorHtml = errorMessage
    ? `<div class="error">${escapeHtml(errorMessage)}</div>`
    : "";
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Hermes WebUI — Login</title>
  <style>
    :root { color-scheme: dark; --bg:#10141f; --panel:#171d2b; --line:#293246; --text:#f4f7fb; --muted:#9aa7bd; --bad:#ef4444; --accent:#38bdf8; }
    * { box-sizing:border-box; }
    body { margin:0; min-height:100vh; display:grid; place-items:center; font-family:Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:var(--bg); color:var(--text); padding:20px; }
    main { width:min(440px, 100%); border:1px solid var(--line); background:var(--panel); border-radius:8px; padding:28px; }
    h1 { margin:0 0 8px; font-size:1.55rem; }
    p { margin:0 0 22px; color:var(--muted); line-height:1.5; }
    label { display:block; color:var(--muted); font-size:.82rem; margin-bottom:8px; }
    input { width:100%; min-height:46px; border:1px solid var(--line); border-radius:7px; background:#0b0f18; color:var(--text); padding:0 12px; font:inherit; }
    button { width:100%; min-height:44px; margin-top:16px; border:0; border-radius:7px; color:#07111f; background:var(--accent); font:inherit; font-weight:750; cursor:pointer; }
    .error { border:1px solid rgba(239,68,68,.4); background:rgba(239,68,68,.1); color:#fecaca; border-radius:7px; padding:10px 12px; margin-bottom:16px; }
  </style>
</head>
<body>
  <main>
    <h1>Hermes Admin</h1>
    <p>Enter the <code>GATEWAY_TOKEN</code> from your Space secrets to access the status dashboard.<br>For the Hermes chat UI, go to <a href="/" style="color:var(--accent)">/</a>.</p>
    ${errorHtml}
    <form method="post" action="${config.LOGIN_PATH}">
      <input type="hidden" name="next" value="${escapeHtml(safeNext)}" />
      <label for="token">GATEWAY_TOKEN</label>
      <input id="token" name="token" type="password" autocomplete="current-password" autofocus required />
      <button type="submit">Continue</button>
    </form>
  </main>
</body>
</html>`;
}

function toneBadge(label, tone = "neutral") {
  return `<span class="badge ${tone}">${escapeHtml(label)}</span>`;
}

function valueOrUnset(value, fallback = "Not set") {
  return value
    ? escapeHtml(value)
    : `<span class="muted">${escapeHtml(fallback)}</span>`;
}

function renderTile({ title, value, detail = "", tone = "neutral", meta = "" }) {
  return `<article class="tile ${tone}">
    <div class="tile-head">
      <span class="tile-title">${escapeHtml(title)}</span>
      <span class="tile-dot"></span>
    </div>
    <div class="tile-value">${value}</div>
    ${detail ? `<div class="tile-detail">${detail}</div>` : ""}
    ${meta ? `<div class="tile-meta">${meta}</div>` : ""}
  </article>`;
}

function renderTiles(data) {
  const syncStatus = String(data.backup?.status || "unknown");
  const syncTone = ["success", "restored", "synced", "configured"].includes(syncStatus)
    ? "ok"
    : syncStatus === "disabled"
      ? "warn"
      : "neutral";
  const telegramTone = data.telegram.configured
    ? data.telegram.webhookListening || !data.telegram.webhook
      ? "ok"
      : "warn"
    : "warn";
  const keepaliveConfigured = data.keepalive?.configured === true;
  const keepaliveStatus = String(
    data.keepalive?.status ||
      (process.env.CLOUDFLARE_WORKERS_TOKEN ? "pending" : "not configured"),
  );
  const keepAliveTone = keepaliveConfigured
    ? "ok"
    : process.env.CLOUDFLARE_WORKERS_TOKEN
      ? "warn"
      : "neutral";
  const telegramDetail = data.telegram.configured
    ? `${data.telegram.webhook ? "Webhook" : "Polling"}${data.telegram.proxy ? " via CF proxy" : ""}`
    : "Not configured";
  const backupDetail = data.backup?.message
    ? escapeHtml(data.backup.message)
    : "No status yet";

  const backupWarning = data.backup?.warning?.message
    ? `<div class="tile-warning">${escapeHtml(data.backup.warning.message)}</div>`
    : "";
  const keepAliveDetail = keepaliveConfigured
    ? `Pinging <code>${escapeHtml(data.keepalive.targetUrl || "/health")}</code>`
    : keepaliveStatus === "error" && data.keepalive?.message
      ? escapeHtml(data.keepalive.message)
      : process.env.CLOUDFLARE_WORKERS_TOKEN
        ? "Worker pending or failed"
        : "Not configured";

  return [
    renderTile({
      title: "WebUI",
      value: toneBadge(data.webui ? "Online" : "Offline", data.webui ? "ok" : "off"),
      detail: data.webui ? `Port ${data.ports.webui}` : "Unreachable",
      tone: data.webui ? "ok" : "off",
    }),
    renderTile({
      title: "Gateway",
      value: toneBadge(data.gateway ? "Online" : "Offline", data.gateway ? "ok" : "off"),
      detail: data.gateway ? `API on port ${data.ports.gateway}` : "Unreachable",
      tone: data.gateway ? "ok" : "off",
      meta: data.authConfigured ? "Protected" : "Unprotected",
    }),
    renderTile({
      title: "Model",
      value: `<code>${valueOrUnset(data.model)}</code>`,
      detail: `Provider: ${valueOrUnset(data.provider || "auto")}`,
      tone: data.model ? "ok" : "warn",
    }),
    renderTile({
      title: "Runtime",
      value: escapeHtml(data.uptime),
      detail: `Port ${data.ports.public}`,
      tone: "neutral",
    }),
    renderTile({
      title: "Telegram",
      value: toneBadge(data.telegram.configured ? "Configured" : "Disabled", telegramTone),
      detail: telegramDetail,
      tone: telegramTone,
    }),
    renderTile({
      title: "Backup",
      value: toneBadge(syncStatus.toUpperCase(), data.backup?.warning ? "warn" : syncTone),
      detail: backupDetail + backupWarning,
      tone: data.backup?.warning ? "warn" : syncTone,
      meta: data.backup?.timestamp
        ? `<span class="local-time" data-iso="${data.backup.timestamp}"></span>`
        : "",
    }),
    renderTile({
      title: "Keep Awake",
      value: toneBadge(
        keepaliveConfigured ? "CF Cron" : keepaliveStatus.toUpperCase(),
        keepAliveTone,
      ),
      detail: keepAliveDetail,
      tone: keepAliveTone,
    }),
  ].join("");
}

function renderStatusPage(data) {
  const tiles = renderTiles(data);

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Hermes WebUI</title>
  <style>
    :root { color-scheme: dark; --bg:#08080f; --panel:#12111b; --line:#26243a; --text:#f6f4ff; --muted:#7f7a9e; --soft:#b8b3d7; --good:#22c55e; --warn:#f5c542; --bad:#fb7185; --accent:#6557df; }
    * { box-sizing:border-box; }
    body { margin:0; min-height:100vh; font-family:Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:var(--bg); color:var(--text); font-size:13px; }
    main { width:min(720px, calc(100% - 32px)); margin:0 auto; padding:36px 0 44px; }
    header { text-align:center; margin-bottom:22px; }
    h1 { margin:0; font-size:1.65rem; }
    .subtitle { margin-top:12px; color:var(--muted); font-size:.72rem; text-transform:uppercase; letter-spacing:.14em; font-weight:800; }
    .row { display:flex; gap:10px; margin:24px 0 20px; flex-wrap:wrap; }
    .hero-action { flex:1 1 200px; min-height:46px; display:flex; align-items:center; justify-content:center; border-radius:8px; background:#ffffff; color:#000000; text-decoration:none; font-weight:850; font-size:.98rem; }
    .hero-action.secondary { background:#232234; color:var(--text); border:1px solid var(--line); }
    .hero-action:hover { opacity:.9; }
    .overview { display:grid; grid-template-columns:repeat(2, minmax(0, 1fr)); gap:10px; margin-bottom:10px; }
    .tile { border:1px solid var(--line); background:var(--panel); border-radius:11px; padding:18px; min-height:124px; display:flex; flex-direction:column; gap:10px; position:relative; }
    .tile.ok { border-color:rgba(34,197,94,.22); }
    .tile.warn { border-color:rgba(245,197,66,.24); }
    .tile.off { border-color:rgba(251,113,133,.28); }
    .tile-head { display:flex; align-items:center; justify-content:space-between; gap:12px; }
    .tile-title { color:var(--muted); font-size:.67rem; letter-spacing:.18em; text-transform:uppercase; font-weight:850; }
    .tile-dot { width:7px; height:7px; border-radius:50%; background:var(--line); }
    .tile.ok .tile-dot { background:var(--good); }
    .tile.warn .tile-dot { background:var(--warn); }
    .tile.off .tile-dot { background:var(--bad); }
    .tile-value { font-size:1.12rem; font-weight:850; overflow-wrap:anywhere; }
    .tile-detail { color:var(--soft); line-height:1.45; font-size:.83rem; }
    .tile-meta { color:var(--muted); line-height:1.4; font-size:.75rem; margin-top:auto; overflow-wrap:anywhere; }
    .tile-warning { color:#fde68a; background:rgba(245,158,11,.08); border:1px solid rgba(245,158,11,.32); border-radius:6px; padding:6px 8px; margin-top:6px; font-size:.78rem; line-height:1.4; }
    code { background:#232234; border:1px solid #34324c; border-radius:6px; padding:2px 6px; color:var(--text); font-size:.9em; }
    .badge { display:inline-flex; align-items:center; border:1px solid var(--line); border-radius:999px; padding:5px 10px; font-size:.72rem; font-weight:850; line-height:1; text-transform:uppercase; }
    .badge.ok { color:var(--good); border-color:rgba(34,197,94,.34); background:rgba(34,197,94,.11); }
    .badge.warn { color:var(--warn); border-color:rgba(245,197,66,.34); background:rgba(245,197,66,.11); }
    .badge.off { color:var(--bad); border-color:rgba(251,113,133,.34); background:rgba(251,113,133,.11); }
    .badge.neutral { color:var(--soft); }
    .muted { color:var(--muted); }
    footer { color:var(--muted); text-align:center; font-size:.74rem; margin-top:18px; }
    @media (max-width: 700px) { .overview { grid-template-columns:1fr; } }
  </style>
</head>
<body>
  <main>
    <header>
      <h1>Hermes WebUI</h1>
      <div class="subtitle">Self-hosted Hermes Agent on HF Spaces</div>
    </header>
    <div class="row">
      <a class="hero-action" href="/" target="_blank" rel="noopener">Open Hermes WebUI -&gt;</a>
      <a class="hero-action secondary" href="${config.HM_PREFIX}/app/" target="_blank" rel="noopener">Open Hermes Dashboard</a>
    </div>
    <section class="overview">
      ${tiles}
    </section>
    <footer>Built on <a href="https://github.com/somratpro/HuggingMes" style="color:var(--accent)">HuggingMes</a> + <a href="https://github.com/nesquena/hermes-webui" style="color:var(--accent)">Hermes WebUI</a></footer>
  </main>
  <script>
    function formatLocalTimes(root) {
      root.querySelectorAll('.local-time').forEach(el => {
        const date = new Date(el.getAttribute('data-iso'));
        if (!isNaN(date)) el.textContent = 'At ' + date.toLocaleTimeString();
      });
    }
    formatLocalTimes(document);

    // First-party fragment; DOMParser → nodes (no innerHTML sink).
    const overview = document.querySelector('.overview');
    const POLL_MIN_MS = 2000;
    const POLL_MAX_MS = 10000;
    let polling = false;
    async function refreshTiles() {
      if (polling || document.hidden || !overview) return;
      polling = true;
      try {
        // redirect:'manual' prevents expired-session 302 from replacing tiles with login page.
        const res = await fetch('${config.HM_PREFIX}/tiles', { cache: 'no-store', redirect: 'manual' });
        if (!res.ok) return;
        const parsed = new DOMParser().parseFromString(await res.text(), 'text/html');
        overview.replaceChildren(...parsed.body.childNodes);
        formatLocalTimes(overview);
      } catch {
        // Transient network/auth hiccup — keep last good render, retry next tick.
      } finally {
        polling = false;
      }
    }
    // Jitter decorrelates polls across open tabs.
    function scheduleNext() {
      const delay = POLL_MIN_MS + Math.random() * (POLL_MAX_MS - POLL_MIN_MS);
      setTimeout(async () => {
        await refreshTiles();
        scheduleNext();
      }, delay);
    }
    scheduleNext();
    const inEmbeddedApp = (() => { try { return window.top !== window.self; } catch { return true; } })();
    const isDirectHfSpaceHost = /\.hf\.space$/i.test(window.location.hostname);
    const HF_SPACE_URL = ${JSON.stringify(config.HF_SPACE_URL)};
    let SPACE_IS_PRIVATE = ${JSON.stringify(config.isSpacePrivate())};

    function syncPrivacy() {
      return fetch('/api/is-private', { cache: 'no-store' })
        .then(r => r.json())
        .then(d => {
          if (d.isPrivate !== SPACE_IS_PRIVATE) {
            SPACE_IS_PRIVATE = d.isPrivate;
          }
          return d.isPrivate;
        })
        .catch(() => SPACE_IS_PRIVATE);
    }

    if (isDirectHfSpaceHost && !inEmbeddedApp) {
      syncPrivacy().then(isPrivate => {
        if (isPrivate) {
          setTimeout(syncPrivacy, 8000);
          setTimeout(syncPrivacy, 16000);
        }
      });
    }
  </script>
</body>
</html>`;
}

Object.assign(module.exports, {
  escapeHtml,
  renderPrivateRedirect,
  isDashboardAssetPath,
  renderLoginPage,
  toneBadge,
  valueOrUnset,
  renderTile,
  renderTiles,
  renderStatusPage,
});

"use strict";

const https = require("https");

const PORT = Number(process.env.PORT || 7861);
const GATEWAY_PORT = Number(process.env.API_SERVER_PORT || 8642);
const DASHBOARD_PORT = Number(process.env.DASHBOARD_PORT || 9119);
const TELEGRAM_WEBHOOK_PORT = Number(process.env.TELEGRAM_WEBHOOK_PORT || 8765);
const WEBUI_PORT = Number(process.env.HERMES_WEBUI_PORT || 8787);
const GATEWAY_HOST = "127.0.0.1";
const startTime = Date.now();
const API_SERVER_KEY = process.env.API_SERVER_KEY || "";
const WEBUI_HAS_PASSWORD = !!(process.env.HERMES_WEBUI_PASSWORD || "").trim(); // WebUI self-gates exec paths when its own auth is on, so defer for single-login; when off, router must gate (fail-closed) to preserve df307c7/09ab5f0.
const HM_PREFIX = "/hm";

const HMD_PREFIX = "/hmd";
const LOGIN_PATH = "/hm/login";
const SESSION_COOKIE = "hermes_session";
const PRIMARY_UI = (process.env.PRIMARY_UI || "webui").toLowerCase();

const SYNC_STATUS_FILE = "/tmp/hermes-sync-status.json";
const CLOUDFLARE_KEEPALIVE_STATUS_FILE =
  "/tmp/hermes-cloudflare-keepalive-status.json";

// ── Private Space redirect support ──
const SPACE_ID = (process.env.SPACE_ID || "").trim();
function deriveHfSpaceUrl() {
  if (SPACE_ID) return `https://huggingface.co/spaces/${SPACE_ID}`;
  const host = (process.env.SPACE_HOST || "").replace(/\.hf\.space$/i, "");
  const author = (process.env.SPACE_AUTHOR_NAME || "").trim().toLowerCase();
  if (author && host.toLowerCase().startsWith(author + "-")) {
    const spaceName = host.slice(author.length + 1);
    return `https://huggingface.co/spaces/${process.env.SPACE_AUTHOR_NAME}/${spaceName}`;
  }
  return "";
}
const HF_SPACE_URL = deriveHfSpaceUrl();

// Privacy detection: explicit SPACE_PRIVACY env > HF API auto-detect > fail-secure (private if SPACE_ID set)
const _spacPrivacyEnv = (process.env.SPACE_PRIVACY || "").trim().toLowerCase();
let SPACE_IS_PRIVATE;
let _privacyDetectionDone = false;
let _privacyDetectionResolve;
const privacyDetectionReady = new Promise((res) => { _privacyDetectionResolve = res; });

if (_spacPrivacyEnv === "public") {
  SPACE_IS_PRIVATE = false;
  _privacyDetectionDone = true;
  console.log("[health-server] Space privacy: public (SPACE_PRIVACY env override)");
  _privacyDetectionResolve();
} else if (_spacPrivacyEnv === "private") {
  SPACE_IS_PRIVATE = true;
  _privacyDetectionDone = true;
  console.log("[health-server] Space privacy: private (SPACE_PRIVACY env override)");
  _privacyDetectionResolve();
} else {
  // Fail-secure default until API call resolves
  SPACE_IS_PRIVATE = !!SPACE_ID;
}

async function detectSpacePrivacy() {
  if (_spacPrivacyEnv === "public" || _spacPrivacyEnv === "private") return;
  if (!SPACE_ID) {
    SPACE_IS_PRIVATE = false;
    _privacyDetectionDone = true;
    _privacyDetectionResolve();
    return;
  }
  const token = (process.env.HF_TOKEN || "").trim();
  const reqOptions = {
    hostname: "huggingface.co",
    path: `/api/spaces/${SPACE_ID}`,
    method: "GET",
    headers: Object.assign(
      { "User-Agent": "Hermes/health-server" },
      token ? { Authorization: `Bearer ${token}` } : {}
    ),
  };
  const MAX_ATTEMPTS = 5;
  let detected = false;
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
      const result = await new Promise((resolve) => {
        const r = https.request(reqOptions, (apiRes) => {
          let body = "";
          apiRes.on("data", (chunk) => { body += chunk; });
          apiRes.on("end", () => {
            try {
              if (apiRes.statusCode === 200) {
                SPACE_IS_PRIVATE = JSON.parse(body).private === true;
                resolve({ ok: true });
              } else if (apiRes.statusCode === 401 || apiRes.statusCode === 403) {
                SPACE_IS_PRIVATE = true;
                resolve({ ok: true });
              } else {
                resolve({ ok: false });
              }
            } catch { resolve({ ok: false }); }
          });
        });
        r.on("error", () => resolve({ ok: false }));
        r.setTimeout(8000, () => { r.destroy(); resolve({ ok: false }); });
        r.end();
      });
      console.log(`[health-server] Privacy detection attempt ${attempt}/${MAX_ATTEMPTS}: ok=${result.ok}`);
      if (result.ok) { detected = true; break; }
    } catch {}
    const delay = Math.min(2000 * attempt, 10000);
    if (attempt < MAX_ATTEMPTS) await new Promise((r) => setTimeout(r, delay));
  }
  if (!detected) {
    console.warn(`[health-server] Privacy detection failed after ${MAX_ATTEMPTS} attempts — defaulting to ${SPACE_IS_PRIVATE ? "private" : "public"}. TIP: Set SPACE_PRIVACY=public in Space secrets to skip API detection.`);
  } else {
    console.log(`[health-server] Space privacy detected: ${SPACE_IS_PRIVATE ? "private" : "public"}`);
  }
  _privacyDetectionDone = true;
  _privacyDetectionResolve();
}

// Kick off async privacy detection + periodic refresh. Called once by the entry
// (kept out of module load so require()-ing config has no network side effect).
function initPrivacyDetection() {
  if (_spacPrivacyEnv !== "public" && _spacPrivacyEnv !== "private") {
    detectSpacePrivacy();
    setInterval(detectSpacePrivacy, 5 * 60 * 1000);
  }
}

// SPACE_IS_PRIVATE / _privacyDetectionDone are mutated after load by
// detectSpacePrivacy; expose via accessors so consumers always read live values
// (a primitive export would freeze at import-time value).
function isSpacePrivate() { return SPACE_IS_PRIVATE; }
function isPrivacyDetectionDone() { return _privacyDetectionDone; }

module.exports = {
  PORT,
  GATEWAY_PORT,
  DASHBOARD_PORT,
  TELEGRAM_WEBHOOK_PORT,
  WEBUI_PORT,
  GATEWAY_HOST,
  startTime,
  API_SERVER_KEY,
  WEBUI_HAS_PASSWORD,
  HM_PREFIX,
  HMD_PREFIX,
  LOGIN_PATH,
  SESSION_COOKIE,
  PRIMARY_UI,
  SYNC_STATUS_FILE,
  CLOUDFLARE_KEEPALIVE_STATUS_FILE,
  SPACE_ID,
  HF_SPACE_URL,
  detectSpacePrivacy,
  initPrivacyDetection,
  isSpacePrivate,
  isPrivacyDetectionDone,
  privacyDetectionReady,
};

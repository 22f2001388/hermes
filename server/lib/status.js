"use strict";

const net = require("net");
const fs = require("fs");

const config = require("./config");

function canConnect(port, host = config.GATEWAY_HOST, timeoutMs = 600) {
  return new Promise((resolve) => {
    const socket = net.createConnection({ port, host });
    const done = (ok) => {
      socket.removeAllListeners();
      socket.destroy();
      resolve(ok);
    };
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => done(true));
    socket.once("timeout", () => done(false));
    socket.once("error", () => done(false));
  });
}

function readJson(path, fallback = null) {
  try {
    if (fs.existsSync(path)) return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch {}
  return fallback;
}

function formatUptime(ms) {
  const total = Math.floor(ms / 1000);
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (days) return `${days}d ${hours}h ${minutes}m`;
  if (hours) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

async function statusPayload() {
  const gateway = await canConnect(config.GATEWAY_PORT);
  const dashboard = await canConnect(config.DASHBOARD_PORT);
  const webui = await canConnect(config.WEBUI_PORT);
  const telegramWebhook =
    !!process.env.TELEGRAM_WEBHOOK_URL &&
    (await canConnect(config.TELEGRAM_WEBHOOK_PORT));
  const sync = readJson(
    config.SYNC_STATUS_FILE,
    process.env.HF_TOKEN
      ? { status: "configured", message: "Backup enabled; waiting for first sync." }
      : { status: "disabled", message: "HF_TOKEN is not configured." },
  );

  return {
    ok: gateway && webui,
    uptime: formatUptime(Date.now() - config.startTime),
    startedAt: new Date(config.startTime).toISOString(),
    gateway,
    dashboard,
    webui,
    authConfigured: !!config.API_SERVER_KEY,
    primaryUi: config.PRIMARY_UI,
    ports: {
      public: config.PORT,
      gateway: config.GATEWAY_PORT,
      dashboard: config.DASHBOARD_PORT,
      webui: config.WEBUI_PORT,
      telegramWebhook: config.TELEGRAM_WEBHOOK_PORT,
    },
    telegram: {
      configured: !!process.env.TELEGRAM_BOT_TOKEN,
      webhook: !!process.env.TELEGRAM_WEBHOOK_URL,
      webhookUrl: process.env.TELEGRAM_WEBHOOK_URL || "",
      webhookListening: telegramWebhook,
      proxy: process.env.CLOUDFLARE_PROXY_URL || "",
    },
    model:
      process.env.MODEL_FOR_CONFIG ||
      process.env.HERMES_MODEL ||
      process.env.LLM_MODEL ||
      "",
    provider:
      process.env.PROVIDER_FOR_CONFIG ||
      process.env.HERMES_INFERENCE_PROVIDER ||
      "auto",
    backup: sync,
    keepalive: readJson(config.CLOUDFLARE_KEEPALIVE_STATUS_FILE, null),
  };
}

Object.assign(module.exports, {
  canConnect,
  readJson,
  formatUptime,
  statusPayload,
});

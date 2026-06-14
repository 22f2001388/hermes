"use strict";

const crypto = require("crypto");

const config = require("./config");
// Required for their side of the auth<->proxy and auth<->views cycles; accessed
// via namespace at call time so circular load order is safe.
const proxy = require("./proxy");
const views = require("./views");

function timingSafeEqualString(left, right) {
  if (!left || !right) return false;
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function expectedSessionValue() {
  if (!config.API_SERVER_KEY) return "";
  return crypto
    .createHmac("sha256", config.API_SERVER_KEY)
    .update("hermes-session-v1")
    .digest("hex");
}

function parseCookies(req) {
  const header = req.headers.cookie || "";
  const cookies = {};
  for (const item of header.split(";")) {
    const sep = item.indexOf("=");
    if (sep < 0) continue;
    const name = item.slice(0, sep).trim();
    const value = item.slice(sep + 1).trim();
    if (!name) continue;
    try {
      cookies[name] = decodeURIComponent(value);
    } catch {
      cookies[name] = value;
    }
  }
  return cookies;
}

function isHttpsRequest(req) {
  return req.headers["x-forwarded-proto"] === "https";
}

function buildSessionCookie(req) {
  const secure = isHttpsRequest(req) ? "; Secure" : "";
  return `${config.SESSION_COOKIE}=${encodeURIComponent(expectedSessionValue())}; Path=/; HttpOnly; SameSite=Strict; Max-Age=86400${secure}`;
}

function getBearerToken(req) {
  const value = req.headers.authorization || "";
  const match = /^Bearer\s+(.+)$/i.exec(value);
  return match ? match[1] : "";
}

function isAuthorized(req) {
  if (!config.API_SERVER_KEY) return true;
  return (
    timingSafeEqualString(getBearerToken(req), config.API_SERVER_KEY) ||
    timingSafeEqualString(
      parseCookies(req)[config.SESSION_COOKIE],
      expectedSessionValue(),
    )
  );
}

function sanitizeNext(value, fallback = "/") {
  if (!value || typeof value !== "string") return fallback;
  if (!value.startsWith("/") || value.startsWith("//")) return fallback;
  return value;
}

function loginUrl(nextPath) {
  return `${config.LOGIN_PATH}?next=${encodeURIComponent(sanitizeNext(nextPath))}`;
}

function wantsHtml(req) {
  const accept = String(req.headers.accept || "");
  return accept.includes("text/html");
}

async function handleLogin(req, res, parsed) {
  const nextPath = sanitizeNext(parsed.searchParams.get("next") || "/", "/");

  if (!config.API_SERVER_KEY) {
    proxy.redirect(res, nextPath);
    return;
  }

  if (req.method === "GET") {
    res.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    });
    res.end(views.renderLoginPage(nextPath));
    return;
  }

  if (req.method !== "POST") {
    res.writeHead(405, { allow: "GET, POST" });
    res.end("Method not allowed");
    return;
  }

  try {
    const body = await proxy.readRequestBody(req);
    const params = new URLSearchParams(body);
    const submittedToken = params.get("token") || "";
    const submittedNext = sanitizeNext(params.get("next") || nextPath, "/");

    if (!timingSafeEqualString(submittedToken, config.API_SERVER_KEY)) {
      res.writeHead(401, {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
      });
      res.end(
        views.renderLoginPage(
          submittedNext,
          "That token did not match GATEWAY_TOKEN.",
        ),
      );
      return;
    }

    res.writeHead(302, {
      location: submittedNext,
      "set-cookie": buildSessionCookie(req),
      "cache-control": "no-store",
    });
    res.end();
  } catch (error) {
    res.writeHead(400, {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
    });
    res.end(error.message || "Invalid login request.");
  }
}

function requireAuth(req, res) {
  if (isAuthorized(req)) return true;
  const parsed = new URL(req.url, "http://localhost");
  proxy.redirect(res, loginUrl(`${parsed.pathname}${parsed.search}`));
  return false;
}

Object.assign(module.exports, {
  timingSafeEqualString,
  expectedSessionValue,
  parseCookies,
  isHttpsRequest,
  buildSessionCookie,
  getBearerToken,
  isAuthorized,
  sanitizeNext,
  loginUrl,
  wantsHtml,
  handleLogin,
  requireAuth,
});

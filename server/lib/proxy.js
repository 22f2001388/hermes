"use strict";

const http = require("http");
const net = require("net");

const config = require("./config");
// auth side of the auth<->proxy cycle; accessed via namespace at call time.
const auth = require("./auth");

function readRequestBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > limit) {
        reject(new Error("Request body is too large."));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

// WebUI exec/terminal surface — RCE-class, gated at the router before the
// unauthenticated WebUI proxy fallback (HTTP and WebSocket upgrade).
const WEBUI_EXEC_PATHS = new Set([
  "/api/terminal/start",
// RCE-class paths — gated at router before unauthenticated WebUI proxy fallback.
  "/api/terminal/close",
  "/api/terminal/output",
  "/api/commands/exec",
]);
function isWebuiExecPath(path) {
  const normalized = path.length > 1 ? path.replace(/\/+$/, "") : path;
  return WEBUI_EXEC_PATHS.has(normalized);
}

function proxyRequest(
  req,
  res,
  targetPort,
  rewritePath = (path) => path,
  headerOverrides = {},
) {
  const parsed = new URL(req.url, "http://localhost");
  const targetPath = rewritePath(parsed.pathname) + parsed.search;
  const localOrigin = `http://${config.GATEWAY_HOST}:${targetPort}`;

  const hasBody = req.method === "POST" || req.method === "PUT" || req.method === "PATCH";

  if (hasBody) {
    const chunks = [];
    let size = 0;

    const limit = 20 * 1024 * 1024;
    req.on("data", (chunk) => {
      chunks.push(chunk);
      size += chunk.length;
      if (size > limit) {
        req.destroy();
        if (!res.headersSent) {
          res.writeHead(413, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: "payload_too_large" }));
        }
      }
    });

    req.on("end", () => {
      const body = Buffer.concat(chunks, size);
      const headers = {
        ...req.headers,
        ...headerOverrides,
        host: `${config.GATEWAY_HOST}:${targetPort}`,
        origin: localOrigin,
        "x-forwarded-host": req.headers.host || "",
        "x-forwarded-proto": req.headers["x-forwarded-proto"] || "https",
      };
      delete headers["transfer-encoding"];
      headers["content-length"] = String(size);

      const proxy = http.request(
        {
          hostname: config.GATEWAY_HOST,
          port: targetPort,
          method: req.method,
          path: targetPath,
          headers,
        },
        (upstream) => {
          res.writeHead(upstream.statusCode || 502, upstream.headers);
          upstream.pipe(res);
        },
      );

      proxy.on("error", (error) => {
        if (!res.headersSent) {
          res.writeHead(502, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: "proxy_error", message: error.message }));
        }
      });

      if (size > 0) proxy.write(body);
      proxy.end();
    });

    req.on("error", (error) => {
      if (!res.headersSent) {
        res.writeHead(502, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "proxy_error", message: error.message }));
      }
    });

    return;
  }

  const headers = {
    ...req.headers,
    ...headerOverrides,
    host: `${config.GATEWAY_HOST}:${targetPort}`,
    origin: localOrigin,
    "x-forwarded-host": req.headers.host || "",
    "x-forwarded-proto": req.headers["x-forwarded-proto"] || "https",
  };

  const proxy = http.request(
    {
      hostname: config.GATEWAY_HOST,
      port: targetPort,
      method: req.method,
      path: targetPath,
      headers,
    },
    (upstream) => {
      res.writeHead(upstream.statusCode || 502, upstream.headers);
      upstream.pipe(res);
    },
  );

  proxy.on("error", (error) => {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "proxy_error", message: error.message }));
  });

  req.pipe(proxy);
}

function redirect(res, location, statusCode = 302) {
  res.writeHead(statusCode, { location });
  res.end();
}

function _rewriteDashboardBody(upRes, res, rawBuffer) {
  let body = rawBuffer.toString("utf8");
  body = body.replace(
    /window\.__HERMES_BASE_PATH__\s*=\s*"[^"]*"/g,
    `window.__HERMES_BASE_PATH__="${config.HM_PREFIX}/app"`,
  );
  const prefix = `${config.HM_PREFIX}/app`;
  body = body.replace(
    /\b(src|href)="\/(?!\/|http)([^"]*)"/g,
    (match, attr, rest) => {
      if (("/" + rest).startsWith(prefix + "/") || "/" + rest === prefix) return match;
      return `${attr}="${prefix}/${rest}"`;
    },
  );
  const buf = Buffer.from(body, "utf8");
  const outHeaders = { ...upRes.headers };
  delete outHeaders["content-length"];
  delete outHeaders["transfer-encoding"];
  delete outHeaders["content-encoding"];
  outHeaders["content-length"] = String(buf.length);
  res.writeHead(upRes.statusCode || 502, outHeaders);
  res.end(buf);
}
function proxyDashboard(req, res) {
  const parsed = new URL(req.url, "http://localhost");
  const inner = parsed.pathname.replace(`${config.HM_PREFIX}/app`, "") || "/";

  const isAssetLike =
    inner.startsWith("/assets/") ||
    inner.startsWith("/api/") ||
    inner.startsWith("/dashboard-plugins/") ||
    inner.startsWith("/ds-assets/") ||
    /\.[a-z0-9]{1,6}$/i.test(inner);

  const targetPath =
    (isAssetLike || inner === "/" ? inner : "/") + parsed.search;

  const hasBody = req.method === "POST" || req.method === "PUT" || req.method === "PATCH";

  if (hasBody) {
    const chunks = [];
    let size = 0;
    const limit = 20 * 1024 * 1024;

    req.on("data", (chunk) => {
      chunks.push(chunk);
      size += chunk.length;
      if (size > limit) {
        req.destroy();
        if (!res.headersSent) {
          res.writeHead(413, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: "payload_too_large" }));
        }
      }
    });

    req.on("end", () => {
      const body = Buffer.concat(chunks, size);
      const headers = {
        ...req.headers,
        host: `${config.GATEWAY_HOST}:${config.DASHBOARD_PORT}`,
        origin: `http://${config.GATEWAY_HOST}:${config.DASHBOARD_PORT}`,
        "x-forwarded-host": req.headers.host || "",
        "x-forwarded-proto": req.headers["x-forwarded-proto"] || "https",
        "accept-encoding": "identity",
      };
      delete headers["transfer-encoding"];
      headers["content-length"] = String(size);

      const upstream = http.request(
        {
          hostname: config.GATEWAY_HOST,
          port: config.DASHBOARD_PORT,
          method: req.method,
          path: targetPath,
          headers,
        },
        (upRes) => {
          const contentType = String(upRes.headers["content-type"] || "");
          const shouldRewrite =
            contentType.includes("text/html") ||
            contentType.includes("application/xhtml");

          if (!shouldRewrite) {
            res.writeHead(upRes.statusCode || 502, upRes.headers);
            upRes.pipe(res);
            return;
          }

          const chunks = [];
          upRes.on("data", (chunk) => chunks.push(chunk));
          upRes.on("end", () => _rewriteDashboardBody(upRes, res, Buffer.concat(chunks)));
          upRes.on("error", () => { try { res.writeHead(502); res.end(); } catch {} });
        },
      );

      upstream.on("error", (error) => {
        if (!res.headersSent) {
          res.writeHead(502, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: "proxy_error", message: error.message }));
        }
      });

      if (size > 0) upstream.write(body);
      upstream.end();
    });

    req.on("error", (error) => {
      if (!res.headersSent) {
        res.writeHead(502, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "proxy_error", message: error.message }));
      }
    });

    return;
  }

  const headers = {
    ...req.headers,
    host: `${config.GATEWAY_HOST}:${config.DASHBOARD_PORT}`,
    origin: `http://${config.GATEWAY_HOST}:${config.DASHBOARD_PORT}`,
    "x-forwarded-host": req.headers.host || "",
    "x-forwarded-proto": req.headers["x-forwarded-proto"] || "https",

    "accept-encoding": "identity",
  };

  const upstream = http.request(
    {
      hostname: config.GATEWAY_HOST,
      port: config.DASHBOARD_PORT,
      method: req.method,
      path: targetPath,
      headers,
    },
    (upRes) => {
      const contentType = String(upRes.headers["content-type"] || "");
      const shouldRewrite =
        contentType.includes("text/html") ||
        contentType.includes("application/xhtml");

      if (!shouldRewrite) {
        res.writeHead(upRes.statusCode || 502, upRes.headers);
        upRes.pipe(res);
        return;
      }

      const chunks = [];
      upRes.on("data", (chunk) => chunks.push(chunk));
      upRes.on("end", () => _rewriteDashboardBody(upRes, res, Buffer.concat(chunks)));
      upRes.on("error", () => { try { res.writeHead(502); res.end(); } catch {} });
    },
  );

  upstream.on("error", (error) => {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "proxy_error", message: error.message }));
  });

  req.pipe(upstream);
}

function handleUpgrade(req, clientSocket, head) {
  const parsed = new URL(req.url, "http://localhost");
  const path = parsed.pathname;

  // Exec auth gate for WS upgrade — no res object, reject socket directly.
  if (isWebuiExecPath(path) && !config.WEBUI_HAS_PASSWORD && !auth.isAuthorized(req)) {
    try {
      clientSocket.end("HTTP/1.1 401 Unauthorized\r\n\r\n");
    } catch {}
    return;
  }

  let targetPort = config.WEBUI_PORT;
  let targetPath = req.url;

  const refererPath = (() => {
    const ref = String(req.headers.referer || "");
    if (!ref) return "";
    try {
      return new URL(ref).pathname;
    } catch {
      return "";
    }
  })();
  const refererIsDashboard = refererPath.startsWith(`${config.HM_PREFIX}/app`);

  if (path === "/v1" || path.startsWith("/v1/")) {
    targetPort = config.GATEWAY_PORT;
  } else if (path === config.HMD_PREFIX || path.startsWith(`${config.HMD_PREFIX}/`)) {

    targetPort = config.DASHBOARD_PORT;
    targetPath = path.replace(config.HMD_PREFIX, "") || "/";
    if (parsed.search) targetPath += parsed.search;
  } else if (path === `${config.HM_PREFIX}/app` || path.startsWith(`${config.HM_PREFIX}/app/`)) {
    targetPort = config.DASHBOARD_PORT;
    targetPath = path.replace(`${config.HM_PREFIX}/app`, "") || "/";
    if (parsed.search) targetPath += parsed.search;
  } else if (refererIsDashboard && !path.startsWith("/webui")) {
    targetPort = config.DASHBOARD_PORT;
  } else if (path.startsWith("/webui/") || path === "/webui") {
    targetPort = config.WEBUI_PORT;
    targetPath = path.replace(/^\/webui/, "") || "/";
    if (parsed.search) targetPath += parsed.search;
  }

  const localHost = `${config.GATEWAY_HOST}:${targetPort}`;
  const upstream = net.createConnection(targetPort, config.GATEWAY_HOST, () => {

    // Rewrite Host/Origin so backends accept WS handshake (HF proxy sends <space>.hf.space).
    const headerLines = [
      `${req.method} ${targetPath} HTTP/1.1`,
      `X-Forwarded-Host: ${req.headers.host || ""}`,
      `X-Forwarded-Proto: ${req.headers["x-forwarded-proto"] || "https"}`,
    ];
    for (const [name, value] of Object.entries(req.headers)) {
      // Skip inbound forwarded headers — re-injected above to avoid duplicates.
      const lower = name.toLowerCase();
      if (lower === "x-forwarded-host" || lower === "x-forwarded-proto") continue;
      // Dashboard origin guard checks Origin against its own host.
      if (lower === "host") {
        headerLines.push(`Host: ${localHost}`);
        continue;
      }
      if (lower === "origin") {
        headerLines.push(`Origin: http://${localHost}`);
        continue;
      }
      if (Array.isArray(value)) {
        for (const v of value) headerLines.push(`${name}: ${v}`);
      } else {
        headerLines.push(`${name}: ${value}`);
      }
    }
    headerLines.push("", "");
    upstream.write(headerLines.join("\r\n"));
    if (head && head.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });

  upstream.on("error", () => {
    try {
      clientSocket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
    } catch {}
  });
  clientSocket.on("error", () => {
    try {
      upstream.destroy();
    } catch {}
  });
}

Object.assign(module.exports, {
  readRequestBody,
  proxyRequest,
  redirect,
  proxyDashboard,
  WEBUI_EXEC_PATHS,
  isWebuiExecPath,
  handleUpgrade,
});

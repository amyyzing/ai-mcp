import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import { Readable } from "node:stream";
import test from "node:test";

import {
  BRIDGE_AUTH_HEADER,
  getBridgeAuthToken,
  isAllowedRequestOrigin,
  isAuthorizedBridgeRequest,
  requiresBridgeAuth,
  setSecurityHeaders,
} from "../dist/http/bridge-auth.js";
import {
  RequestBodyTooLargeError,
  readBody,
} from "../dist/http/body.js";
import { normalizeClientRegistration } from "../dist/http/client-registration.js";
import { CLIENT_AUTH_HEADER } from "../dist/http/client-auth.js";
import { dispatchHttp, loadRoutes } from "../dist/http/router.js";
import {
  clearScriptSourceIndex,
  getCachedScriptSourcesByScriptHashResult,
  getScriptSourceIndex,
  upsertScriptSources,
} from "../dist/bridge/handlers/shared/script-source-store.js";
import { resetRegistry } from "../dist/bridge/handlers/shared/registry.js";
import { GET as getAvatar } from "../dist/http/routes/api/avatar.js";
import {
  buildLoaderSnippet,
  normalizeBridgeUrl,
} from "../dist/shared/connector-snippet.mjs";

function request({
  address = "127.0.0.1",
  host = "127.0.0.1:16384",
  origin,
  fetchSite,
  token,
  url = "/mcp",
} = {}) {
  return {
    url,
    socket: { remoteAddress: address },
    headers: {
      host,
      ...(origin ? { origin } : {}),
      ...(fetchSite ? { "sec-fetch-site": fetchSite } : {}),
      ...(token ? { [BRIDGE_AUTH_HEADER]: token } : {}),
    },
  };
}

test("loader snippets preserve an explicitly configured HTTPS bridge", () => {
  assert.equal(normalizeBridgeUrl("https://bridge.example"), "https://bridge.example:16384");
  const snippet = buildLoaderSnippet("https://bridge.example");
  assert.match(snippet, /BridgeURL = "https:\/\/bridge\.example:16384"/);
  assert.match(snippet, /string\.match\(bridgeUrl, "\^https\?:\/\/"\)/);
  assert.doesNotMatch(snippet, /http:\/\/https:\/\//);
});

test("bridge auth preserves local clients and pairs remote clients", () => {
  const remote = request({ address: "192.168.1.50" });
  assert.equal(isAuthorizedBridgeRequest(remote, new URL("http://host/mcp")), false);

  const paired = request({
    address: "192.168.1.50",
    token: getBridgeAuthToken(),
  });
  assert.equal(isAuthorizedBridgeRequest(paired, new URL("http://host/mcp")), true);

  const queryOnly = request({ address: "192.168.1.50" });
  assert.equal(
    isAuthorizedBridgeRequest(
      queryOnly,
      new URL(`http://host/api/tool?token=${getBridgeAuthToken()}`)
    ),
    false
  );
  assert.equal(
    isAuthorizedBridgeRequest(
      queryOnly,
      new URL(`http://host/script.luau?token=${getBridgeAuthToken()}`)
    ),
    true
  );

  for (const pathname of [
    "/mcp",
    "/mcp-relay",
    "/register",
    "/poll",
    "/respond",
    "/script-sources",
    "/api/tool",
    "/api/status",
  ]) {
    assert.equal(requiresBridgeAuth(pathname), true, pathname);
  }
  assert.equal(requiresBridgeAuth("/api/admin-session"), false);
  assert.equal(requiresBridgeAuth("/dashboard.js"), false);
});

test("browser origins must match the requested host", () => {
  assert.equal(
    isAllowedRequestOrigin(
      request({ origin: "http://127.0.0.1:16384", fetchSite: "same-origin" })
    ),
    true
  );
  assert.equal(
    isAllowedRequestOrigin(
      request({ origin: "https://attacker.example", fetchSite: "cross-site" })
    ),
    false
  );
  assert.equal(
    isAllowedRequestOrigin(
      request({ origin: "https://attacker.example", fetchSite: "same-origin" })
    ),
    false
  );
  assert.equal(
    isAllowedRequestOrigin(
      request({
        host: "attacker.example:16384",
        origin: "http://attacker.example:16384",
        fetchSite: "same-origin",
      })
    ),
    false,
    "same-origin DNS rebinding hosts must not be treated as loopback"
  );
  assert.equal(isAllowedRequestOrigin(request()), true, "non-browser clients omit Origin");
});

test("responses receive browser hardening headers", () => {
  const headers = new Map();
  setSecurityHeaders({ setHeader: (name, value) => headers.set(name, value) });
  assert.equal(headers.get("X-Content-Type-Options"), "nosniff");
  assert.equal(headers.get("X-Frame-Options"), "DENY");
  assert.match(headers.get("Content-Security-Policy"), /frame-ancestors 'none'/);
  assert.doesNotMatch(
    headers.get("Content-Security-Policy"),
    /script-src[^;]*unsafe-inline/
  );
});

test("streamed and declared oversized bodies are rejected", async () => {
  const streamed = Readable.from([Buffer.alloc(9)]);
  streamed.url = "/register";
  streamed.headers = {};
  await assert.rejects(readBody(streamed, 8), RequestBodyTooLargeError);

  const declared = Readable.from([]);
  declared.url = "/register";
  declared.headers = { "content-length": "9" };
  await assert.rejects(readBody(declared, 8), RequestBodyTooLargeError);
});

test("chunked oversized HTTP requests receive 413", async (t) => {
  await loadRoutes();
  const server = http.createServer((req, res) => void dispatchHttp(req, res));
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  t.after(() => new Promise((resolve) => server.close(resolve)));

  const address = server.address();
  assert.ok(address && typeof address === "object");
  const status = await new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: "127.0.0.1",
        port: address.port,
        path: "/mcp",
        method: "POST",
        headers: { "Content-Type": "application/json" },
      },
      (res) => {
        res.resume();
        res.once("end", () => resolve(res.statusCode));
      }
    );
    req.once("error", reject);
    req.write(Buffer.alloc(1024 * 1024));
    req.write(Buffer.alloc(1024 * 1024 + 1));
    req.end();
  });
  assert.equal(status, 413);
});

test("per-client credentials isolate connector HTTP routes and session resume", async (t) => {
  await loadRoutes();
  resetRegistry();
  const server = http.createServer((req, res) => void dispatchHttp(req, res));
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  t.after(async () => {
    resetRegistry();
    await new Promise((resolve) => server.close(resolve));
  });
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const baseUrl = `http://127.0.0.1:${address.port}`;
  const bridgeHeaders = {
    [BRIDGE_AUTH_HEADER]: getBridgeAuthToken(),
    "Content-Type": "application/json",
  };

  const firstResponse = await fetch(`${baseUrl}/register`, {
    method: "POST",
    headers: bridgeHeaders,
    body: JSON.stringify({ username: "one", sessionId: "stable-session" }),
  });
  assert.equal(firstResponse.status, 200);
  const first = await firstResponse.json();
  assert.equal(typeof first.clientId, "string");
  assert.equal(typeof first.clientToken, "string");

  const sourceBody = JSON.stringify({ clientId: first.clientId, scripts: [] });
  const missingCredential = await fetch(`${baseUrl}/script-sources`, {
    method: "POST",
    headers: bridgeHeaders,
    body: sourceBody,
  });
  assert.equal(missingCredential.status, 403);

  const accepted = await fetch(`${baseUrl}/script-sources`, {
    method: "POST",
    headers: { ...bridgeHeaders, [CLIENT_AUTH_HEADER]: first.clientToken },
    body: sourceBody,
  });
  assert.equal(accepted.status, 200);

  const hijack = await fetch(`${baseUrl}/register`, {
    method: "POST",
    headers: bridgeHeaders,
    body: JSON.stringify({ username: "attacker", sessionId: "stable-session" }),
  });
  assert.equal(hijack.status, 403);

  const resumedResponse = await fetch(`${baseUrl}/register`, {
    method: "POST",
    headers: bridgeHeaders,
    body: JSON.stringify({
      username: "one",
      sessionId: "stable-session",
      clientToken: first.clientToken,
    }),
  });
  assert.equal(resumedResponse.status, 200);
  const resumed = await resumedResponse.json();
  assert.equal(resumed.clientId, first.clientId);
  assert.notEqual(resumed.clientToken, first.clientToken);

  const staleCredential = await fetch(`${baseUrl}/script-sources`, {
    method: "POST",
    headers: { ...bridgeHeaders, [CLIENT_AUTH_HEADER]: first.clientToken },
    body: sourceBody,
  });
  assert.equal(staleCredential.status, 403);
});

test("connector registration metadata is bounded and typed", () => {
  const normalized = normalizeClientRegistration({
    username: 42,
    userId: Number.POSITIVE_INFINITY,
    placeId: -1,
    jobId: `job\u0000${"x".repeat(300)}`,
    placeName: { toString: () => "unsafe" },
    sessionId: "s".repeat(300),
  });
  assert.equal(normalized.username, "Unknown");
  assert.equal(normalized.userId, 0);
  assert.equal(normalized.placeId, 0);
  assert.equal(normalized.jobId.includes("\u0000"), false);
  assert.equal(normalized.jobId.length, 160);
  assert.equal(normalized.placeName, "Unknown");
  assert.equal(normalized.sessionId.length, 160);
});

test("per-script source limits reject oversized source payloads", () => {
  const identity = {
    clientId: "security-source-limit",
    placeId: 1,
    jobId: "job",
  };
  try {
    upsertScriptSources(identity, {
      scripts: [
        {
          debugId: "oversized",
          path: "Workspace.Oversized",
          source: "x".repeat(2 * 1024 * 1024 + 1),
        },
      ],
    });
    assert.equal(getScriptSourceIndex(identity).scripts.length, 0);
  } finally {
    clearScriptSourceIndex(identity.clientId);
  }
});

test("script hash cache responses are bounded", () => {
  const identity = {
    clientId: "security-cache-limit",
    placeId: 1,
    jobId: "job",
  };
  try {
    const scripts = Array.from({ length: 65 }, (_, index) => ({
      debugId: `debug-${index}`,
      path: `Workspace.Script${index}`,
      source: `return ${index}`,
      scriptHash: `hash-${index}`,
    }));
    upsertScriptSources(identity, { scripts });
    const result = getCachedScriptSourcesByScriptHashResult(
      identity,
      scripts.map((script) => script.scriptHash)
    );
    assert.equal(result.sources.length, 64);
    assert.equal(result.limited, true);
    assert.equal(result.omitted, 1);
  } finally {
    clearScriptSourceIndex(identity.clientId);
  }
});

test("dashboard escapes connector-controlled client metadata", async () => {
  const source = await fs.readFile(
    new URL("../src/http/assets/dashboard/dashboard.js", import.meta.url),
    "utf8"
  );
  assert.doesNotMatch(source, /onerror=/i);
  assert.doesNotMatch(source, />\$\{c\.username\}</);
  assert.doesNotMatch(source, />\$\{c\.placeName\}/);
  assert.doesNotMatch(source, /data-cid="\$\{c\.clientId\}"/);
  assert.match(source, /escapeHtml\(c\.username\)/);
  assert.match(source, /escapeHtml\(c\.placeName\)/);
});

test("avatar proxy validates IDs and returns bounded same-origin image bytes", async (t) => {
  const calls = [];
  t.mock.method(globalThis, "fetch", async (input) => {
    calls.push(String(input));
    if (String(input).startsWith("https://thumbnails.roblox.com/")) {
      return new Response(
        JSON.stringify({ data: [{ imageUrl: "https://tr.rbxcdn.com/avatar.png" }] }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }
    return new Response(Buffer.from([0x89, 0x50, 0x4e, 0x47]), {
      status: 200,
      headers: { "Content-Type": "image/png" },
    });
  });

  const response = {
    status: 0,
    headers: {},
    body: undefined,
    writeHead(status, headers = {}) {
      this.status = status;
      this.headers = headers;
    },
    end(body) {
      this.body = body;
    },
  };
  await getAvatar(
    {},
    response,
    new URL("http://127.0.0.1/api/avatar?userId=123")
  );
  assert.equal(response.status, 200);
  assert.equal(response.headers["Content-Type"], "image/png");
  assert.deepEqual(response.body, Buffer.from([0x89, 0x50, 0x4e, 0x47]));
  assert.equal(calls.length, 2);

  const invalid = {
    status: 0,
    writeHead(status) { this.status = status; },
    end() {},
  };
  await getAvatar(
    {},
    invalid,
    new URL("http://127.0.0.1/api/avatar?userId=1%26size%3D999")
  );
  assert.equal(invalid.status, 400);
  assert.equal(calls.length, 2, "invalid IDs must not trigger an upstream fetch");
});

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs/promises";
import http from "node:http";
import { Readable } from "node:stream";
import test from "node:test";

import {
  BRIDGE_AUTH_HEADER,
  getBridgeAuthToken,
  getConnectorAuthToken,
  isAllowedRequestOrigin,
  isAuthorizedBridgeRequest,
  requiresBridgeAuth,
  setSecurityHeaders,
} from "../dist/http/bridge-auth.js";
import {
  RequestBodyTooLargeError,
  readBody,
  requestBodyLimit,
} from "../dist/http/body.js";
import {
  HTTP_BODY_LIMIT_BYTES,
  SCRIPT_UPLOAD_BODY_LIMIT_BYTES,
} from "../dist/config.js";
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
  buildHostedLoaderSnippet,
  buildOneLineLoaderSnippet,
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

function runAuthFixture(source, environment = {}) {
  const result = spawnSync(process.execPath, ["--input-type=module", "--eval", source], {
    cwd: new URL("../", import.meta.url),
    encoding: "utf8",
    timeout: 10000,
    env: {
      ...process.env,
      ROBLOX_MCP_AUTH_TOKEN: "agent-only-test-token",
      ROBLOX_MCP_CONNECTOR_TOKEN: "connector-only-test-token",
      ROBLOX_MCP_HOST: "127.0.0.1",
      ROBLOX_MCP_ALLOWED_HOSTS: "",
      ROBLOX_MCP_PUBLIC_LOADER: "",
      RAILWAY_PUBLIC_DOMAIN: "",
      RAILWAY_ENVIRONMENT_ID: "",
      RAILWAY_PROJECT_ID: "",
      ...environment,
    },
  });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  return JSON.parse(result.stdout);
}

test("loader snippets preserve an explicitly configured HTTPS bridge", () => {
  assert.equal(normalizeBridgeUrl("https://bridge.example"), "https://bridge.example");
  assert.equal(normalizeBridgeUrl("wss://bridge.example/socket"), "wss://bridge.example");
  assert.equal(normalizeBridgeUrl("bridge.example"), "bridge.example:16384");
  const snippet = buildLoaderSnippet("https://bridge.example");
  assert.match(snippet, /BridgeURL = "https:\/\/bridge\.example"/);
  assert.match(snippet, /string\.match\(bridgeUrl, "\^https\?:\/\/"\)/);
  assert.doesNotMatch(snippet, /http:\/\/https:\/\//);
  assert.match(snippet, /HttpService:UrlEncode\(token\)/);
  assert.match(snippet, /Connector attempt/);
  assert.match(snippet, /assert\(chunk, compileError/);
});

test("one-line loader is copyable on PC and mobile without committing a credential", () => {
  const snippet = buildOneLineLoaderSnippet("https://bridge.example");
  assert.equal(snippet.includes("\n"), false);
  assert.match(snippet, /getgenv\(\)\.BridgeURL="https:\/\/bridge\.example"/);
  assert.match(snippet, /game:HttpGet\(u\)/);
  assert.match(snippet, /getgenv\(\)\.MCPAuthToken/);
  assert.match(snippet, /HttpService/);
  assert.doesNotMatch(snippet, /replace-with|example-secret|ROBLOX_MCP_AUTH_TOKEN/);
});

test("hosted loader keeps the permanent credential out of the pasted command", () => {
  const snippet = buildHostedLoaderSnippet("https://bridge.example");
  assert.equal(
    snippet,
    'loadstring(game:HttpGet("https://bridge.example/loader.luau"))()'
  );
  assert.doesNotMatch(snippet, /MCPAuthToken|token=/);
});

test("connector setup can inject a connector-scoped token without changing the source template", () => {
  const snippet = buildOneLineLoaderSnippet("https://bridge.example", "connector-only");
  assert.match(snippet, /^getgenv\(\)\.MCPAuthToken="connector-only";/);
  assert.equal(getConnectorAuthToken(), getBridgeAuthToken());
});

test("configured connector and agent credentials cannot substitute for each other", async () => {
  const previousAgent = process.env.ROBLOX_MCP_AUTH_TOKEN;
  const previousConnector = process.env.ROBLOX_MCP_CONNECTOR_TOKEN;
  process.env.ROBLOX_MCP_AUTH_TOKEN = "agent-only-test-token";
  process.env.ROBLOX_MCP_CONNECTOR_TOKEN = "connector-only-test-token";
  try {
    const isolated = await import(
      `../dist/http/bridge-auth.js?credential-split=${Date.now()}`
    );
    const connectorRequest = request({
      address: "192.168.1.50",
      token: "connector-only-test-token",
      url: "/register",
    });
    const agentRequest = request({
      address: "192.168.1.50",
      token: "agent-only-test-token",
      url: "/mcp",
    });
    assert.equal(
      isolated.isAuthorizedBridgeRequest(
        connectorRequest,
        new URL("http://host/register")
      ),
      true
    );
    assert.equal(
      isolated.isAuthorizedBridgeRequest(
        agentRequest,
        new URL("http://host/register")
      ),
      false
    );
    assert.equal(
      isolated.isAuthorizedBridgeRequest(agentRequest, new URL("http://host/mcp")),
      true
    );
    assert.equal(
      isolated.isAuthorizedBridgeRequest(
        connectorRequest,
        new URL("http://host/mcp")
      ),
      false
    );
  } finally {
    if (previousAgent === undefined) delete process.env.ROBLOX_MCP_AUTH_TOKEN;
    else process.env.ROBLOX_MCP_AUTH_TOKEN = previousAgent;
    if (previousConnector === undefined) delete process.env.ROBLOX_MCP_CONNECTOR_TOKEN;
    else process.env.ROBLOX_MCP_CONNECTOR_TOKEN = previousConnector;
  }
});

test("WebSocket upgrades cannot turn agent routes into connector access", () => {
  const result = runAuthFixture(`
    import assert from "node:assert/strict";
    import { isAuthorizedBridgeRequest } from "./dist/http/bridge-auth.js";
    const agent = "agent-only-test-token";
    const connector = "connector-only-test-token";
    function allowed(path, token, upgrade, query = false, bearer = false) {
      const url = new URL(path, "http://bridge.example");
      if (query) url.searchParams.set("token", token);
      const headers = {host: "bridge.example"};
      if (upgrade) headers.upgrade = "WebSocket";
      if (!query && token) {
        if (bearer) headers.authorization = "Bearer " + token;
        else headers["x-roblox-mcp-token"] = token;
      }
      return isAuthorizedBridgeRequest({
        method: "GET", url: url.pathname + url.search,
        socket: {remoteAddress: "192.0.2.1"}, headers,
      }, url);
    }
    for (const path of ["/mcp", "/mcp-relay", "/api/tool", "/api/status", "/api/admin-session"]) {
      for (const upgrade of [false, true]) {
        assert.equal(allowed(path, connector, upgrade), false, path + " connector header");
        assert.equal(allowed(path, agent, upgrade), true, path + " agent header");
        assert.equal(allowed(path, agent, upgrade, false, true), true, path + " agent bearer");
        assert.equal(allowed(path, agent, upgrade, true), false, path + " agent query");
        assert.equal(allowed(path, connector, upgrade, true), false, path + " connector query");
      }
    }
    for (const path of ["/", "/connector", "/legacy-socket", "/register"]) {
      assert.equal(allowed(path, connector, true), true, path + " fallback header");
      assert.equal(allowed(path, connector, true, true), true, path + " fallback query");
      assert.equal(allowed(path, agent, true), false, path + " wrong fallback scope");
      assert.equal(allowed(path, connector, false, true), false, path + " HTTP query");
    }
    assert.equal(allowed("/script.luau", connector, false, true), true);
    assert.equal(allowed("/script.luau", agent, false, true), false);
    console.log(JSON.stringify({ok: true}));
  `);
  assert.equal(result.ok, true);
});

test("hosted loader never publishes an absent or shared agent credential", () => {
  const fixture = `
    import { GET } from "./dist/http/routes/loader.luau.js";
    let status, headers, body;
    GET({headers: {host: "127.0.0.1:16384"}}, {
      writeHead(value, values) {status = value; headers = values;},
      end(value) {body = value;},
    });
    console.log(JSON.stringify({
      status,
      cacheControl: headers["Cache-Control"],
      hasConnector: body.includes("connector-only-test-token"),
      hasAgent: body.includes("agent-only-test-token"),
      executable: body.includes("getgenv().MCPAuthToken"),
      guidance: body.includes("ROBLOX_MCP_CONNECTOR_TOKEN"),
    }));
  `;
  for (const environment of [
    { ROBLOX_MCP_AUTH_TOKEN: "", ROBLOX_MCP_CONNECTOR_TOKEN: "" },
    { ROBLOX_MCP_CONNECTOR_TOKEN: "" },
    { ROBLOX_MCP_CONNECTOR_TOKEN: "agent-only-test-token" },
  ]) {
    const result = runAuthFixture(fixture, environment);
    assert.equal(result.status, 503);
    assert.equal(result.cacheControl, "no-store");
    assert.equal(result.hasAgent, false);
    assert.equal(result.hasConnector, false);
    assert.equal(result.executable, false);
    assert.equal(result.guidance, true);
  }
  const distinct = runAuthFixture(fixture);
  assert.equal(distinct.status, 200);
  assert.equal(distinct.cacheControl, "no-store");
  assert.equal(distinct.hasConnector, true);
  assert.equal(distinct.hasAgent, false);
  assert.equal(distinct.executable, true);
  const disabled = runAuthFixture(fixture, { ROBLOX_MCP_PUBLIC_LOADER: "0" });
  assert.equal(disabled.status, 404);
  assert.equal(disabled.cacheControl, "no-store");
  assert.equal(disabled.hasConnector, false);
  assert.equal(disabled.hasAgent, false);
});

test("Railway public host allowlisting rejects URL-shaped or malformed configuration", () => {
  const fixture = `
    import { isAllowedRequestOrigin } from "./dist/http/bridge-auth.js";
    const check = (host, origin) => isAllowedRequestOrigin({
      method: "GET", url: "/mcp", socket: {remoteAddress: "192.0.2.1"},
      headers: {host, ...(origin ? {origin} : {})},
    });
    console.log(JSON.stringify({
      publicHost: check("mcp-test.up.railway.app"),
      differentHost: check("other.up.railway.app"),
      crossOrigin: check("mcp-test.up.railway.app", "https://other.up.railway.app"),
      loopback: check("127.0.0.1:16384"),
    }));
  `;
  const valid = runAuthFixture(fixture, { RAILWAY_PUBLIC_DOMAIN: " MCP-TEST.up.railway.app. " });
  assert.equal(valid.publicHost, true);
  assert.equal(valid.differentHost, false);
  assert.equal(valid.crossOrigin, false);
  assert.equal(valid.loopback, true);
  for (const domain of [
    "https://mcp-test.up.railway.app",
    "mcp-test.up.railway.app:443",
    "mcp-test.up.railway.app/path",
    "user@mcp-test.up.railway.app",
    "-mcp-test.up.railway.app",
    "[mcp-test.up.railway.app]",
  ]) {
    assert.equal(runAuthFixture(fixture, { RAILWAY_PUBLIC_DOMAIN: domain }).publicHost, false, domain);
  }
});

test("Railway healthcheck hostname is allowed only for the platform GET readiness probe", () => {
  const fixture = `
    import { isAllowedRequestOrigin } from "./dist/http/bridge-auth.js";
    const check = (url, method = "GET", headers = {}) => isAllowedRequestOrigin({
      method, url, socket: {remoteAddress: "192.0.2.1"},
      headers: {host: "healthcheck.railway.app", ...headers},
    });
    console.log(JSON.stringify({
      health: check("/health"),
      post: check("/health", "POST"),
      agent: check("/mcp"),
      api: check("/api/status"),
      loader: check("/loader.luau"),
      websocket: check("/health", "GET", {upgrade: "websocket"}),
      crossSite: check("/health", "GET", {"sec-fetch-site": "cross-site"}),
    }));
  `;
  for (const marker of ["RAILWAY_ENVIRONMENT_ID", "RAILWAY_PROJECT_ID"]) {
    const hosted = runAuthFixture(fixture, { [marker]: "test-environment" });
    assert.equal(hosted.health, true);
    for (const key of ["post", "agent", "api", "loader", "websocket", "crossSite"]) {
      assert.equal(hosted[key], false, key);
    }
  }
  assert.equal(runAuthFixture(fixture).health, false, "non-Railway processes do not trust the platform hostname");
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
  assert.equal(requiresBridgeAuth("/loader.luau"), false);
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

test("MCP and tool relay allow the bounded raw-source upload envelope", () => {
  assert.equal(requestBodyLimit({ url: "/mcp" }), SCRIPT_UPLOAD_BODY_LIMIT_BYTES);
  assert.equal(requestBodyLimit({ url: "/api/tool" }), SCRIPT_UPLOAD_BODY_LIMIT_BYTES);
  assert.equal(requestBodyLimit({ url: "/register" }), HTTP_BODY_LIMIT_BYTES);
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
    req.write(Buffer.alloc(SCRIPT_UPLOAD_BODY_LIMIT_BYTES / 2));
    req.write(Buffer.alloc(SCRIPT_UPLOAD_BODY_LIMIT_BYTES / 2 + 1));
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

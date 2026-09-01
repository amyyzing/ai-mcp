export const DEFAULT_BRIDGE_URL = "localhost:16384";
export const SERVER_PORT = 16384;

export function normalizeBridgeUrl(value) {
  const trimmed = String(value || "").trim().replace(/\/+$/, "");
  if (!trimmed) return DEFAULT_BRIDGE_URL;
  const hasProtocol = /^(?:https?|wss?):\/\//i.test(trimmed);
  const withProtocol = hasProtocol ? trimmed : `http://${trimmed}`;
  try {
    const url = new URL(withProtocol);
    if (!hasProtocol && !url.port) url.port = String(SERVER_PORT);
    return hasProtocol ? `${url.protocol}//${url.host}` : url.host;
  } catch {
    return DEFAULT_BRIDGE_URL;
  }
}

function luaHttpBaseExpression(variableName) {
  return `local bridgeBase
    if string.match(${variableName}, "^https?://") then
        bridgeBase = ${variableName}
    elseif string.match(${variableName}, "^wss://") then
        bridgeBase = "https://" .. string.sub(${variableName}, 7)
    elseif string.match(${variableName}, "^ws://") then
        bridgeBase = "http://" .. string.sub(${variableName}, 6)
    else
        bridgeBase = "http://" .. ${variableName}
    end`;
}

function loaderBody(authToken) {
  const credential = typeof authToken === "string" && authToken
    ? `getgenv().MCPAuthToken = ${JSON.stringify(authToken)}\n`
    : "";
  return `${credential}local HttpService = game:GetService("HttpService")
local attempts = 0

while not getgenv().MCP_Loaded do
    local bridgeUrl = tostring(getgenv().BridgeURL or "${DEFAULT_BRIDGE_URL}"):gsub("/+$", "")
    ${luaHttpBaseExpression("bridgeUrl")}
    local scriptUrl = bridgeBase .. "/script.luau"
    local token = getgenv().MCPAuthToken or getgenv().BridgeAuthToken
    if type(token) == "string" and token ~= "" then
        scriptUrl ..= "?token=" .. HttpService:UrlEncode(token)
    end

    attempts += 1
    local success, loadError = pcall(function()
        local source = game:HttpGet(scriptUrl)
        local chunk, compileError = loadstring(source)
        assert(chunk, compileError or "The bridge returned an invalid connector script.")
        chunk()
    end)

    if not success and (attempts == 1 or attempts % 20 == 0) then
        warn("[Roblox MCP] Connector attempt " .. attempts .. " failed for " .. bridgeBase .. ": " .. tostring(loadError))
    end

    task.wait(attempts < 10 and 0.15 or 1)
end`;
}

export function buildLoaderSnippet(bridgeUrl = DEFAULT_BRIDGE_URL, authToken) {
  const normalized = normalizeBridgeUrl(bridgeUrl);
  if (normalized === DEFAULT_BRIDGE_URL) {
    return loaderBody(authToken);
  }
  return `getgenv().BridgeURL = "${normalized}"\n${loaderBody(authToken)}`;
}

export function buildOneLineLoaderSnippet(bridgeUrl = DEFAULT_BRIDGE_URL, authToken) {
  const normalized = normalizeBridgeUrl(bridgeUrl);
  const httpBase = /^(?:https?):\/\//i.test(normalized)
    ? normalized
    : /^wss:\/\//i.test(normalized)
      ? `https://${normalized.slice(6)}`
      : /^ws:\/\//i.test(normalized)
        ? `http://${normalized.slice(5)}`
        : `http://${normalized}`;
  const bridgeLiteral = JSON.stringify(normalized);
  const scriptLiteral = JSON.stringify(`${httpBase}/script.luau`);
  const credential = typeof authToken === "string" && authToken
    ? `getgenv().MCPAuthToken=${JSON.stringify(authToken)};`
    : "";
  return `${credential}getgenv().BridgeURL=${bridgeLiteral};local h=game:GetService("HttpService");local t=getgenv().MCPAuthToken or getgenv().BridgeAuthToken;local u=${scriptLiteral}..(type(t)=="string" and t~="" and ("?token="..h:UrlEncode(t)) or "");local s=game:HttpGet(u);local f,e=loadstring(s);assert(f,e or "The bridge returned an invalid connector script.");f()`;
}

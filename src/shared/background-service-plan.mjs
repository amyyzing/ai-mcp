import os from "node:os";
import path from "node:path";

function displayPath(filePath) {
  const home = os.homedir();
  return filePath === home || filePath.startsWith(`${home}${path.sep}`)
    ? `~${filePath.slice(home.length)}`
    : filePath;
}

export function getBackgroundServicePlan(serverRoot) {
  const coreEntry = path.join(serverRoot, "dist", "core-bootstrap.js");
  if (process.platform === "darwin") {
    return {
      id: "launchd",
      manager: "launchd",
      title: "Run in the background",
      description: "Start the active Roblox MCP release when you sign in.",
      configPath: displayPath(
        path.join(os.homedir(), "Library", "LaunchAgents", "com.roblox-mcp.core.plist")
      ),
      command: `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.roblox-mcp.core.plist`,
      coreEntry: displayPath(coreEntry),
    };
  }
  if (process.platform === "win32") {
    const configPath = path.join(
      process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming"),
      "Microsoft", "Windows", "Start Menu", "Programs", "Startup", "Roblox MCP.vbs"
    );
    return {
      id: "windows-startup",
      manager: "Windows Startup",
      title: "Run in the background",
      description: "Start the active Roblox MCP release when you sign in.",
      configPath: displayPath(configPath),
      command: "Place Roblox MCP.vbs in the current user's Startup folder",
      coreEntry: displayPath(coreEntry),
    };
  }
  if (process.platform === "linux") {
    return {
      id: "systemd-user",
      manager: "systemd user service",
      title: "Run in the background",
      description: "Start the active Roblox MCP release with your user session.",
      configPath: displayPath(
        path.join(os.homedir(), ".config", "systemd", "user", "roblox-mcp.service")
      ),
      command: "systemctl --user enable --now roblox-mcp.service",
      coreEntry: displayPath(coreEntry),
    };
  }
  return {
    id: "session-startup",
    manager: "session startup",
    title: "Run in the background",
    description: "Start Roblox MCP with your desktop session.",
    configPath: "Platform startup configuration",
    command: `${process.execPath} ${coreEntry}`,
    coreEntry: displayPath(coreEntry),
  };
}

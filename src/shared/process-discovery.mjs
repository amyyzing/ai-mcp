import { spawnSync } from "node:child_process";
import path from "node:path";

export function normalizeProcessPath(value) {
  return String(value || "").replace(/\\/g, "/");
}

export function isCoreProcess(processInfo) {
  const command = normalizeProcessPath(processInfo?.command);
  return (
    command.includes("dist/core.js") ||
    command.includes("dist/core-bootstrap.js")
  );
}

export function listMcpRuntimeProcesses() {
  let rows = [];
  if (process.platform === "win32") {
    const script = [
      "$ErrorActionPreference = 'SilentlyContinue';",
      "Get-CimInstance Win32_Process |",
      "Where-Object { $_.CommandLine -and ($_.CommandLine -like '*dist/index.js*' -or $_.CommandLine -like '*dist\\index.js*' -or $_.CommandLine -like '*dist/core.js*' -or $_.CommandLine -like '*dist\\core.js*' -or $_.CommandLine -like '*dist/core-bootstrap.js*' -or $_.CommandLine -like '*dist\\core-bootstrap.js*') } |",
      "ForEach-Object { [PSCustomObject]@{ ProcessId = $_.ProcessId; CommandLine = $_.CommandLine } } |",
      "ConvertTo-Json -Compress",
    ].join(" ");
    const result = spawnSync("powershell.exe", ["-NoProfile", "-Command", script], {
      encoding: "utf8",
      windowsHide: true,
    });
    if (result.status === 0 && result.stdout.trim()) {
      try {
        const parsed = JSON.parse(result.stdout);
        rows = (Array.isArray(parsed) ? parsed : [parsed]).map((row) => ({
          pid: Number(row.ProcessId),
          command: String(row.CommandLine || ""),
        }));
      } catch {
        rows = [];
      }
    }
  } else {
    const result = spawnSync("ps", ["-axo", "pid=,command="], {
      encoding: "utf8",
      windowsHide: true,
    });
    if (result.status === 0) {
      rows = result.stdout
        .split(/\r?\n/)
        .map((line) => {
          const match = line.trim().match(/^(\d+)\s+(.+)$/);
          return match
            ? { pid: Number(match[1]), command: match[2] }
            : null;
        })
        .filter(Boolean);
    }
  }
  return rows.filter((processInfo) => {
    const command = normalizeProcessPath(processInfo?.command);
    return (
      Number.isInteger(processInfo?.pid) &&
      processInfo.pid !== process.pid &&
      (
        command.includes("dist/index.js") ||
        command.includes("dist/core.js") ||
        command.includes("dist/core-bootstrap.js")
      )
    );
  });
}

export function findInstallationRuntimeProcesses(serverRoot) {
  const normalizedRoot = normalizeProcessPath(path.resolve(serverRoot));
  const normalizedAdapter = normalizeProcessPath(
    path.join(serverRoot, "dist", "index.js")
  );
  return listMcpRuntimeProcesses().filter((processInfo) => {
    const command = normalizeProcessPath(processInfo.command);
    return (
      command.includes(normalizedAdapter) ||
      command.includes(normalizedRoot)
    );
  });
}

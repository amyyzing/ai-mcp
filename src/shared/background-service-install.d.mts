export interface BackgroundServiceInstallResult {
  manager: string;
  configPath: string | null;
  message: string;
}

export interface BackgroundServiceStatus {
  supported: boolean;
  enabled: boolean;
  manager: string;
  configPath: string | null;
}

export function applyBackgroundService(options: {
  serverRoot: string;
  mode: "background" | "on-demand";
  dryRun?: boolean;
  platform?: NodeJS.Platform;
  homeDir?: string;
  nodePath?: string;
  env?: NodeJS.ProcessEnv;
  windowsTaskExists?: (taskName: string) => boolean;
  runCommand?: (
    command: string,
    args: string[],
    options?: { allowFailure?: boolean },
  ) => Promise<void>;
}): Promise<BackgroundServiceInstallResult>;

export function resolveServiceHome(options?: {
  platform?: NodeJS.Platform;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
}): string;

export function getBackgroundServiceStatus(options?: {
  platform?: NodeJS.Platform;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  fileExists?: (filePath: string) => boolean;
  windowsTaskExists?: (taskName: string) => boolean;
}): BackgroundServiceStatus;

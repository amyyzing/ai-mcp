export interface StartupStatus {
  state: "idle" | "running" | "complete" | "failed";
  message: string;
  enabled?: boolean;
  startedAt?: number;
  updatedAt?: number;
  finishedAt?: number;
  workerPid?: number;
  error?: string;
}

export function startupStatusPath(env?: NodeJS.ProcessEnv): string;
export function readStartupStatus(env?: NodeJS.ProcessEnv): Promise<StartupStatus>;
export function writeStartupStatus(
  status: Omit<StartupStatus, "updatedAt">,
  env?: NodeJS.ProcessEnv,
): Promise<void>;

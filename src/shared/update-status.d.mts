export interface UpdateStatus {
  state: "idle" | "running" | "restarting" | "complete" | "failed";
  message: string;
  startedAt?: number;
  updatedAt?: number;
  finishedAt?: number;
  workerPid?: number;
  runId?: string;
  error?: string;
  operation?: "update" | "restart";
}

export const UPDATE_STATUS_PATH: string;
export const UPDATE_LOCK_PATH: string;
export function readUpdateStatus(): Promise<UpdateStatus>;
export function writeUpdateStatus(
  status: Omit<UpdateStatus, "updatedAt">,
  options?: { expectedRunId?: string }
): Promise<boolean>;
export interface UpdateLock {
  runId: string;
  workerPid: number;
  createdAt: number;
  commandToken?: string;
}
export function readUpdateLock(): Promise<UpdateLock | null>;
export function processIsRunning(pid: number): boolean;
export function updateWorkerIsRunning(lock: UpdateLock | null): boolean;
export function acquireUpdateLock(
  runId: string,
  options?: { commandToken?: string }
): Promise<UpdateLock>;
export function releaseUpdateLock(runId: string): Promise<boolean>;

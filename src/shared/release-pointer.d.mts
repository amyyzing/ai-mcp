export interface ReleasePointer {
  releaseRoot: string;
  runId: string;
  commit?: string;
}

export const RELEASE_POINTER_FILENAME: string;
export const RELEASES_DIRECTORY_NAME: string;
export function releaseIsCompleteSync(releaseRoot: string): boolean;
export function releaseIsComplete(releaseRoot: string): Promise<boolean>;
export function readReleasePointerSync(serverRoot: string): ReleasePointer | null;
export function readReleasePointer(serverRoot: string): Promise<ReleasePointer | null>;
export function writeReleasePointer(
  serverRoot: string,
  pointer: ReleasePointer | null
): Promise<void>;
export function resolveActiveReleaseRoot(serverRoot: string): Promise<string>;

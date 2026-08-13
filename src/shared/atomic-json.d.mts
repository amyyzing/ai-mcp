export function withFileTransaction<T>(
  filePath: string,
  operation: () => Promise<T>,
): Promise<T>;
export function writeJsonAtomic(
  filePath: string,
  value: unknown,
  mode?: number,
): Promise<void>;

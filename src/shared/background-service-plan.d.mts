export interface BackgroundServicePlan {
  id: string;
  manager: string;
  title: string;
  description: string;
  configPath: string;
  command: string;
  coreEntry: string;
}
export function getBackgroundServicePlan(
  serverRoot: string,
): BackgroundServicePlan;

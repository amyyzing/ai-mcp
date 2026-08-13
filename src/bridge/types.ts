import type { WebSocket } from "ws";

export type InstanceRole = "primary" | "secondary";

export interface RobloxClient {
  clientId: string;
  clientToken: string;
  sessionId?: string;
  username: string;
  userId: number;
  placeId: number;
  jobId: string;
  placeName: string;
  transport: "ws" | "http";
  ws?: WebSocket;
  lastHttpPoll: number;
  pendingHttpCommands: string[];
  pendingPollResolve: ((commands: string[]) => void) | null;
}

export interface RobloxResponse {
  id: string;
  /** Trusted by the bridge and overwritten from the validated transport origin. */
  clientId?: string;
  output?: string;
  error?: string;
  [key: string]: unknown;
}

export type ResponseResolver = (data: RobloxResponse) => void;

export const NO_CLIENT_SENTINEL = null;
export const INVALID_CLIENT_SENTINEL = "INVALID_CLIENT";
export const AMBIGUOUS_CLIENT_SENTINEL = "AMBIGUOUS_CLIENT";
export const CLIENT_QUEUE_FULL_SENTINEL = "CLIENT_QUEUE_FULL";
export const BRIDGE_BUSY_SENTINEL = "BRIDGE_BUSY";
export type DispatchResult =
  | string
  | null
  | "INVALID_CLIENT"
  | "AMBIGUOUS_CLIENT"
  | "CLIENT_QUEUE_FULL"
  | "BRIDGE_BUSY";

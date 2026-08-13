export function isIpv4Address(value: unknown): boolean;
export function isLinkLocalIpv4(ip: string): boolean;
export function isRfc1918Ipv4(ip: string): boolean;
export function isTailscaleIpv4(ip: string): boolean;
export function getLocalAddresses(networkInterfaces?: unknown): {
  lanIp: string | null;
  tailscaleIp: string | null;
};
export function getLocalLanIp(networkInterfaces?: unknown): string | null;
export function getTailscaleIp(networkInterfaces?: unknown): string | null;

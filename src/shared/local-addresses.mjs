import os from "node:os";

function ipv4ToInt(ip) {
  const parts = String(ip || "").split(".");
  if (parts.length !== 4) return null;
  let value = 0;
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    const octet = Number(part);
    if (octet > 255) return null;
    value = (value << 8) + octet;
  }
  return value >>> 0;
}

function ipv4InCidr(ip, base, prefixLength) {
  const address = ipv4ToInt(ip);
  const network = ipv4ToInt(base);
  if (address === null || network === null) return false;
  const shift = 32 - prefixLength;
  const mask = prefixLength === 0 ? 0 : ((0xffffffff << shift) >>> 0);
  return ((address & mask) >>> 0) === ((network & mask) >>> 0);
}

export function isIpv4Address(value) {
  return ipv4ToInt(value) !== null;
}

export function isLinkLocalIpv4(ip) {
  return ipv4InCidr(ip, "169.254.0.0", 16);
}

export function isRfc1918Ipv4(ip) {
  return (
    ipv4InCidr(ip, "10.0.0.0", 8) ||
    ipv4InCidr(ip, "192.168.0.0", 16) ||
    ipv4InCidr(ip, "172.16.0.0", 12)
  );
}

export function isTailscaleIpv4(ip) {
  return ipv4InCidr(ip, "100.64.0.0", 10);
}

function isIpv4Entry(entry) {
  return entry?.family === "IPv4" || entry?.family === 4;
}

export function getLocalAddresses(networkInterfaces = os.networkInterfaces) {
  const nets = typeof networkInterfaces === "function" ? networkInterfaces() : networkInterfaces;
  const lanCandidates = [];
  const tailscaleCandidates = [];

  for (const entries of Object.values(nets || {})) {
    for (const entry of entries || []) {
      if (!isIpv4Entry(entry) || entry.internal) continue;
      const address = entry.address;
      if (!isIpv4Address(address) || isLinkLocalIpv4(address)) continue;
      if (isTailscaleIpv4(address)) tailscaleCandidates.push(address);
      else lanCandidates.push(address);
    }
  }

  return {
    lanIp: lanCandidates.find((ip) => isRfc1918Ipv4(ip)) || lanCandidates[0] || null,
    tailscaleIp: tailscaleCandidates[0] || null,
  };
}

export function getLocalLanIp(networkInterfaces) {
  return getLocalAddresses(networkInterfaces).lanIp;
}

export function getTailscaleIp(networkInterfaces) {
  return getLocalAddresses(networkInterfaces).tailscaleIp;
}

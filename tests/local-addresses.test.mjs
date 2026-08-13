import assert from "node:assert/strict";
import test from "node:test";
import { getLocalAddresses, isRfc1918Ipv4, isTailscaleIpv4 } from "../src/shared/local-addresses.mjs";

test("classifies private LAN and Tailscale CGNAT addresses", () => {
  assert.equal(isRfc1918Ipv4("10.0.0.4"), true);
  assert.equal(isRfc1918Ipv4("192.168.1.20"), true);
  assert.equal(isRfc1918Ipv4("172.16.0.2"), true);
  assert.equal(isRfc1918Ipv4("100.106.204.90"), false);
  assert.equal(isTailscaleIpv4("100.64.0.1"), true);
  assert.equal(isTailscaleIpv4("100.106.204.90"), true);
  assert.equal(isTailscaleIpv4("100.127.255.255"), true);
  assert.equal(isTailscaleIpv4("100.63.255.255"), false);
  assert.equal(isTailscaleIpv4("100.128.0.1"), false);
  assert.equal(isTailscaleIpv4("10.0.0.4"), false);
});

test("reads LAN and Tailscale IPs from network interfaces without a CLI", () => {
  assert.deepEqual(getLocalAddresses({
    lo0: [{ family: "IPv4", address: "127.0.0.1", internal: true }],
    en0: [{ family: "IPv4", address: "10.0.0.4", internal: false }],
    utun5: [{ family: 4, address: "100.106.204.90", internal: false }],
    awdl0: [{ family: "IPv4", address: "169.254.12.34", internal: false }],
  }), { lanIp: "10.0.0.4", tailscaleIp: "100.106.204.90" });
});

test("does not treat a Tailscale address as the LAN IP", () => {
  const addresses = getLocalAddresses({
    utun5: [{ family: "IPv4", address: "100.106.204.90", internal: false }],
    en0: [{ family: "IPv4", address: "203.0.113.8", internal: false }],
  });
  assert.equal(addresses.lanIp, "203.0.113.8");
  assert.equal(addresses.tailscaleIp, "100.106.204.90");
});

test("prefers RFC1918 when multiple public and private addresses exist", () => {
  const addresses = getLocalAddresses({
    en0: [{ family: "IPv4", address: "203.0.113.8", internal: false }],
    en1: [{ family: "IPv4", address: "192.168.1.20", internal: false }],
  });
  assert.equal(addresses.lanIp, "192.168.1.20");
  assert.equal(addresses.tailscaleIp, null);
});

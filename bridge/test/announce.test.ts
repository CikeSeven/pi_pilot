import assert from "node:assert/strict";
import test from "node:test";
import {
  selectLanIpv4,
  type AnnounceNetworkInterfaces,
} from "../src/announce.js";

const ipv4 = (address: string, internal = false) => ({
  address,
  family: "IPv4",
  internal,
});

test("mDNS announcement prefers Wi-Fi over virtual and Ethernet interfaces", () => {
  const interfaces: AnnounceNetworkInterfaces = {
    Meta: [ipv4("198.18.0.1")],
    "br-deadbeef": [ipv4("172.23.0.1")],
    enp4s0: [ipv4("192.168.2.10")],
    wlan0: [ipv4("192.168.1.10")],
  };

  assert.equal(selectLanIpv4(interfaces), "192.168.1.10");
});

test("mDNS announcement falls back to a physical Ethernet interface", () => {
  const interfaces: AnnounceNetworkInterfaces = {
    docker0: [ipv4("172.17.0.1")],
    enp4s0: [ipv4("10.0.0.8")],
  };

  assert.equal(selectLanIpv4(interfaces), "10.0.0.8");
});

test("mDNS announcement rejects virtual, loopback, and public addresses", () => {
  const interfaces: AnnounceNetworkInterfaces = {
    lo: [ipv4("127.0.0.1", true)],
    Meta: [ipv4("198.18.0.1")],
    veth1234: [ipv4("172.18.0.1")],
    eth0: [ipv4("203.0.113.9")],
  };

  assert.equal(selectLanIpv4(interfaces), undefined);
});

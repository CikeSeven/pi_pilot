import assert from "node:assert/strict";
import test from "node:test";
import { OwnerLeaseManager } from "../src/owner_lease.js";

const TTL = 5_000;

test("only one client can own a source", () => {
  let now = 1_000;
  const leases = new OwnerLeaseManager(() => now);
  const first = leases.acquire("phone-a", TTL);
  assert.equal(first.ok, true);
  assert.equal(leases.acquire("phone-b", TTL).ok, false);

  if (!first.ok) return;
  assert.equal(leases.validate("phone-a", first.lease.leaseId, first.lease.fence).ok, true);
  assert.equal(leases.validate("phone-b", first.lease.leaseId, first.lease.fence).ok, false);

  now += TTL + 1;
  const second = leases.acquire("phone-b", TTL);
  assert.equal(second.ok, true);
  if (second.ok) assert.ok(second.lease.fence > first.lease.fence);
});

test("renew and release reject stale fencing data", () => {
  const leases = new OwnerLeaseManager(() => 10_000);
  const acquired = leases.acquire("phone", TTL);
  assert.equal(acquired.ok, true);
  if (!acquired.ok) return;

  assert.equal(
    leases.renew("phone", acquired.lease.leaseId, acquired.lease.fence + 1, TTL).ok,
    false,
  );
  assert.equal(leases.release("phone", acquired.lease.leaseId, acquired.lease.fence + 1), false);
  assert.equal(leases.release("phone", acquired.lease.leaseId, acquired.lease.fence), true);
  assert.equal(leases.publicState().owned, false);
});

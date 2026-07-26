import crypto from "node:crypto";

export interface OwnerLease {
  leaseId: string;
  clientId: string;
  fence: number;
  expiresAt: number;
}

export interface PublicOwnerState {
  owned: boolean;
  fence: number | null;
  expiresAt: number | null;
}

export type LeaseResult =
  | { ok: true; lease: OwnerLease }
  | { ok: false; error: string };

export class OwnerLeaseManager {
  private active: OwnerLease | undefined;
  private nextFence = 0;

  constructor(private readonly now: () => number = Date.now) {}

  acquire(clientId: string, ttlMs: number): LeaseResult {
    this.expire();
    if (this.active && this.active.clientId !== clientId) {
      return { ok: false, error: "source is controlled by another client" };
    }
    if (this.active) {
      this.active.expiresAt = this.now() + ttlMs;
      return { ok: true, lease: { ...this.active } };
    }
    const lease: OwnerLease = {
      leaseId: crypto.randomUUID(),
      clientId,
      fence: ++this.nextFence,
      expiresAt: this.now() + ttlMs,
    };
    this.active = lease;
    return { ok: true, lease: { ...lease } };
  }

  renew(clientId: string, leaseId: string, fence: number, ttlMs: number): LeaseResult {
    this.expire();
    if (!this.matches(clientId, leaseId, fence)) {
      return { ok: false, error: "lease is missing, expired, or stale" };
    }
    this.active!.expiresAt = this.now() + ttlMs;
    return { ok: true, lease: { ...this.active! } };
  }

  validate(clientId: string, leaseId: unknown, fence: unknown): LeaseResult {
    this.expire();
    if (typeof leaseId !== "string" || typeof fence !== "number") {
      return { ok: false, error: "a valid owner lease is required" };
    }
    if (!this.matches(clientId, leaseId, fence)) {
      return { ok: false, error: "lease is missing, expired, or stale" };
    }
    return { ok: true, lease: { ...this.active! } };
  }

  release(clientId: string, leaseId?: string, fence?: number): boolean {
    this.expire();
    if (!this.active || this.active.clientId !== clientId) return false;
    if (leaseId !== undefined && this.active.leaseId !== leaseId) return false;
    if (fence !== undefined && this.active.fence !== fence) return false;
    this.active = undefined;
    return true;
  }

  releaseClient(clientId: string): boolean {
    return this.release(clientId);
  }

  expire(): boolean {
    if (this.active && this.active.expiresAt <= this.now()) {
      this.active = undefined;
      return true;
    }
    return false;
  }

  publicState(): PublicOwnerState {
    this.expire();
    return this.active
      ? { owned: true, fence: this.active.fence, expiresAt: this.active.expiresAt }
      : { owned: false, fence: null, expiresAt: null };
  }

  isOwnedBy(clientId: string): boolean {
    this.expire();
    return this.active?.clientId === clientId;
  }

  private matches(clientId: string, leaseId: string, fence: number): boolean {
    return (
      this.active?.clientId === clientId &&
      this.active.leaseId === leaseId &&
      this.active.fence === fence
    );
  }
}

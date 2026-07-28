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
  | { ok: true; lease: OwnerLease; stolenFrom?: string }
  | { ok: false; error: string };

export class OwnerLeaseManager {
  private active: OwnerLease | undefined;
  private nextFence = 0;

  constructor(private readonly now: () => number = Date.now) {}

  /**
   * 获取租约。
   *
   * `force` 让新客户端直接抢占:fence 严格递增,旧持有者的在途命令因此被
   * relay 的单调 fence 判定作废。这是"隐形租约"的基础——用户不该看到
   * 「接管失败」,更不该等 TTL 过期。
   */
  acquire(clientId: string, ttlMs: number, opts?: { force?: boolean }): LeaseResult {
    this.expire();
    if (this.active && this.active.clientId !== clientId) {
      if (opts?.force !== true) {
        return { ok: false, error: "source is controlled by another client" };
      }
      const stolenFrom = this.active.clientId;
      this.active = undefined;
      const lease = this.mint(clientId, ttlMs);
      return { ok: true, lease: { ...lease }, stolenFrom };
    }
    if (this.active) {
      this.active.expiresAt = this.now() + ttlMs;
      return { ok: true, lease: { ...this.active } };
    }
    return { ok: true, lease: { ...this.mint(clientId, ttlMs) } };
  }

  private mint(clientId: string, ttlMs: number): OwnerLease {
    const lease: OwnerLease = {
      leaseId: crypto.randomUUID(),
      clientId,
      fence: ++this.nextFence,
      expiresAt: this.now() + ttlMs,
    };
    this.active = lease;
    return lease;
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

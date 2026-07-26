export interface SourceHandoffOps {
  isConnected(): boolean;
  blockNewCommands(): void;
  failPending(): void;
  notifyOffline(): void;
  stopOwner(): Promise<void>;
}

/**
 * Establishes the no-new-writes barrier before waiting for the old owner.
 * The caller may publish the replacement source only after this resolves.
 */
export async function quiesceSourceForHandoff(ops: SourceHandoffOps): Promise<void> {
  if (ops.isConnected()) {
    ops.blockNewCommands();
    ops.failPending();
    ops.notifyOffline();
  }
  await ops.stopOwner();
}

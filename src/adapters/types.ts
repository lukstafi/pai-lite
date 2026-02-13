// Adapter type definitions

export interface AdapterContext {
  slot: number;
  mode: string;
  session: string;
  taskId: string;
  process: string;
  harnessDir: string;
  stateRepoDir: string;
}

/** Allow adapter methods to return sync or async results. */
export type MaybePromise<T> = T | Promise<T>;

export interface Adapter {
  readState(ctx: AdapterContext): MaybePromise<string | null>;
  start(ctx: AdapterContext): MaybePromise<string>;
  stop(ctx: AdapterContext): MaybePromise<string>;
}

export interface AgentStatus {
  status: string; // working|paused|done|error|interrupted
  epoch: number;
  message: string;
}

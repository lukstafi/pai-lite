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

export interface Adapter {
  readState(ctx: AdapterContext): string | null;
  start(ctx: AdapterContext): string;
  stop(ctx: AdapterContext): string;
}

export interface AgentStatus {
  status: string; // working|paused|done|error|interrupted
  epoch: number;
  message: string;
}

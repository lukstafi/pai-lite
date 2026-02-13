// Adapter dispatch — direct TypeScript dispatch (replaces bash bridge)

import type { AdapterContext, Adapter } from "./types.ts";

export type { AdapterContext } from "./types.ts";

import * as agentClaude from "./agent-claude.ts";
import * as agentCodex from "./agent-codex.ts";
import * as agentDuo from "./agent-duo.ts";
import * as agentSolo from "./agent-solo.ts";
import * as claudeAi from "./claude-ai.ts";
import * as chatgptCom from "./chatgpt-com.ts";
import * as manual from "./manual.ts";

const adapters: Record<string, Adapter> = {
  "agent-claude": agentClaude,
  "agent-codex": agentCodex,
  "agent-duo": agentDuo,
  "agent-solo": agentSolo,
  "claude-ai": claudeAi,
  "chatgpt-com": chatgptCom,
  "manual": manual,
};

function getAdapter(mode: string): Adapter {
  const adapter = adapters[mode];
  if (!adapter) throw new Error(`adapter not found: ${mode}`);
  return adapter;
}

export function runAdapterAction(action: string, ctx: AdapterContext): string {
  const adapter = getAdapter(ctx.mode);
  switch (action) {
    case "start":
      return adapter.start(ctx);
    case "stop":
      return adapter.stop(ctx);
    case "read_state":
      return adapter.readState(ctx) ?? "";
    default:
      throw new Error(`unknown adapter action: ${action}`);
  }
}

export function readAdapterState(ctx: AdapterContext): string | null {
  const adapter = adapters[ctx.mode];
  if (!adapter) return null;
  return adapter.readState(ctx);
}

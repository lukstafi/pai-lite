// Agent-codex adapter — delegates to shared agent-session module

import { createAgentSessionAdapter } from "./agent-session.ts";
import type { Adapter } from "./types.ts";

const adapter = createAgentSessionAdapter({
  command: "agent-codex",
  modeLabel: "agent-codex",
  terminalLabel: "Codex",
  statusFileName: "codex.status",
  sessionPrefixes: ["codex-", "agent-codex-"],
});

export const { readState, start, stop, lastActivity } = adapter;
export default adapter satisfies Adapter;

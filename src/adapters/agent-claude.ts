// Agent-claude adapter — delegates to shared agent-session module

import { createAgentSessionAdapter } from "./agent-session.ts";
import type { Adapter } from "./types.ts";

const adapter = createAgentSessionAdapter({
  command: "agent-claude",
  modeLabel: "agent-claude",
  terminalLabel: "Claude Code",
  statusFileName: "claude.status",
  sessionPrefixes: ["claude-", "agent-claude-"],
});

export const { readState, start, stop, lastActivity } = adapter;
export default adapter satisfies Adapter;

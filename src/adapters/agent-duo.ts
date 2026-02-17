// Agent-duo adapter — delegates to shared orchestrated-adapter module

import { createOrchestratedAdapter } from "./orchestrated-adapter.ts";
import type { Adapter } from "./types.ts";

const adapter = createOrchestratedAdapter({
  modeLabel: "agent-duo",
  statusSectionLabel: "Agents",
  statusFiles: [
    { label: "Claude", fileName: "claude.status" },
    { label: "Codex", fileName: "codex.status" },
  ],
  portLabels: {
    ORCHESTRATOR_PORT: "Orchestrator",
    CLAUDE_PORT: "Claude",
    CODEX_PORT: "Codex",
  },
  worktreeKeys: ["claude", "codex"],
  cliCommand: "agent-duo",
});

export const { readState, start, stop, lastActivity } = adapter;
export default adapter satisfies Adapter;

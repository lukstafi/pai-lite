// Agent-pair-codex adapter — coder is Codex, reviewer is Claude.
// Delegates to shared orchestrated-adapter module.

import { createOrchestratedAdapter } from "./orchestrated-adapter.ts";
import type { Adapter } from "./types.ts";

const adapter = createOrchestratedAdapter({
  modeLabel: "agent-pair-codex",
  modeFilter: "pair",
  statusSectionLabel: "Roles",
  statusFiles: [
    { label: "Coder", fileName: "coder.status" },
    { label: "Reviewer", fileName: "reviewer.status" },
  ],
  portLabels: {
    ORCHESTRATOR_PORT: "Orchestrator",
    CODER_PORT: "Coder",
    REVIEWER_PORT: "Reviewer",
  },
  worktreeKeys: ["coder", "reviewer"],
  cliCommand: "agent-pair",
  cliStartArgs: "--coder codex --reviewer claude",
  cliStartHint: "This adapter starts agent-pair with coder=codex and reviewer=claude.",
});

export const { readState, start, stop, lastActivity } = adapter;
export default adapter satisfies Adapter;

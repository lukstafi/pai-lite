// Agent-pair-codex adapter — coder is Codex, reviewer is Claude.
// Delegates to shared orchestrated-adapter module.

import { createOrchestratedAdapter } from "./orchestrated-adapter.ts";
import type { Adapter } from "./types.ts";

const adapter = createOrchestratedAdapter({
  modeLabel: "agent-pair-codex",
  modeFilter: "solo",
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
  cliCommand: "agent-solo",
  cliStartArgs: "--codex",
  cliStartHint: "agent-solo start requires explicit coder selection. This adapter defaults to --codex (coder=codex, reviewer=claude).",
});

export const { readState, start, stop, lastActivity } = adapter;
export default adapter satisfies Adapter;

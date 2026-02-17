// Agent-solo adapter — delegates to shared orchestrated-adapter module

import { createOrchestratedAdapter } from "./orchestrated-adapter.ts";
import type { Adapter } from "./types.ts";

const adapter = createOrchestratedAdapter({
  modeLabel: "agent-solo",
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
  cliCommand: "agent-duo",
  cliModeFlag: "--mode solo",
});

export const { readState, start, stop, lastActivity } = adapter;
export default adapter satisfies Adapter;

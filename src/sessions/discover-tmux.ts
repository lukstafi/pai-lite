// tmux session discovery
// Detects running tmux sessions and extracts their working directories

import { $ } from "bun";
import type { DiscoveredSession } from "../types.ts";

function normalizeCwd(cwd: string): string {
  return cwd !== "/" ? cwd.replace(/\/+$/, "") : cwd;
}

export async function discoverTmux(): Promise<DiscoveredSession[]> {
  // Check if tmux is available
  try {
    await $`which tmux`.quiet();
  } catch {
    return [];
  }

  const now = Math.floor(Date.now() / 1000);

  // Get pane info with active flag for accurate cwd in multi-pane sessions
  let paneOutput: string;
  try {
    paneOutput = await $`tmux list-panes -a -F '#{session_name}|#{pane_active}|#{pane_current_path}'`.text();
  } catch {
    return []; // tmux server not running
  }

  if (!paneOutput.trim()) return [];

  // Build session→cwd map, preferring active pane
  const sessionPaths = new Map<string, string>();
  for (const line of paneOutput.trim().split("\n")) {
    const parts = line.split("|");
    if (parts.length < 3) continue;
    const [name, active, path] = parts;
    if (!name || !path) continue;
    if (active === "1" || !sessionPaths.has(name)) {
      sessionPaths.set(name, path);
    }
  }

  // Get last-attached timestamps
  const sessionTimes = new Map<string, number>();
  try {
    const sessionOutput = await $`tmux list-sessions -F '#{session_name}|#{session_last_attached}'`.text();
    for (const line of sessionOutput.trim().split("\n")) {
      const [name, last] = line.split("|");
      if (name) {
        sessionTimes.set(name, last ? parseInt(last, 10) : now);
      }
    }
  } catch {
    // Couldn't get timestamps — use current time
  }

  const sessions: DiscoveredSession[] = [];
  for (const [name, cwd] of sessionPaths) {
    const mtime = sessionTimes.get(name) ?? now;
    sessions.push({
      agentType: "tmux",
      cwd: normalizeCwd(cwd),
      cwdNormalized: normalizeCwd(cwd),
      sessionId: `tmux:${name}`,
      source: "cli",
      lastActivityEpoch: mtime,
      meta: { tmux_session: name },
    });
  }

  return sessions;
}

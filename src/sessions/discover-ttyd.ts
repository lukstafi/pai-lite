// ttyd process discovery
// Finds running ttyd processes, extracts port and linked tmux session

import { $ } from "bun";
import type { DiscoveredSession } from "../types.ts";

function normalizeCwd(cwd: string): string {
  return cwd !== "/" ? cwd.replace(/\/+$/, "") : cwd;
}

export async function discoverTtyd(): Promise<DiscoveredSession[]> {
  const now = Math.floor(Date.now() / 1000);

  // Try pgrep first, then fall back to ps
  let lines: string;
  try {
    lines = await $`pgrep -a ttyd`.text();
  } catch {
    try {
      const psOut = await $`ps -ax -o pid=,command=`.text();
      lines = psOut
        .split("\n")
        .filter((l) => l.includes("ttyd") && !l.includes("grep"))
        .join("\n");
    } catch {
      return [];
    }
  }

  if (!lines.trim()) return [];

  const sessions: DiscoveredSession[] = [];

  for (const line of lines.trim().split("\n")) {
    if (!line.includes("ttyd")) continue;

    const parts = line.trim().split(/\s+/);
    const pid = parts[0];
    const cmd = parts.slice(1).join(" ");

    // Extract port from -p <port> or --port <port>
    let port = "";
    const portMatch = cmd.match(/-p\s+(\d+)|--port\s+(\d+)/);
    if (portMatch) {
      port = portMatch[1] ?? portMatch[2];
    }

    // Extract tmux session from "tmux attach -t <name>"
    let tmuxSession = "";
    const tmuxMatch = cmd.match(/tmux\s+attach\S*\s+-t\s+(\S+)/);
    if (tmuxMatch) {
      tmuxSession = tmuxMatch[1];
    }

    // Try to resolve cwd from linked tmux session
    let cwd = "unknown";
    if (tmuxSession) {
      try {
        const result = await $`tmux display-message -t ${tmuxSession} -p '#{pane_current_path}'`.text();
        const resolved = result.trim();
        if (resolved) cwd = resolved;
      } catch {
        // tmux session not available
      }
    }

    sessions.push({
      agentType: "ttyd",
      cwd: normalizeCwd(cwd),
      cwdNormalized: normalizeCwd(cwd),
      sessionId: `ttyd:${pid}`,
      source: "web",
      lastActivityEpoch: now,
      meta: { pid, port, tmux_session: tmuxSession, command: cmd },
    });
  }

  return sessions;
}

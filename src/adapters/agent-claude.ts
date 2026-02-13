// Agent-claude adapter — delegates to ~/agent-duo/agent-claude
// Replaces the old claude-code.sh adapter with agent-launch managed sessions.

import { existsSync, readdirSync } from "fs";
import { join } from "path";
import { tmuxAvailable, tmuxHasSession, tmuxPaneCwd } from "./tmux.ts";
import { readStatusFile, formatAgentStatus, timeAgo, isGitWorktree, getMainRepoFromWorktree, getGitBranch, readSingleFile } from "./base.ts";
import { readAgentSessionFile } from "./peer-sync.ts";
import { getUrl } from "../network.ts";
import type { AdapterContext, Adapter } from "./types.ts";

function resolveProjectDir(ctx: AdapterContext): string {
  const s = ctx.session;
  if (s && s !== "null") {
    const home = process.env.HOME!;
    if (existsSync(`${home}/${s}`)) return `${home}/${s}`;
    if (existsSync(`${home}/repos/${s}`)) return `${home}/repos/${s}`;
  }
  return process.cwd();
}

function findSessionFile(projectDir: string, taskId: string): string | null {
  // Look for .agent-sessions/*-<task>.session or matching files
  const sessionsDir = join(projectDir, ".agent-sessions");
  if (!existsSync(sessionsDir)) return null;
  const entries = readdirSync(sessionsDir);
  for (const entry of entries) {
    if (!entry.endsWith(".session")) continue;
    // Match by task ID in the filename
    if (taskId && entry.includes(taskId)) {
      return join(sessionsDir, entry);
    }
    // Also match claude-prefixed sessions
    if (entry.startsWith("claude-") || entry.startsWith("agent-claude-")) {
      return join(sessionsDir, entry);
    }
  }
  return null;
}

export function readState(ctx: AdapterContext): string | null {
  if (!tmuxAvailable()) return null;

  const projectDir = resolveProjectDir(ctx);
  const sessionFile = findSessionFile(projectDir, ctx.taskId);
  const sessionInfo = sessionFile ? readAgentSessionFile(sessionFile) : null;

  // Determine tmux session name
  const tmuxName = sessionInfo?.tmux
    || (ctx.session && ctx.session !== "null" ? ctx.session : null);
  if (!tmuxName) return null;
  if (!tmuxHasSession(tmuxName)) return null;

  const lines: string[] = [];
  lines.push("**Mode:** agent-claude");
  lines.push("");

  // Terminals
  lines.push("**Terminals:**");
  lines.push(`- Claude Code: tmux session '${tmuxName}'`);
  if (sessionInfo?.ttydPort) {
    lines.push(`- Web: ${getUrl(sessionInfo.ttydPort)}`);
  }

  // Git info
  const cwd = tmuxPaneCwd(tmuxName);
  if (cwd) {
    lines.push("");
    lines.push("**Git:**");
    if (isGitWorktree(cwd)) {
      const mainRepo = getMainRepoFromWorktree(cwd);
      lines.push(`- Working directory: ${cwd} (worktree)`);
      if (mainRepo) lines.push(`- Main repository: ${mainRepo}`);
    } else {
      lines.push(`- Working directory: ${cwd}`);
    }
    const branch = getGitBranch(cwd);
    if (branch) lines.push(`- Branch: ${branch}`);
  }

  // Runtime info from session file
  if (sessionInfo) {
    lines.push("");
    lines.push("**Runtime:**");
    if (sessionInfo.task) lines.push(`- Task: ${sessionInfo.task}`);
    if (sessionInfo.mode) lines.push(`- Mode: ${sessionInfo.mode}`);
    if (sessionInfo.started) lines.push(`- Started: ${sessionInfo.started}`);
  }

  // Agent status
  if (sessionInfo?.workdir) {
    const statusPath = join(sessionInfo.workdir, ".peer-sync", "claude.status");
    const status = readStatusFile(statusPath);
    if (status && status.status) {
      lines.push(`- Status: ${formatAgentStatus(status)}`);
      if (status.epoch) lines.push(`  Updated: ${timeAgo(status.epoch)}`);
    }
  }

  // Integration with peer-sync
  const peerSyncDir = cwd ? join(cwd, ".peer-sync") : null;
  if (peerSyncDir && existsSync(peerSyncDir)) {
    const feature = readSingleFile(join(peerSyncDir, "feature"));
    const mode = readSingleFile(join(peerSyncDir, "mode"));
    if (feature || mode) {
      lines.push("");
      lines.push("**Integration:**");
      lines.push("- Part of agent-duo session");
      if (feature) lines.push(`- Feature: ${feature}`);
      if (mode) lines.push(`- Mode: ${mode}`);
    }
  }

  return lines.join("\n");
}

export function start(ctx: AdapterContext): string {
  const projectDir = resolveProjectDir(ctx);
  const task = ctx.taskId || ctx.session || `slot-${ctx.slot}`;

  const result = Bun.spawnSync(["agent-claude", task, "--bare"], {
    cwd: projectDir,
    stdout: "pipe",
    stderr: "pipe",
    env: process.env as Record<string, string>,
  });

  if (result.exitCode !== 0) {
    const stderr = result.stderr.toString().trim();
    throw new Error(`agent-claude start failed: ${stderr}`);
  }

  return result.stdout.toString().trim() || `agent-claude session started for ${task}`;
}

export function stop(ctx: AdapterContext): string {
  const projectDir = resolveProjectDir(ctx);
  const task = ctx.taskId || ctx.session || `slot-${ctx.slot}`;

  const result = Bun.spawnSync(["agent-claude", "cleanup", task], {
    cwd: projectDir,
    stdout: "pipe",
    stderr: "pipe",
    env: process.env as Record<string, string>,
  });

  if (result.exitCode !== 0) {
    const stderr = result.stderr.toString().trim();
    throw new Error(`agent-claude cleanup failed: ${stderr}`);
  }

  return result.stdout.toString().trim() || `agent-claude session stopped for ${task}`;
}

export default { readState, start, stop } satisfies Adapter;

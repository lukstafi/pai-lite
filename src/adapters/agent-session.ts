// Shared logic for agent-claude and agent-codex adapters.
//
// Both adapters are ~95% identical — parameterize the differences via
// AgentSessionConfig and export factory functions.

import { existsSync, readdirSync } from "fs";
import { join } from "path";
import { tmuxAvailable, tmuxHasSession, tmuxPaneCwd } from "./tmux.ts";
import { readStatusFile, formatAgentStatus, timeAgo, isGitWorktree, getMainRepoFromWorktree, getGitBranch, readSingleFile, resolveProjectDir } from "./base.ts";
import { readAgentSessionFile } from "./peer-sync.ts";
import { getUrl } from "../network.ts";
import type { AdapterContext, Adapter } from "./types.ts";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

export interface AgentSessionConfig {
  command: string;          // "agent-claude" | "agent-codex"
  modeLabel: string;        // "agent-claude" | "agent-codex"
  terminalLabel: string;    // "Claude Code" | "Codex"
  statusFileName: string;   // "claude.status" | "codex.status"
  sessionPrefixes: string[]; // ["claude-", "agent-claude-"] | ["codex-", "agent-codex-"]
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function findSessionFile(projectDir: string, taskId: string, prefixes: string[]): string | null {
  const sessionsDir = join(projectDir, ".agent-sessions");
  if (!existsSync(sessionsDir)) return null;
  const entries = readdirSync(sessionsDir);
  for (const entry of entries) {
    if (!entry.endsWith(".session")) continue;
    if (taskId && entry.includes(taskId)) {
      return join(sessionsDir, entry);
    }
    if (prefixes.some((p) => entry.startsWith(p))) {
      return join(sessionsDir, entry);
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Adapter factory
// ---------------------------------------------------------------------------

export function createAgentSessionAdapter(cfg: AgentSessionConfig): Adapter {
  function readState(ctx: AdapterContext): string | null {
    if (!tmuxAvailable()) return null;

    const projectDir = resolveProjectDir(ctx.session);
    const sessionFile = findSessionFile(projectDir, ctx.taskId, cfg.sessionPrefixes);
    const sessionInfo = sessionFile ? readAgentSessionFile(sessionFile) : null;

    const tmuxName = sessionInfo?.tmux
      || (ctx.session && ctx.session !== "null" ? ctx.session : null);
    if (!tmuxName) return null;
    if (!tmuxHasSession(tmuxName)) return null;

    const lines: string[] = [];
    lines.push(`**Mode:** ${cfg.modeLabel}`);
    lines.push("");

    // Terminals
    lines.push("**Terminals:**");
    lines.push(`- ${cfg.terminalLabel}: tmux session '${tmuxName}'`);
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
      const statusPath = join(sessionInfo.workdir, ".peer-sync", cfg.statusFileName);
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

  function start(ctx: AdapterContext): string {
    const projectDir = resolveProjectDir(ctx.session);
    const task = ctx.taskId || ctx.session || `slot-${ctx.slot}`;

    const result = Bun.spawnSync([cfg.command, task, "--bare"], {
      cwd: projectDir,
      stdout: "pipe",
      stderr: "pipe",
      env: process.env as Record<string, string>,
    });

    if (result.exitCode !== 0) {
      const stderr = result.stderr.toString().trim();
      throw new Error(`${cfg.command} start failed: ${stderr}`);
    }

    return result.stdout.toString().trim() || `${cfg.command} session started for ${task}`;
  }

  function stop(ctx: AdapterContext): string {
    const projectDir = resolveProjectDir(ctx.session);
    const task = ctx.taskId || ctx.session || `slot-${ctx.slot}`;

    const result = Bun.spawnSync([cfg.command, "cleanup", task], {
      cwd: projectDir,
      stdout: "pipe",
      stderr: "pipe",
      env: process.env as Record<string, string>,
    });

    if (result.exitCode !== 0) {
      const stderr = result.stderr.toString().trim();
      throw new Error(`${cfg.command} cleanup failed: ${stderr}`);
    }

    return result.stdout.toString().trim() || `${cfg.command} session stopped for ${task}`;
  }

  return { readState, start, stop };
}

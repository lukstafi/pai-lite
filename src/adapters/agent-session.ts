// Shared logic for agent-claude and agent-codex adapters.
//
// Both adapters are ~95% identical — parameterize the differences via
// AgentSessionConfig and export factory functions.

import { existsSync } from "fs";
import { join } from "path";
import { tmuxAvailable, tmuxHasSession, tmuxPaneCwd } from "./tmux.ts";
import { readStatusFile, formatAgentStatus, timeAgo, isGitWorktree, getMainRepoFromWorktree, getGitBranch, readSingleFile, resolveProjectDir } from "./base.ts";
import { readAgentSessionFile, findSessionByPrefixOrTask } from "./peer-sync.ts";
import { getUrl } from "../network.ts";
import { MarkdownBuilder } from "./markdown.ts";
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
// Adapter factory
// ---------------------------------------------------------------------------

export function createAgentSessionAdapter(cfg: AgentSessionConfig): Adapter {
  function readState(ctx: AdapterContext): string | null {
    if (!tmuxAvailable()) return null;

    const projectDir = resolveProjectDir(ctx.session);
    const sessionFile = findSessionByPrefixOrTask(projectDir, ctx.taskId, cfg.sessionPrefixes);
    const sessionInfo = sessionFile ? readAgentSessionFile(sessionFile) : null;

    const tmuxName = sessionInfo?.tmux
      || (ctx.session && ctx.session !== "null" ? ctx.session : null);
    if (!tmuxName) return null;
    if (!tmuxHasSession(tmuxName)) return null;

    const md = new MarkdownBuilder();
    md.keyValue("Mode", cfg.modeLabel);

    // Terminals
    md.section("Terminals");
    md.bullet(`${cfg.terminalLabel}: tmux session '${tmuxName}'`);
    if (sessionInfo?.ttydPort) {
      md.bullet(`Web: ${getUrl(sessionInfo.ttydPort)}`);
    }

    // Git info
    const cwd = tmuxPaneCwd(tmuxName);
    if (cwd) {
      md.section("Git");
      if (isGitWorktree(cwd)) {
        const mainRepo = getMainRepoFromWorktree(cwd);
        md.bullet(`Working directory: ${cwd} (worktree)`);
        if (mainRepo) md.bullet(`Main repository: ${mainRepo}`);
      } else {
        md.bullet(`Working directory: ${cwd}`);
      }
      const branch = getGitBranch(cwd);
      if (branch) md.bullet(`Branch: ${branch}`);
    }

    // Runtime info from session file
    if (sessionInfo) {
      md.section("Runtime");
      if (sessionInfo.task) md.bullet(`Task: ${sessionInfo.task}`);
      if (sessionInfo.mode) md.bullet(`Mode: ${sessionInfo.mode}`);
      if (sessionInfo.started) md.bullet(`Started: ${sessionInfo.started}`);
    }

    // Agent status
    if (sessionInfo?.workdir) {
      const statusPath = join(sessionInfo.workdir, ".peer-sync", cfg.statusFileName);
      const status = readStatusFile(statusPath);
      if (status && status.status) {
        md.bullet(`Status: ${formatAgentStatus(status)}`);
        if (status.epoch) md.detail(`Updated: ${timeAgo(status.epoch)}`);
      }
    }

    // Integration with peer-sync
    const peerSyncDir = cwd ? join(cwd, ".peer-sync") : null;
    if (peerSyncDir && existsSync(peerSyncDir)) {
      const feature = readSingleFile(join(peerSyncDir, "feature"));
      const mode = readSingleFile(join(peerSyncDir, "mode"));
      if (feature || mode) {
        md.section("Integration");
        md.bullet("Part of agent-duo session");
        if (feature) md.bullet(`Feature: ${feature}`);
        if (mode) md.bullet(`Mode: ${mode}`);
      }
    }

    return md.toString();
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

// Shared logic for agent-duo and agent-solo adapters.
//
// Both adapters share ~80% structure. The differences are parameterized
// via OrchestratedConfig.

import { existsSync } from "fs";
import { join } from "path";
import {
  listSessions,
  sessionCount,
  readBasicState,
  readPorts,
  readWorktrees,
} from "./peer-sync.ts";
import { readStatusFile, formatAgentStatus, readSingleFile, resolveProjectDir } from "./base.ts";
import { getUrl } from "../network.ts";
import type { AdapterContext, Adapter } from "./types.ts";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

export interface OrchestratedStatusFile {
  label: string;    // "Claude" | "Codex" | "Coder" | "Reviewer"
  fileName: string; // "claude.status" | "codex.status" | "coder.status" | "reviewer.status"
}

export interface OrchestratedConfig {
  modeLabel: string;                     // "agent-duo" | "agent-solo"
  modeFilter?: string;                   // undefined for duo, "solo" for solo
  statusSectionLabel: string;            // "Agents" | "Roles"
  statusFiles: OrchestratedStatusFile[]; // which status files to check
  portLabels: Record<string, string>;    // PORT_KEY → display label
  worktreeKeys: string[];                // which worktree keys to display
  cliCommand: string;                    // "agent-duo" (both use agent-duo CLI)
  cliModeFlag: string;                   // "" for duo, "--mode solo" for solo
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function matchesMode(peerSyncPath: string, modeFilter?: string): boolean {
  if (!modeFilter) return true;
  const mode = readSingleFile(join(peerSyncPath, "mode"));
  return mode === modeFilter;
}

function readSessionState(
  cfg: OrchestratedConfig,
  syncDir: string,
  feature: string,
): string[] {
  if (!existsSync(syncDir)) return [];

  const state = readBasicState(syncDir);
  const lines: string[] = [];

  // Header
  if (state.session) lines.push(`**Session:** ${state.session}`);
  if (feature) lines.push(`**Feature:** ${feature}`);

  // Status files (agents/roles)
  const hasAnyStatus = cfg.statusFiles.some((sf) =>
    existsSync(join(syncDir, sf.fileName)),
  );
  if (hasAnyStatus) {
    lines.push("");
    lines.push(`**${cfg.statusSectionLabel}:**`);
    for (const sf of cfg.statusFiles) {
      const status = readStatusFile(join(syncDir, sf.fileName));
      if (status?.status) lines.push(`- ${sf.label}: ${formatAgentStatus(status)}`);
    }
  }

  // Terminals from ports file
  const ports = readPorts(syncDir);
  if (ports.size > 0) {
    lines.push("");
    lines.push("**Terminals:**");
    for (const [key, port] of ports) {
      const label = cfg.portLabels[key];
      if (label) lines.push(`- ${label}: ${getUrl(port)}`);
    }
  }

  // Runtime
  if (state.phase || state.round) {
    lines.push("");
    lines.push("**Runtime:**");
    if (state.phase) lines.push(`- Phase: ${state.phase}`);
    if (state.round) lines.push(`- Round: ${state.round}`);
  }

  // Worktrees
  const worktrees = readWorktrees(syncDir);
  const wtEntries = Object.entries(worktrees).filter(([k]) =>
    cfg.worktreeKeys.includes(k),
  );
  if (wtEntries.length > 0) {
    lines.push("");
    lines.push("**Git:**");
    for (const [agent, path] of wtEntries) {
      lines.push(`- ${agent} worktree: ${path}`);
    }
  }

  // Error warning
  const errorLog = join(syncDir, "error.log");
  if (existsSync(errorLog)) {
    const content = readSingleFile(errorLog);
    if (content) {
      const errorCount = content.split("\n").filter(Boolean).length;
      if (errorCount > 0) {
        lines.push("");
        lines.push("**Warnings:**");
        lines.push(`- Error log has ${errorCount} entries`);
      }
    }
  }

  return lines;
}

// ---------------------------------------------------------------------------
// Adapter factory
// ---------------------------------------------------------------------------

export function createOrchestratedAdapter(cfg: OrchestratedConfig): Adapter {
  const modeFlag = cfg.cliModeFlag ? ` ${cfg.cliModeFlag}` : "";

  function readState(ctx: AdapterContext): string | null {
    const projectDir = resolveProjectDir(ctx.session, true);
    const sessions = listSessions(projectDir);
    const filtered = sessions.filter((s) => matchesMode(s.peerSyncPath, cfg.modeFilter));
    const count = filtered.length;
    if (count === 0) return null;

    const lines: string[] = [];
    lines.push(`**Mode:** ${cfg.modeLabel} (${count} sessions)`);
    lines.push("");

    let first = true;
    for (const session of filtered) {
      if (!first) {
        lines.push("");
        lines.push("---");
        lines.push("");
      }
      first = false;

      lines.push(`### Task: ${session.feature}`);
      lines.push(`**Root:** ${session.rootWorktree}`);
      lines.push(...readSessionState(cfg, session.peerSyncPath, session.feature));
    }

    return lines.join("\n");
  }

  function start(ctx: AdapterContext): string {
    const projectDir = resolveProjectDir(ctx.session, true);
    const count = sessionCount(projectDir, cfg.modeFilter);
    const parts: string[] = [];

    parts.push(`${cfg.modeLabel} start: Use the ${cfg.cliCommand} CLI${modeFlag ? ` with ${cfg.cliModeFlag}` : ""} to launch sessions.`);
    if (count > 0) parts.push(`Project has ${count}${cfg.modeFilter ? ` ${cfg.modeFilter}` : ""} sessions.`);

    if (ctx.taskId && ctx.session) {
      parts.push(`Suggested command:\n  cd ${projectDir} && ${cfg.cliCommand} start${modeFlag} --session ${ctx.session} --task ${ctx.taskId}`);
    } else if (ctx.taskId) {
      parts.push(`Suggested command:\n  cd ${projectDir} && ${cfg.cliCommand} start${modeFlag} --task ${ctx.taskId}`);
    } else {
      parts.push(`Usage:\n  cd ${projectDir} && ${cfg.cliCommand} start${modeFlag} <feature1> <feature2> ... [--auto-run]`);
    }

    return parts.join("\n");
  }

  function stop(ctx: AdapterContext): string {
    const projectDir = resolveProjectDir(ctx.session, true);
    const sessions = listSessions(projectDir);
    const filtered = sessions.filter((s) => matchesMode(s.peerSyncPath, cfg.modeFilter));
    const count = filtered.length;
    const parts: string[] = [];

    parts.push(`${cfg.modeLabel} stop: Use the ${cfg.cliCommand} CLI to stop sessions.`);

    if (count === 0) {
      parts.push(`No active ${cfg.modeLabel} sessions detected in ${projectDir}`);
      parts.push(`Usage:\n  cd ${projectDir} && ${cfg.cliCommand} stop${modeFlag} [--feature <name>]`);
    } else {
      parts.push(`Project has ${count}${cfg.modeFilter ? ` ${cfg.modeFilter}` : ""} sessions.`);
      parts.push(`Active${cfg.modeFilter ? ` ${cfg.modeFilter}` : ""} sessions:`);
      for (const s of filtered) parts.push(`  - ${s.feature}`);
      parts.push(`To stop all:\n  cd ${projectDir} && ${cfg.cliCommand} stop${modeFlag}`);
      parts.push(`To stop specific feature:\n  cd ${projectDir} && ${cfg.cliCommand} stop${modeFlag} --feature <feature-name>`);
    }

    return parts.join("\n");
  }

  return { readState, start, stop };
}

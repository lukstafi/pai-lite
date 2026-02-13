// Agent-duo adapter — orchestrated Claude + Codex sessions
// Uses peer-sync.ts for session discovery, getUrl() from network.ts

import { existsSync } from "fs";
import { join } from "path";
import {
  listSessions,
  sessionCount,
  readBasicState,
  readPorts,
  readWorktrees,
  getPhaseStatus,
} from "./peer-sync.ts";
import { readStatusFile, formatAgentStatus, readSingleFile } from "./base.ts";
import { getUrl } from "../network.ts";
import type { AdapterContext, Adapter } from "./types.ts";

// Port key → label mappings for duo sessions
const PORT_LABELS: Record<string, string> = {
  ORCHESTRATOR_PORT: "Orchestrator",
  CLAUDE_PORT: "Claude",
  CODEX_PORT: "Codex",
};

function resolveProjectDir(ctx: AdapterContext): string {
  const s = ctx.session;
  if (s && s !== "null") {
    const home = process.env.HOME!;
    if (existsSync(`${home}/${s}`)) return `${home}/${s}`;
    if (existsSync(`${home}/repos/${s}`)) return `${home}/repos/${s}`;
    if (existsSync(`${home}/${s}/.peer-sync`)) return `${home}/${s}`;
    if (existsSync(`${home}/repos/${s}/.peer-sync`)) return `${home}/repos/${s}`;
  }
  if (existsSync(`${process.cwd()}/.peer-sync`)) return process.cwd();
  return process.cwd();
}

function readSessionState(syncDir: string, feature: string): string[] {
  if (!existsSync(syncDir)) return [];

  const state = readBasicState(syncDir);
  const lines: string[] = [];

  // Header
  if (state.session) lines.push(`**Session:** ${state.session}`);
  if (feature) lines.push(`**Feature:** ${feature}`);

  // Agent status (claude + codex)
  const claudeStatusPath = join(syncDir, "claude.status");
  const codexStatusPath = join(syncDir, "codex.status");
  if (existsSync(claudeStatusPath) || existsSync(codexStatusPath)) {
    lines.push("");
    lines.push("**Agents:**");
    const claudeStatus = readStatusFile(claudeStatusPath);
    if (claudeStatus?.status) lines.push(`- Claude: ${formatAgentStatus(claudeStatus)}`);
    const codexStatus = readStatusFile(codexStatusPath);
    if (codexStatus?.status) lines.push(`- Codex: ${formatAgentStatus(codexStatus)}`);
  }

  // Terminals from ports file
  const ports = readPorts(syncDir);
  if (ports.size > 0) {
    lines.push("");
    lines.push("**Terminals:**");
    for (const [key, port] of ports) {
      const label = PORT_LABELS[key];
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
  const wtEntries = Object.entries(worktrees).filter(
    ([k]) => k === "claude" || k === "codex",
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

export function readState(ctx: AdapterContext): string | null {
  const projectDir = resolveProjectDir(ctx);
  const sessions = listSessions(projectDir);
  const count = sessions.length;
  if (count === 0) return null;

  const lines: string[] = [];
  lines.push(`**Mode:** agent-duo (${count} sessions)`);
  lines.push("");

  let first = true;
  for (const session of sessions) {
    if (!first) {
      lines.push("");
      lines.push("---");
      lines.push("");
    }
    first = false;

    lines.push(`### Task: ${session.feature}`);
    lines.push(`**Root:** ${session.rootWorktree}`);
    lines.push(...readSessionState(session.peerSyncPath, session.feature));
  }

  return lines.join("\n");
}

export function start(ctx: AdapterContext): string {
  const projectDir = resolveProjectDir(ctx);
  const count = sessionCount(projectDir);
  const parts: string[] = [];

  parts.push("agent-duo start: Use the agent-duo CLI to launch sessions.");
  if (count > 0) parts.push(`Project has ${count} active sessions.`);

  if (ctx.taskId && ctx.session) {
    parts.push(`Suggested command:\n  cd ${projectDir} && agent-duo start --session ${ctx.session} --task ${ctx.taskId}`);
  } else if (ctx.taskId) {
    parts.push(`Suggested command:\n  cd ${projectDir} && agent-duo start --task ${ctx.taskId}`);
  } else {
    parts.push(`Usage:\n  cd ${projectDir} && agent-duo start <feature1> <feature2> ... [--auto-run]`);
  }

  return parts.join("\n");
}

export function stop(ctx: AdapterContext): string {
  const projectDir = resolveProjectDir(ctx);
  const sessions = listSessions(projectDir);
  const count = sessions.length;
  const parts: string[] = [];

  parts.push("agent-duo stop: Use the agent-duo CLI to stop sessions.");

  if (count === 0) {
    parts.push(`No active agent-duo sessions detected in ${projectDir}`);
    parts.push(`Usage:\n  cd ${projectDir} && agent-duo stop [--feature <name>]`);
  } else {
    parts.push(`Project has ${count} active sessions.`);
    parts.push("Active sessions:");
    for (const s of sessions) parts.push(`  - ${s.feature}`);
    parts.push(`To stop all:\n  cd ${projectDir} && agent-duo stop`);
    parts.push(`To stop specific feature:\n  cd ${projectDir} && agent-duo stop --feature <feature-name>`);
  }

  return parts.join("\n");
}

export default { readState, start, stop } satisfies Adapter;

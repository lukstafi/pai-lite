// Agent-solo adapter — orchestrated Coder + Reviewer sessions
// Same structure as agent-duo but filters mode === "solo", different agent labels.

import { existsSync } from "fs";
import { join } from "path";
import {
  listSessions,
  sessionCount,
  readBasicState,
  readPorts,
  readWorktrees,
} from "./peer-sync.ts";
import { readStatusFile, formatAgentStatus, readSingleFile } from "./base.ts";
import { getUrl } from "../network.ts";
import type { AdapterContext, Adapter } from "./types.ts";

const MODE_FILTER = "solo";

// Port key → label mappings for solo sessions
const PORT_LABELS: Record<string, string> = {
  ORCHESTRATOR_PORT: "Orchestrator",
  CODER_PORT: "Coder",
  REVIEWER_PORT: "Reviewer",
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

function isSoloSession(peerSyncPath: string): boolean {
  const mode = readSingleFile(join(peerSyncPath, "mode"));
  return mode === MODE_FILTER;
}

function readSessionState(syncDir: string, feature: string): string[] {
  if (!existsSync(syncDir)) return [];

  const state = readBasicState(syncDir);
  const lines: string[] = [];

  // Header
  if (state.session) lines.push(`**Session:** ${state.session}`);
  if (feature) lines.push(`**Feature:** ${feature}`);

  // Role status (coder + reviewer)
  const coderStatusPath = join(syncDir, "coder.status");
  const reviewerStatusPath = join(syncDir, "reviewer.status");
  if (existsSync(coderStatusPath) || existsSync(reviewerStatusPath)) {
    lines.push("");
    lines.push("**Roles:**");
    const coderStatus = readStatusFile(coderStatusPath);
    if (coderStatus?.status) lines.push(`- Coder: ${formatAgentStatus(coderStatus)}`);
    const reviewerStatus = readStatusFile(reviewerStatusPath);
    if (reviewerStatus?.status) lines.push(`- Reviewer: ${formatAgentStatus(reviewerStatus)}`);
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
    ([k]) => k === "coder" || k === "reviewer",
  );
  if (wtEntries.length > 0) {
    lines.push("");
    lines.push("**Git:**");
    for (const [role, path] of wtEntries) {
      lines.push(`- ${role} worktree: ${path}`);
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
  const soloSessions = sessions.filter((s) => isSoloSession(s.peerSyncPath));
  const count = soloSessions.length;
  if (count === 0) return null;

  const lines: string[] = [];
  lines.push(`**Mode:** agent-solo (${count} sessions)`);
  lines.push("");

  let first = true;
  for (const session of soloSessions) {
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
  const count = sessionCount(projectDir, MODE_FILTER);
  const parts: string[] = [];

  parts.push("agent-solo start: Use the agent-duo CLI with --mode solo to launch sessions.");
  if (count > 0) parts.push(`Project has ${count} solo sessions.`);

  if (ctx.taskId && ctx.session) {
    parts.push(`Suggested command:\n  cd ${projectDir} && agent-duo start --mode solo --session ${ctx.session} --task ${ctx.taskId}`);
  } else if (ctx.taskId) {
    parts.push(`Suggested command:\n  cd ${projectDir} && agent-duo start --mode solo --task ${ctx.taskId}`);
  } else {
    parts.push(`Usage:\n  cd ${projectDir} && agent-duo start --mode solo <feature1> <feature2> ... [--auto-run]`);
  }

  return parts.join("\n");
}

export function stop(ctx: AdapterContext): string {
  const projectDir = resolveProjectDir(ctx);
  const sessions = listSessions(projectDir);
  const soloSessions = sessions.filter((s) => isSoloSession(s.peerSyncPath));
  const count = soloSessions.length;
  const parts: string[] = [];

  parts.push("agent-solo stop: Use the agent-duo CLI to stop sessions.");

  if (count === 0) {
    parts.push(`No active agent-solo sessions detected in ${projectDir}`);
    parts.push(`Usage:\n  cd ${projectDir} && agent-duo stop --mode solo [--feature <name>]`);
  } else {
    parts.push(`Project has ${count} solo sessions.`);
    parts.push("Active solo sessions:");
    for (const s of soloSessions) parts.push(`  - ${s.feature}`);
    parts.push(`To stop all:\n  cd ${projectDir} && agent-duo stop --mode solo`);
    parts.push(`To stop specific feature:\n  cd ${projectDir} && agent-duo stop --mode solo --feature <feature-name>`);
  }

  return parts.join("\n");
}

export default { readState, start, stop } satisfies Adapter;

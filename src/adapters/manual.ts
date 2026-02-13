// Manual/human work tracking adapter — pure file I/O

import { existsSync, readFileSync, writeFileSync, mkdirSync, renameSync, unlinkSync } from "fs";
import { join } from "path";
import {
  ensureAdapterStateDir,
  adapterStateDir,
  readStateFile,
  writeStateFile,
  updateStateKey,
  readSingleFile,
  isoTimestamp,
} from "./base.ts";
import type { AdapterContext, Adapter } from "./types.ts";

const ADAPTER_NAME = "manual";

function slotFile(ctx: AdapterContext): string {
  return join(adapterStateDir(ADAPTER_NAME), `slot-${ctx.slot}.md`);
}

function statusFile(ctx: AdapterContext): string {
  return join(adapterStateDir(ADAPTER_NAME), `slot-${ctx.slot}.status`);
}

export function readState(ctx: AdapterContext): string | null {
  const sf = statusFile(ctx);
  if (!existsSync(sf)) return null;

  const data = readStateFile(sf);
  const status = data.get("status") ?? "active";
  const started = data.get("started") ?? "unknown";
  const task = data.get("task") ?? "";

  const lines: string[] = [];
  lines.push("**Mode:** manual (human work)");
  lines.push("");
  lines.push(`**Status:** ${status}`);
  lines.push(`**Started:** ${started}`);
  if (task) lines.push(`**Task:** ${task}`);

  // Show notes if file exists
  const nf = slotFile(ctx);
  if (existsSync(nf)) {
    lines.push("");
    lines.push("**Notes:**");
    lines.push(readFileSync(nf, "utf-8"));
  }

  return lines.join("\n");
}

export function start(ctx: AdapterContext): string {
  ensureAdapterStateDir(ADAPTER_NAME);

  const now = isoTimestamp();
  const data = new Map<string, string>();
  data.set("status", "active");
  data.set("started", now);
  data.set("task", "");
  writeStateFile(statusFile(ctx), data);

  // Create empty notes file
  writeFileSync(
    slotFile(ctx),
    `# Manual Work Notes - Slot ${ctx.slot}\n\nStarted: ${now}\n\n## Progress\n\n`,
  );

  return `Manual tracking initialized for slot ${ctx.slot}`;
}

export function stop(ctx: AdapterContext): string {
  const sf = statusFile(ctx);
  if (!existsSync(sf)) {
    return `No manual tracking found for slot ${ctx.slot}`;
  }

  const now = isoTimestamp();

  // Archive notes
  const nf = slotFile(ctx);
  if (existsSync(nf)) {
    const archiveDir = join(adapterStateDir(ADAPTER_NAME), "archive");
    mkdirSync(archiveDir, { recursive: true });
    const archiveName = `slot-${ctx.slot}-${now.replace(/[:.]/g, "-")}.md`;
    renameSync(nf, join(archiveDir, archiveName));
  }

  // Clean up status file
  unlinkSync(sf);

  return `Manual tracking completed for slot ${ctx.slot}`;
}

export default { readState, start, stop } satisfies Adapter;

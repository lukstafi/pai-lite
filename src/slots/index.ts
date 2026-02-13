// Slot operations — list, show, assign, clear, note, start, stop, refresh

import { existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { harnessDir, slotsFilePath, slotsCount, stateRepoDir, loadConfigSync } from "../config.ts";
import { parseSlotBlocks, getField, getTask, getMode, getSession, getProcess, getPath,
         emptyBlock, writeSlotFile, addNoteToBlock, mergeAdapterState } from "./markdown.ts";
import { stateCommit } from "../state.ts";
import { journalAppend } from "../journal.ts";
import { runAdapterAction, readAdapterState } from "../adapters/index.ts";
import type { AdapterContext } from "../adapters/index.ts";

function ensureSlotsFile(): string {
  const file = slotsFilePath();
  if (!existsSync(file)) {
    const count = slotsCount();
    const blocks = new Map<number, string>();
    writeSlotFile(file, blocks, count);
  }
  return file;
}

function loadBlocks(file: string): Map<number, string> {
  const content = readFileSync(file, "utf-8");
  return parseSlotBlocks(content);
}

function validateRange(slot: number, count: number): void {
  if (slot < 1 || slot > count) {
    throw new Error(`slot out of range: ${slot} (1-${count})`);
  }
}

// --- Task file helpers ---

function taskFilePath(taskId: string): string {
  return join(harnessDir(), "tasks", `${taskId}.md`);
}

function taskUpdateFrontmatter(taskId: string, field: string, value: string): void {
  const file = taskFilePath(taskId);
  if (!existsSync(file)) return;

  const content = readFileSync(file, "utf-8");
  const lines = content.split("\n");
  let inFrontmatter = false;
  let done = false;

  const output: string[] = [];
  for (const line of lines) {
    if (line === "---" && !inFrontmatter) {
      inFrontmatter = true;
      output.push(line);
      continue;
    }
    if (line === "---" && inFrontmatter) {
      inFrontmatter = false;
      output.push(line);
      continue;
    }
    if (inFrontmatter && !done && line.startsWith(`${field}:`)) {
      output.push(`${field}: ${value}`);
      done = true;
      continue;
    }
    output.push(line);
  }

  writeFileSync(file, output.join("\n"));
}

function taskUpdateForSlotAssign(taskId: string, slot: number, adapter: string, started: string): void {
  const file = taskFilePath(taskId);
  if (!existsSync(file)) {
    console.error(`ludics: task file not found: ${taskId} (skipping task update)`);
    return;
  }
  taskUpdateFrontmatter(taskId, "status", "in-progress");
  taskUpdateFrontmatter(taskId, "slot", String(slot));
  taskUpdateFrontmatter(taskId, "adapter", adapter);
  taskUpdateFrontmatter(taskId, "started", started);
}

function taskUpdateForSlotClear(taskId: string, finalStatus: string): void {
  const file = taskFilePath(taskId);
  if (!existsSync(file)) {
    console.error(`ludics: task file not found: ${taskId} (skipping task update)`);
    return;
  }
  taskUpdateFrontmatter(taskId, "status", finalStatus);
  taskUpdateFrontmatter(taskId, "slot", "null");

  if (finalStatus === "done") {
    const completed = new Date().toISOString().replace(/\.\d{3}Z$/, "Z").replace(/:\d{2}Z$/, "Z");
    taskUpdateFrontmatter(taskId, "completed", completed);
  }
}

// --- Slot CLI handlers ---

export function slotsList(): void {
  const file = ensureSlotsFile();
  const blocks = loadBlocks(file);
  const count = slotsCount();

  for (let i = 1; i <= count; i++) {
    const block = blocks.get(i);
    const process = block ? getProcess(block) : "(empty)";
    console.log(`Slot ${i}: ${process}`);
  }
}

export function slotShow(slotNum: number): void {
  const count = slotsCount();
  validateRange(slotNum, count);
  const file = ensureSlotsFile();
  const blocks = loadBlocks(file);
  const block = blocks.get(slotNum);
  if (!block) {
    console.log(emptyBlock(slotNum));
  } else {
    console.log(block.trimEnd());
  }
}

export function slotAssign(
  slotNum: number,
  taskOrDesc: string,
  adapter: string = "manual",
  session: string = "",
  path: string = "",
): void {
  const file = ensureSlotsFile();
  const blocks = loadBlocks(file);
  const count = slotsCount();
  validateRange(slotNum, count);

  const started = new Date().toISOString().replace(/\.\d{3}Z$/, "Z").replace(/:\d{2}Z$/, "Z");

  // Normalize path
  if (path && path !== "/") {
    path = path.replace(/\/$/, "");
  }

  // Determine task ID vs description
  let taskId: string;
  let processDesc: string;
  if (/^task-\d+/.test(taskOrDesc) || /^gh-/.test(taskOrDesc) || /^readme-/.test(taskOrDesc)) {
    taskId = taskOrDesc;
    // Try to get title from task file
    const tf = taskFilePath(taskId);
    if (existsSync(tf)) {
      const content = readFileSync(tf, "utf-8");
      const titleMatch = content.match(/^title:\s*"?(.+?)"?\s*$/m);
      processDesc = titleMatch ? titleMatch[1]! : taskId;
    } else {
      processDesc = taskId;
    }
  } else {
    taskId = "null";
    processDesc = taskOrDesc;
  }

  // Session handling
  if (!session) {
    switch (adapter) {
      case "claude-code":
      case "codex":
      case "manual":
        session = String(slotNum);
        break;
      case "agent-duo":
      case "agent-solo":
        session = "null";
        break;
      default:
        session = String(slotNum);
        break;
    }
  }

  const block = `## Slot ${slotNum}

**Process:** ${processDesc}
**Task:** ${taskId}
**Mode:** ${adapter}
**Session:** ${session}
**Path:** ${path || "null"}
**Started:** ${started}

**Terminals:**

**Runtime:**
- Assigned via ludics

**Git:**
`;

  blocks.set(slotNum, block);
  writeSlotFile(file, blocks, count);

  // Update task file
  if (taskId !== "null") {
    taskUpdateForSlotAssign(taskId, slotNum, adapter, started);
  }

  journalAppend("slot", `Slot ${slotNum} assigned: ${processDesc} (task=${taskId}, adapter=${adapter})`);
  stateCommit(`slot ${slotNum}: assign ${taskOrDesc}`);
}

export function slotClear(slotNum: number, finalStatus: string = "ready"): void {
  const file = ensureSlotsFile();
  const blocks = loadBlocks(file);
  const count = slotsCount();
  validateRange(slotNum, count);

  const block = blocks.get(slotNum) ?? "";
  const taskId = block ? getTask(block) : "null";

  blocks.set(slotNum, emptyBlock(slotNum));
  writeSlotFile(file, blocks, count);

  if (taskId && taskId !== "null") {
    taskUpdateForSlotClear(taskId, finalStatus);
    journalAppend("slot", `Slot ${slotNum} cleared: task=${taskId} status=${finalStatus}`);
  } else {
    journalAppend("slot", `Slot ${slotNum} cleared`);
  }

  stateCommit(`slot ${slotNum}: cleared (status=${finalStatus})`);
}

export function slotNote(slotNum: number, note: string): void {
  const file = ensureSlotsFile();
  const blocks = loadBlocks(file);
  const count = slotsCount();
  validateRange(slotNum, count);

  const block = blocks.get(slotNum);
  if (!block) {
    throw new Error(`slot ${slotNum} not found`);
  }

  blocks.set(slotNum, addNoteToBlock(block, note));
  writeSlotFile(file, blocks, count);
}

function makeAdapterContext(slotNum: number, block: string): AdapterContext {
  const mode = getMode(block).trim();
  const session = getSession(block).trim();
  const taskIdRaw = getTask(block).trim();
  const process = getProcess(block).trim();

  return {
    slot: slotNum,
    mode: mode === "null" ? "" : mode,
    session: session === "null" ? "" : session,
    taskId: taskIdRaw === "null" ? "" : taskIdRaw,
    process: process === "(empty)" ? "" : process,
    harnessDir: harnessDir(),
    stateRepoDir: stateRepoDir(),
  };
}

export async function slotStart(slotNum: number): Promise<void> {
  const file = ensureSlotsFile();
  const blocks = loadBlocks(file);
  const count = slotsCount();
  validateRange(slotNum, count);

  const block = blocks.get(slotNum);
  if (!block) throw new Error(`slot ${slotNum} not found`);

  const ctx = makeAdapterContext(slotNum, block);
  if (!ctx.mode) throw new Error(`slot ${slotNum} has no Mode`);

  await runAdapterAction("start", ctx);
  journalAppend("slot", `Slot ${slotNum} started (adapter=${ctx.mode})`);
}

export async function slotStop(slotNum: number): Promise<void> {
  const file = ensureSlotsFile();
  const blocks = loadBlocks(file);
  const count = slotsCount();
  validateRange(slotNum, count);

  const block = blocks.get(slotNum);
  if (!block) throw new Error(`slot ${slotNum} not found`);

  const ctx = makeAdapterContext(slotNum, block);
  if (!ctx.mode) throw new Error(`slot ${slotNum} has no Mode`);

  await runAdapterAction("stop", ctx);
  journalAppend("slot", `Slot ${slotNum} stopped (adapter=${ctx.mode})`);
}

export async function slotsRefresh(): Promise<void> {
  const file = ensureSlotsFile();
  const blocks = loadBlocks(file);
  const count = slotsCount();
  let anyUpdated = false;

  for (let i = 1; i <= count; i++) {
    const block = blocks.get(i);
    if (!block) continue;

    const mode = getMode(block).trim();
    if (!mode || mode === "null") continue;

    const ctx = makeAdapterContext(i, block);
    const output = await readAdapterState(ctx);
    if (!output) continue;

    blocks.set(i, mergeAdapterState(block, output));
    anyUpdated = true;
    console.error(`ludics: refreshed slot ${i} (${mode})`);
  }

  if (anyUpdated) {
    writeSlotFile(file, blocks, count);
    stateCommit("slots refresh");
  }
}

// --- CLI handler ---

export async function runSlots(args: string[]): Promise<void> {
  const sub = args[0] ?? "";

  if (sub === "refresh") {
    await slotsRefresh();
    return;
  }

  // Default: list slots
  if (sub === "" || sub === "list") {
    slotsList();
    return;
  }

  throw new Error(`unknown slots subcommand: ${sub}`);
}

export async function runSlot(args: string[]): Promise<void> {
  const slotStr = args[0];
  if (!slotStr || !/^\d+$/.test(slotStr)) {
    throw new Error("slot number required (e.g., ludics slot 1)");
  }
  const slotNum = parseInt(slotStr, 10);
  const sub = args[1] ?? "";

  switch (sub) {
    case "":
      slotShow(slotNum);
      break;

    case "assign": {
      const taskOrDesc = args[2];
      if (!taskOrDesc) throw new Error("task or description required");
      // Parse optional flags
      let adapter = "manual";
      let session = "";
      let path = "";
      for (let i = 3; i < args.length; i++) {
        switch (args[i]) {
          case "-a": adapter = args[++i] ?? "manual"; break;
          case "-s": session = args[++i] ?? ""; break;
          case "-p": path = args[++i] ?? ""; break;
        }
      }
      slotAssign(slotNum, taskOrDesc, adapter, session, path);
      break;
    }

    case "clear": {
      const finalStatus = args[2] ?? "ready";
      const VALID_CLEAR_STATUSES = ["ready", "done", "abandoned"];
      if (!VALID_CLEAR_STATUSES.includes(finalStatus)) {
        throw new Error(`invalid clear status: ${finalStatus} (use: ${VALID_CLEAR_STATUSES.join(", ")})`);
      }
      slotClear(slotNum, finalStatus);
      break;
    }

    case "start":
      await slotStart(slotNum);
      break;

    case "stop":
      await slotStop(slotNum);
      break;

    case "note": {
      const noteText = args[2];
      if (!noteText) throw new Error("note text required");
      slotNote(slotNum, noteText);
      break;
    }

    default:
      throw new Error(`unknown slot subcommand: ${sub}`);
  }
}

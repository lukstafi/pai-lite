// Dashboard — generate JSON data, serve, install

import { existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync, copyFileSync, statSync } from "fs";
import { join, dirname } from "path";
import YAML from "yaml";
import { harnessDir, loadConfigSync, slotsFilePath } from "./config.ts";
import { parseSlotBlocks, getField, getProcess, getTask, getMode } from "./slots/markdown.ts";
import { getUrl } from "./network.ts";

function dashboardDataDir(): string {
  return join(harnessDir(), "dashboard", "data");
}

// --- Generate slots.json ---

interface SlotJson {
  number: number;
  empty: boolean;
  process: string | null;
  task: string | null;
  mode: string | null;
  started: string | null;
  phase: string | null;
  terminals: Record<string, string> | null;
}

function generateSlots(): SlotJson[] {
  const slotsFile = slotsFilePath();
  if (!existsSync(slotsFile)) return [];

  const content = readFileSync(slotsFile, "utf-8");
  const blocks = parseSlotBlocks(content);
  const result: SlotJson[] = [];

  for (const [num, block] of blocks) {
    const process = getProcess(block).trim();
    const empty = !process || process === "(empty)";

    // Parse terminals from block
    const terminals: Record<string, string> = {};
    const termLines = block.match(/^- ([^:]+):\s*(.+)$/gm);
    let inTerminals = false;
    for (const line of block.split("\n")) {
      if (line === "**Terminals:**") { inTerminals = true; continue; }
      if (line.match(/^\*\*[A-Za-z]+:\*\*/)) { inTerminals = false; continue; }
      if (inTerminals) {
        const m = line.match(/^- ([^:]+):\s*(.+)$/);
        if (m) {
          terminals[m[1]!.toLowerCase().replace(/ /g, "_")] = m[2]!;
        }
      }
    }

    // Parse phase from Runtime section
    let phase: string | null = null;
    const phaseMatch = block.match(/^- Phase:\s*(.+)$/m);
    if (phaseMatch) phase = phaseMatch[1]!.trim();

    result.push({
      number: num,
      empty,
      process: empty ? null : process,
      task: empty ? null : getTask(block).trim() || null,
      mode: empty ? null : getMode(block).trim() || null,
      started: empty ? null : getField(block, "Started").trim() || null,
      phase: empty ? null : phase,
      terminals: empty ? null : Object.keys(terminals).length > 0 ? terminals : null,
    });
  }

  return result;
}

// --- Generate ready.json ---

interface ReadyTask {
  id: string;
  title: string;
  priority: string;
  project: string;
  context: string;
  deadline: string | null;
}

function generateReady(): ReadyTask[] {
  const tasksDir = join(harnessDir(), "tasks");
  if (!existsSync(tasksDir)) return [];

  const files = readdirSync(tasksDir).filter((f: string) => f.endsWith(".md"));
  const tasks: ReadyTask[] = [];

  for (const f of files) {
    const content = readFileSync(join(tasksDir, f), "utf-8");
    const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
    if (!fmMatch) continue;

    try {
      const data = YAML.parse(fmMatch[1]!) as Record<string, unknown>;
      const deps = (data.dependencies as Record<string, unknown>) ?? {};
      const blockedBy = Array.isArray(deps.blocked_by) ? deps.blocked_by : [];

      if (data.status === "ready" && blockedBy.length === 0) {
        tasks.push({
          id: String(data.id ?? ""),
          title: String(data.title ?? ""),
          priority: String(data.priority ?? "B"),
          project: String(data.project ?? ""),
          context: String(data.context ?? ""),
          deadline: data.deadline ? String(data.deadline) : null,
        });
      }
    } catch {
      // skip
    }
  }

  // Sort by priority then deadline
  const pv = (p: string) => (p === "A" ? 1 : p === "B" ? 2 : p === "C" ? 3 : 9);
  tasks.sort((a, b) => {
    const pd = pv(a.priority) - pv(b.priority);
    if (pd !== 0) return pd;
    return (a.deadline ?? "9999-99-99").localeCompare(b.deadline ?? "9999-99-99");
  });

  return tasks;
}

// --- Generate notifications.json ---

function generateNotifications(): unknown[] {
  const logFile = join(harnessDir(), "journal", "notifications.jsonl");
  if (!existsSync(logFile)) return [];

  const lines = readFileSync(logFile, "utf-8").trim().split("\n");
  const recent = lines.slice(-50).reverse();
  const result: unknown[] = [];
  for (const line of recent) {
    try {
      result.push(JSON.parse(line));
    } catch {
      // skip
    }
  }
  return result;
}

// --- Generate mayor.json ---

function generateMayor(): Record<string, unknown> {
  const harness = harnessDir();
  const queueFile = join(harness, "mayor", "queue.jsonl");

  let pending = 0;
  if (existsSync(queueFile)) {
    const content = readFileSync(queueFile, "utf-8").trim();
    if (content) pending = content.split("\n").length;
  }

  // Check tmux session
  let status = "unknown";
  const config = loadConfigSync();
  const mayorSession = String((config.mayor as Record<string, unknown> | undefined)?.session ?? "pai-mayor");
  const tmuxResult = Bun.spawnSync(["tmux", "has-session", "-t", mayorSession], { stdout: "pipe", stderr: "pipe" });
  if (tmuxResult.exitCode === 0) status = "running";

  // Get ttyd port
  const mayorPort = String((config.mayor as Record<string, unknown> | undefined)?.ttyd_port ?? "7679");
  const terminal = getUrl(mayorPort);

  // Check for last activity
  let lastActivity: string | null = null;
  const resultsDir = join(harness, "mayor", "results");
  if (existsSync(resultsDir)) {
    const files = readdirSync(resultsDir)
      .filter((f: string) => f.endsWith(".json"))
      .map((f: string) => join(resultsDir, f));

    if (files.length > 0) {
      // Sort by mtime descending
      files.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
      try {
        const data = JSON.parse(readFileSync(files[0]!, "utf-8")) as Record<string, unknown>;
        if (data.timestamp) lastActivity = String(data.timestamp);
      } catch {
        // ignore
      }
    }
  }

  return {
    status,
    lastActivity,
    pendingRequests: pending,
    terminal: terminal || null,
  };
}

// --- Generate briefing.json ---

function generateBriefing(): Record<string, unknown> {
  const briefingFile = join(harnessDir(), "briefing.md");
  if (!existsSync(briefingFile)) {
    return { date: null, content: "", exists: false };
  }

  const content = readFileSync(briefingFile, "utf-8");
  let date: string | null = null;
  const dateMatch = content.match(/^# Briefing - (\d{4}-\d{2}-\d{2})/m);
  if (dateMatch) date = dateMatch[1]!;

  return { date, content, exists: true };
}

// --- Generate all ---

export function dashboardGenerate(): void {
  const dataDir = dashboardDataDir();
  mkdirSync(dataDir, { recursive: true });

  console.error("pai-lite: generating dashboard data...");

  writeFileSync(join(dataDir, "slots.json"), JSON.stringify(generateSlots(), null, 2));
  console.error("  slots.json");

  writeFileSync(join(dataDir, "ready.json"), JSON.stringify(generateReady(), null, 2));
  console.error("  ready.json");

  writeFileSync(join(dataDir, "notifications.json"), JSON.stringify(generateNotifications(), null, 2));
  console.error("  notifications.json");

  writeFileSync(join(dataDir, "mayor.json"), JSON.stringify(generateMayor(), null, 2));
  console.error("  mayor.json");

  writeFileSync(join(dataDir, "briefing.json"), JSON.stringify(generateBriefing(), null, 2));
  console.error("  briefing.json");

  console.error(`pai-lite: dashboard data generated in ${dataDir}`);
}

// --- Serve ---

export function dashboardServe(port: number = 7678): void {
  const dashboardDir = join(harnessDir(), "dashboard");
  if (!existsSync(dashboardDir)) {
    throw new Error("dashboard not installed. Run: pai-lite dashboard install");
  }

  const serverScript = join(dashboardDir, "..", "..", "pai-lite", "lib", "dashboard_server.py");
  // Fallback: try to find the server script relative to the binary
  const altScript = join(dirname(dirname(process.argv[1] ?? "")), "lib", "dashboard_server.py");

  let script = "";
  if (existsSync(serverScript)) script = serverScript;
  else if (existsSync(altScript)) script = altScript;

  if (!script) {
    throw new Error("dashboard server script not found");
  }

  const config = loadConfigSync();
  const ttl = config.dashboard?.ttl ?? 5;
  const bin = process.argv[1] ?? "pai-lite";

  // Generate initial data
  dashboardGenerate();

  console.error(`pai-lite: serving dashboard at ${getUrl(port)}`);
  console.error(`pai-lite: data regenerates lazily (TTL: ${ttl}s)`);
  console.error("pai-lite: press Ctrl+C to stop");

  Bun.spawnSync(["python3", script, String(port), dashboardDir, bin, String(ttl)], {
    stdio: ["inherit", "inherit", "inherit"],
  });
}

// --- Install ---

export function dashboardInstall(): void {
  const rootDir = dirname(dirname(process.argv[1] ?? ""));
  const templateDir = join(rootDir, "templates", "dashboard");
  const dashboardDir = join(harnessDir(), "dashboard");

  if (!existsSync(templateDir)) {
    throw new Error(`dashboard templates not found: ${templateDir}`);
  }

  console.error(`pai-lite: installing dashboard to ${dashboardDir}`);
  mkdirSync(dashboardDir, { recursive: true });

  // Copy template files recursively
  function copyDir(src: string, dest: string): void {
    mkdirSync(dest, { recursive: true });
    for (const entry of readdirSync(src, { withFileTypes: true })) {
      const srcPath = join(src, entry.name);
      const destPath = join(dest, entry.name);
      if (entry.isDirectory()) {
        copyDir(srcPath, destPath);
      } else {
        copyFileSync(srcPath, destPath);
      }
    }
  }

  copyDir(templateDir, dashboardDir);
  mkdirSync(join(dashboardDir, "data"), { recursive: true });

  console.error("pai-lite: dashboard installed");
  console.error("  run: pai-lite dashboard generate");
  console.error("  then: pai-lite dashboard serve");
}

// --- CLI dispatch ---

export async function runDashboard(args: string[]): Promise<void> {
  const sub = args[0] ?? "";

  switch (sub) {
    case "generate":
      dashboardGenerate();
      break;
    case "serve": {
      let port: number;
      if (args[1]) {
        port = parseInt(args[1], 10);
      } else {
        const config = loadConfigSync();
        port = config.dashboard?.port ?? 7678;
      }
      dashboardServe(port);
      break;
    }
    case "install":
      dashboardInstall();
      break;
    default:
      throw new Error(`unknown dashboard command: ${sub} (use: generate, serve, install)`);
  }
}

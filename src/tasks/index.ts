// Tasks CLI handlers

import { existsSync, readFileSync, readdirSync, mkdirSync, writeFileSync } from "fs";
import { join } from "path";
import { harnessDir } from "../config.ts";
import { parseTaskFrontmatter, updateFrontmatterField, addFrontmatterField } from "./markdown.ts";
import { tasksSync, tasksConvert, tasksNeedsElaborationList, tasksQueueElaborations, contentFingerprint } from "./sync.ts";
import { stateCommit } from "../state.ts";

function tasksDir(): string {
  return join(harnessDir(), "tasks");
}

function tasksYamlPath(): string {
  return join(harnessDir(), "tasks.yaml");
}

function tasksList(): void {
  const file = tasksYamlPath();
  if (!existsSync(file)) {
    throw new Error(`tasks file not found: ${file} (run: ludics tasks sync)`);
  }

  const content = readFileSync(file, "utf-8");
  let currentId = "";
  for (const line of content.split("\n")) {
    const idMatch = line.match(/^\s*-\s*id:\s*(.+)$/);
    if (idMatch) {
      currentId = idMatch[1]!.replace(/"/g, "");
      continue;
    }
    const titleMatch = line.match(/^\s*title:\s*"?(.+?)"?\s*$/);
    if (titleMatch && currentId) {
      console.log(`${currentId} - ${titleMatch[1]!.replace(/"$/, "")}`);
      currentId = "";
    }
  }
}

function tasksShow(taskId: string): void {
  const file = tasksYamlPath();
  if (!existsSync(file)) {
    throw new Error(`tasks file not found: ${file} (run: ludics tasks sync)`);
  }

  const content = readFileSync(file, "utf-8");
  const lines = content.split("\n");
  let inBlock = false;
  let output: string[] = [];

  for (const line of lines) {
    const idMatch = line.match(/^\s*-\s*id:\s*(.+)$/);
    if (idMatch) {
      const current = idMatch[1]!.replace(/"/g, "");
      if (inBlock && current !== taskId) break;
      inBlock = current === taskId;
    }
    if (inBlock) output.push(line);
  }

  if (output.length === 0) {
    throw new Error(`task not found: ${taskId}`);
  }
  console.log(output.join("\n"));
}

function tasksCreate(
  title: string,
  project: string = "personal",
  priority: string = "B",
  usesBrowser: boolean = false,
): void {
  const dir = tasksDir();
  mkdirSync(dir, { recursive: true });

  const files = readdirSync(dir).filter((f) => f.endsWith(".md"));
  const nextNum = files.length + 1;
  const today = new Date().toISOString().slice(0, 10);
  const id = `task-${String(nextNum).padStart(3, "0")}`;
  const file = join(dir, `${id}.md`);

  const content = `---
id: ${id}
title: "${title}"
project: ${project}
status: ready
priority: ${priority}
deadline: null
dependencies:
  blocks: []
  blocked_by: []
  relates_to: []
  subtask_of: null
effort: medium
context: ${project}
uses_browser: ${usesBrowser}
slot: null
adapter: null
created: ${today}
started: null
completed: null
modified: null
---

# ${title}

## Context

Created manually via ludics.

## Acceptance Criteria

- [ ] TBD

## Notes

`;

  writeFileSync(file, content);
  console.log(`Created task: ${file}`);
  console.log(`ID: ${id}`);
}

function tasksFilesList(): void {
  const dir = tasksDir();
  if (!existsSync(dir)) {
    console.log("No task files yet (run: ludics tasks convert)");
    return;
  }

  const files = readdirSync(dir).filter((f) => f.endsWith(".md")).sort();
  for (const f of files) {
    const content = readFileSync(join(dir, f), "utf-8");
    const fm = parseTaskFrontmatter(content);
    console.log(`${fm.id} (${fm.priority}) [${fm.status}] ${fm.title}`);
  }
}

function tasksSamples(): void {
  const dir = tasksDir();
  mkdirSync(dir, { recursive: true });
  const today = new Date().toISOString().slice(0, 10);

  const samples = [
    {
      id: "task-001", title: "Implement user authentication", project: "sample-app",
      status: "ready", priority: "A", blocks: "[task-002, task-003]", blocked_by: "[]",
      effort: "large", context: "auth", extra: "",
    },
    {
      id: "task-002", title: "Add password reset flow", project: "sample-app",
      status: "ready", priority: "B", blocks: "[]", blocked_by: "[task-001]",
      effort: "medium", context: "auth", extra: "",
    },
    {
      id: "task-003", title: "Write API documentation", project: "sample-app",
      status: "ready", priority: "B", blocks: "[]", blocked_by: "[task-001]",
      effort: "medium", context: "docs", extra: `deadline: ${today}`,
    },
    {
      id: "task-004", title: "Refactor database layer", project: "sample-app",
      status: "in-progress", priority: "B", blocks: "[]", blocked_by: "[]",
      effort: "large", context: "backend", extra: `started: ${today}`,
    },
    {
      id: "task-005", title: "Add dark mode support", project: "sample-app",
      status: "ready", priority: "C", blocks: "[]", blocked_by: "[]",
      effort: "small", context: "ui", extra: "",
    },
  ];

  for (const s of samples) {
    const file = join(dir, `${s.id}.md`);
    let content = `---
id: ${s.id}
title: "${s.title}"
project: ${s.project}
status: ${s.status}
priority: ${s.priority}
${s.extra ? s.extra + "\n" : ""}deadline: null
dependencies:
  blocks: ${s.blocks}
  blocked_by: ${s.blocked_by}
  relates_to: []
  subtask_of: null
effort: ${s.effort}
context: ${s.context}
uses_browser: false
slot: null
adapter: null
created: ${today}
started: null
completed: null
modified: null
---

# ${s.title}

## Context

Sample task for testing ludics flow engine.

## Acceptance Criteria

- [ ] TBD

## Notes

`;
    writeFileSync(file, content);
  }

  console.log(`Created 5 sample task files in ${dir}`);
}

function tasksNeedsElaboration(): void {
  const dir = tasksDir();
  if (!existsSync(dir)) return;

  const ids = tasksNeedsElaborationList(dir);
  for (const id of ids) {
    console.log(id);
  }
}

function tasksCheckElaboration(taskId: string): void {
  const dir = tasksDir();
  const file = join(dir, `${taskId}.md`);
  if (!existsSync(file)) {
    throw new Error(`task file not found: ${file}`);
  }

  const content = readFileSync(file, "utf-8");
  if (!content.includes("\nelaborated:")) {
    console.log("needs-elaboration");
    return;
  }
  if (content.includes("- [ ] TBD\n")) {
    console.log("needs-elaboration");
    return;
  }
  console.log("elaborated");
}

function tasksMerge(targetId: string, sourceIds: string[]): void {
  const dir = tasksDir();
  const targetFile = join(dir, `${targetId}.md`);
  if (!existsSync(targetFile)) {
    throw new Error(`target task not found: ${targetId}`);
  }

  for (const srcId of sourceIds) {
    const srcFile = join(dir, `${srcId}.md`);
    if (!existsSync(srcFile)) throw new Error(`source task not found: ${srcId}`);
    if (srcId === targetId) throw new Error(`cannot merge a task into itself: ${srcId}`);
  }

  for (const srcId of sourceIds) {
    updateFrontmatterField(join(dir, `${srcId}.md`), "status", "merged");
    addFrontmatterField(join(dir, `${srcId}.md`), "merged_into", targetId);
    updateFrontmatterField(join(dir, `${srcId}.md`), "slot", "null");
    console.log(`Merged: ${srcId} -> ${targetId}`);
  }

  // Add merged_from to target
  const mergedList = `[${sourceIds.join(",")}]`;
  const targetContent = readFileSync(targetFile, "utf-8");
  if (targetContent.includes("\nmerged_from:")) {
    // Append to existing
    const existingMatch = targetContent.match(/^merged_from:\s*(.+)$/m);
    if (existingMatch) {
      const existing = existingMatch[1]!.replace(/^\[/, "").replace(/\]$/, "");
      const combined = existing ? `[${existing}, ${sourceIds.join(",")}]` : mergedList;
      updateFrontmatterField(targetFile, "merged_from", combined);
    }
  } else {
    addFrontmatterField(targetFile, "merged_from", mergedList);
  }

  console.log(`\nMerged ${sourceIds.length} task(s) into ${targetId}`);
}

function tasksDuplicates(): void {
  const dir = tasksDir();
  if (!existsSync(dir)) {
    console.log("No task files yet");
    return;
  }

  const files = readdirSync(dir).filter((f) => f.endsWith(".md"));
  const groups = new Map<string, Array<{ id: string; title: string }>>();

  for (const f of files) {
    const content = readFileSync(join(dir, f), "utf-8");
    const fm = parseTaskFrontmatter(content);
    if (["done", "abandoned", "merged"].includes(fm.status ?? "")) continue;
    if (!fm.title) continue;

    const fp = contentFingerprint(fm.title);
    if (!groups.has(fp)) groups.set(fp, []);
    groups.get(fp)!.push({ id: fm.id, title: fm.title });
  }

  let found = false;
  let groupNum = 0;
  for (const [fp, entries] of groups) {
    if (entries.length < 2) continue;
    found = true;
    groupNum++;
    console.log(`Group ${groupNum} (fingerprint: ${fp}):`);
    for (const entry of entries) {
      console.log(`  ${entry.id}  "${entry.title}"`);
    }
    const first = entries[0]!.id;
    const others = entries.slice(1).map((e) => e.id).join(" ");
    console.log(`  -> ludics tasks merge ${first} ${others}`);
    console.log("");
  }

  if (!found) {
    console.log("No duplicate tasks found");
  }
}

export async function runTasks(args: string[]): Promise<void> {
  const sub = args[0] ?? "";

  switch (sub) {
    case "sync":
      await tasksSync();
      break;
    case "list":
      tasksList();
      break;
    case "show": {
      const id = args[1];
      if (!id) throw new Error("task ID required");
      tasksShow(id);
      break;
    }
    case "convert":
      await tasksConvert();
      break;
    case "create": {
      const title = args[1];
      if (!title) throw new Error("title required");
      let project: string | undefined;
      let priority: string | undefined;
      let usesBrowser = false;
      for (let i = 2; i < args.length; i++) {
        const a = args[i];
        if (a === "--uses-browser") {
          usesBrowser = true;
          continue;
        }
        if (!project) {
          project = a;
          continue;
        }
        if (!priority) {
          priority = a;
        }
      }
      tasksCreate(title, project, priority, usesBrowser);
      break;
    }
    case "files":
      tasksFilesList();
      break;
    case "samples":
      tasksSamples();
      break;
    case "needs-elaboration":
      tasksNeedsElaboration();
      break;
    case "queue-elaborations":
      tasksQueueElaborations();
      break;
    case "check": {
      const id = args[1];
      if (!id) throw new Error("task ID required");
      tasksCheckElaboration(id);
      break;
    }
    case "merge": {
      const target = args[1];
      if (!target) throw new Error("target task ID required");
      const sources = args.slice(2);
      if (sources.length === 0) throw new Error("at least one source task ID required");
      tasksMerge(target, sources);
      break;
    }
    case "duplicates":
      tasksDuplicates();
      break;
    default:
      throw new Error(
        `unknown tasks subcommand: ${sub} (use: sync, list, show, convert, create, files, samples, needs-elaboration, check, merge, duplicates)`,
      );
  }
}

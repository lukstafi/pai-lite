// Task frontmatter parsing and writing

import { existsSync, readFileSync, writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import YAML from "yaml";
import type { TaskFrontmatter } from "./types.ts";

export function parseTaskFrontmatter(content: string): Partial<TaskFrontmatter> & { id: string; title: string } {
  const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
  if (!fmMatch) throw new Error("no frontmatter found");

  const data = YAML.parse(fmMatch[1]!) as Record<string, unknown>;
  return {
    id: String(data.id ?? ""),
    title: String(data.title ?? ""),
    project: String(data.project ?? ""),
    status: String(data.status ?? "ready"),
    priority: String(data.priority ?? "B"),
    deadline: data.deadline ? String(data.deadline) : null,
    dependencies: {
      blocks: Array.isArray((data.dependencies as Record<string, unknown>)?.blocks)
        ? ((data.dependencies as Record<string, unknown>).blocks as string[])
        : [],
      blocked_by: Array.isArray((data.dependencies as Record<string, unknown>)?.blocked_by)
        ? ((data.dependencies as Record<string, unknown>).blocked_by as string[])
        : [],
    },
    effort: String(data.effort ?? "medium"),
    context: String(data.context ?? ""),
    slot: data.slot ? String(data.slot) : null,
    adapter: data.adapter ? String(data.adapter) : null,
    created: String(data.created ?? ""),
    started: data.started ? String(data.started) : null,
    completed: data.completed ? String(data.completed) : null,
    source: String(data.source ?? ""),
    url: data.url ? String(data.url) : undefined,
    github_issue: data.github_issue ? Number(data.github_issue) : undefined,
    elaborated: data.elaborated ? String(data.elaborated) : undefined,
    merged_into: data.merged_into ? String(data.merged_into) : undefined,
    merged_from: Array.isArray(data.merged_from) ? (data.merged_from as string[]) : undefined,
  };
}

export function updateFrontmatterField(filePath: string, field: string, value: string): void {
  if (!existsSync(filePath)) return;
  const content = readFileSync(filePath, "utf-8");
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

  writeFileSync(filePath, output.join("\n"));
}

export function addFrontmatterField(filePath: string, field: string, value: string): void {
  if (!existsSync(filePath)) return;
  const content = readFileSync(filePath, "utf-8");

  // If field already exists, update instead
  if (content.includes(`\n${field}:`)) {
    updateFrontmatterField(filePath, field, value);
    return;
  }

  // Insert before closing ---
  const lines = content.split("\n");
  let count = 0;
  const output: string[] = [];
  for (const line of lines) {
    if (line === "---") count++;
    if (count === 2 && line === "---") {
      output.push(`${field}: ${value}`);
    }
    output.push(line);
  }

  writeFileSync(filePath, output.join("\n"));
}

export function writeTaskFile(
  dir: string,
  id: string,
  title: string,
  source: string,
  repo: string,
  url: string,
  labels: string,
  today: string,
  watchPath?: string,
): boolean {
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${id}.md`);

  // Skip if file already exists (don't overwrite user edits)
  if (existsSync(file)) {
    console.error(`pai-lite: skipping existing: ${id}`);
    return false;
  }

  // Infer priority from labels
  let priority = "B";
  if (/urgent|critical|high|priority/i.test(labels)) {
    priority = "A";
  } else if (/low|minor|nice-to-have/i.test(labels)) {
    priority = "C";
  }

  const project = repo ? repo.split("/").pop()! : "";

  let content = `---
id: ${id}
title: "${title}"
project: ${project}
status: ready
priority: ${priority}
deadline: null
dependencies:
  blocks: []
  blocked_by: []
effort: medium
context: ${project}
slot: null
adapter: null
created: ${today}
started: null
completed: null
source: ${source}
`;

  if (url) content += `url: ${url}\n`;
  if (source === "github") {
    const m = id.match(/gh-[^-]+-(\d+)$/);
    if (m) content += `github_issue: ${m[1]}\n`;
  }

  content += `---

# ${title}

## Context

${url ? `Source: ${url}\n` : ""}${labels ? `Labels: ${labels}\n` : ""}
## Acceptance Criteria

- [ ] TBD

## Notes

`;

  writeFileSync(file, content);
  console.error(`pai-lite: created: ${id}`);
  return true;
}

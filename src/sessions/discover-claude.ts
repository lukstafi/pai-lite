// Claude Code session discovery
// Layout: ~/.claude/projects/<encoded-path>/
// Primary: scan *.jsonl files for sessions
// Enrichment: sessions-index.json (VS Code only) adds metadata

import { readdirSync, readFileSync, statSync, existsSync } from "fs";
import { join, basename } from "path";
import type { DiscoveredSession, SourceKind } from "../types.ts";
import { readFirstLines } from "./read-lines.ts";

const MAX_SCAN_LINES = 20;

function normalizeCwd(cwd: string): string {
  return cwd !== "/" ? cwd.replace(/\/+$/, "") : cwd;
}

interface IndexEntry {
  sessionId: string;
  fileMtime?: number;
  projectPath?: string;
  gitBranch?: string;
  summary?: string;
  messageCount?: number;
  isSidechain?: boolean;
}

interface IndexMeta {
  git_branch: string | null;
  summary: string | null;
  message_count: number | null;
  is_sidechain: boolean;
}

function buildMetaCache(indexFile: string): Map<string, IndexMeta> {
  const cache = new Map<string, IndexMeta>();
  try {
    const content = readFileSync(indexFile, "utf-8");
    const data = JSON.parse(content);
    const entries: IndexEntry[] = data.entries ?? [];
    for (const entry of entries) {
      if (!entry.sessionId) continue;
      cache.set(entry.sessionId, {
        git_branch: entry.gitBranch ?? null,
        summary: entry.summary ?? null,
        message_count: entry.messageCount ?? null,
        is_sidechain: entry.isSidechain ?? false,
      });
    }
  } catch {
    // Index file missing or malformed — not fatal
  }
  return cache;
}

export async function discoverClaudeCode(
  staleThreshold: number,
): Promise<DiscoveredSession[]> {
  const projectsDir = process.env.CLAUDE_PROJECTS_DIR ?? join(process.env.HOME!, ".claude/projects");

  if (!existsSync(projectsDir)) return [];

  const now = Math.floor(Date.now() / 1000);
  const sessions: DiscoveredSession[] = [];

  let projectDirs: string[];
  try {
    projectDirs = readdirSync(projectsDir)
      .map((d) => join(projectsDir, d))
      .filter((d) => {
        try {
          return statSync(d).isDirectory();
        } catch {
          return false;
        }
      });
  } catch {
    return [];
  }

  for (const projectDir of projectDirs) {
    // Build metadata cache from index if available
    const indexFile = join(projectDir, "sessions-index.json");
    const metaCache = existsSync(indexFile)
      ? buildMetaCache(indexFile)
      : new Map<string, IndexMeta>();

    // Scan JSONL files (ground truth for all sessions)
    let jsonlFiles: string[];
    try {
      jsonlFiles = readdirSync(projectDir)
        .filter((f) => f.endsWith(".jsonl"))
        .map((f) => join(projectDir, f));
    } catch {
      continue;
    }

    for (const file of jsonlFiles) {
      let mtimeEpoch: number;
      try {
        const st = statSync(file);
        mtimeEpoch = Math.floor(st.mtimeMs / 1000);
      } catch {
        continue;
      }

      // Skip stale sessions
      if (now - mtimeEpoch > staleThreshold) continue;

      const lines = await readFirstLines(file, MAX_SCAN_LINES);

      let sessionId = "";
      let cwd = "";

      // Find the first entry with cwd (typically root entry with parentUuid: null)
      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const obj = JSON.parse(line);
          if (obj.cwd) {
            sessionId = obj.sessionId ?? "";
            cwd = obj.cwd;
            break;
          }
        } catch {
          // Skip unparseable lines
        }
      }

      if (!cwd) continue;
      if (!sessionId) sessionId = basename(file, ".jsonl");

      // Enrich with index metadata if available
      const indexMeta = metaCache.get(sessionId);
      const meta: Record<string, unknown> = indexMeta
        ? { ...indexMeta }
        : {};

      sessions.push({
        agentType: "claude-code",
        cwd: normalizeCwd(cwd),
        cwdNormalized: normalizeCwd(cwd),
        sessionId,
        source: "unknown" as SourceKind,
        lastActivityEpoch: mtimeEpoch,
        meta,
      });
    }
  }

  return sessions;
}

// Extract slot paths from slots.md for session classification
// Simplified regex-based parser (full slots.md parser comes in Phase 2)

import { existsSync } from "fs";
import type { SlotPath } from "../types.ts";

interface SlotBlock {
  slot: number;
  content: string;
}

function parseSlotBlocks(text: string): SlotBlock[] {
  const blocks: SlotBlock[] = [];
  const lines = text.split("\n");
  let currentSlot = 0;
  let currentContent = "";

  for (const line of lines) {
    const match = line.match(/^##\s+Slot\s+(\d+)/);
    if (match) {
      if (currentSlot > 0) {
        blocks.push({ slot: currentSlot, content: currentContent });
      }
      currentSlot = parseInt(match[1], 10);
      currentContent = "";
    } else {
      currentContent += line + "\n";
    }
  }
  if (currentSlot > 0) {
    blocks.push({ slot: currentSlot, content: currentContent });
  }
  return blocks;
}

function extractField(content: string, field: string): string | null {
  const regex = new RegExp(`^\\*\\*${field}:\\*\\*\\s*(.*)$`, "m");
  const match = content.match(regex);
  if (!match) return null;
  const val = match[1].trim();
  return val && val !== "null" && val !== "(empty)" ? val : null;
}

function extractGitPaths(content: string): string[] {
  const paths: string[] = [];
  const lines = content.split("\n");
  let inGit = false;

  for (const line of lines) {
    if (line.startsWith("**Git:**")) {
      inGit = true;
      continue;
    }
    if (/^\*\*[A-Z]/.test(line)) {
      inGit = false;
      continue;
    }
    if (inGit) {
      // Match "Working directory: /path" or "worktree: /path"
      const wdMatch = line.match(/Working directory:\s*(.+?)(?:\s*\(worktree\))?$/);
      if (wdMatch) {
        const p = wdMatch[1].trim();
        if (p) paths.push(p);
      }
      const wtMatch = line.match(/worktree:\s*(.+)$/);
      if (wtMatch) {
        const p = wtMatch[1].trim();
        if (p) paths.push(p);
      }
    }
  }
  return paths;
}

export async function extractSlotPaths(slotsFilePath: string): Promise<SlotPath[]> {
  if (!existsSync(slotsFilePath)) return [];

  const text = await Bun.file(slotsFilePath).text();
  const blocks = parseSlotBlocks(text);
  const results: SlotPath[] = [];

  for (const block of blocks) {
    const mode = extractField(block.content, "Mode");
    // Skip empty slots (mode is null or "(empty)")
    if (!mode) continue;

    // Prefer explicit **Path:** field
    const explicitPath = extractField(block.content, "Path");
    if (explicitPath) {
      results.push({ slot: block.slot, path: explicitPath });
      continue;
    }

    // Fallback: extract from Git section
    const gitPaths = extractGitPaths(block.content);
    if (gitPaths.length > 0) {
      for (const p of gitPaths) {
        results.push({ slot: block.slot, path: p });
      }
      continue;
    }

    // Last resort: Session field as directory
    const session = extractField(block.content, "Session");
    if (session) {
      if (session.startsWith("/") && existsSync(session)) {
        results.push({ slot: block.slot, path: session });
      } else {
        const homePath = `${process.env.HOME}/${session}`;
        if (existsSync(homePath)) {
          results.push({ slot: block.slot, path: homePath });
        }
      }
    }
  }

  return results;
}

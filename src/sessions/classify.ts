// Slot classification: longest-prefix cwd matching
// A session belongs to the slot whose path is the longest prefix of the session's cwd

import type { MergedSession, SlotPath } from "../types.ts";

export interface ClassificationResult {
  classified: MergedSession[];
  unclassified: MergedSession[];
}

export function classifySessions(
  sessions: MergedSession[],
  slotPaths: SlotPath[],
): ClassificationResult {
  const classified: MergedSession[] = [];
  const unclassified: MergedSession[] = [];

  for (const session of sessions) {
    let bestSlot: number | null = null;
    let bestPath: string | null = null;
    let bestLen = 0;

    for (const sp of slotPaths) {
      const slotPath = sp.path.replace(/\/+$/, "");
      const sessionCwd = session.cwdNormalized;

      // Must match exactly or at directory boundary
      if (sessionCwd === slotPath || sessionCwd.startsWith(slotPath + "/")) {
        if (slotPath.length > bestLen) {
          bestLen = slotPath.length;
          bestSlot = sp.slot;
          bestPath = sp.path;
        }
      }
    }

    if (bestSlot !== null) {
      classified.push({ ...session, slot: bestSlot, slotPath: bestPath });
    } else {
      unclassified.push(session);
    }
  }

  return { classified, unclassified };
}

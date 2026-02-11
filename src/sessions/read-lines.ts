// Streaming first-N-lines reader for JSONL files
// Reads only the bytes needed rather than loading entire files

import { createReadStream } from "fs";
import { createInterface } from "readline";

export async function readFirstLines(filePath: string, count: number): Promise<string[]> {
  const lines: string[] = [];
  const stream = createReadStream(filePath, { encoding: "utf-8" });
  const rl = createInterface({ input: stream, crlfDelay: Infinity });

  for await (const line of rl) {
    lines.push(line);
    if (lines.length >= count) {
      rl.close();
      break;
    }
  }

  stream.destroy();
  return lines;
}

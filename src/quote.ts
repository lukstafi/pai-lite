// ludics quote — print a random quote from the quotes file

import { readFileSync } from "fs";
import { join, dirname } from "path";

function quotesFilePath(): string {
  // Resolve relative to the project root (one level up from src/)
  const projectRoot = join(dirname(import.meta.dir), "");
  return join(projectRoot, "templates", "Girard_quotes.txt");
}

export async function runQuote(): Promise<void> {
  const path = quotesFilePath();
  let text: string;
  try {
    text = readFileSync(path, "utf-8");
  } catch {
    throw new Error(`quotes file not found: ${path}`);
  }

  const lines = text.split("\n").filter((l) => l.length > 0);

  // Quotes are pairs: even index = quote, odd index = source
  const pairs: Array<{ quote: string; source: string }> = [];
  for (let i = 0; i + 1 < lines.length; i += 2) {
    pairs.push({ quote: lines[i], source: lines[i + 1] });
  }

  if (pairs.length === 0) {
    throw new Error("no quotes found in quotes file");
  }

  const pick = pairs[Math.floor(Math.random() * pairs.length)];
  console.log(pick.quote);
  console.log(pick.source);
}

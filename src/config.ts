// Config reading for ludics (Phase 2: native YAML parsing)

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import YAML from "yaml";

const DEFAULT_STALE_THRESHOLD = 86400; // 24 hours

export interface LudicsFullConfig {
  state_repo: string;
  state_path: string;
  staleThresholdSeconds: number;
  slots?: { count?: number };
  projects?: Array<{ name: string; repo: string; issues?: boolean }>;
  adapters?: Record<string, { enabled?: boolean }>;
  mag?: Record<string, unknown>;
  triggers?: Record<string, unknown>;
  notifications?: {
    provider?: string;
    topics?: Record<string, string>;
    priorities?: Record<string, number>;
  };
  dashboard?: { port?: number; ttl?: number };
  network?: { mode?: string; hostname?: string; nodes?: unknown[] };
}

export function ludicsRoot(): string {
  const execPath = process.execPath;
  if (execPath.includes("/bin/")) {
    return execPath.replace(/\/bin\/.*$/, "");
  }
  if (execPath.includes("/src/")) {
    return execPath.replace(/\/src\/.*$/, "");
  }
  return process.cwd();
}

export function pointerConfigPath(): string {
  if (process.env.LUDICS_CONFIG) return process.env.LUDICS_CONFIG;
  if (process.env.PAI_LITE_CONFIG) return process.env.PAI_LITE_CONFIG;
  const newPath = join(process.env.HOME!, ".config/ludics/config.yaml");
  if (existsSync(newPath)) return newPath;
  // Legacy fallback for upgrades from pai-lite
  const legacyPath = join(process.env.HOME!, ".config/pai-lite/config.yaml");
  if (existsSync(legacyPath)) return legacyPath;
  return newPath;
}

function parseYamlFile(path: string): Record<string, unknown> {
  const text = readFileSync(path, "utf-8");
  return YAML.parse(text) ?? {};
}

function resolveConfigPath(): string {
  const pointer = pointerConfigPath();
  if (!existsSync(pointer)) return pointer;

  const data = parseYamlFile(pointer);
  const stateRepo = (data.state_repo as string) ?? "";
  const statePath = (data.state_path as string) || "harness";

  if (stateRepo) {
    const repoName = stateRepo.split("/").pop()!;
    const harnessConfig = join(process.env.HOME!, repoName, statePath, "config.yaml");
    if (existsSync(harnessConfig)) return harnessConfig;
  }

  return pointer;
}

export function loadConfigSync(): LudicsFullConfig {
  const configPath = resolveConfigPath();
  if (!existsSync(configPath)) {
    throw new Error(`config not found: ${configPath} (run: ludics init)`);
  }

  const data = parseYamlFile(configPath) as Record<string, unknown>;

  const staleEnv = process.env.SESSIONS_STALE_THRESHOLD;
  const staleThresholdSeconds = staleEnv ? parseInt(staleEnv, 10) : DEFAULT_STALE_THRESHOLD;

  return {
    state_repo: (data.state_repo as string) ?? "",
    state_path: (data.state_path as string) || "harness",
    staleThresholdSeconds,
    slots: data.slots as LudicsFullConfig["slots"],
    projects: data.projects as LudicsFullConfig["projects"],
    adapters: data.adapters as LudicsFullConfig["adapters"],
    mag: data.mag as LudicsFullConfig["mag"],
    triggers: data.triggers as LudicsFullConfig["triggers"],
    notifications: data.notifications as LudicsFullConfig["notifications"],
    dashboard: data.dashboard as LudicsFullConfig["dashboard"],
    network: data.network as LudicsFullConfig["network"],
  };
}

// Async wrapper for backward compatibility with Phase 1 callers
export async function loadConfig(): Promise<LudicsFullConfig> {
  return loadConfigSync();
}

export function harnessDir(): string {
  const configPath = resolveConfigPath();
  if (!existsSync(configPath)) {
    throw new Error(`config not found: ${configPath}`);
  }

  const data = parseYamlFile(configPath);
  const stateRepo = (data.state_repo as string) ?? "";
  const statePath = (data.state_path as string) || "harness";

  const repoName = stateRepo.split("/").pop()!;
  return join(process.env.HOME!, repoName, statePath);
}

export function stateRepoDir(): string {
  const config = loadConfigSync();
  const repoName = config.state_repo.split("/").pop()!;
  return join(process.env.HOME!, repoName);
}

export function slotsFilePath(harness?: string): string {
  const h = harness ?? harnessDir();
  return join(h, "slots.md");
}

export function slotsCount(): number {
  const config = loadConfigSync();
  return config.slots?.count ?? 6;
}

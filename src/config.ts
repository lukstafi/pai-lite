// Config reading for pai-lite (Phase 2: native YAML parsing)

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import YAML from "yaml";

const DEFAULT_STALE_THRESHOLD = 86400; // 24 hours

export interface PaiLiteFullConfig {
  state_repo: string;
  state_path: string;
  staleThresholdSeconds: number;
  slots?: { count?: number };
  projects?: Array<{ name: string; repo: string; issues?: boolean }>;
  adapters?: Record<string, { enabled?: boolean }>;
  mayor?: Record<string, unknown>;
  triggers?: Record<string, unknown>;
  notifications?: {
    provider?: string;
    topics?: Record<string, string>;
    priorities?: Record<string, number>;
  };
  dashboard?: { port?: number; ttl?: number };
  network?: { mode?: string; hostname?: string; nodes?: unknown[] };
}

function pointerConfigPath(): string {
  return process.env.PAI_LITE_CONFIG ?? join(process.env.HOME!, ".config/pai-lite/config.yaml");
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

export function loadConfigSync(): PaiLiteFullConfig {
  const configPath = resolveConfigPath();
  if (!existsSync(configPath)) {
    throw new Error(`config not found: ${configPath} (run: pai-lite init)`);
  }

  const data = parseYamlFile(configPath) as Record<string, unknown>;

  const staleEnv = process.env.SESSIONS_STALE_THRESHOLD;
  const staleThresholdSeconds = staleEnv ? parseInt(staleEnv, 10) : DEFAULT_STALE_THRESHOLD;

  return {
    state_repo: (data.state_repo as string) ?? "",
    state_path: (data.state_path as string) || "harness",
    staleThresholdSeconds,
    slots: data.slots as PaiLiteFullConfig["slots"],
    projects: data.projects as PaiLiteFullConfig["projects"],
    adapters: data.adapters as PaiLiteFullConfig["adapters"],
    mayor: data.mayor as PaiLiteFullConfig["mayor"],
    triggers: data.triggers as PaiLiteFullConfig["triggers"],
    notifications: data.notifications as PaiLiteFullConfig["notifications"],
    dashboard: data.dashboard as PaiLiteFullConfig["dashboard"],
    network: data.network as PaiLiteFullConfig["network"],
  };
}

// Async wrapper for backward compatibility with Phase 1 callers
export async function loadConfig(): Promise<PaiLiteFullConfig> {
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

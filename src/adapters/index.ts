// Adapter dispatch — call Bash adapter scripts for start/stop/read_state

import { existsSync } from "fs";
import { join, dirname } from "path";

function paiLiteRoot(): string {
  // src/adapters/index.ts → project root
  return join(dirname(new URL(import.meta.url).pathname), "../..");
}

export interface AdapterContext {
  slot: number;
  mode: string;
  session: string;
  taskId: string;
  process: string;
  harnessDir: string;
  stateRepoDir: string;
}

function adapterFilePath(mode: string): string {
  return join(paiLiteRoot(), "adapters", `${mode}.sh`);
}

function buildEnv(ctx: AdapterContext): Record<string, string> {
  return {
    ...process.env as Record<string, string>,
    PAI_LITE_STATE_DIR: ctx.harnessDir,
    PAI_LITE_STATE_REPO: ctx.stateRepoDir,
    PAI_LITE_SLOT: String(ctx.slot),
    PAI_LITE_TASK: ctx.taskId,
    PAI_LITE_SESSION: ctx.session,
    PAI_LITE_PROCESS: ctx.process,
  };
}

function buildArgs(action: string, ctx: AdapterContext): string[] {
  const fn = `adapter_${ctx.mode.replace(/-/g, "_")}_${action}`;
  switch (ctx.mode) {
    case "agent-duo":
    case "agent-solo": {
      let projectDir = "";
      const s = ctx.session;
      if (s && s !== "null") {
        const home = process.env.HOME!;
        if (existsSync(`${home}/${s}`)) projectDir = `${home}/${s}`;
        else if (existsSync(`${home}/repos/${s}`)) projectDir = `${home}/repos/${s}`;
      }
      if (!projectDir) projectDir = process.cwd();
      return [projectDir, ctx.taskId, ctx.session];
    }
    case "claude-code":
    case "codex": {
      const session = ctx.session || String(ctx.slot);
      let projectDir = "";
      const home = process.env.HOME!;
      if (session && session !== "null") {
        if (existsSync(`${home}/${session}`)) projectDir = `${home}/${session}`;
        else if (existsSync(`${home}/repos/${session}`)) projectDir = `${home}/repos/${session}`;
      }
      if (!projectDir) projectDir = process.cwd();
      return [session, projectDir, ctx.taskId];
    }
    case "claude-ai":
    case "chatgpt-com":
      return [ctx.session, ctx.process, ctx.taskId];
    case "manual":
      return [String(ctx.slot)];
    default:
      return [String(ctx.slot), ctx.harnessDir];
  }
}

export function runAdapterAction(action: string, ctx: AdapterContext): string {
  const adapterFile = adapterFilePath(ctx.mode);
  if (!existsSync(adapterFile)) {
    throw new Error(`adapter not found: ${ctx.mode}`);
  }

  const fn = `adapter_${ctx.mode.replace(/-/g, "_")}_${action}`;
  const args = buildArgs(action, ctx);

  // Source the adapter file and call the function
  const script = `source "${adapterFile}" && ${fn} ${args.map((a) => `"${a}"`).join(" ")}`;
  const result = Bun.spawnSync(["bash", "-c", script], {
    env: buildEnv(ctx),
    cwd: process.cwd(),
    stdout: "pipe",
    stderr: "pipe",
  });

  if (result.exitCode !== 0) {
    const stderr = result.stderr.toString().trim();
    throw new Error(`adapter ${ctx.mode} ${action} failed: ${stderr}`);
  }

  return result.stdout.toString();
}

export function readAdapterState(ctx: AdapterContext): string | null {
  const adapterFile = adapterFilePath(ctx.mode);
  if (!existsSync(adapterFile)) return null;

  const fn = `adapter_${ctx.mode.replace(/-/g, "_")}_read_state`;

  // Determine adapter argument based on mode
  let adapterArg = "";
  switch (ctx.mode) {
    case "agent-duo":
    case "agent-solo": {
      const s = ctx.session;
      const home = process.env.HOME!;
      if (s && s !== "null") {
        if (existsSync(`${home}/${s}/.peer-sync`)) adapterArg = `${home}/${s}`;
        else if (existsSync(`${home}/repos/${s}/.peer-sync`)) adapterArg = `${home}/repos/${s}`;
      }
      if (!adapterArg && existsSync(`${process.cwd()}/.peer-sync`)) {
        adapterArg = process.cwd();
      }
      if (!adapterArg) return null;
      break;
    }
    case "claude-code":
    case "codex":
      adapterArg = ctx.session === "null" ? "" : ctx.session;
      break;
    case "manual":
      adapterArg = String(ctx.slot);
      break;
    default:
      adapterArg = ctx.session === "null" ? "" : ctx.session;
      break;
  }

  const script = `source "${adapterFile}" && declare -F "${fn}" >/dev/null 2>&1 && ${fn} "${adapterArg}"`;
  const result = Bun.spawnSync(["bash", "-c", script], {
    env: buildEnv(ctx),
    cwd: process.cwd(),
    stdout: "pipe",
    stderr: "pipe",
  });

  if (result.exitCode !== 0) return null;
  const output = result.stdout.toString().trim();
  return output || null;
}

// Trigger installation — launchd (macOS) and systemd (Linux)

import { existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync, unlinkSync } from "fs";
import { join, basename } from "path";
import { loadConfigSync } from "./config.ts";

function paiLiteRoot(): string {
  // Use process.execPath — in compiled Bun binaries, process.argv[1] is a
  // virtual /$bunfs/... path, but process.execPath is the real filesystem path.
  const execPath = process.execPath;
  if (execPath.includes("/bin/")) {
    return execPath.replace(/\/bin\/.*$/, "");
  }
  if (execPath.includes("/src/")) {
    return execPath.replace(/\/src\/.*$/, "");
  }
  return process.cwd();
}

function binPath(): string {
  // The binary is the compiled entry point
  return join(paiLiteRoot(), "bin", "pai-lite");
}

function sanitizeAction(action: string): string {
  return action.replace(/ /g, "-").replace(/[^a-zA-Z0-9_-]/g, "");
}

function commandFromAction(action: string): string {
  return action || "mayor briefing";
}

function triggerGet(section: string, key: string): string {
  const config = loadConfigSync();
  const triggers = config.triggers as Record<string, unknown> | undefined;
  if (!triggers) return "";
  const sectionData = triggers[section] as Record<string, unknown> | undefined;
  if (!sectionData) return "";
  const val = sectionData[key];
  if (val === null || val === undefined) return "";
  return String(val);
}

function triggerGetWatchRules(): { action: string; paths: string[] }[] {
  const config = loadConfigSync();
  const triggers = config.triggers as Record<string, unknown> | undefined;
  if (!triggers) return [];
  const watch = triggers.watch as Array<{ paths?: string[]; action?: string }> | undefined;
  if (!Array.isArray(watch)) return [];

  return watch
    .filter((r) => r.action && Array.isArray(r.paths) && r.paths.length > 0)
    .map((r) => ({
      action: String(r.action),
      paths: r.paths!.map((p) => p.replace(/^~/, process.env.HOME!)),
    }));
}

// --- Plist generation helpers ---

const PLIST_HEADER = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>`;

const PLIST_FOOTER = `</dict>
</plist>`;

function plistEnv(): string {
  return `  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:${process.env.HOME}/.local/bin:${process.env.HOME}/.bun/bin</string>
  </dict>`;
}

function plistArgs(bin: string, ...args: string[]): string {
  let xml = `  <key>ProgramArguments</key>\n  <array>\n    <string>${bin}</string>\n`;
  for (const arg of args) {
    xml += `    <string>${arg}</string>\n`;
  }
  xml += `  </array>`;
  return xml;
}

function plistLogs(name: string): string {
  return `  <key>StandardOutPath</key>
  <string>${process.env.HOME}/Library/Logs/pai-lite-${name}.log</string>
  <key>StandardErrorPath</key>
  <string>${process.env.HOME}/Library/Logs/pai-lite-${name}.err</string>`;
}

function installPlist(label: string, content: string): void {
  const agentsDir = join(process.env.HOME!, "Library/LaunchAgents");
  mkdirSync(agentsDir, { recursive: true });
  const plist = join(agentsDir, `${label}.plist`);

  writeFileSync(plist, content);
  Bun.spawnSync(["launchctl", "unload", plist], { stdout: "pipe", stderr: "pipe" });
  Bun.spawnSync(["launchctl", "load", plist], { stdout: "pipe", stderr: "pipe" });
}

// --- macOS launchd ---

function triggersInstallMacos(): void {
  const bin = binPath();

  // Startup trigger
  if (triggerGet("startup", "enabled") === "true") {
    const action = commandFromAction(triggerGet("startup", "action"));
    const label = "com.pai-lite.startup";
    const content = [
      PLIST_HEADER,
      `  <key>Label</key>\n  <string>${label}</string>`,
      `  <key>RunAtLoad</key>\n  <true/>`,
      plistEnv(),
      plistArgs(bin, ...action.split(" ")),
      plistLogs("startup"),
      PLIST_FOOTER,
    ].join("\n");
    installPlist(label, content);
    console.log("Installed launchd trigger: startup");
  }

  // Sync trigger
  if (triggerGet("sync", "enabled") === "true") {
    const action = commandFromAction(triggerGet("sync", "action"));
    const interval = triggerGet("sync", "interval") || "3600";
    const label = "com.pai-lite.sync";
    const content = [
      PLIST_HEADER,
      `  <key>Label</key>\n  <string>${label}</string>`,
      `  <key>StartInterval</key>\n  <integer>${interval}</integer>`,
      plistEnv(),
      plistArgs(bin, ...action.split(" ")),
      plistLogs("sync"),
      PLIST_FOOTER,
    ].join("\n");
    installPlist(label, content);
    console.log("Installed launchd trigger: sync");
  }

  // Morning briefing trigger
  if (triggerGet("morning", "enabled") === "true") {
    const action = commandFromAction(triggerGet("morning", "action"));
    const hour = triggerGet("morning", "hour") || "8";
    const minute = triggerGet("morning", "minute") || "0";
    const label = "com.pai-lite.morning";
    const content = [
      PLIST_HEADER,
      `  <key>Label</key>\n  <string>${label}</string>`,
      `  <key>StartCalendarInterval</key>\n  <dict>\n    <key>Hour</key>\n    <integer>${hour}</integer>\n    <key>Minute</key>\n    <integer>${minute}</integer>\n  </dict>`,
      plistEnv(),
      plistArgs(bin, ...action.split(" ")),
      plistLogs("morning"),
      PLIST_FOOTER,
    ].join("\n");
    installPlist(label, content);
    console.log(`Installed launchd trigger: morning (daily at ${hour}:${minute.padStart(2, "0")})`);
  }

  // Health check trigger
  if (triggerGet("health", "enabled") === "true") {
    const action = commandFromAction(triggerGet("health", "action"));
    const interval = triggerGet("health", "interval") || "14400";
    const label = "com.pai-lite.health";
    const content = [
      PLIST_HEADER,
      `  <key>Label</key>\n  <string>${label}</string>`,
      `  <key>StartInterval</key>\n  <integer>${interval}</integer>`,
      plistEnv(),
      plistArgs(bin, ...action.split(" ")),
      plistLogs("health"),
      PLIST_FOOTER,
    ].join("\n");
    installPlist(label, content);
    console.log(`Installed launchd trigger: health (every ${Math.floor(parseInt(interval) / 3600)}h)`);
  }

  // Watch triggers
  for (const rule of triggerGetWatchRules()) {
    const sanitized = sanitizeAction(rule.action);
    const label = `com.pai-lite.watch-${sanitized}`;
    const actionCmd = commandFromAction(rule.action);

    let watchPaths = `  <key>WatchPaths</key>\n  <array>\n`;
    for (const p of rule.paths) {
      watchPaths += `    <string>${p}</string>\n`;
    }
    watchPaths += `  </array>`;

    const content = [
      PLIST_HEADER,
      `  <key>Label</key>\n  <string>${label}</string>`,
      watchPaths,
      plistEnv(),
      plistArgs(bin, ...actionCmd.split(" ")),
      plistLogs(`watch-${sanitized}`),
      PLIST_FOOTER,
    ].join("\n");
    installPlist(label, content);
    console.log(`Installed launchd trigger: watch-${sanitized} (${rule.paths.length} paths)`);
  }

  // Federation trigger
  if (triggerGet("federation", "enabled") === "true") {
    const action = commandFromAction(triggerGet("federation", "action"));
    const interval = triggerGet("federation", "interval") || "300";
    const label = "com.pai-lite.federation";
    const content = [
      PLIST_HEADER,
      `  <key>Label</key>\n  <string>${label}</string>`,
      `  <key>StartInterval</key>\n  <integer>${interval}</integer>`,
      plistEnv(),
      plistArgs(bin, ...action.split(" ")),
      plistLogs("federation"),
      PLIST_FOOTER,
    ].join("\n");
    installPlist(label, content);
    console.log(`Installed launchd trigger: federation (every ${Math.floor(parseInt(interval) / 60)}m)`);
  }

  // Mayor keepalive
  const config = loadConfigSync();
  const mayorEnabled = (config.mayor as Record<string, unknown> | undefined)?.enabled;
  if (mayorEnabled === true || mayorEnabled === "true") {
    const label = "com.pai-lite.mayor";
    const content = [
      PLIST_HEADER,
      `  <key>Label</key>\n  <string>${label}</string>`,
      `  <key>RunAtLoad</key>\n  <true/>`,
      `  <key>StartInterval</key>\n  <integer>900</integer>`,
      plistEnv(),
      plistArgs(bin, "mayor", "start"),
      plistLogs("mayor"),
      PLIST_FOOTER,
    ].join("\n");
    installPlist(label, content);
    console.log("Installed launchd trigger: mayor (keepalive every 15m)");
  }

  // Dashboard trigger
  if (triggerGet("dashboard", "enabled") === "true") {
    let port = triggerGet("dashboard", "port");
    if (!port) port = String(config.dashboard?.port ?? 7678);
    const label = "com.pai-lite.dashboard";
    const content = [
      PLIST_HEADER,
      `  <key>Label</key>\n  <string>${label}</string>`,
      `  <key>KeepAlive</key>\n  <true/>`,
      `  <key>RunAtLoad</key>\n  <true/>`,
      plistEnv(),
      plistArgs(bin, "dashboard", "serve", port),
      plistLogs("dashboard"),
      PLIST_FOOTER,
    ].join("\n");
    installPlist(label, content);
    console.log(`Installed launchd trigger: dashboard (port ${port}, KeepAlive)`);
  }
}

// --- Linux systemd ---

function writeSystemdUnit(name: string, content: string): void {
  const dir = join(process.env.HOME!, ".config/systemd/user");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), content);
}

function enableSystemdUnit(unitName: string): void {
  Bun.spawnSync(["systemctl", "--user", "daemon-reload"], { stdout: "pipe", stderr: "pipe" });
  Bun.spawnSync(["systemctl", "--user", "enable", "--now", unitName], { stdout: "pipe", stderr: "pipe" });
}

function triggersInstallLinux(): void {
  const bin = binPath();

  // Startup
  if (triggerGet("startup", "enabled") === "true") {
    const action = commandFromAction(triggerGet("startup", "action"));
    writeSystemdUnit("pai-lite-startup.service", `[Unit]\nDescription=pai-lite startup trigger\n\n[Service]\nType=oneshot\nExecStart=${bin} ${action}\n\n[Install]\nWantedBy=default.target\n`);
    enableSystemdUnit("pai-lite-startup.service");
    console.log("Installed systemd trigger: startup");
  }

  // Sync
  if (triggerGet("sync", "enabled") === "true") {
    const action = commandFromAction(triggerGet("sync", "action"));
    const interval = triggerGet("sync", "interval") || "3600";
    writeSystemdUnit("pai-lite-sync.service", `[Unit]\nDescription=pai-lite sync trigger\n\n[Service]\nType=oneshot\nExecStart=${bin} ${action}\n`);
    writeSystemdUnit("pai-lite-sync.timer", `[Unit]\nDescription=pai-lite sync timer\n\n[Timer]\nOnUnitActiveSec=${interval}s\nUnit=pai-lite-sync.service\n\n[Install]\nWantedBy=timers.target\n`);
    enableSystemdUnit("pai-lite-sync.timer");
    console.log("Installed systemd trigger: sync");
  }

  // Morning
  if (triggerGet("morning", "enabled") === "true") {
    const action = commandFromAction(triggerGet("morning", "action"));
    const hour = triggerGet("morning", "hour") || "8";
    const minute = (triggerGet("morning", "minute") || "0").padStart(2, "0");
    writeSystemdUnit("pai-lite-morning.service", `[Unit]\nDescription=pai-lite morning briefing\n\n[Service]\nType=oneshot\nExecStart=${bin} ${action}\n`);
    writeSystemdUnit("pai-lite-morning.timer", `[Unit]\nDescription=pai-lite morning briefing timer\n\n[Timer]\nOnCalendar=*-*-* ${hour}:${minute}:00\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n`);
    enableSystemdUnit("pai-lite-morning.timer");
    console.log(`Installed systemd trigger: morning (daily at ${hour}:${minute})`);
  }

  // Health
  if (triggerGet("health", "enabled") === "true") {
    const action = commandFromAction(triggerGet("health", "action"));
    const interval = triggerGet("health", "interval") || "14400";
    writeSystemdUnit("pai-lite-health.service", `[Unit]\nDescription=pai-lite health check\n\n[Service]\nType=oneshot\nExecStart=${bin} ${action}\n`);
    writeSystemdUnit("pai-lite-health.timer", `[Unit]\nDescription=pai-lite health check timer\n\n[Timer]\nOnUnitActiveSec=${interval}s\nUnit=pai-lite-health.service\n\n[Install]\nWantedBy=timers.target\n`);
    enableSystemdUnit("pai-lite-health.timer");
    console.log(`Installed systemd trigger: health (every ${Math.floor(parseInt(interval) / 3600)}h)`);
  }

  // Watch
  for (const rule of triggerGetWatchRules()) {
    const sanitized = sanitizeAction(rule.action);
    const unitName = `pai-lite-watch-${sanitized}`;
    const actionCmd = commandFromAction(rule.action);

    writeSystemdUnit(`${unitName}.service`, `[Unit]\nDescription=pai-lite watch trigger (${rule.action})\n\n[Service]\nType=oneshot\nExecStart=${bin} ${actionCmd}\n`);

    let pathUnit = `[Unit]\nDescription=pai-lite watch for file changes (${rule.action})\n\n[Path]\n`;
    for (const p of rule.paths) {
      pathUnit += `PathModified=${p}\n`;
    }
    pathUnit += `Unit=${unitName}.service\n\n[Install]\nWantedBy=default.target\n`;

    writeSystemdUnit(`${unitName}.path`, pathUnit);
    enableSystemdUnit(`${unitName}.path`);
    console.log(`Installed systemd trigger: watch-${sanitized} (${rule.paths.length} paths)`);
  }

  // Federation
  if (triggerGet("federation", "enabled") === "true") {
    const action = commandFromAction(triggerGet("federation", "action"));
    const interval = triggerGet("federation", "interval") || "300";
    writeSystemdUnit("pai-lite-federation.service", `[Unit]\nDescription=pai-lite federation heartbeat\n\n[Service]\nType=oneshot\nExecStart=${bin} ${action}\n`);
    writeSystemdUnit("pai-lite-federation.timer", `[Unit]\nDescription=pai-lite federation timer\n\n[Timer]\nOnUnitActiveSec=${interval}s\nUnit=pai-lite-federation.service\n\n[Install]\nWantedBy=timers.target\n`);
    enableSystemdUnit("pai-lite-federation.timer");
    console.log(`Installed systemd trigger: federation (every ${Math.floor(parseInt(interval) / 60)}m)`);
  }

  // Mayor keepalive
  const config = loadConfigSync();
  const mayorEnabled = (config.mayor as Record<string, unknown> | undefined)?.enabled;
  if (mayorEnabled === true || mayorEnabled === "true") {
    writeSystemdUnit("pai-lite-mayor.service", `[Unit]\nDescription=pai-lite Mayor keepalive\n\n[Service]\nType=oneshot\nExecStart=${bin} mayor start\n`);
    writeSystemdUnit("pai-lite-mayor.timer", `[Unit]\nDescription=pai-lite Mayor keepalive timer\n\n[Timer]\nOnBootSec=60\nOnUnitActiveSec=900s\nUnit=pai-lite-mayor.service\n\n[Install]\nWantedBy=timers.target\n`);
    enableSystemdUnit("pai-lite-mayor.timer");
    console.log("Installed systemd trigger: mayor (keepalive every 15m)");
  }

  // Dashboard
  if (triggerGet("dashboard", "enabled") === "true") {
    let port = triggerGet("dashboard", "port");
    if (!port) port = String(config.dashboard?.port ?? 7678);
    writeSystemdUnit("pai-lite-dashboard.service", `[Unit]\nDescription=pai-lite dashboard server\n\n[Service]\nType=simple\nExecStart=${bin} dashboard serve ${port}\nRestart=on-failure\n\n[Install]\nWantedBy=default.target\n`);
    enableSystemdUnit("pai-lite-dashboard.service");
    console.log(`Installed systemd trigger: dashboard (port ${port})`);
  }
}

// --- Uninstall ---

function triggersUninstallMacos(): void {
  const agentsDir = join(process.env.HOME!, "Library/LaunchAgents");
  const labels = [
    "com.pai-lite.startup", "com.pai-lite.sync", "com.pai-lite.morning",
    "com.pai-lite.health", "com.pai-lite.federation", "com.pai-lite.mayor",
    "com.pai-lite.dashboard",
  ];

  for (const label of labels) {
    const plist = join(agentsDir, `${label}.plist`);
    if (existsSync(plist)) {
      Bun.spawnSync(["launchctl", "unload", plist], { stdout: "pipe", stderr: "pipe" });
      unlinkSync(plist);
      console.log(`Uninstalled launchd trigger: ${label.replace("com.pai-lite.", "")}`);
    }
  }

  // Watch plists
  if (existsSync(agentsDir)) {
    for (const f of readdirSync(agentsDir)) {
      if (f.startsWith("com.pai-lite.watch-") && f.endsWith(".plist")) {
        const plist = join(agentsDir, f);
        Bun.spawnSync(["launchctl", "unload", plist], { stdout: "pipe", stderr: "pipe" });
        unlinkSync(plist);
        console.log(`Uninstalled launchd trigger: ${f.replace("com.pai-lite.", "").replace(".plist", "")}`);
      }
    }
  }

  console.log("All pai-lite launchd triggers uninstalled");
}

function triggersUninstallLinux(): void {
  const systemdDir = join(process.env.HOME!, ".config/systemd/user");
  const names = ["startup", "sync", "morning", "health", "federation", "mayor", "dashboard"];

  for (const name of names) {
    const serviceFile = join(systemdDir, `pai-lite-${name}.service`);
    const timerFile = join(systemdDir, `pai-lite-${name}.timer`);
    const pathFile = join(systemdDir, `pai-lite-${name}.path`);

    if (existsSync(timerFile)) {
      Bun.spawnSync(["systemctl", "--user", "disable", "--now", `pai-lite-${name}.timer`], { stdout: "pipe", stderr: "pipe" });
      unlinkSync(timerFile);
    }
    if (existsSync(pathFile)) {
      Bun.spawnSync(["systemctl", "--user", "disable", "--now", `pai-lite-${name}.path`], { stdout: "pipe", stderr: "pipe" });
      unlinkSync(pathFile);
    }
    if (existsSync(serviceFile)) {
      Bun.spawnSync(["systemctl", "--user", "disable", "--now", `pai-lite-${name}.service`], { stdout: "pipe", stderr: "pipe" });
      unlinkSync(serviceFile);
      console.log(`Uninstalled systemd trigger: ${name}`);
    }
  }

  // Watch units
  if (existsSync(systemdDir)) {
    for (const f of readdirSync(systemdDir)) {
      if (f.startsWith("pai-lite-watch-") && f.endsWith(".service")) {
        const unitName = f.replace(".service", "");
        const pathFile = join(systemdDir, `${unitName}.path`);
        if (existsSync(pathFile)) {
          Bun.spawnSync(["systemctl", "--user", "disable", "--now", `${unitName}.path`], { stdout: "pipe", stderr: "pipe" });
          unlinkSync(pathFile);
        }
        Bun.spawnSync(["systemctl", "--user", "disable", "--now", `${unitName}.service`], { stdout: "pipe", stderr: "pipe" });
        unlinkSync(join(systemdDir, f));
        console.log(`Uninstalled systemd trigger: ${unitName.replace("pai-lite-", "")}`);
      }
    }
  }

  Bun.spawnSync(["systemctl", "--user", "daemon-reload"], { stdout: "pipe", stderr: "pipe" });
  console.log("All pai-lite systemd triggers uninstalled");
}

// --- Status ---

function triggersStatusMacos(): void {
  const agentsDir = join(process.env.HOME!, "Library/LaunchAgents");
  const labels = [
    "com.pai-lite.startup", "com.pai-lite.sync", "com.pai-lite.morning",
    "com.pai-lite.health", "com.pai-lite.federation", "com.pai-lite.mayor",
    "com.pai-lite.dashboard",
  ];

  console.log("pai-lite launchd triggers:");
  console.log("");

  let foundAny = false;

  for (const label of labels) {
    const plist = join(agentsDir, `${label}.plist`);
    if (!existsSync(plist)) continue;
    foundAny = true;

    const name = label.replace("com.pai-lite.", "");
    const check = Bun.spawnSync(["launchctl", "list", label], { stdout: "pipe", stderr: "pipe" });
    const status = check.exitCode === 0 ? "loaded" : "not loaded";
    console.log(`  ${name.padEnd(20)} ${status}`);
  }

  // Watch plists
  if (existsSync(agentsDir)) {
    for (const f of readdirSync(agentsDir)) {
      if (f.startsWith("com.pai-lite.watch-") && f.endsWith(".plist")) {
        foundAny = true;
        const label = f.replace(".plist", "");
        const name = label.replace("com.pai-lite.", "");
        const check = Bun.spawnSync(["launchctl", "list", label], { stdout: "pipe", stderr: "pipe" });
        const status = check.exitCode === 0 ? "loaded" : "not loaded";
        console.log(`  ${name.padEnd(20)} ${status}`);
      }
    }
  }

  if (!foundAny) {
    console.log("  No pai-lite triggers installed");
  }

  console.log("");
  console.log(`Log files: ${process.env.HOME}/Library/Logs/pai-lite-*.log`);
}

function triggersStatusLinux(): void {
  const systemdDir = join(process.env.HOME!, ".config/systemd/user");
  const names = ["startup", "sync", "morning", "health", "federation", "mayor", "dashboard"];

  console.log("pai-lite systemd triggers:");
  console.log("");

  let foundAny = false;

  for (const name of names) {
    const serviceFile = join(systemdDir, `pai-lite-${name}.service`);
    if (!existsSync(serviceFile)) continue;
    foundAny = true;

    const timerFile = join(systemdDir, `pai-lite-${name}.timer`);
    const pathFile = join(systemdDir, `pai-lite-${name}.path`);

    let unitToCheck = `pai-lite-${name}.service`;
    if (existsSync(timerFile)) unitToCheck = `pai-lite-${name}.timer`;
    else if (existsSync(pathFile)) unitToCheck = `pai-lite-${name}.path`;

    const check = Bun.spawnSync(["systemctl", "--user", "is-active", unitToCheck], { stdout: "pipe", stderr: "pipe" });
    const status = check.stdout.toString().trim() || "inactive";
    console.log(`  ${name.padEnd(20)} ${status}`);
  }

  // Watch units
  if (existsSync(systemdDir)) {
    for (const f of readdirSync(systemdDir)) {
      if (f.startsWith("pai-lite-watch-") && f.endsWith(".service")) {
        foundAny = true;
        const unitName = f.replace(".service", "");
        const name = unitName.replace("pai-lite-", "");
        const pathFile = join(systemdDir, `${unitName}.path`);
        const unitToCheck = existsSync(pathFile) ? `${unitName}.path` : `${unitName}.service`;
        const check = Bun.spawnSync(["systemctl", "--user", "is-active", unitToCheck], { stdout: "pipe", stderr: "pipe" });
        const status = check.stdout.toString().trim() || "inactive";
        console.log(`  ${name.padEnd(20)} ${status}`);
      }
    }
  }

  if (!foundAny) {
    console.log("  No pai-lite triggers installed");
  }

  console.log("");
  console.log("View logs: journalctl --user -u 'pai-lite-*'");
}

// --- Public API ---

function currentPlatform(): string {
  const result = Bun.spawnSync(["uname", "-s"], { stdout: "pipe", stderr: "pipe" });
  return result.stdout.toString().trim();
}

export function triggersInstall(): void {
  const platform = currentPlatform();
  switch (platform) {
    case "Darwin":
      triggersInstallMacos();
      break;
    case "Linux":
      triggersInstallLinux();
      break;
    default:
      throw new Error(`unsupported OS for triggers: ${platform}`);
  }
}

export function triggersUninstall(): void {
  const platform = currentPlatform();
  switch (platform) {
    case "Darwin":
      triggersUninstallMacos();
      break;
    case "Linux":
      triggersUninstallLinux();
      break;
    default:
      throw new Error(`unsupported OS for triggers: ${platform}`);
  }
}

export function triggersStatus(): void {
  const platform = currentPlatform();
  switch (platform) {
    case "Darwin":
      triggersStatusMacos();
      break;
    case "Linux":
      triggersStatusLinux();
      break;
    default:
      throw new Error(`unsupported OS for triggers: ${platform}`);
  }
}

export async function runTriggers(args: string[]): Promise<void> {
  const sub = args[0] ?? "";

  switch (sub) {
    case "install":
      triggersInstall();
      break;
    case "uninstall":
      triggersUninstall();
      break;
    case "status":
    case "":
      triggersStatus();
      break;
    default:
      throw new Error(`unknown triggers command: ${sub} (use: install, uninstall, status)`);
  }
}

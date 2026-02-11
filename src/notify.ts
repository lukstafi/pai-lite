// Notification system — three-tier ntfy.sh integration

import { existsSync, readFileSync, appendFileSync, mkdirSync } from "fs";
import { join } from "path";
import { loadConfigSync, harnessDir } from "./config.ts";

function notificationLogFile(): string {
  return join(harnessDir(), "journal", "notifications.jsonl");
}

function notifyLog(tier: string, message: string, priority: number, title: string): void {
  const logFile = notificationLogFile();
  mkdirSync(join(harnessDir(), "journal"), { recursive: true });

  const timestamp = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  const escapedTitle = title.replace(/"/g, '\\"');
  const escapedMsg = message.replace(/"/g, '\\"');
  const line = `{"timestamp":"${timestamp}","tier":"${tier}","priority":${priority},"title":"${escapedTitle}","message":"${escapedMsg}"}`;
  appendFileSync(logFile, line + "\n");
}

function notifySend(topic: string, message: string, priority: number, title: string, tags: string): void {
  if (!topic) throw new Error("notify: topic required");
  if (!message) throw new Error("notify: message required");

  const curlArgs = [
    "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
    "-d", message,
  ];
  if (title) curlArgs.push("-H", `Title: ${title}`);
  curlArgs.push("-H", `Priority: ${priority}`);
  if (tags) curlArgs.push("-H", `Tags: ${tags}`);
  curlArgs.push(`https://ntfy.sh/${topic}`);

  const result = Bun.spawnSync(curlArgs, { stdout: "pipe", stderr: "pipe" });
  const httpCode = result.stdout.toString().trim();
  if (httpCode !== "200") {
    console.error(`pai-lite: ntfy.sh notification failed (HTTP ${httpCode}), logged locally`);
  }
}

function getTopic(tier: string): string {
  const config = loadConfigSync();
  return config.notifications?.topics?.[tier] ?? "";
}

export function notifyPai(message: string, priority: number = 3, title: string = "pai-lite"): void {
  const topic = getTopic("pai");
  notifyLog("pai", message, priority, title);

  if (!topic) {
    console.error("pai-lite: pai topic not configured, logging locally only");
    return;
  }
  notifySend(topic, message, priority, title, "robot_face");
}

export function notifyAgents(message: string, priority: number = 3, title: string = "agent update"): void {
  const topic = getTopic("agents");
  notifyLog("agents", message, priority, title);

  if (!topic) {
    console.error("pai-lite: agents topic not configured, logging locally only");
    return;
  }
  notifySend(topic, message, priority, title, "gear");
}

export function notifyPublic(message: string, priority: number = 3, title: string = "announcement"): void {
  const topic = getTopic("public");
  notifyLog("public", message, priority, title);

  if (!topic) {
    console.error("pai-lite: public topic not configured, logging locally only");
    return;
  }
  notifySend(topic, message, priority, title, "mega,tada");
}

export function notifyRecent(count: number = 10): void {
  const logFile = notificationLogFile();
  if (!existsSync(logFile)) {
    console.log("No notifications yet");
    return;
  }

  const lines = readFileSync(logFile, "utf-8").trim().split("\n");
  const recent = lines.slice(-count);
  for (const line of recent) {
    try {
      const obj = JSON.parse(line);
      console.log(`${obj.timestamp} [${obj.tier}] ${obj.title}: ${obj.message}`);
    } catch {
      console.log(line);
    }
  }
}

export async function runNotify(args: string[]): Promise<void> {
  const tier = args[0] ?? "";

  switch (tier) {
    case "pai":
      if (!args[1]) throw new Error("message required");
      notifyPai(args.slice(1).join(" "));
      break;
    case "agents":
      if (!args[1]) throw new Error("message required");
      notifyAgents(args.slice(1).join(" "));
      break;
    case "public":
      if (!args[1]) throw new Error("message required");
      notifyPublic(args.slice(1).join(" "));
      break;
    case "recent":
      notifyRecent(args[1] ? parseInt(args[1], 10) : 10);
      break;
    default:
      throw new Error(`unknown notify command: ${tier} (use: pai, agents, public, recent)`);
  }
}

// Notification system — ntfy.sh integration (outgoing + incoming + agents)

import { existsSync, readFileSync, appendFileSync, writeFileSync, mkdirSync } from "fs";
import { join } from "path";
import { loadConfigSync, harnessDir } from "./config.ts";
import { queueRequest } from "./queue.ts";

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

function getToken(): string {
  const config = loadConfigSync();
  return config.notifications?.token ?? "";
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
  const token = getToken();
  if (token) curlArgs.push("-H", `Authorization: Bearer ${token}`);
  curlArgs.push(`https://ntfy.sh/${topic}`);

  const result = Bun.spawnSync(curlArgs, { stdout: "pipe", stderr: "pipe" });
  const httpCode = result.stdout.toString().trim();
  if (httpCode !== "200") {
    console.error(`ludics: ntfy.sh notification failed (HTTP ${httpCode}), logged locally`);
  }
}

function getTopic(tier: string): string {
  const config = loadConfigSync();
  const topics = config.notifications?.topics;
  if (!topics) return "";
  // Support "outgoing" with fallback to legacy "pai" key
  if (tier === "outgoing") {
    return topics["outgoing"] ?? topics["pai"] ?? "";
  }
  return topics[tier] ?? "";
}

export function notifyOutgoing(message: string, priority: number = 3, title: string = "ludics"): void {
  const topic = getTopic("outgoing");
  notifyLog("outgoing", message, priority, title);

  if (!topic) {
    console.error("ludics: outgoing topic not configured, logging locally only");
    return;
  }
  notifySend(topic, message, priority, title, "robot_face");
}

/** @deprecated Use notifyOutgoing instead */
export const notifyPai = notifyOutgoing;

export function notifyAgents(message: string, priority: number = 3, title: string = "agent update"): void {
  const topic = getTopic("agents");
  notifyLog("agents", message, priority, title);

  if (!topic) {
    console.error("ludics: agents topic not configured, logging locally only");
    return;
  }
  notifySend(topic, message, priority, title, "gear");
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

// --- Incoming subscriber ---

function subscriberStateFile(): string {
  return join(harnessDir(), "mag", "ntfy-subscriber.state");
}

function loadSubscriberState(): { last_id?: string; last_time?: string } {
  const file = subscriberStateFile();
  if (!existsSync(file)) return {};
  try {
    return JSON.parse(readFileSync(file, "utf-8"));
  } catch {
    return {};
  }
}

function saveSubscriberState(lastId: string): void {
  const file = subscriberStateFile();
  mkdirSync(join(harnessDir(), "mag"), { recursive: true });
  const state = { last_id: lastId, last_time: new Date().toISOString().replace(/\.\d{3}Z$/, "Z") };
  writeFileSync(file, JSON.stringify(state) + "\n");
}

function appendToInbox(message: string, title?: string): void {
  const inboxFile = join(harnessDir(), "mag", "inbox.md");
  mkdirSync(join(harnessDir(), "mag"), { recursive: true });

  const timestamp = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  const heading = title ? `## ntfy: ${title} - ${timestamp}` : `## ntfy Message - ${timestamp}`;
  const entry = `\n${heading}\n\n${message}\n`;

  const existing = existsSync(inboxFile) ? readFileSync(inboxFile, "utf-8") : "# Mag Inbox\n";
  writeFileSync(inboxFile, existing + entry);
}

export async function subscribeIncoming(): Promise<void> {
  const topic = getTopic("incoming");
  if (!topic) {
    console.error("ludics: incoming topic not configured (set notifications.topics.incoming in config)");
    process.exit(1);
  }

  console.log(`ludics: subscribing to incoming messages on topic "${topic}"`);

  let backoff = 1000; // start at 1s
  const MAX_BACKOFF = 60000; // cap at 60s

  while (true) {
    try {
      const state = loadSubscriberState();
      let url = `https://ntfy.sh/${topic}/sse`;
      if (state.last_id) {
        url += `?since=${state.last_id}`;
      }

      console.log(`ludics: connecting to ${url}`);
      const headers: Record<string, string> = {};
      const token = getToken();
      if (token) headers["Authorization"] = `Bearer ${token}`;
      const response = await fetch(url, { headers });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }
      if (!response.body) {
        throw new Error("No response body");
      }

      // Reset backoff on successful connection
      backoff = 1000;

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        // Keep the last partial line in the buffer
        buffer = lines.pop() ?? "";

        for (const line of lines) {
          if (!line.startsWith("data: ")) continue;
          try {
            const data = JSON.parse(line.slice(6));
            if (data.event === "message" && data.message) {
              console.log(`ludics: received message [${data.id}]: ${data.message.slice(0, 80)}`);

              // Append to inbox and queue for Mag
              appendToInbox(data.message, data.title);
              queueRequest("message");

              // Log to journal
              notifyLog("incoming", data.message, 3, data.title || "ntfy incoming");

              // Persist state
              saveSubscriberState(data.id);
            }
          } catch {
            // Ignore unparseable data lines (e.g. open events)
          }
        }
      }

      // Stream ended normally — reconnect
      console.log("ludics: SSE stream ended, reconnecting...");
    } catch (err) {
      console.error(`ludics: subscriber error: ${err instanceof Error ? err.message : String(err)}`);
      console.error(`ludics: retrying in ${backoff / 1000}s...`);
      await Bun.sleep(backoff);
      backoff = Math.min(backoff * 2, MAX_BACKOFF);
    }
  }
}

export async function runNotify(args: string[]): Promise<void> {
  const tier = args[0] ?? "";

  switch (tier) {
    case "outgoing":
    case "pai":
      if (!args[1]) throw new Error("message required");
      notifyOutgoing(args.slice(1).join(" "));
      break;
    case "agents":
      if (!args[1]) throw new Error("message required");
      notifyAgents(args.slice(1).join(" "));
      break;
    case "subscribe":
      await subscribeIncoming();
      break;
    case "recent":
      notifyRecent(args[1] ? parseInt(args[1], 10) : 10);
      break;
    default:
      throw new Error(`unknown notify command: ${tier} (use: outgoing, agents, subscribe, recent)`);
  }
}

// Dashboard server — Bun.serve() replacement for dashboard_server.py
//
// Serves static files from the dashboard directory and lazily regenerates
// data/*.json files when they become stale (TTL-based).

import { existsSync, readFileSync, statSync } from "fs";
import { resolve, extname } from "path";
import { dashboardGenerate } from "./dashboard.ts";

const MIME_TYPES: Record<string, string> = {
  ".html": "text/html",
  ".css": "text/css",
  ".js": "application/javascript",
  ".json": "application/json",
  ".md": "text/markdown; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
};

export function startDashboardServer(
  port: number,
  dashboardDir: string,
  ttlSeconds: number,
): void {
  // Normalize to absolute path with trailing separator for safe startsWith checks
  const resolvedRoot = resolve(dashboardDir) + "/";
  const tasksRoot = resolve(dashboardDir, "..", "tasks") + "/";
  let lastGenerated = 0;

  function maybeRegenerate(): void {
    const now = Math.floor(Date.now() / 1000);
    if (now - lastGenerated >= ttlSeconds) {
      try {
        dashboardGenerate();
        lastGenerated = now;
      } catch (e) {
        console.error(`ludics: dashboard regeneration failed: ${e}`);
      }
    }
  }

  const server = Bun.serve({
    port,
    fetch(req) {
      const url = new URL(req.url);
      let pathname = url.pathname;

      // Default to index.html
      if (pathname === "/") pathname = "/index.html";

      // Regenerate data if stale on any request to /data/
      if (pathname.startsWith("/data/")) {
        maybeRegenerate();
      }

      if (pathname.startsWith("/task-files/")) {
        const taskPath = pathname.slice("/task-files/".length);
        const taskMatch = taskPath.match(/^([A-Za-z0-9._-]+)\.md$/);
        if (!taskMatch) {
          return new Response("Bad Request", { status: 400 });
        }

        const taskFilePath = resolve(tasksRoot, taskMatch[1]! + ".md");
        if (!taskFilePath.startsWith(tasksRoot)) {
          return new Response("Forbidden", { status: 403 });
        }
        if (!existsSync(taskFilePath) || statSync(taskFilePath).isDirectory()) {
          return new Response("Not Found", { status: 404 });
        }

        const body = readFileSync(taskFilePath);
        return new Response(body, {
          headers: { "Content-Type": MIME_TYPES[".md"]! },
        });
      }

      // Resolve file path with proper traversal prevention
      const filePath = resolve(resolvedRoot, "." + pathname);
      if (!filePath.startsWith(resolvedRoot)) {
        return new Response("Forbidden", { status: 403 });
      }
      if (!existsSync(filePath) || statSync(filePath).isDirectory()) {
        return new Response("Not Found", { status: 404 });
      }

      const ext = extname(filePath);
      const contentType = MIME_TYPES[ext] ?? "application/octet-stream";

      const body = readFileSync(filePath);
      return new Response(body, {
        headers: { "Content-Type": contentType },
      });
    },
  });

  console.error(`ludics: dashboard server listening on http://localhost:${server.port}`);
  console.error(`ludics: data regenerates lazily (TTL: ${ttlSeconds}s)`);
  console.error("ludics: press Ctrl+C to stop");
}

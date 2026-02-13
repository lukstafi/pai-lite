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

// Claude.ai bookmark tracker — delegates to shared bookmark module

import { bookmarkReadState, bookmarkStart, bookmarkStop, type BookmarkConfig } from "./bookmark.ts";
import type { AdapterContext, Adapter } from "./types.ts";

const config: BookmarkConfig = {
  adapterName: "claude-ai",
  urlPattern: /claude\.ai\/chat\/([a-zA-Z0-9-]+)/,
  defaultLabel: "Claude.ai conversation",
  defaultModel: "claude-sonnet",
};

export const readState = (ctx: AdapterContext) => bookmarkReadState(config, ctx);
export const start = (ctx: AdapterContext) => bookmarkStart(config, ctx);
export const stop = (ctx: AdapterContext) => bookmarkStop(config, ctx);

export default { readState, start, stop } satisfies Adapter;

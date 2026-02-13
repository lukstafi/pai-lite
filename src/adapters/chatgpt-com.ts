// ChatGPT bookmark tracker — delegates to shared bookmark module

import { bookmarkReadState, bookmarkStart, bookmarkStop, type BookmarkConfig } from "./bookmark.ts";
import type { AdapterContext, Adapter } from "./types.ts";

const config: BookmarkConfig = {
  adapterName: "chatgpt-com",
  urlPattern: /chat\.openai\.com\/c\/([a-zA-Z0-9-]+)/,
  defaultLabel: "ChatGPT conversation",
  defaultModel: "gpt-4",
};

export const readState = (ctx: AdapterContext) => bookmarkReadState(config, ctx);
export const start = (ctx: AdapterContext) => bookmarkStart(config, ctx);
export const stop = (ctx: AdapterContext) => bookmarkStop(config, ctx);

export default { readState, start, stop } satisfies Adapter;

import { describe, test, expect } from "bun:test";
import { MarkdownBuilder } from "./markdown.ts";

describe("MarkdownBuilder", () => {
  test("keyValue produces bold key-value line", () => {
    const md = new MarkdownBuilder();
    md.keyValue("Mode", "agent-claude");
    expect(md.toString()).toBe("**Mode:** agent-claude");
  });

  test("section adds blank line separator before header (when not first)", () => {
    const md = new MarkdownBuilder();
    md.keyValue("Mode", "test");
    md.section("Terminals");
    md.bullet("tmux session 'foo'");
    expect(md.toString()).toBe(
      "**Mode:** test\n\n**Terminals:**\n- tmux session 'foo'",
    );
  });

  test("section does not add blank line when it is the first line", () => {
    const md = new MarkdownBuilder();
    md.section("Header");
    expect(md.toString()).toBe("**Header:**");
  });

  test("bullet adds dash prefix", () => {
    const md = new MarkdownBuilder();
    md.bullet("item 1");
    md.bullet("item 2");
    expect(md.toString()).toBe("- item 1\n- item 2");
  });

  test("detail adds two-space indent", () => {
    const md = new MarkdownBuilder();
    md.bullet("Status: working");
    md.detail("Updated: 5m ago");
    expect(md.toString()).toBe("- Status: working\n  Updated: 5m ago");
  });

  test("line adds raw text", () => {
    const md = new MarkdownBuilder();
    md.line("raw text here");
    expect(md.toString()).toBe("raw text here");
  });

  test("separator adds empty line", () => {
    const md = new MarkdownBuilder();
    md.line("before");
    md.separator();
    md.line("after");
    expect(md.toString()).toBe("before\n\nafter");
  });

  test("rule adds horizontal rule with surrounding blank lines", () => {
    const md = new MarkdownBuilder();
    md.line("above");
    md.rule();
    md.line("below");
    expect(md.toString()).toBe("above\n\n---\n\nbelow");
  });

  test("heading produces correct level", () => {
    const md = new MarkdownBuilder();
    md.heading(3, "Task: my-feature");
    expect(md.toString()).toBe("### Task: my-feature");
  });

  test("chaining works via this return", () => {
    const result = new MarkdownBuilder()
      .keyValue("Mode", "test")
      .section("Git")
      .bullet("Branch: main")
      .toString();
    expect(result).toBe("**Mode:** test\n\n**Git:**\n- Branch: main");
  });

  test("full adapter-like output matches expected format", () => {
    const md = new MarkdownBuilder();
    md.keyValue("Mode", "agent-claude");
    md.section("Terminals");
    md.bullet("Claude Code: tmux session 'my-session'");
    md.bullet("Web: http://localhost:7681");
    md.section("Git");
    md.bullet("Working directory: /home/user/project");
    md.bullet("Branch: feature-x");
    md.section("Runtime");
    md.bullet("Task: implement-feature");
    md.bullet("Status: working - on task");
    md.detail("Updated: 5m ago");

    const expected = [
      "**Mode:** agent-claude",
      "",
      "**Terminals:**",
      "- Claude Code: tmux session 'my-session'",
      "- Web: http://localhost:7681",
      "",
      "**Git:**",
      "- Working directory: /home/user/project",
      "- Branch: feature-x",
      "",
      "**Runtime:**",
      "- Task: implement-feature",
      "- Status: working - on task",
      "  Updated: 5m ago",
    ].join("\n");

    expect(md.toString()).toBe(expected);
  });
});

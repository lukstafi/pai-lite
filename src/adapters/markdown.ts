// Markdown output builder — eliminates repeated lines.push("") + lines.push("**X:**")
// pattern across adapters.

export class MarkdownBuilder {
  private lines: string[] = [];

  /** Add a bold section header (e.g. "**Git:**"), preceded by a blank line separator if not first. */
  section(header: string): this {
    if (this.lines.length > 0) this.lines.push("");
    this.lines.push(`**${header}:**`);
    return this;
  }

  /** Add a bold key-value line (e.g. "**Mode:** agent-claude"). */
  keyValue(key: string, value: string): this {
    this.lines.push(`**${key}:** ${value}`);
    return this;
  }

  /** Add a bullet point (e.g. "- Claude Code: tmux session 'foo'"). */
  bullet(text: string): this {
    this.lines.push(`- ${text}`);
    return this;
  }

  /** Add an indented detail line (e.g. "  Updated: 5m ago"). */
  detail(text: string): this {
    this.lines.push(`  ${text}`);
    return this;
  }

  /** Add a raw line of text. */
  line(text: string): this {
    this.lines.push(text);
    return this;
  }

  /** Add a blank line separator. */
  separator(): this {
    this.lines.push("");
    return this;
  }

  /** Add a horizontal rule (---) with surrounding blank lines. */
  rule(): this {
    this.lines.push("");
    this.lines.push("---");
    this.lines.push("");
    return this;
  }

  /** Add a heading (e.g. "### Task: my-feature"). */
  heading(level: number, text: string): this {
    this.lines.push(`${"#".repeat(level)} ${text}`);
    return this;
  }

  /** Return the built Markdown string. */
  toString(): string {
    return this.lines.join("\n");
  }
}

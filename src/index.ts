#!/usr/bin/env bun
// pai-lite — TypeScript entry point

import { runSessions } from "./sessions/index.ts";
import { runSlots, runSlot } from "./slots/index.ts";
import { runTasks } from "./tasks/index.ts";
import { stateFullSync, statePull, statePush } from "./state.ts";
import { journalRecent, journalList } from "./journal.ts";
import { queueShow } from "./queue.ts";
import { runFlow } from "./flow.ts";
import { runNotify } from "./notify.ts";
import { runMayor } from "./mayor.ts";
import { runDashboard } from "./dashboard.ts";
import { runNetwork } from "./network.ts";
import { runFederation } from "./federation.ts";
import { runTriggers } from "./triggers.ts";
import { slotsList } from "./slots/index.ts";
import { flowReady, flowCritical } from "./flow.ts";

const MIGRATED_COMMANDS: Record<string, (args: string[]) => Promise<void>> = {
  sessions: runSessions,
  slots: runSlots,
  slot: runSlot,
  tasks: runTasks,
  flow: runFlow,
  mayor: runMayor,
  notify: runNotify,
  dashboard: runDashboard,
  network: runNetwork,
  federation: runFederation,
  triggers: runTriggers,
  sync: async () => stateFullSync(),
  state: async (args) => {
    const sub = args[0] ?? "";
    if (sub === "pull") { statePull(); }
    else if (sub === "push") { statePush(); }
    else { throw new Error(`unknown state subcommand: ${sub} (use: pull, push)`); }
  },
  journal: async (args) => {
    const sub = args[0] ?? "";
    if (sub === "" || sub === "today") { journalRecent(); }
    else if (sub === "recent") { journalRecent(parseInt(args[1] ?? "20", 10)); }
    else if (sub === "list") { journalList(parseInt(args[1] ?? "7", 10)); }
    else { throw new Error(`unknown journal subcommand: ${sub}`); }
  },
  status: async () => {
    slotsList();
    console.log("");
    flowReady();
  },
  briefing: async () => {
    const { mayorBriefing } = await import("./mayor.ts");
    mayorBriefing();
  },
  doctor: async () => {
    const { mayorDoctor } = await import("./mayor.ts");
    mayorDoctor();
  },
};

const USAGE = `Usage: pai-lite <command>

Commands:
  slots                        Show all slots
  slots refresh                Refresh slot state from adapters
  slot <n>                     Show slot n
  slot <n> assign <task|desc> [-a adapter] [-s session] [-p path]
                               Assign a task to slot n
  slot <n> clear [done|abandoned]
                               Clear slot n (optionally mark task done/abandoned)
  slot <n> start               Start agent session (adapter)
  slot <n> stop                Stop agent session (adapter)
  slot <n> note "text"         Add runtime note to slot n

  tasks sync                   Aggregate tasks and convert to task files
  tasks list                   Show unified task list
  tasks show <id>              Show task details
  tasks convert                Convert tasks.yaml to individual task files (also run by sync)
  tasks create <title>         Create a new task manually
  tasks files                  List individual task files
  tasks samples                Create sample tasks for testing
  tasks needs-elaboration      List tasks needing elaboration
  tasks queue-elaborations     Queue elaboration for unprocessed ready tasks
  tasks check <id>             Check if task needs elaboration
  tasks merge <target> <src..> Merge source task(s) into target
  tasks duplicates             Find potential duplicate tasks

  flow ready                   Priority-sorted ready tasks
  flow blocked                 What's blocked and why
  flow critical                Deadlines + stalled + high-priority
  flow impact <id>             What this task unblocks
  flow context                 Context distribution across slots
  flow check-cycle             Check for dependency cycles

  mayor start [--no-ttyd]      Start Mayor tmux session (with ttyd by default)
  mayor stop                   Stop Mayor tmux session
  mayor status                 Show Mayor status
  mayor attach                 Attach to Mayor tmux session
  mayor logs [n]               Show recent Mayor activity
  mayor doctor                 Health check for Mayor setup
  mayor briefing               Request morning briefing
  mayor suggest                Get task suggestions
  mayor analyze <issue>        Analyze GitHub issue
  mayor elaborate <id>         Elaborate task into detailed spec
  mayor health-check           Check for stalled work, deadlines
  mayor message "text"         Send async message to Mayor
  mayor inbox                  Show and consume pending messages
  mayor queue                  Show pending queue requests
  mayor context                Pre-compute briefing context file

  notify pai <msg>             Send strategic notification
  notify agents <msg>          Send operational notification
  notify public <msg>          Send public broadcast
  notify recent [n]            Show recent notifications

  dashboard generate           Generate JSON data for dashboard
  dashboard serve [port]       Serve dashboard (default: 7678)
  dashboard install            Install dashboard to state repo

  sessions [--json]            Discover and classify all agent sessions
  sessions report [--json]     Generate sessions report for Mayor (Markdown + JSON)
  sessions refresh [--json]    Re-run discovery and update report
  sessions show [filter]       Show detailed session info (optional cwd/id filter)

  sync                         Pull + push state repo (full sync)
  state pull                   Pull latest from state repo
  state push                   Push local changes to state repo

  journal                      Show today's journal entries
  journal recent [n]           Show last n journal entries
  journal list [days]          List journal files from last n days

  network status               Show network configuration
  federation status            Show federation status (multi-machine Mayor)
  federation tick              Publish heartbeat and run leader election
  federation elect             Run leader election only
  federation heartbeat         Publish heartbeat only

  status                       Overview of slots + tasks
  briefing                     Morning briefing
  init [--no-hooks] [--no-dashboard] [--no-triggers]
                               Initialize config, harness, hooks, dashboard, and triggers
  triggers install             Install launchd/systemd triggers
  triggers status              Show trigger status
  triggers uninstall           Remove all triggers
  doctor                       Check system health and dependencies

  help                         Show this message`;

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const cmd = args[0] ?? "";

  if (cmd === "" || cmd === "help" || cmd === "-h" || cmd === "--help") {
    console.log(USAGE);
    process.exit(0);
  }

  const handler = MIGRATED_COMMANDS[cmd];
  if (handler) {
    await handler(args.slice(1));
  } else {
    console.error(`pai-lite ${cmd}: not yet migrated`);
    process.exit(1);
  }
}

main().catch((err: unknown) => {
  console.error(`pai-lite: fatal: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});

#!/usr/bin/env bash
set -euo pipefail

# pai-lite/lib/sessions.sh - Session discovery + classification

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/common.sh"

sessions_file_path() {
  echo "$(pai_lite_state_harness_dir)/sessions.json"
}

sessions_slots_file_path() {
  if declare -F slots_file_path >/dev/null 2>&1; then
    slots_file_path
  else
    echo "$(pai_lite_state_harness_dir)/slots.md"
  fi
}

sessions_refresh() {
  local output slots_file
  output="$(sessions_file_path)"
  slots_file="$(sessions_slots_file_path)"

  pai_lite_ensure_state_repo
  pai_lite_ensure_state_dir

  python3 - "$output" "$slots_file" << 'PY'
import datetime
import json
import os
import re
import subprocess
import sys
import time
import shutil

output_path = sys.argv[1]
slots_path = sys.argv[2] if len(sys.argv) > 2 else None

now = time.time()
stale_hours = float(os.environ.get("PAI_LITE_SESSIONS_STALE_HOURS", "24"))
stale_cutoff = now - (stale_hours * 3600)


def iso(ts):
    return datetime.datetime.utcfromtimestamp(ts).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_path(path):
    if not path:
        return None
    try:
        path = os.path.expanduser(path)
    except Exception:
        pass
    if path.endswith("/") and path != "/":
        path = path.rstrip("/")
    try:
        path = os.path.abspath(path)
    except Exception:
        pass
    if os.path.exists(path):
        try:
            path = os.path.realpath(path)
        except Exception:
            pass
    return path


def find_key_recursive(obj, keys):
    if isinstance(obj, dict):
        for k in keys:
            if k in obj and obj[k] not in (None, ""):
                return obj[k]
        for v in obj.values():
            res = find_key_recursive(v, keys)
            if res not in (None, ""):
                return res
    elif isinstance(obj, list):
        for v in obj:
            res = find_key_recursive(v, keys)
            if res not in (None, ""):
                return res
    return None


def parse_jsonl(path, prefer_parent=False):
    first_cwd = None
    root_cwd = None
    root_id = None
    source_kind = None
    model = None

    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue

                if first_cwd is None:
                    c = find_key_recursive(obj, ["cwd", "workdir", "workingDirectory"])
                    if isinstance(c, str) and c:
                        first_cwd = c

                if prefer_parent and root_cwd is None:
                    if obj.get("parentUuid", "__missing__") is None:
                        c = find_key_recursive(obj, ["cwd", "workdir", "workingDirectory"])
                        if isinstance(c, str) and c:
                            root_cwd = c
                        root_id = obj.get("uuid") or obj.get("id") or root_id

                if source_kind is None:
                    sk = find_key_recursive(obj, ["sourceKind", "source_kind", "source"])
                    if isinstance(sk, str) and sk:
                        source_kind = sk

                if model is None:
                    m = find_key_recursive(obj, ["model"])
                    if isinstance(m, str) and m:
                        model = m

                if prefer_parent:
                    if root_cwd is not None and (source_kind is not None or model is not None):
                        break
                else:
                    if first_cwd is not None and (source_kind is not None or model is not None):
                        break
    except Exception:
        return None, None, None, None

    return (root_cwd or first_cwd), root_id, source_kind, model


def extract_slots_paths(path):
    slots = []
    if not path or not os.path.isfile(path):
        return slots

    current_slot = None
    current_paths = []

    def flush():
        nonlocal current_slot, current_paths
        if current_slot is None:
            return
        normalized = []
        for p in current_paths:
            np = normalize_path(p)
            if np and np not in normalized:
                normalized.append(np)
        for np in normalized:
            slots.append({"slot": current_slot, "path": np})
        current_paths = []

    def maybe_add_path(raw):
        if not raw:
            return
        raw = raw.strip()
        if raw in ("null", "(empty)"):
            return
        current_paths.append(raw)

    path_line_patterns = [
        re.compile(r"^\\*\\*Path:\\*\\*\\s*(.+)$"),
        re.compile(r"^\\*\\*Root:\\*\\*\\s*(.+)$"),
        re.compile(r"^\\*\\*Base:\\*\\*\\s*(.+)$"),
        re.compile(r"^-\\s*Working directory:\\s*(.+)$"),
        re.compile(r"^-\\s*Base:\\s*(.+)$"),
    ]

    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                m = re.match(r"^##\\s+Slot\\s+([0-9]+)", line)
                if m:
                    flush()
                    current_slot = int(m.group(1))
                    continue

                if current_slot is None:
                    continue

                if line.startswith("**Session:**") or line.startswith("**Process:**"):
                    val = line.split("**", 2)[-1]
                    val = val.split(":", 1)[-1].strip()
                    if val.startswith("/") or val.startswith("~") or val.startswith("./"):
                        maybe_add_path(val)

                for pat in path_line_patterns:
                    m = pat.match(line)
                    if m:
                        maybe_add_path(m.group(1))
                        break
    except Exception:
        return slots

    flush()
    return slots


def tmux_sessions():
    sessions = []
    tmux_paths = {}
    tmux_last = {}

    if not shutil.which("tmux"):
        return sessions, tmux_paths

    try:
        pane_lines = subprocess.check_output(
            ["tmux", "list-panes", "-a", "-F", "#{session_name}|#{pane_active}|#{pane_current_path}"],
            text=True,
        )
    except Exception:
        pane_lines = ""

    for line in pane_lines.splitlines():
        parts = line.split("|", 2)
        if len(parts) != 3:
            continue
        name, active, path = parts
        if not name or not path:
            continue
        if active == "1" or name not in tmux_paths:
            tmux_paths[name] = path

    try:
        session_lines = subprocess.check_output(
            ["tmux", "list-sessions", "-F", "#{session_name}|#{session_last_attached}"],
            text=True,
        )
    except Exception:
        session_lines = ""

    for line in session_lines.splitlines():
        parts = line.split("|", 1)
        if len(parts) != 2:
            continue
        name, last = parts
        try:
            tmux_last[name] = int(last)
        except Exception:
            tmux_last[name] = int(now)

    for name, path in tmux_paths.items():
        last = tmux_last.get(name, int(now))
        sessions.append({
            "source": "tmux",
            "agent": "terminal",
            "id": name,
            "cwd": path,
            "last_activity_epoch": last,
            "meta": {"session_name": name},
        })

    return sessions, tmux_paths


def ttyd_sessions(tmux_paths):
    sessions = []
    lines = ""

    try:
        lines = subprocess.check_output(["pgrep", "-a", "ttyd"], text=True)
    except Exception:
        try:
            lines = subprocess.check_output(["ps", "-ax", "-o", "pid=,command="], text=True)
        except Exception:
            lines = ""

    for line in lines.splitlines():
        if "ttyd" not in line:
            continue
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        pid, cmd = parts
        port = None
        tmux_session = None

        m = re.search(r"\\s-p\\s+(\\d+)", cmd)
        if m:
            port = m.group(1)
        else:
            m = re.search(r"--port\\s+(\\d+)", cmd)
            if m:
                port = m.group(1)

        m = re.search(r"tmux\\s+attach(?:-session)?\\s+-t\\s+([^\\s]+)", cmd)
        if m:
            tmux_session = m.group(1)

        cwd = tmux_paths.get(tmux_session) if tmux_session else None
        sessions.append({
            "source": "ttyd",
            "agent": "terminal",
            "id": pid,
            "cwd": cwd,
            "last_activity_epoch": int(now),
            "meta": {
                "pid": pid,
                "port": port,
                "tmux_session": tmux_session,
                "command": cmd,
            },
        })

    return sessions


def codex_sessions():
    sessions = []
    codex_home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    sessions_dir = os.path.join(codex_home, "sessions")

    if not os.path.isdir(sessions_dir):
        return sessions

    for root, _dirs, files in os.walk(sessions_dir):
        for entry in files:
            if not entry.endswith(".jsonl"):
                continue
            path = os.path.join(root, entry)
            try:
                mtime = os.path.getmtime(path)
            except Exception:
                mtime = int(now)
            cwd, root_id, source_kind, model = parse_jsonl(path, prefer_parent=False)
            meta = {"file": path}
            if root_id:
                meta["thread_id"] = root_id
            if source_kind:
                meta["source_kind"] = source_kind
            if model:
                meta["model"] = model

            sessions.append({
                "source": "codex",
                "agent": "codex",
                "id": root_id or os.path.splitext(entry)[0],
                "cwd": cwd,
                "last_activity_epoch": int(mtime),
                "meta": meta,
            })

    return sessions


def claude_sessions():
    sessions = []
    claude_home = os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")
    projects_dir = os.path.join(claude_home, "projects")

    if not os.path.isdir(projects_dir):
        return sessions

    def coerce_epoch(value):
        if value is None:
            return None
        try:
            if isinstance(value, str):
                if value.isdigit():
                    value = int(value)
                else:
                    return None
            if isinstance(value, (int, float)):
                if value > 1_000_000_000_000:
                    value = value / 1000.0
                return int(value)
        except Exception:
            return None
        return None

    for entry in os.scandir(projects_dir):
        if not entry.is_dir():
            continue
        project_dir = entry.path
        index_path = os.path.join(project_dir, "sessions-index.json")

        if os.path.isfile(index_path):
            try:
                with open(index_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except Exception:
                data = {}

            original_path = data.get("originalPath")
            for sess in data.get("entries") or []:
                session_id = sess.get("sessionId") or sess.get("id")
                if not session_id:
                    continue
                cwd = sess.get("projectPath") or original_path
                if not cwd:
                    continue
                mtime = coerce_epoch(sess.get("fileMtime") or sess.get("modified") or sess.get("updatedAt"))
                if mtime is None:
                    try:
                        mtime = os.path.getmtime(index_path)
                    except Exception:
                        mtime = int(now)

                meta = {
                    "file": index_path,
                    "git_branch": sess.get("gitBranch"),
                    "summary": sess.get("summary"),
                    "message_count": sess.get("messageCount"),
                    "is_sidechain": sess.get("isSidechain"),
                }

                sessions.append({
                    "source": "claude",
                    "agent": "claude-code",
                    "id": session_id,
                    "cwd": cwd,
                    "last_activity_epoch": int(mtime),
                    "meta": meta,
                })
            continue

        for name in os.listdir(project_dir):
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(project_dir, name)
            try:
                mtime = os.path.getmtime(path)
            except Exception:
                mtime = int(now)

            cwd, root_id, _source_kind, model = parse_jsonl(path, prefer_parent=True)
            if not cwd:
                continue

            meta = {"file": path}
            if root_id:
                meta["session_id"] = root_id
            if model:
                meta["model"] = model

            sessions.append({
                "source": "claude",
                "agent": "claude-code",
                "id": root_id or os.path.splitext(name)[0],
                "cwd": cwd,
                "last_activity_epoch": int(mtime),
                "meta": meta,
            })

    return sessions


def find_peer_sync(path):
    if not path:
        return None
    cur = path
    while True:
        candidate = os.path.join(cur, ".peer-sync")
        if os.path.isdir(candidate):
            return candidate
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return None


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""


sessions = []

sessions.extend(codex_sessions())
sessions.extend(claude_sessions())

tmux_list, tmux_paths = tmux_sessions()
sessions.extend(tmux_list)
sessions.extend(ttyd_sessions(tmux_paths))

# Merge by cwd
merged = {}

for entry in sessions:
    cwd_norm = normalize_path(entry.get("cwd"))
    key = cwd_norm or f"unknown:{entry.get('source')}:{entry.get('id')}"

    rec = merged.get(key)
    if rec is None:
        rec = {
            "cwd": entry.get("cwd"),
            "cwd_normalized": cwd_norm,
            "sources": set(),
            "agents": set(),
            "ids": [],
            "details": {},
            "last_activity_epoch": 0,
        }
        merged[key] = rec

    rec["sources"].add(entry.get("source"))
    agent = entry.get("agent")
    if agent:
        rec["agents"].add(agent)

    if entry.get("id") is not None:
        rec["ids"].append(entry.get("id"))

    meta = entry.get("meta") or {}
    src = entry.get("source") or "unknown"
    rec["details"].setdefault(src, [])
    rec["details"][src].append({"id": entry.get("id"), **meta})

    ts = entry.get("last_activity_epoch") or 0
    if ts > rec["last_activity_epoch"]:
        rec["last_activity_epoch"] = ts

# Enrichment: agent-duo/solo via .peer-sync
for rec in merged.values():
    cwd_norm = rec.get("cwd_normalized")
    if not cwd_norm:
        continue
    sync_dir = find_peer_sync(cwd_norm)
    if not sync_dir:
        continue

    mode = read_text(os.path.join(sync_dir, "mode"))
    feature = read_text(os.path.join(sync_dir, "feature"))
    phase = read_text(os.path.join(sync_dir, "phase"))
    round_ = read_text(os.path.join(sync_dir, "round"))

    rec["orchestration"] = {
        "type": "agent-duo" if mode != "solo" else "agent-solo",
        "mode": mode or None,
        "feature": feature or None,
        "phase": phase or None,
        "round": round_ or None,
        "peer_sync": sync_dir,
    }

# Slot classification
slot_paths = extract_slots_paths(slots_path)

for rec in merged.values():
    rec["slot"] = None
    rec["slot_path"] = None
    if not rec.get("cwd_normalized"):
        continue

    best = None
    best_len = -1
    cwd = rec["cwd_normalized"]
    for slot_info in slot_paths:
        spath = slot_info["path"]
        if cwd == spath or cwd.startswith(spath + os.sep):
            if len(spath) > best_len:
                best = slot_info
                best_len = len(spath)

    if best:
        rec["slot"] = best["slot"]
        rec["slot_path"] = best["path"]

# Finalize
final_sessions = []
source_counts = {}

for rec in merged.values():
    rec["sources"] = sorted(rec["sources"])
    rec["agents"] = sorted(rec["agents"])
    rec["last_activity"] = iso(rec["last_activity_epoch"] or now)
    rec["stale"] = (rec["last_activity_epoch"] or 0) < stale_cutoff

    for src in rec["sources"]:
        source_counts[src] = source_counts.get(src, 0) + 1

    final_sessions.append(rec)

final_sessions.sort(key=lambda r: r.get("last_activity_epoch", 0), reverse=True)

unassigned = [s for s in final_sessions if s.get("slot") is None]

output = {
    "generated_at": iso(now),
    "stale_after_hours": stale_hours,
    "sources": source_counts,
    "slots": slot_paths,
    "sessions": final_sessions,
    "unassigned": unassigned,
}

# Atomic write
os.makedirs(os.path.dirname(output_path), exist_ok=True)

tmp_path = output_path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(output, f, indent=2)
    f.write("\n")

os.replace(tmp_path, output_path)
PY

  local session_count unassigned_count
  session_count=$(python3 - "$output" << 'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    print(len(data.get("sessions", [])))
except Exception:
    print(0)
PY
)
  unassigned_count=$(python3 - "$output" << 'PY'
import json,sys
try:
    data = json.load(open(sys.argv[1]))
    print(len(data.get("unassigned", [])))
except Exception:
    print(0)
PY
)

  pai_lite_info "sessions refreshed: ${session_count} sessions (${unassigned_count} unassigned)"
}

sessions_list() {
  local file
  file="$(sessions_file_path)"
  if [[ ! -f "$file" ]]; then
    echo "No sessions file found. Run: pai-lite sessions refresh"
    return 1
  fi

  python3 - "$file" << 'PY'
import json,sys

def fmt_session(s):
    slot = s.get("slot")
    slot_str = f"slot {slot}" if slot else "unassigned"
    cwd = s.get("cwd") or "(no cwd)"
    sources = ",".join(s.get("sources", []))
    stale = " stale" if s.get("stale") else ""
    return f"- {slot_str}: {cwd} [{sources}]{stale}"

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("Failed to read sessions file")
    raise SystemExit(1)

sessions = data.get("sessions", [])
if not sessions:
    print("No sessions found")
    raise SystemExit(0)

for s in sessions:
    print(fmt_session(s))

unassigned = data.get("unassigned", [])
if unassigned:
    print("")
    print(f"Unassigned: {len(unassigned)}")
PY
}

sessions_show() {
  local file
  file="$(sessions_file_path)"
  if [[ ! -f "$file" ]]; then
    echo "No sessions file found. Run: pai-lite sessions refresh"
    return 1
  fi
  cat "$file"
}

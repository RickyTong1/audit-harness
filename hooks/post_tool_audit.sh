#!/usr/bin/env bash
# ============================================================
# PostToolUse Hook: 自动捕获工具调用审计
# ============================================================
# 关键设计：
#   1. 把 stdin 整体 cat 到临时文件（无字节级 read，无截断）
#   2. 用 python3 从临时文件读取并安全解析 JSON
#   3. 不使用 set -e / watchdog / timeout
#   4. 路径与 lib 的 find_runs_dir() 一致：${PWD}/.claude/runs
# ============================================================

# shellcheck source=./_audit_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_audit_common.sh"

BUFFER="${RUNS_DIR}/audit_buffer.jsonl"
mkdir -p "$RUNS_DIR" 2>/dev/null || exit 0

# stdin → 临时文件（整体读取，不再用 dd bs=1 count=8000）
TMPFILE=$(mktemp /tmp/audit_hook_XXXXXX 2>/dev/null) || exit 0
if ! [ -t 0 ]; then
    # head -c 限制最大 1MB，足够任何 tool_input；避免恶意/无穷流
    head -c 1048576 > "$TMPFILE" 2>/dev/null
fi

if ! [[ -s "$TMPFILE" ]]; then
    rm -f "$TMPFILE"
    exit 0
fi

if command -v python3 &>/dev/null; then
    python3 - "$TMPFILE" "$BUFFER" << 'PYEOF' 2>/dev/null
import sys, json, datetime

stdin_file = sys.argv[1]
buffer_file = sys.argv[2]

try:
    with open(stdin_file, "r", encoding="utf-8", errors="replace") as f:
        data = json.loads(f.read())
except Exception:
    sys.exit(0)

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
tool = data.get("tool_name", "tool_use")
sid = data.get("session_id", "")
tool_input = data.get("tool_input", {}) or {}

summary = ""
if tool == "Bash":
    cmd = tool_input.get("command", "") or ""
    for line in cmd.split("\n"):
        line = line.strip()
        if line and not line.startswith("#"):
            summary = line[:200]
            break
    if not summary:
        summary = cmd[:200]
elif tool in ("Write", "Edit"):
    summary = tool_input.get("file_path", "") or ""
elif tool == "NotebookEdit":
    summary = tool_input.get("notebook_path", "") or ""

record = {
    "timestamp": ts,
    "tool": tool,
    "session": sid,
    "summary": summary,
}

with open(buffer_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False) + "\n")
PYEOF
fi

rm -f "$TMPFILE"
exit 0

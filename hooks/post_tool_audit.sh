#!/usr/bin/env bash
# ============================================================
# PostToolUse Hook: 自动捕获工具调用审计
# ============================================================
# 关键设计：
#   1. 先用 dd 把 stdin 存到临时文件（避免 shell 变量损坏中文/引号）
#   2. 用 python3 从临时文件读取并安全解析 JSON
#   3. 不使用 set -e / watchdog / timeout
# ============================================================

RUNS_DIR="${PWD}/.claude/runs"
BUFFER="${RUNS_DIR}/audit_buffer.jsonl"

mkdir -p "$RUNS_DIR" 2>/dev/null || exit 0

# 把 stdin 存到临时文件（避免 shell 变量中转损坏数据）
TMPFILE=$(mktemp /tmp/audit_hook_XXXXXX 2>/dev/null) || exit 0
if ! [ -t 0 ]; then
    dd bs=1 count=8000 of="$TMPFILE" 2>/dev/null
fi

# 检查临时文件是否有内容
[[ -s "$TMPFILE" ]] || { rm -f "$TMPFILE"; exit 0; }

if command -v python3 &>/dev/null; then
    python3 - "$TMPFILE" "$BUFFER" << 'PYEOF' 2>/dev/null
import sys, json, datetime

stdin_file = sys.argv[1]
buffer_file = sys.argv[2]

try:
    with open(stdin_file, "r", encoding="utf-8", errors="replace") as f:
        data = json.loads(f.read())
except:
    sys.exit(0)

ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
tool = data.get("tool_name", "tool_use")
sid = data.get("session_id", "")
tool_input = data.get("tool_input", {})

summary = ""
if tool == "Bash":
    cmd = tool_input.get("command", "")
    for line in cmd.split("\n"):
        line = line.strip()
        if line and not line.startswith("#"):
            summary = line[:200]
            break
    if not summary:
        summary = cmd[:200]
elif tool in ("Write", "Edit"):
    summary = tool_input.get("file_path", "")
elif tool == "NotebookEdit":
    summary = tool_input.get("notebook_path", "")

record = {
    "timestamp": ts,
    "tool": tool,
    "session": sid,
    "summary": summary,
}

with open(buffer_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, ensure_ascii=False) + "\n")
PYEOF
else
    # 无 python3 fallback
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
    TOOL=$(grep -o '"tool_name":"[^"]*"' "$TMPFILE" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "tool_use")
    echo "{\"timestamp\":\"${TIMESTAMP}\",\"tool\":\"${TOOL}\",\"summary\":\"(no python3)\"}" >> "$BUFFER" 2>/dev/null
fi

rm -f "$TMPFILE"
exit 0

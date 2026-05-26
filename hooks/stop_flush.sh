#!/usr/bin/env bash
# ============================================================
# Stop Hook: 每轮会话结束后刷写审计数据
# ============================================================
# 设计：
#   - 不使用 watchdog/timeout，错误静默
#   - session.json 与 index.json 通过 lib CLI 写入（统一 schema）
#   - 不再用 heredoc 内插变量构造 JSON
# ============================================================

# shellcheck source=./_audit_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_audit_common.sh"

BUFFER="${RUNS_DIR}/audit_buffer.jsonl"
PENDING="${RUNS_DIR}/audit_pending.jsonl"
SESSION_FILE="${RUNS_DIR}/.current_session"

mkdir -p "$RUNS_DIR" 2>/dev/null || exit 0

# 是否有数据需要归档
BUFFER_LINES=0
PENDING_LINES=0
[[ -f "$BUFFER" ]] && BUFFER_LINES=$(wc -l < "$BUFFER" 2>/dev/null | tr -d ' ')
[[ -f "$PENDING" ]] && PENDING_LINES=$(wc -l < "$PENDING" 2>/dev/null | tr -d ' ')
[[ $BUFFER_LINES -eq 0 && $PENDING_LINES -eq 0 ]] && exit 0

# 确定 session
SESSION_ID=""
[[ -f "$SESSION_FILE" ]] && SESSION_ID=$(cat "$SESSION_FILE" 2>/dev/null | tr -d '\n\r ')
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="auto_$(date +%Y%m%d_%H%M)"
    echo "$SESSION_ID" > "$SESSION_FILE" 2>/dev/null
fi

SESSION_DIR="${RUNS_DIR}/${SESSION_ID}"
mkdir -p "$SESSION_DIR" 2>/dev/null
TRAIL="${SESSION_DIR}/audit_trail.jsonl"

# 归档：buffer + pending → trail
if [[ -f "$BUFFER" && $BUFFER_LINES -gt 0 ]]; then
    cat "$BUFFER" >> "$TRAIL" 2>/dev/null
    > "$BUFFER" 2>/dev/null
fi
if [[ -f "$PENDING" && $PENDING_LINES -gt 0 ]]; then
    cat "$PENDING" >> "$TRAIL" 2>/dev/null
    > "$PENDING" 2>/dev/null
fi

TOTAL_RECORDS=0
[[ -f "$TRAIL" ]] && TOTAL_RECORDS=$(wc -l < "$TRAIL" 2>/dev/null | tr -d ' ')
NOW=$(audit_now)

# 写 session.json —— 通过 python3 stdin 传值，杜绝 heredoc 变量注入
if command -v python3 &>/dev/null; then
    python3 - "$SESSION_DIR/session.json" "$SESSION_ID" "$NOW" "$TOTAL_RECORDS" << 'PYEOF' 2>/dev/null
import sys, json, os
session_path, sid, now, total = sys.argv[1:5]

# 保留 session.json 中已有的 task / start_time 等字段（由 /start 写入）
existing = {}
if os.path.exists(session_path):
    try:
        with open(session_path, encoding="utf-8") as f:
            existing = json.load(f)
    except Exception:
        existing = {}

existing["session_id"] = sid
existing["last_updated"] = now
existing.setdefault("status", "in_progress")
try:
    existing["total_records"] = int(total)
except ValueError:
    existing["total_records"] = 0

tmp = session_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(existing, f, ensure_ascii=False, indent=2)
os.replace(tmp, session_path)
PYEOF
fi

# 更新 index.json（通过 lib CLI，schema 与 AuditContext.save() 一致）
audit_update_index \
    --id "$SESSION_ID" \
    --type "auto" \
    --status "in_progress" \
    --last-updated "$NOW" \
    --record-count "$TOTAL_RECORDS"

exit 0

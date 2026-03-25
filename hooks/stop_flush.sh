#!/usr/bin/env bash
# ============================================================
# Stop Hook: 每轮会话结束后刷写审计数据
# ============================================================
# 安全保证：不使用 watchdog/timeout，所有命令 2>/dev/null
# ============================================================

RUNS_DIR="${PWD}/.claude/runs"
BUFFER="${RUNS_DIR}/audit_buffer.jsonl"
PENDING="${RUNS_DIR}/audit_pending.jsonl"
INDEX="${RUNS_DIR}/index.json"
SESSION_FILE="${RUNS_DIR}/.current_session"

mkdir -p "$RUNS_DIR" 2>/dev/null || exit 0

# 检查是否有数据需要归档
BUFFER_LINES=0
PENDING_LINES=0
[[ -f "$BUFFER" ]] && BUFFER_LINES=$(wc -l < "$BUFFER" 2>/dev/null | tr -d ' ')
[[ -f "$PENDING" ]] && PENDING_LINES=$(wc -l < "$PENDING" 2>/dev/null | tr -d ' ')

[[ $BUFFER_LINES -eq 0 && $PENDING_LINES -eq 0 ]] && exit 0

# 确定 session
SESSION_ID=""
[[ -f "$SESSION_FILE" ]] && SESSION_ID=$(cat "$SESSION_FILE" 2>/dev/null | tr -d '\n')
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="auto_$(date +%Y%m%d_%H%M)"
    echo "$SESSION_ID" > "$SESSION_FILE" 2>/dev/null
fi

SESSION_DIR="${RUNS_DIR}/${SESSION_ID}"
mkdir -p "$SESSION_DIR" 2>/dev/null
TRAIL="${SESSION_DIR}/audit_trail.jsonl"

# 归档 buffer
if [[ -f "$BUFFER" && $BUFFER_LINES -gt 0 ]]; then
    cat "$BUFFER" >> "$TRAIL" 2>/dev/null
    > "$BUFFER" 2>/dev/null
fi

# 归档 pending
if [[ -f "$PENDING" && $PENDING_LINES -gt 0 ]]; then
    cat "$PENDING" >> "$TRAIL" 2>/dev/null
    > "$PENDING" 2>/dev/null
fi

# 更新 session.json
TOTAL_RECORDS=0
[[ -f "$TRAIL" ]] && TOTAL_RECORDS=$(wc -l < "$TRAIL" 2>/dev/null | tr -d ' ')
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

cat > "${SESSION_DIR}/session.json" 2>/dev/null << SESSIONEOF
{
    "session_id": "${SESSION_ID}",
    "last_updated": "${NOW}",
    "status": "in_progress",
    "total_records": ${TOTAL_RECORDS}
}
SESSIONEOF

# 更新 index.json
if command -v python3 &>/dev/null; then
    python3 -c "
import json
try:
    idx = {'entries': []}
    try:
        with open('$INDEX') as f:
            idx = json.load(f)
    except: pass
    entries = idx.get('entries', [])
    found = False
    for e in entries:
        if e.get('id') == '${SESSION_ID}':
            e['last_updated'] = '${NOW}'
            e['total_records'] = ${TOTAL_RECORDS}
            found = True
            break
    if not found:
        entries.append({'id':'${SESSION_ID}','type':'auto','last_updated':'${NOW}','status':'in_progress','total_records':${TOTAL_RECORDS}})
    with open('$INDEX', 'w') as f:
        json.dump(idx, f, ensure_ascii=False, indent=2)
except: pass
" 2>/dev/null
else
    echo "{\"entries\":[{\"id\":\"${SESSION_ID}\",\"type\":\"auto\",\"last_updated\":\"${NOW}\",\"status\":\"in_progress\",\"total_records\":${TOTAL_RECORDS}}]}" > "$INDEX" 2>/dev/null
fi

exit 0

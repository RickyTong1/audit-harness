#!/usr/bin/env bash
# ============================================================
# UserPromptSubmit Hook: 每轮用户输入时注入 session 上下文
# ============================================================
# 输出的内容会自动注入 Claude 的 context。
# 用途：
#   1. 提醒 Claude 当前 session_id（确保 [AUDIT] 块使用正确的 batch）
#   2. 提醒 Claude 写 [AUDIT] 时同时持久化到 audit_pending.jsonl
#   3. 如果有未解决的 CRITICAL 告警，优先展示
# ============================================================

RUNS_DIR="${PWD}/.claude/runs"
SESSION_FILE="${RUNS_DIR}/.current_session"
INDEX="${RUNS_DIR}/index.json"

[[ -d "$RUNS_DIR" ]] || exit 0

# 读取当前 session
SESSION_ID=""
if [[ -f "$SESSION_FILE" ]]; then
    SESSION_ID=$(cat "$SESSION_FILE" | tr -d '\n')
fi

# 构建注入文本
OUTPUT=""

if [[ -n "$SESSION_ID" ]]; then
    RECORDS=0
    TRAIL="${RUNS_DIR}/${SESSION_ID}/audit_trail.jsonl"
    [[ -f "$TRAIL" ]] && RECORDS=$(wc -l < "$TRAIL" | tr -d ' ')
    OUTPUT="[audit-harness] session=${SESSION_ID} | records=${RECORDS}"
    OUTPUT="${OUTPUT} | 当你输出 [AUDIT] 块时，同时用 Bash 追加到 .claude/runs/audit_pending.jsonl:"
    OUTPUT="${OUTPUT} echo '{\"batch\":\"${SESSION_ID}\",\"action\":\"...\",\"input\":\"...\",\"output\":\"...\"}' >> .claude/runs/audit_pending.jsonl"
fi

# 如果有未解决的 CRITICAL 告警
if [[ -f "$INDEX" ]] && command -v python3 &>/dev/null; then
    ALERTS=$(python3 -c "
import json
try:
    with open('$INDEX') as f:
        idx = json.load(f)
    for e in idx.get('entries', []):
        if e.get('max_anomaly_level') == 'CRITICAL':
            print(f'⚠️ CRITICAL: {e.get(\"id\")} - 有未解决的告警')
except: pass
" 2>/dev/null)
    if [[ -n "$ALERTS" ]]; then
        OUTPUT="${OUTPUT} | ${ALERTS}"
    fi
fi

[[ -n "$OUTPUT" ]] && echo "$OUTPUT"
exit 0

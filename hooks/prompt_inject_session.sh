#!/usr/bin/env bash
# ============================================================
# UserPromptSubmit Hook: 每轮用户输入时注入 session 上下文
# ============================================================
# 安全保证：不使用 watchdog/timeout，所有命令 2>/dev/null
# stdout 输出注入到 Claude 的 context
# ============================================================

RUNS_DIR="${PWD}/.claude/runs"
SESSION_FILE="${RUNS_DIR}/.current_session"
INDEX="${RUNS_DIR}/index.json"

mkdir -p "$RUNS_DIR" 2>/dev/null

SESSION_ID=""
[[ -f "$SESSION_FILE" ]] && SESSION_ID=$(cat "$SESSION_FILE" 2>/dev/null | tr -d '\n')

OUTPUT=""

if [[ -n "$SESSION_ID" ]]; then
    RECORDS=0
    TRAIL="${RUNS_DIR}/${SESSION_ID}/audit_trail.jsonl"
    [[ -f "$TRAIL" ]] && RECORDS=$(wc -l < "$TRAIL" 2>/dev/null | tr -d ' ')
    OUTPUT="[audit-harness] session=${SESSION_ID} | records=${RECORDS}"
    OUTPUT="${OUTPUT} | 当你输出 [AUDIT] 块时，同时用 Bash 追加到 .claude/runs/audit_pending.jsonl:"
    OUTPUT="${OUTPUT} echo '{\"batch\":\"${SESSION_ID}\",\"action\":\"...\",\"input\":\"...\",\"output\":\"...\",\"timestamp\":\"'$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)'\"}' >> .claude/runs/audit_pending.jsonl"
else
    OUTPUT="[audit-harness] 无活跃审计会话。建议执行 /start \"任务描述\" 创建审计会话。"
fi

# CRITICAL 告警检查
if [[ -f "$INDEX" ]] && command -v python3 &>/dev/null; then
    ALERTS=$(python3 -c "
import json
try:
    with open('$INDEX') as f:
        idx = json.load(f)
    for e in idx.get('entries', []):
        if e.get('max_anomaly_level') == 'CRITICAL':
            print(f'CRITICAL: {e.get(\"id\")}')
except: pass
" 2>/dev/null || true)
    [[ -n "$ALERTS" ]] && OUTPUT="${OUTPUT} | ${ALERTS}"
fi

[[ -n "$OUTPUT" ]] && echo "$OUTPUT"
exit 0

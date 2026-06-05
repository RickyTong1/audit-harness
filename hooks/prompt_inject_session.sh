#!/usr/bin/env bash
# ============================================================
# UserPromptSubmit Hook: 每轮用户输入时注入 session 上下文
# ============================================================
# 输出 JSON hookSpecificOutput.additionalContext 格式，
# 兼容 Claude Code 和 Codex CLI。裸文本 echo 在部分版本的
# Claude Code 中会被内部对象序列化为 [object Object]。
# ============================================================

# shellcheck source=./_audit_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_audit_common.sh"

SESSION_FILE="${RUNS_DIR}/.current_session"
INDEX="${RUNS_DIR}/index.json"

mkdir -p "$RUNS_DIR" 2>/dev/null

SESSION_ID=""
[[ -f "$SESSION_FILE" ]] && SESSION_ID=$(cat "$SESSION_FILE" 2>/dev/null | tr -d '\n\r ')

CONTEXT=""

if [[ -n "$SESSION_ID" ]]; then
    RECORDS=0
    TRAIL="${RUNS_DIR}/${SESSION_ID}/audit_trail.jsonl"
    [[ -f "$TRAIL" ]] && RECORDS=$(wc -l < "$TRAIL" 2>/dev/null | tr -d ' ')
    NOW=$(audit_now)
    CONTEXT="[audit-harness] session=${SESSION_ID} records=${RECORDS}
当输出 [AUDIT] 块时，同时用 Bash 追加到 .claude/runs/audit_pending.jsonl：
  echo '{\"batch\":\"${SESSION_ID}\",\"action\":\"...\",\"input\":\"...\",\"output\":\"...\",\"timestamp\":\"${NOW}\"}' >> .claude/runs/audit_pending.jsonl"
else
    CONTEXT="[audit-harness] 无活跃审计会话。建议执行 /start \"任务描述\" 创建审计会话。"
fi

# CRITICAL 告警检查 —— 通过 python3 stdin 传 index 路径，不嵌入到源码字符串
if [[ -f "$INDEX" ]] && command -v python3 &>/dev/null; then
    ALERTS=$(python3 - "$INDEX" << 'PYEOF' 2>/dev/null
import sys, json
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        idx = json.load(f)
    for e in idx.get("entries", []):
        if e.get("max_anomaly_level") == "CRITICAL":
            print(f"CRITICAL: {e.get('id')}")
except Exception:
    pass
PYEOF
)
    if [[ -n "$ALERTS" ]]; then
        CONTEXT="${CONTEXT}
告警：
${ALERTS}"
    fi
fi

if [[ -n "$CONTEXT" ]]; then
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
ctx = sys.stdin.read()
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit',
        'additionalContext': ctx
    }
}, ensure_ascii=False))
" <<< "$CONTEXT"
    else
        ESCAPED=$(printf '%s' "$CONTEXT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n')
        printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$ESCAPED"
    fi
fi
exit 0

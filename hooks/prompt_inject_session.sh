#!/usr/bin/env bash
# ============================================================
# UserPromptSubmit Hook: 每轮用户输入时注入 session 上下文
# ============================================================
# stdout 输出注入到 Agent 的 context
# 不使用 watchdog/timeout，错误静默
# ============================================================

# shellcheck source=./_audit_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_audit_common.sh"

SESSION_FILE="${RUNS_DIR}/.current_session"
INDEX="${RUNS_DIR}/index.json"

mkdir -p "$RUNS_DIR" 2>/dev/null

SESSION_ID=""
[[ -f "$SESSION_FILE" ]] && SESSION_ID=$(cat "$SESSION_FILE" 2>/dev/null | tr -d '\n\r ')

OUTPUT=""

if [[ -n "$SESSION_ID" ]]; then
    RECORDS=0
    TRAIL="${RUNS_DIR}/${SESSION_ID}/audit_trail.jsonl"
    [[ -f "$TRAIL" ]] && RECORDS=$(wc -l < "$TRAIL" 2>/dev/null | tr -d ' ')
    NOW=$(audit_now)
    OUTPUT="[audit-harness] session=${SESSION_ID} records=${RECORDS}"
    # 提示 Agent 如何持久化 [AUDIT] 块（占位符 SESSION_ID 在 CLAUDE.md
    # 中是字面字符串；这里实际注入 session_id 真值）
    OUTPUT="${OUTPUT}
当输出 [AUDIT] 块时，同时用 Bash 追加到 .claude/runs/audit_pending.jsonl：
  echo '{\"batch\":\"${SESSION_ID}\",\"action\":\"...\",\"input\":\"...\",\"output\":\"...\",\"timestamp\":\"${NOW}\"}' >> .claude/runs/audit_pending.jsonl"
else
    OUTPUT="[audit-harness] 无活跃审计会话。建议执行 /start \"任务描述\" 创建审计会话。"
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
        OUTPUT="${OUTPUT}
告警：
${ALERTS}"
    fi
fi

[[ -n "$OUTPUT" ]] && echo "$OUTPUT"
exit 0

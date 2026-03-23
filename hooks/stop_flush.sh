#!/usr/bin/env bash
# ============================================================
# Stop Hook: 每轮会话结束后刷写审计数据
# ============================================================
# Claude 每次回复结束后自动触发。
# 1. 读取 audit_buffer.jsonl（PostToolUse hook 写入的工具操作记录）
# 2. 读取 audit_pending.jsonl（Claude 主动写入的 [AUDIT] 块）
# 3. 将两者合并归档到当前 session 的 audit_trail.jsonl
# 4. 更新 index.json
# 5. 清空 buffer
# ============================================================

RUNS_DIR="${PWD}/.claude/runs"
BUFFER="${RUNS_DIR}/audit_buffer.jsonl"
PENDING="${RUNS_DIR}/audit_pending.jsonl"
INDEX="${RUNS_DIR}/index.json"
SESSION_FILE="${RUNS_DIR}/.current_session"

# 如果 runs 目录不存在，跳过
[[ -d "$RUNS_DIR" ]] || exit 0

# 如果 buffer 和 pending 都是空的，什么都不做
BUFFER_LINES=0
PENDING_LINES=0
[[ -f "$BUFFER" ]] && BUFFER_LINES=$(wc -l < "$BUFFER" | tr -d ' ')
[[ -f "$PENDING" ]] && PENDING_LINES=$(wc -l < "$PENDING" | tr -d ' ')

[[ $BUFFER_LINES -eq 0 && $PENDING_LINES -eq 0 ]] && exit 0

# 确定当前 session 目录
SESSION_ID=""
if [[ -f "$SESSION_FILE" ]]; then
    SESSION_ID=$(cat "$SESSION_FILE" | tr -d '\n')
fi

# 如果没有活跃 session，创建一个自动 session
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="auto_$(date +%Y%m%d_%H%M)"
    echo "$SESSION_ID" > "$SESSION_FILE"
fi

SESSION_DIR="${RUNS_DIR}/${SESSION_ID}"
mkdir -p "$SESSION_DIR"

TRAIL="${SESSION_DIR}/audit_trail.jsonl"

# 1. 归档 buffer（工具操作记录）
if [[ -f "$BUFFER" && $BUFFER_LINES -gt 0 ]]; then
    cat "$BUFFER" >> "$TRAIL"
    > "$BUFFER"  # 清空但不删除
fi

# 2. 归档 pending（Claude 写入的 [AUDIT] 块）
if [[ -f "$PENDING" && $PENDING_LINES -gt 0 ]]; then
    cat "$PENDING" >> "$TRAIL"
    > "$PENDING"
fi

# 3. 更新 session.json
TOTAL_RECORDS=0
[[ -f "$TRAIL" ]] && TOTAL_RECORDS=$(wc -l < "$TRAIL" | tr -d ' ')
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "${SESSION_DIR}/session.json" << SESSIONEOF
{
    "session_id": "${SESSION_ID}",
    "last_updated": "${NOW}",
    "status": "in_progress",
    "total_records": ${TOTAL_RECORDS}
}
SESSIONEOF

# 4. 更新 index.json
# 简单策略：重写整个 index（session 数量不会很多）
_update_index() {
    local new_entry="{\"id\":\"${SESSION_ID}\",\"type\":\"auto\",\"last_updated\":\"${NOW}\",\"status\":\"in_progress\",\"total_records\":${TOTAL_RECORDS}}"

    if [[ ! -f "$INDEX" ]]; then
        echo "{\"entries\":[${new_entry}]}" > "$INDEX"
        return
    fi

    # 用 sed 替换或追加（纯 bash，不依赖 python/jq）
    # 如果 session_id 已存在，替换该行；否则追加
    if grep -q "\"${SESSION_ID}\"" "$INDEX" 2>/dev/null; then
        # 已存在 → 用 python 做最小更新（如果可用），否则跳过
        if command -v python3 &>/dev/null; then
            python3 -c "
import json, sys
with open('$INDEX') as f:
    idx = json.load(f)
entries = idx.get('entries', [])
for e in entries:
    if e.get('id') == '${SESSION_ID}':
        e['last_updated'] = '${NOW}'
        e['total_records'] = ${TOTAL_RECORDS}
        break
with open('$INDEX', 'w') as f:
    json.dump(idx, f, ensure_ascii=False, indent=2)
" 2>/dev/null
        fi
    else
        # 不存在 → 追加
        if command -v python3 &>/dev/null; then
            python3 -c "
import json
with open('$INDEX') as f:
    idx = json.load(f)
idx.setdefault('entries', []).append({
    'id': '${SESSION_ID}',
    'type': 'auto',
    'last_updated': '${NOW}',
    'status': 'in_progress',
    'total_records': ${TOTAL_RECORDS}
})
with open('$INDEX', 'w') as f:
    json.dump(idx, f, ensure_ascii=False, indent=2)
" 2>/dev/null
        else
            # 无 python 时的 fallback：直接写新 index
            echo "{\"entries\":[${new_entry}]}" > "$INDEX"
        fi
    fi
}

_update_index

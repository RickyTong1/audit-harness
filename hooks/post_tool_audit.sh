#!/usr/bin/env bash
# ============================================================
# PostToolUse Hook: 自动捕获工具调用审计
# ============================================================
# 安全保证：
#   - 不使用 set -e（任何命令失败都不终止脚本）
#   - 所有操作包裹在超时和错误保护中
#   - 整个脚本不会阻塞主流程
#   - 最坏情况：静默退出，不记录本次操作（可接受）
# ============================================================

# 超时保护：整个脚本最多执行 2 秒
( sleep 2 && kill -9 $$ 2>/dev/null ) &
WATCHDOG=$!

RUNS_DIR="${PWD}/.claude/runs"
BUFFER="${RUNS_DIR}/audit_buffer.jsonl"

mkdir -p "$RUNS_DIR" 2>/dev/null || { kill $WATCHDOG 2>/dev/null; exit 0; }

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

# 读 stdin：限制 2000 字节，1 秒超时
STDIN_DATA=""
if ! [ -t 0 ]; then
    STDIN_DATA=$(timeout 1 head -c 2000 2>/dev/null || true)
fi

# 提取工具名
TOOL="${CLAUDE_TOOL_NAME:-}"
if [[ -z "$TOOL" && -n "$STDIN_DATA" ]]; then
    TOOL=$(echo "$STDIN_DATA" | grep -o '"tool_name":"[^"]*"' 2>/dev/null | head -1 | cut -d'"' -f4 2>/dev/null || true)
fi
TOOL="${TOOL:-tool_use}"

# 写入 buffer（转义简化，只取前 500 字符）
DETAIL=$(echo "$STDIN_DATA" | tr '\n' ' ' | tr '"' "'" | head -c 500 2>/dev/null || true)
echo "{\"timestamp\":\"${TIMESTAMP}\",\"tool\":\"${TOOL}\",\"detail\":\"${DETAIL}\"}" >> "$BUFFER" 2>/dev/null

# 清理 watchdog
kill $WATCHDOG 2>/dev/null
wait $WATCHDOG 2>/dev/null
exit 0

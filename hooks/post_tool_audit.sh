#!/usr/bin/env bash
# ============================================================
# PostToolUse Hook: 自动捕获工具调用审计
# ============================================================
# 安全保证：
#   - 不使用 set -e
#   - 不使用 watchdog（会干扰 stdin 读取）
#   - 不使用 timeout（macOS 可能不支持或行为不一致）
#   - 所有命令附带 2>/dev/null
#   - 最坏情况：静默退出
# ============================================================

RUNS_DIR="${PWD}/.claude/runs"
BUFFER="${RUNS_DIR}/audit_buffer.jsonl"

mkdir -p "$RUNS_DIR" 2>/dev/null || exit 0

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

# 读 stdin：Claude Code 通过 stdin 传入 JSON
# 不用 timeout，不用 watchdog，直接 read 限制字节数
STDIN_DATA=""
if ! [ -t 0 ]; then
    STDIN_DATA=$(dd bs=1 count=4000 2>/dev/null || true)
fi

# 从 stdin JSON 中提取 tool_name
TOOL=""
if [[ -n "$STDIN_DATA" ]]; then
    TOOL=$(echo "$STDIN_DATA" | grep -o '"tool_name":"[^"]*"' 2>/dev/null | head -1 | cut -d'"' -f4 2>/dev/null || true)
fi
TOOL="${TOOL:-tool_use}"

# 提取 session_id（用于关联）
SID=$(echo "$STDIN_DATA" | grep -o '"session_id":"[^"]*"' 2>/dev/null | head -1 | cut -d'"' -f4 2>/dev/null || true)

# 提取 command 或 file_path 的前 200 字符作为摘要
SUMMARY=""
if [[ "$TOOL" == "Bash" ]]; then
    SUMMARY=$(echo "$STDIN_DATA" | grep -o '"command":"[^"]*"' 2>/dev/null | head -1 | cut -d'"' -f4 2>/dev/null | head -c 200 || true)
elif [[ "$TOOL" == "Write" || "$TOOL" == "Edit" ]]; then
    SUMMARY=$(echo "$STDIN_DATA" | grep -o '"file_path":"[^"]*"' 2>/dev/null | head -1 | cut -d'"' -f4 2>/dev/null || true)
fi

# 转义引号
SUMMARY=$(echo "$SUMMARY" | tr '"' "'" 2>/dev/null || true)

echo "{\"timestamp\":\"${TIMESTAMP}\",\"tool\":\"${TOOL}\",\"session\":\"${SID}\",\"summary\":\"${SUMMARY}\"}" >> "$BUFFER" 2>/dev/null

exit 0

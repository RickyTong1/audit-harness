#!/usr/bin/env bash
# ============================================================
# PostToolUse Hook: 自动捕获工具调用审计
# ============================================================
# 每次 Claude 调用 Write/Edit/Bash 后自动触发。
# 将工具使用记录追加到 .claude/runs/audit_buffer.jsonl。
# Stop hook 负责将 buffer 内容归档到正确的 session。
#
# 环境变量（由 Claude Code 注入）：
#   CLAUDE_TOOL_NAME   — 工具名 (Write, Edit, Bash 等)
#   CLAUDE_TOOL_INPUT  — 工具输入 JSON
#   CLAUDE_FILE_PATHS  — 受影响的文件路径
# ============================================================

RUNS_DIR="${PWD}/.claude/runs"
BUFFER="${RUNS_DIR}/audit_buffer.jsonl"

# 确保目录存在
mkdir -p "$RUNS_DIR" 2>/dev/null || exit 0

TOOL="${CLAUDE_TOOL_NAME:-unknown}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FILES="${CLAUDE_FILE_PATHS:-}"

# 只记录有实际副作用的工具
case "$TOOL" in
    Write|Edit|NotebookEdit)
        ACTION="file_modify"
        ;;
    Bash)
        ACTION="script_exec"
        ;;
    *)
        # Read/Glob/Grep 等只读工具不记录
        exit 0
        ;;
esac

# 构建 JSON 行（纯 bash，不依赖 python/jq）
# 转义双引号
ESCAPED_FILES=$(echo "$FILES" | sed 's/"/\\"/g')

echo "{\"timestamp\":\"${TIMESTAMP}\",\"tool\":\"${TOOL}\",\"action\":\"${ACTION}\",\"files\":\"${ESCAPED_FILES}\"}" >> "$BUFFER"

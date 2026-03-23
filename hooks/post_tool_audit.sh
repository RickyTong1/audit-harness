#!/usr/bin/env bash
# ============================================================
# PostToolUse Hook: 自动捕获工具调用审计
# ============================================================
# settings.json 的 matcher 已限定只有 Write|Edit|Bash|NotebookEdit 触发。
# 因此 hook 内部不再做工具过滤——只要被触发就记录。
#
# 不依赖 CLAUDE_TOOL_NAME 等环境变量（已知可能为空）。
# 仅依赖 $PWD（始终可用）和 stdin（Claude Code 传入的 JSON，可能为空）。
# ============================================================

RUNS_DIR="${PWD}/.claude/runs"
BUFFER="${RUNS_DIR}/audit_buffer.jsonl"

# 自动初始化：runs/ 不存在则创建（全局生效，无需 --init）
mkdir -p "$RUNS_DIR" 2>/dev/null

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 尝试读取 stdin（Claude Code 可能传入 tool 信息的 JSON）
STDIN_DATA=""
if ! [ -t 0 ]; then
    STDIN_DATA=$(head -c 2000)  # 限制读取量，防止阻塞
fi

# 尝试从环境变量获取工具名（可能为空）
TOOL="${CLAUDE_TOOL_NAME:-}"
FILES="${CLAUDE_FILE_PATHS:-}"

# 如果环境变量为空，尝试从 stdin 解析
if [[ -z "$TOOL" && -n "$STDIN_DATA" ]]; then
    # 简单提取 tool_name（不依赖 jq）
    TOOL=$(echo "$STDIN_DATA" | grep -o '"tool_name":"[^"]*"' | head -1 | cut -d'"' -f4)
fi

# 如果还是拿不到工具名，用 "tool_use" 作为通用标记
TOOL="${TOOL:-tool_use}"

# 转义 stdin 中的引号用于 JSON
ESCAPED_STDIN=$(echo "$STDIN_DATA" | tr '\n' ' ' | sed 's/"/\\"/g' | head -c 500)

echo "{\"timestamp\":\"${TIMESTAMP}\",\"tool\":\"${TOOL}\",\"files\":\"${FILES}\",\"detail\":\"${ESCAPED_STDIN}\"}" >> "$BUFFER"

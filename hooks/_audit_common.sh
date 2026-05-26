#!/usr/bin/env bash
# ============================================================
# 共享 helper（hooks 间共用）
# ============================================================
# 解析 audit_context.py 路径 + 暴露 RUNS_DIR / AUDIT_PY 变量
#
# 设计：hooks 不再嵌入 Python 源码。所有需要写 index.json 的操作
# 都通过 `python3 "$AUDIT_PY" update-index ...` CLI 调用，与 lib
# 共享同一份 schema 定义。
# ============================================================

# RUNS_DIR：始终基于 ${PWD}/.claude/runs，与 lib 的 find_runs_dir() 行为一致
RUNS_DIR="${PWD}/.claude/runs"

# AUDIT_PY：定位 audit_context.py
#   全局安装：~/.claude/audit-harness/audit_context.py
#               hooks 在 ~/.claude/audit-harness/hooks/，向上一级即可
#   开发态：  audit-harness/lib/audit_context.py
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)"
AUDIT_PY=""
for _p in \
    "${_HOOK_DIR}/../audit_context.py" \
    "${_HOOK_DIR}/../lib/audit_context.py" \
    "${HOME}/.claude/audit-harness/audit_context.py"
do
    if [[ -f "$_p" ]]; then
        AUDIT_PY="$_p"
        break
    fi
done

# 当前 ISO8601 时间戳
audit_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown"
}

# 调用 lib CLI 写 index.json。失败时静默（hook 不阻断主流程）
# 用法：audit_update_index --id X --type Y --status Z ...
audit_update_index() {
    if [[ -z "$AUDIT_PY" ]] || ! command -v python3 &>/dev/null; then
        return 0
    fi
    python3 "$AUDIT_PY" update-index --runs-dir "$RUNS_DIR" "$@" >/dev/null 2>&1 || true
}

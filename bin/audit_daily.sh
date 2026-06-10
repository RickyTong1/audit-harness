#!/usr/bin/env bash
# ============================================================
# L3 | bin/audit_daily.sh — 每日审计闭环（cron/launchd 入口）
#
# 用途：每天 08:03 由 launchd 触发，对注册项目依次执行：
#       1. 生成昨日日报（audit-report-daily skill, headless claude）
#       2. 晨间自我修正报告（morning_review）
#       3. engram consolidation（本地 LLM 语义提炼，每日一次）
#
# 输入：~/.claude/audit-harness/daily_projects.conf（每行一个项目绝对路径）
# 输出：各项目 .claude/runs/daily/{date}_daily.md + {date}_morning_review.md
#       日志 ~/.claude/audit-harness/logs/daily_{date}.log
#
# 关联文件：
#   上游：docs/L2_audit_enforcement_design.md §8.4/§8.5（cron 设计）
#         templates/com.audit-harness.daily.plist（launchd 定时）
#   内部：~/.claude/audit-harness/engram/consolidate_llm.py（consolidation）
#         ~/.claude/skills/audit-report-daily/SKILL.md（日报模板）
# 版本：v4.1.0 — 首次实现（L2_audit §11 P2）
# ============================================================

set -uo pipefail   # 不用 -e：单个项目失败不阻断其余项目

HARNESS_DIR="$HOME/.claude/audit-harness"
CONF="$HARNESS_DIR/daily_projects.conf"
LOG_DIR="$HARNESS_DIR/logs"
mkdir -p "$LOG_DIR"

exec >> "$LOG_DIR/daily_$(date +%Y%m%d).log" 2>&1
echo "=== audit-daily start $(date -u +%FT%TZ) ==="

# launchd 环境 PATH 极简，补齐常见安装位置（nvm 不锁定版本号）
for d in "$HOME"/.nvm/versions/node/*/bin /opt/homebrew/bin /usr/local/bin; do
    [[ -d "$d" ]] && PATH="$d:$PATH"
done
export PATH

# 可选超时保护（macOS 默认无 timeout，有 coreutils 则用）
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
_run_with_timeout() {
    local secs="$1"; shift
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" "$secs" "$@"
    else
        "$@"
    fi
}

YESTERDAY="$(date -v-1d +%Y%m%d 2>/dev/null || date -d yesterday +%Y%m%d)"
TODAY="$(date +%Y%m%d)"

# --- 1+2. 各项目日报 + 晨间修正 ---
CLAUDE_BIN="$(command -v claude || true)"
if [[ -z "$CLAUDE_BIN" ]]; then
    echo "[warn] claude CLI 不可用，跳过日报生成"
elif [[ ! -f "$CONF" ]]; then
    echo "[warn] $CONF 不存在，无注册项目，跳过日报生成"
else
    PROMPT="读取 ~/.claude/skills/audit-report-daily/SKILL.md 并严格按其执行：
1. 扫描 .claude/runs/ 下 ${YESTERDAY} 的审计记录，生成日报保存到 .claude/runs/daily/${YESTERDAY}_daily.md（若该文件已存在则跳过此步）
2. 基于日报执行晨间自我修正，生成 .claude/runs/daily/${TODAY}_morning_review.md
只读取审计数据和写入上述两个报告文件，不做任何代码修改。"

    while IFS= read -r proj; do
        [[ -z "$proj" || "$proj" == \#* ]] && continue
        proj="${proj/#\~/$HOME}"
        if [[ ! -d "$proj/.claude/runs" ]]; then
            echo "[skip] $proj（无 .claude/runs/）"
            continue
        fi
        echo "[report] $proj"
        # 预建输出目录——否则 headless agent 需要 Bash mkdir，
        # 会触发无人应答的权限弹窗导致报告静默落进 /tmp
        mkdir -p "$proj/.claude/runs/daily"
        # --allowed-tools 是变长参数，必须逐个传
        if (cd "$proj" && _run_with_timeout 600 "$CLAUDE_BIN" -p "$PROMPT" \
                --allowed-tools "Read" "Glob" "Grep" "Write" "Bash"); then
            echo "[ok] $proj"
        else
            echo "[fail] $proj（exit=$?，不阻断后续项目）"
        fi
    done < "$CONF"
fi

# --- 3. engram consolidation（全局一次，失败不阻断） ---
if [[ -f "$HARNESS_DIR/engram/consolidate_llm.py" ]]; then
    echo "[consolidate] engram 本地 LLM 语义提炼"
    _run_with_timeout 900 python3 "$HARNESS_DIR/engram/consolidate_llm.py" \
        || echo "[warn] consolidation 失败（非阻断）"
else
    echo "[skip] consolidate_llm.py 未安装"
fi

echo "=== audit-daily done $(date -u +%FT%TZ) ==="

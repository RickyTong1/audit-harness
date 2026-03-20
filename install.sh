#!/usr/bin/env bash
# ============================================================
# audit-harness 安装向导
# ============================================================
#
# 两种模式:
#
#   bash install.sh --global
#     全局安装到 ~/.claude/
#     Skills + 核心代码 → 所有项目自动可用
#     只需执行一次
#
#   bash install.sh --init [/path/to/project]
#     项目初始化
#     创建 .claude/runs/ + audit_config.py + 注入 CLAUDE.md
#     每个新项目执行一次
#
#   bash install.sh --auto [/path/to/project]
#     全局安装 + 项目初始化，一步到位
#
# ============================================================

set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "$0")" && pwd)"
SKILLS_SRC="$HARNESS_ROOT/skills"
LIB_SRC="$HARNESS_ROOT/lib"
TEMPLATES_SRC="$HARNESS_ROOT/templates"

GLOBAL_DIR="$HOME/.claude"

GREEN='\033[92m'  YELLOW='\033[93m'  RED='\033[91m'
BOLD='\033[1m'    DIM='\033[2m'      RESET='\033[0m'

ok()     { echo -e "    ${GREEN}✅${RESET} $*"; }
fail()   { echo -e "    ${RED}❌${RESET} $*"; }
header() { echo -e "\n${BOLD}--- $* ---${RESET}\n"; }

# ==========================================
# 参数解析
# ==========================================
# 智能模式选择：
#   无参数        → 自动判断（全局未装→全局+当前项目 / 全局已装→仅当前项目）
#   --global      → 仅全局安装
#   --init [path] → 仅项目初始化（默认当前目录）
#   --auto [path] → 全局 + 项目初始化
# ==========================================
MODE=""
PROJECT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --global) MODE="global"; shift ;;
        --init)   MODE="init";   shift ;;
        --auto)   MODE="auto";   shift ;;
        --help|-h)
            echo "用法:"
            echo "  bash install.sh                         智能模式（自动判断）"
            echo "  bash install.sh --global                仅全局安装"
            echo "  bash install.sh --init [project_dir]    仅项目初始化（默认当前目录）"
            echo "  bash install.sh --auto [project_dir]    全局 + 项目初始化"
            echo ""
            echo "无参数时自动判断："
            echo "  全局未安装 → 全局安装 + 当前目录项目初始化"
            echo "  全局已安装 → 仅当前目录项目初始化"
            exit 0
            ;;
        *) PROJECT="$1"; shift ;;
    esac
done

# 智能模式：无参数时自动判断
if [[ -z "$MODE" ]]; then
    if [[ -f "$GLOBAL_DIR/audit-harness/audit_context.py" ]]; then
        MODE="init"
    else
        MODE="auto"
    fi
fi

# 项目路径：默认当前工作目录
if [[ "$MODE" == "init" || "$MODE" == "auto" ]]; then
    PROJECT="${PROJECT:-$(pwd)}"
    PROJECT="$(cd "$PROJECT" && pwd)"
    if [[ "$PROJECT" == "$HARNESS_ROOT" ]]; then
        echo -e "${RED}错误: 不能安装到 audit-harness 包自身。${RESET}"
        echo "  请在项目目录中运行，或指定目标路径:"
        echo "    cd /your/project && bash $HARNESS_ROOT/install.sh"
        exit 1
    fi
fi

# ============================================================
# 全局安装
# ============================================================
install_global() {
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
    echo -e "${BOLD}  audit-harness 全局安装${RESET}"
    echo -e "${BOLD}============================================================${RESET}"
    echo ""
    echo "  安装目标: $GLOBAL_DIR/"
    echo ""

    # --- 检测 ---
    echo "  环境检测:"
    local has_core=false has_skills=false
    [[ -f "$GLOBAL_DIR/audit-harness/audit_context.py" ]] && has_core=true
    [[ -d "$GLOBAL_DIR/skills/audit-start" ]] && has_skills=true

    if $has_core; then
        echo -e "    ${GREEN}✅ 已存在${RESET}    ~/.claude/audit-harness/（将更新）"
    else
        echo -e "    ${YELLOW}❌ 需要安装${RESET}  ~/.claude/audit-harness/"
    fi
    if $has_skills; then
        echo -e "    ${GREEN}✅ 已存在${RESET}    ~/.claude/skills/audit-*（将更新）"
    else
        echo -e "    ${YELLOW}❌ 需要安装${RESET}  ~/.claude/skills/audit-*"
    fi

    # --- 安装核心代码 ---
    header "安装核心代码 → ~/.claude/audit-harness/"

    local install_dir="$GLOBAL_DIR/audit-harness"
    mkdir -p "$install_dir"

    cp "$LIB_SRC/audit_context.py" "$install_dir/audit_context.py"
    ok "audit_context.py"

    # __init__.py
    cat > "$install_dir/__init__.py" << 'PYEOF'
"""audit-harness: 审计执行保障框架（全局安装）"""
PYEOF
    ok "__init__.py"

    # 模板文件（供 --init 使用）
    mkdir -p "$install_dir/templates"
    cp "$TEMPLATES_SRC/audit_config.example.py" "$install_dir/templates/"
    cp "$TEMPLATES_SRC/CLAUDE.md.audit-section" "$install_dir/templates/"
    ok "templates/"

    # --- 安装 Skills ---
    header "安装 Skills → ~/.claude/skills/"

    local skills_dst="$GLOBAL_DIR/skills"
    mkdir -p "$skills_dst"

    local installed=0
    for skill_dir in "$SKILLS_SRC"/*/; do
        local name
        name=$(basename "$skill_dir")
        [[ "$name" == "audit-init" ]] && continue
        [[ ! -f "$skill_dir/SKILL.md" ]] && continue

        local dst="$skills_dst/$name"
        rm -rf "$dst"
        cp -r "$skill_dir" "$dst"

        local short_name="${name#audit-}"
        ok "/$short_name → ~/.claude/skills/$name"
        ((installed++))
    done
    echo ""
    echo "    已安装 $installed 个 Skills（全局可用）"

    # --- 总结 ---
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
    echo -e "${GREEN}${BOLD}  全局安装完成！${RESET}"
    echo -e "${BOLD}============================================================${RESET}"
    echo ""
    echo "  已安装:"
    echo "    ~/.claude/audit-harness/  — 核心代码 + 模板"
    echo "    ~/.claude/skills/         — 4 个 Skills（所有项目可用）"
    echo ""
    echo "  下一步: 在项目中执行初始化:"
    echo "    bash install.sh --init /path/to/your/project"
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
}

# ============================================================
# 项目初始化
# ============================================================

# 配置收集变量
CFG_SCRIPTS=""
CFG_ASSETS=""
CFG_PROMPT_GLOB=""

init_project() {
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
    echo -e "${BOLD}  audit-harness 项目初始化${RESET}"
    echo -e "${BOLD}============================================================${RESET}"
    echo ""
    echo "  目标项目: $PROJECT"
    echo ""

    # 检查全局安装是否存在
    if [[ ! -f "$GLOBAL_DIR/audit-harness/audit_context.py" ]]; then
        echo -e "${YELLOW}  ⚠️  全局安装未检测到，将同时执行全局安装...${RESET}"
        echo ""
        install_global
        echo ""
        echo -e "${BOLD}  继续项目初始化...${RESET}"
        echo ""
    fi

    local proj_claude="$PROJECT/.claude"
    local proj_runs="$proj_claude/runs"

    # --- 检测 ---
    echo "  环境检测:"
    local has_git=false has_runs=false has_config=false has_claude=false has_audit=false
    [[ -d "$PROJECT/.git" ]] && has_git=true
    [[ -d "$proj_runs" ]] && has_runs=true
    [[ -f "$proj_claude/audit_config.py" ]] && has_config=true
    [[ -f "$PROJECT/CLAUDE.md" ]] && has_claude=true
    $has_claude && grep -q "\[AUDIT\]" "$PROJECT/CLAUDE.md" 2>/dev/null && has_audit=true

    _check() {
        if $2; then
            echo -e "    ${GREEN}✅ 已存在${RESET}    $1"
        else
            echo -e "    ${YELLOW}❌ 需要配置${RESET}  $1"
        fi
    }

    _check "Git 仓库"                     "$has_git"
    _check ".claude/audit_config.py"      "$has_config"
    _check ".claude/runs/"                "$has_runs"
    _check "CLAUDE.md"                    "$has_claude"
    _check "CLAUDE.md 审计规范"            "$has_audit"

    # --- 自动收集配置 ---
    header "收集项目配置"

    CFG_SCRIPTS=$(find "$PROJECT" -maxdepth 1 -name "*.py" ! -name "_*" ! -name ".*" -exec basename {} \; 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
    CFG_ASSETS=$(find "$PROJECT" -maxdepth 1 \( -name "*.pkl" -o -name "*.yaml" \) -exec basename {} \; 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
    for pattern in "prompts/*.txt" "docs/prompt_*.md" "docs/long_text_*.txt"; do
        if compgen -G "$PROJECT/$pattern" > /dev/null 2>&1; then
            CFG_PROMPT_GLOB="$pattern"
            break
        fi
    done

    local n_scripts=0 n_assets=0
    [[ -n "$CFG_SCRIPTS" ]] && n_scripts=$(echo "$CFG_SCRIPTS" | tr ',' '\n' | wc -l | tr -d ' ')
    [[ -n "$CFG_ASSETS" ]] && n_assets=$(echo "$CFG_ASSETS" | tr ',' '\n' | wc -l | tr -d ' ')
    echo "    扫描到: $n_scripts 个脚本, $n_assets 个资产, prompt_glob=${CFG_PROMPT_GLOB:-N/A}"

    # --- 创建 audit_config.py ---
    header "创建项目配置"

    mkdir -p "$proj_claude"

    local dst_cfg="$proj_claude/audit_config.py"
    if $has_config; then
        ok "audit_config.py 已存在（保留）"
    else
        _gen_config "$dst_cfg"
        ok "audit_config.py → .claude/"
    fi

    # --- 创建 runs/ ---
    mkdir -p "$proj_runs/daily"
    ok ".claude/runs/ 目录已创建"

    if [[ ! -f "$proj_runs/.gitignore" ]]; then
        cat > "$proj_runs/.gitignore" << 'GITIGNORE'
*.jsonl
*.json
!index.json
!daily/
!weekly/
GITIGNORE
        ok ".claude/runs/.gitignore"
    fi

    # --- CLAUDE.md ---
    header "配置 CLAUDE.md"

    local audit_section
    audit_section=$(cat "$GLOBAL_DIR/audit-harness/templates/CLAUDE.md.audit-section" 2>/dev/null || cat "$TEMPLATES_SRC/CLAUDE.md.audit-section")

    if ! $has_claude; then
        local proj_name
        proj_name=$(basename "$PROJECT")
        {
            echo "# $proj_name"
            echo ""
            echo "> 项目描述（请填写）"
            echo ""
            echo "---"
            echo ""
            echo "$audit_section"
        } > "$PROJECT/CLAUDE.md"
        ok "创建 CLAUDE.md（含审计规范）"
    elif ! $has_audit; then
        {
            echo ""
            echo "---"
            echo ""
            echo "$audit_section"
        } >> "$PROJECT/CLAUDE.md"
        ok "审计规范已追加到 CLAUDE.md"
    else
        ok "CLAUDE.md 已包含审计规范"
    fi

    # --- 验证 ---
    header "验证"

    local passed=0 total=0

    _verify() {
        local label="$1"; shift
        ((total++))
        if "$@" 2>/dev/null; then
            ok "$label"
            ((passed++)) || true
        else
            fail "$label"
        fi
    }

    _verify "全局: audit_context.py" test -f "$GLOBAL_DIR/audit-harness/audit_context.py"
    _verify "全局: Skills"           test -d "$GLOBAL_DIR/skills/audit-start"
    _verify "项目: audit_config.py"  test -f "$proj_claude/audit_config.py"
    _verify "项目: .claude/runs/"    test -d "$proj_runs"
    _verify "项目: CLAUDE.md"        grep -q "\[AUDIT\]" "$PROJECT/CLAUDE.md"

    echo ""
    echo "    验证结果: $passed/$total 通过"

    # --- 总结 ---
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
    if [[ $passed -eq $total ]]; then
        echo -e "${GREEN}${BOLD}  项目初始化完成！${RESET}"
    else
        echo -e "${YELLOW}${BOLD}  项目初始化完成（部分验证未通过）${RESET}"
    fi
    echo -e "${BOLD}============================================================${RESET}"
    echo ""
    echo "  全局（所有项目共享）:"
    echo "    ~/.claude/audit-harness/  — 核心代码"
    echo "    ~/.claude/skills/         — /start /end /recover /report-daily"
    echo ""
    echo "  本项目:"
    echo "    .claude/audit_config.py   — 项目配置（$n_scripts 个脚本, $n_assets 个资产）"
    echo "    .claude/runs/             — 审计数据存储"
    echo "    CLAUDE.md                 — 审计规范（已注入）"
    echo ""
    echo "  开始使用:"
    echo '    /start "你的第一个任务"'
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
}

_gen_config() {
    local dst="$1"
    local scripts_py="" assets_py=""
    if [[ -n "$CFG_SCRIPTS" ]]; then
        IFS=',' read -ra arr <<< "$CFG_SCRIPTS"
        for s in "${arr[@]}"; do
            s=$(echo "$s" | xargs)
            [[ -n "$s" ]] && scripts_py="$scripts_py    \"$s\",
"
        done
    fi
    if [[ -n "$CFG_ASSETS" ]]; then
        IFS=',' read -ra arr <<< "$CFG_ASSETS"
        for a in "${arr[@]}"; do
            a=$(echo "$a" | xargs)
            [[ -n "$a" ]] && assets_py="$assets_py    \"$a\",
"
        done
    fi
    cat > "$dst" << PYEOF
"""
audit_config.py — 项目专属审计配置
自动生成 by audit-harness install.sh --init
"""

CORE_SCRIPTS = [
${scripts_py}]

CORE_ASSETS = [
${assets_py}]

PROMPT_TEMPLATE_GLOB = "${CFG_PROMPT_GLOB}"

def _safe_div(a, b):
    return a / b if b else 0

ALERT_RULES = [
    {
        "id": "output_integrity",
        "condition": lambda m: (
            m.get("output", {}).get("total_records") is not None
            and m.get("cleaning", {}).get("total_input") is not None
            and m.get("cleaning", {}).get("total_deleted") is not None
            and m["output"]["total_records"]
            != m["cleaning"]["total_input"] - m["cleaning"]["total_deleted"]
        ),
        "level": "CRITICAL",
        "message": "输出记录数 ≠ 输入 - 删除，存在数据丢失",
    },
]
PYEOF
}

# ============================================================
# Main
# ============================================================
case "$MODE" in
    global)
        install_global
        ;;
    init)
        init_project
        ;;
    auto)
        install_global
        echo ""
        init_project
        ;;
esac

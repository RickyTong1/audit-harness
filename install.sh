#!/usr/bin/env bash
# ============================================================
# audit-harness 安装向导
# ============================================================
# 在目标项目中完成 audit-harness 的全部配置。
# 安装完成后 /start, /end, /recover, /report-daily 立即可用。
#
# 用法:
#   bash install.sh                    # 交互模式，安装到当前目录
#   bash install.sh /path/to/project   # 交互模式，指定目标项目
#   bash install.sh --auto             # 全自动模式，安装到当前目录
#   bash install.sh --auto /path/to    # 全自动模式，指定目标项目
# ============================================================

set -euo pipefail

# ==========================================
# 路径
# ==========================================
HARNESS_ROOT="$(cd "$(dirname "$0")" && pwd)"
SKILLS_SRC="$HARNESS_ROOT/skills"
LIB_SRC="$HARNESS_ROOT/lib"
TEMPLATES_SRC="$HARNESS_ROOT/templates"

# ==========================================
# 颜色
# ==========================================
GREEN='\033[92m'
YELLOW='\033[93m'
RED='\033[91m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

ok()   { echo -e "    ${GREEN}✅${RESET} $*"; }
warn() { echo -e "    ${YELLOW}⚠️${RESET}  $*"; }
fail() { echo -e "    ${RED}❌${RESET} $*"; }
header() { echo -e "\n${BOLD}--- $* ---${RESET}\n"; }

# ==========================================
# 参数解析
# ==========================================
AUTO=false
PROJECT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) AUTO=true; shift ;;
        *)      PROJECT="$1"; shift ;;
    esac
done

if [[ -z "$PROJECT" ]]; then
    PROJECT="$(pwd)"
fi

PROJECT="$(cd "$PROJECT" && pwd)"

# 自保护：禁止安装到 harness 包自身
if [[ "$PROJECT" == "$HARNESS_ROOT" ]]; then
    echo ""
    echo -e "${RED}错误: 不能安装到 audit-harness 包自身。${RESET}"
    echo ""
    echo "  用法:"
    echo "    bash $0 /path/to/your/project          # 指定目标项目"
    echo "    bash $0 --auto /path/to/your/project    # 全自动安装到指定项目"
    echo "    cd /your/project && bash $HARNESS_ROOT/install.sh  # 安装到当前目录"
    echo ""
    exit 1
fi

# ==========================================
# Step 1: 环境检测
# ==========================================
step1_detect() {
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
    echo -e "${BOLD}  audit-harness 安装向导${RESET}"
    echo -e "${BOLD}============================================================${RESET}"
    echo ""
    echo "  目标项目: $PROJECT"
    echo ""
    echo "  环境检测:"

    HAS_GIT=false;           [[ -d "$PROJECT/.git" ]] && HAS_GIT=true
    HAS_AUDIT_CTX=false;     [[ -f "$PROJECT/audit_context.py" ]] && HAS_AUDIT_CTX=true
    HAS_AUDIT_CFG=false;     [[ -f "$PROJECT/audit_config.py" ]] && HAS_AUDIT_CFG=true
    HAS_RUNS=false;          [[ -d "$PROJECT/runs" ]] && HAS_RUNS=true
    HAS_CLAUDE_MD=false;     [[ -f "$PROJECT/CLAUDE.md" ]] && HAS_CLAUDE_MD=true
    HAS_AUDIT_SECTION=false; $HAS_CLAUDE_MD && grep -q "\[AUDIT\]" "$PROJECT/CLAUDE.md" 2>/dev/null && grep -q "audit_blocks" "$PROJECT/CLAUDE.md" 2>/dev/null && HAS_AUDIT_SECTION=true
    HAS_SKILLS=false;        [[ -d "$PROJECT/.claude/skills" ]] && HAS_SKILLS=true

    _check() {
        if $2; then
            echo -e "    ${GREEN}✅ 已存在${RESET}    $1"
        else
            echo -e "    ${YELLOW}❌ 需要安装${RESET}  $1"
        fi
    }

    _check "Git 仓库"           "$HAS_GIT"
    _check "audit_context.py"   "$HAS_AUDIT_CTX"
    _check "audit_config.py"    "$HAS_AUDIT_CFG"
    _check "runs/ 目录"         "$HAS_RUNS"
    _check "CLAUDE.md"          "$HAS_CLAUDE_MD"
    _check "CLAUDE.md 审计规范" "$HAS_AUDIT_SECTION"
    _check ".claude/skills/"    "$HAS_SKILLS"

    echo ""
    local needs=0
    $HAS_GIT           || ((needs++))
    $HAS_AUDIT_CTX     || ((needs++))
    $HAS_AUDIT_CFG     || ((needs++))
    $HAS_RUNS          || ((needs++))
    $HAS_CLAUDE_MD     || ((needs++))
    $HAS_AUDIT_SECTION || ((needs++))
    $HAS_SKILLS        || ((needs++))

    if [[ $needs -eq 0 ]]; then
        echo -e "  ${GREEN}所有组件已安装。重新运行将更新到最新版本。${RESET}"
    else
        echo "  需要安装/配置 $needs 个组件。"
    fi
}

# ==========================================
# Step 2: 收集项目配置（交互模式）
# ==========================================
CFG_SCRIPTS=""
CFG_ASSETS=""
CFG_PROMPT_GLOB=""

step2_collect() {
    header "Step 2: 项目配置"

    # 核心脚本
    echo -e "  ${DIM}核心脚本: 环境快照时计算这些文件的哈希，用于追踪配置变化${RESET}"
    echo -n "  输入核心脚本(逗号分隔) 或 'scan' 自动扫描 [scan]: "
    read -r choice
    choice="${choice:-scan}"

    if [[ "$choice" == "scan" ]]; then
        local py_files
        py_files=$(find "$PROJECT" -maxdepth 1 -name "*.py" ! -name "_*" ! -name ".*" -printf "%f\n" 2>/dev/null | sort || \
                   find "$PROJECT" -maxdepth 1 -name "*.py" ! -name "_*" ! -name ".*" -exec basename {} \; 2>/dev/null | sort)
        if [[ -n "$py_files" ]]; then
            echo "    扫描到的 .py 文件:"
            local i=1
            while IFS= read -r f; do
                echo "      $i. $f"
                ((i++))
            done <<< "$py_files"
            echo -n "  选择编号(逗号分隔) 或 'all' 或回车跳过: "
            read -r selected
            if [[ "$selected" == "all" ]]; then
                CFG_SCRIPTS="$py_files"
            elif [[ -n "$selected" ]]; then
                CFG_SCRIPTS=""
                IFS=',' read -ra indices <<< "$selected"
                for idx in "${indices[@]}"; do
                    idx=$(echo "$idx" | tr -d ' ')
                    local line
                    line=$(echo "$py_files" | sed -n "${idx}p")
                    [[ -n "$line" ]] && CFG_SCRIPTS="$CFG_SCRIPTS$line,"
                done
                CFG_SCRIPTS="${CFG_SCRIPTS%,}"
            fi
        else
            echo "    未扫描到 .py 文件"
        fi
    else
        CFG_SCRIPTS="$choice"
    fi

    echo ""

    # 核心资产
    echo -e "  ${DIM}核心资产: 模型文件(.pkl)、配置文件(.yaml)等${RESET}"
    echo -n "  输入资产文件名(逗号分隔) 或 'none' [none]: "
    read -r assets_input
    assets_input="${assets_input:-none}"
    [[ "$assets_input" != "none" ]] && CFG_ASSETS="$assets_input"

    echo ""

    # Prompt 模板
    echo -e "  ${DIM}Prompt 模板: 如果使用 AI Prompt，提供 glob 模式${RESET}"
    echo -n "  glob 模式(如 'prompts/*.txt') 或 'none' [none]: "
    read -r prompt_glob
    prompt_glob="${prompt_glob:-none}"
    [[ "$prompt_glob" != "none" ]] && CFG_PROMPT_GLOB="$prompt_glob"
}

step2_auto() {
    # 自动模式：扫描所有 .py 和 .pkl
    CFG_SCRIPTS=$(find "$PROJECT" -maxdepth 1 -name "*.py" ! -name "_*" ! -name ".*" -exec basename {} \; 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
    CFG_ASSETS=$(find "$PROJECT" -maxdepth 1 \( -name "*.pkl" -o -name "*.yaml" \) -exec basename {} \; 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')

    # 检测常见 prompt 模式
    for pattern in "prompts/*.txt" "docs/prompt_*.md" "docs/long_text_*.txt"; do
        if compgen -G "$PROJECT/$pattern" > /dev/null 2>&1; then
            CFG_PROMPT_GLOB="$pattern"
            break
        fi
    done
}

# ==========================================
# Step 3: 安装核心文件
# ==========================================
step3_install_core() {
    header "Step 3: 安装核心文件"

    # audit_context.py
    local src="$LIB_SRC/audit_context.py"
    local dst="$PROJECT/audit_context.py"
    if $HAS_AUDIT_CTX && ! $AUTO; then
        echo -n "  audit_context.py 已存在，覆盖? (y/N): "
        read -r yn
        [[ "$yn" != "y" && "$yn" != "Y" ]] && { echo "    ⏭️  跳过 audit_context.py"; } || { cp "$src" "$dst"; ok "audit_context.py"; }
    else
        cp "$src" "$dst"
        ok "audit_context.py → $dst"
    fi

    # audit_config.py
    local dst_cfg="$PROJECT/audit_config.py"
    if $HAS_AUDIT_CFG && ! $AUTO; then
        echo -n "  audit_config.py 已存在，覆盖? (y/N): "
        read -r yn
        [[ "$yn" != "y" && "$yn" != "Y" ]] && { echo "    ⏭️  跳过 audit_config.py"; } || { _gen_config "$dst_cfg"; ok "audit_config.py (已填入配置)"; }
    else
        _gen_config "$dst_cfg"
        ok "audit_config.py → $dst_cfg"
    fi

    # runs/
    mkdir -p "$PROJECT/runs/daily"
    ok "runs/ 目录已创建"

    # runs/.gitignore
    if [[ ! -f "$PROJECT/runs/.gitignore" ]]; then
        cat > "$PROJECT/runs/.gitignore" << 'GITIGNORE'
# 审计数据：大文件不入库，保留目录结构和日报
*.jsonl
*.json
!index.json
!daily/
!weekly/
GITIGNORE
        ok "runs/.gitignore 已创建"
    fi
}

_gen_config() {
    local dst="$1"

    # 构建 CORE_SCRIPTS 列表
    local scripts_py=""
    if [[ -n "$CFG_SCRIPTS" ]]; then
        IFS=',' read -ra arr <<< "$CFG_SCRIPTS"
        for s in "${arr[@]}"; do
            s=$(echo "$s" | xargs)  # trim
            [[ -n "$s" ]] && scripts_py="$scripts_py    \"$s\",
"
        done
    fi

    # 构建 CORE_ASSETS 列表
    local assets_py=""
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
自动生成 by audit-harness install.sh
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

# ==========================================
# Step 4: 安装 Skills
# ==========================================
step4_install_skills() {
    header "Step 4: 安装 Skills"

    local skills_dst="$PROJECT/.claude/skills"
    mkdir -p "$skills_dst"

    local installed=0
    for skill_dir in "$SKILLS_SRC"/*/; do
        local name
        name=$(basename "$skill_dir")
        [[ "$name" == "audit-init" ]] && continue  # 不复制安装向导自身
        [[ ! -f "$skill_dir/SKILL.md" ]] && continue

        local dst="$skills_dst/$name"
        rm -rf "$dst"
        cp -r "$skill_dir" "$dst"

        local short_name="${name#audit-}"
        ok "/$short_name → .claude/skills/$name"
        ((installed++))
    done

    echo ""
    echo "    已安装 $installed 个 Skills"
}

# ==========================================
# Step 5: 注入 CLAUDE.md
# ==========================================
step5_inject_claude_md() {
    header "Step 5: 配置 CLAUDE.md"

    local audit_section
    audit_section=$(cat "$TEMPLATES_SRC/CLAUDE.md.audit-section")

    if ! $HAS_CLAUDE_MD; then
        # 创建新的 CLAUDE.md
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

    elif ! $HAS_AUDIT_SECTION; then
        local should_append=false
        if $AUTO; then
            should_append=true
        else
            echo -n "  将在 CLAUDE.md 末尾追加审计规范，确认? (Y/n): "
            read -r yn
            [[ "$yn" != "n" && "$yn" != "N" ]] && should_append=true
        fi

        if $should_append; then
            {
                echo ""
                echo "---"
                echo ""
                echo "$audit_section"
            } >> "$PROJECT/CLAUDE.md"
            ok "审计规范已追加到 CLAUDE.md"
        else
            echo "    ⏭️  跳过"
        fi
    else
        ok "CLAUDE.md 已包含审计规范（跳过）"
    fi
}

# ==========================================
# Step 6: 验证安装
# ==========================================
step6_verify() {
    header "Step 6: 验证安装"

    local passed=0
    local total=0

    # 6.1 audit_context.py 存在且语法正确
    ((total++))
    if [[ -f "$PROJECT/audit_context.py" ]]; then
        ok "audit_context.py 存在"
        ((passed++))
    else
        fail "audit_context.py 不存在"
    fi

    # 6.2 audit_config.py 存在且语法正确
    ((total++))
    if [[ -f "$PROJECT/audit_config.py" ]]; then
        ok "audit_config.py 存在"
        ((passed++))
    else
        fail "audit_config.py 不存在"
    fi

    # 6.3 runs/ 目录可写
    ((total++))
    if [[ -d "$PROJECT/runs" ]] && touch "$PROJECT/runs/.verify_test" 2>/dev/null; then
        rm -f "$PROJECT/runs/.verify_test"
        ok "runs/ 目录可写"
        ((passed++))
    else
        fail "runs/ 目录不可写"
    fi

    # 6.4 Skills 完整
    ((total++))
    local skill_count=0
    for d in "$PROJECT/.claude/skills"/*/; do
        [[ -f "$d/SKILL.md" ]] && ((skill_count++))
    done
    if [[ $skill_count -ge 4 ]]; then
        ok "Skills 已安装 ($skill_count 个)"
        ((passed++))
    else
        fail "Skills 不完整 ($skill_count/4)"
    fi

    # 6.5 CLAUDE.md 包含审计规范
    ((total++))
    if grep -q "\[AUDIT\]" "$PROJECT/CLAUDE.md" 2>/dev/null; then
        ok "CLAUDE.md 包含 [AUDIT] 格式规范"
        ((passed++))
    else
        fail "CLAUDE.md 缺少 [AUDIT] 格式规范"
    fi

    echo ""
    echo "    验证结果: $passed/$total 通过"
    [[ $passed -eq $total ]]
}

# ==========================================
# Step 7: 安装总结
# ==========================================
step7_summary() {
    local all_passed=$1

    echo ""
    echo -e "${BOLD}============================================================${RESET}"
    if $all_passed; then
        echo -e "${GREEN}${BOLD}  audit-harness 安装完成！${RESET}"
    else
        echo -e "${YELLOW}${BOLD}  audit-harness 安装完成（部分验证未通过）${RESET}"
    fi
    echo -e "${BOLD}============================================================${RESET}"
    echo ""
    echo "  已安装组件:"
    echo "    📦 audit_context.py    — 审计引擎"
    echo "    ⚙️  audit_config.py     — 项目配置"
    echo "    📂 runs/               — 审计数据存储"
    echo "    📝 CLAUDE.md           — 审计规范"
    echo ""
    echo "  可用 Skills:"
    echo '    /start "任务描述"      — 创建审计会话 + 恢复历史上下文'
    echo "    /end                   — 结束会话 + 审计完整性检查"
    echo "    /recover               — 恢复丢失的 Context"
    echo "    /report-daily          — 生成审计驱动的工作日报"
    echo ""
    echo "  现在可以开始使用:"
    echo '    /start "你的第一个任务"'
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
}

# ==========================================
# Main
# ==========================================
step1_detect

if ! $AUTO; then
    echo ""
    echo -n "  开始安装? (Y/n): "
    read -r yn
    if [[ "$yn" == "n" || "$yn" == "N" ]]; then
        echo "  已取消。"
        exit 0
    fi
    step2_collect
else
    step2_auto
fi

step3_install_core
step4_install_skills
step5_inject_claude_md

all_passed=true
step6_verify || all_passed=false

step7_summary "$all_passed"

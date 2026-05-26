#!/usr/bin/env bash
# ============================================================
# audit-harness 安装向导
# ============================================================
#
# 同时支持 Claude Code 和 OpenAI Codex：
#
#   bash install.sh                    Claude Code（默认）智能模式
#   bash install.sh --codex            OpenAI Codex 智能模式
#
# 模式参数（与平台参数正交）:
#   --global       仅全局安装到 ~/.claude/ 或 ~/.codex/
#   --init [path]  仅项目初始化（默认当前目录）
#   --auto [path]  全局 + 项目初始化
#
# 平台差异:
#   Claude Code:   ~/.claude/  + CLAUDE.md + settings.json hooks
#   OpenAI Codex:  ~/.codex/   + AGENTS.md + hooks.json
#
# ============================================================

set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "$0")" && pwd)"
SKILLS_SRC="$HARNESS_ROOT/skills"
LIB_SRC="$HARNESS_ROOT/lib"
TEMPLATES_SRC="$HARNESS_ROOT/templates"

# ==========================================
# 平台变量（默认 Claude Code，--codex 切换）
# ==========================================
PLATFORM="claude"
GLOBAL_DIR="$HOME/.claude"
DOT_DIR=".claude"            # 项目级目录名
DOCS_FILE="CLAUDE.md"        # 项目指令文件名
HOOKS_IN_SETTINGS=true       # Claude: settings.json hooks 子树；Codex: 独立 hooks.json

GREEN='\033[92m'  YELLOW='\033[93m'  RED='\033[91m'
BOLD='\033[1m'    DIM='\033[2m'      RESET='\033[0m'

ok()     { echo -e "    ${GREEN}✅${RESET} $*"; }
fail()   { echo -e "    ${RED}❌${RESET} $*"; }
warn()   { echo -e "    ${YELLOW}⚠️${RESET}  $*"; }
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
        --codex)
            PLATFORM="codex"
            GLOBAL_DIR="$HOME/.codex"
            DOT_DIR=".codex"
            DOCS_FILE="AGENTS.md"
            HOOKS_IN_SETTINGS=false
            shift ;;
        --help|-h)
            echo "用法:"
            echo "  bash install.sh                         Claude Code 智能模式"
            echo "  bash install.sh --codex                 OpenAI Codex 智能模式"
            echo "  bash install.sh --global                仅全局安装"
            echo "  bash install.sh --init [project_dir]    仅项目初始化（默认当前目录）"
            echo "  bash install.sh --auto [project_dir]    全局 + 项目初始化"
            echo "  bash install.sh --codex --auto [path]   Codex 全局 + 项目初始化"
            echo ""
            echo "无参数时自动判断："
            echo "  全局未安装 → 全局安装 + 当前目录项目初始化"
            echo "  全局已安装 → 仅当前目录项目初始化"
            echo ""
            echo "平台差异："
            echo "  Claude Code: ~/.claude/  + CLAUDE.md + settings.json hooks"
            echo "  OpenAI Codex: ~/.codex/  + AGENTS.md + hooks.json"
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
        echo -e "    ${GREEN}✅ 已存在${RESET}    ~/${DOT_DIR}/audit-harness/（将更新）"
    else
        echo -e "    ${YELLOW}❌ 需要安装${RESET}  ~/${DOT_DIR}/audit-harness/"
    fi
    if $has_skills; then
        echo -e "    ${GREEN}✅ 已存在${RESET}    ~/${DOT_DIR}/skills/audit-*（将更新）"
    else
        echo -e "    ${YELLOW}❌ 需要安装${RESET}  ~/${DOT_DIR}/skills/audit-*"
    fi

    # --- 安装核心代码 ---
    header "安装核心代码 → ~/${DOT_DIR}/audit-harness/"

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
    header "安装 Skills → ~/${DOT_DIR}/skills/"

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
        ok "/$short_name → ~/${DOT_DIR}/skills/$name"
        installed=$((installed + 1))
    done
    echo ""
    echo "    已安装 $installed 个 Skills（全局可用）"

    # --- 安装 Hooks ---
    header "安装 Hooks → ~/${DOT_DIR}/audit-harness/hooks/"

    local hooks_dst="$install_dir/hooks"
    mkdir -p "$hooks_dst"

    cp "$HARNESS_ROOT/hooks/_audit_common.sh" "$hooks_dst/"
    cp "$HARNESS_ROOT/hooks/post_tool_audit.sh" "$hooks_dst/"
    cp "$HARNESS_ROOT/hooks/stop_flush.sh" "$hooks_dst/"
    cp "$HARNESS_ROOT/hooks/prompt_inject_session.sh" "$hooks_dst/"
    chmod +x "$hooks_dst"/*.sh
    ok "3 个 Hooks 已安装（+ _audit_common.sh 共享 helper）"

    # --- 配置 Hooks ---
    local hooks_path="$hooks_dst"

    if $HOOKS_IN_SETTINGS; then
        header "配置 Hooks → ~/${DOT_DIR}/settings.json"
        local settings="$GLOBAL_DIR/settings.json"
        _install_hooks_config "$settings" "$hooks_path"
        ok "settings.json hooks 已配置"
    else
        header "配置 Hooks → ~/${DOT_DIR}/hooks.json"
        _install_codex_hooks "$GLOBAL_DIR/hooks.json" "$hooks_path"
        ok "hooks.json 已配置"
        warn "Codex 启动后需执行 /hooks 命令 trust 这 3 个 hook 才会生效"
    fi

    # --- 注入全局指令文件 ---
    header "配置全局审计规范 → ~/${DOT_DIR}/${DOCS_FILE}"

    local global_docs="$GLOBAL_DIR/$DOCS_FILE"
    local audit_section
    audit_section=$(cat "$TEMPLATES_SRC/CLAUDE.md.audit-section")

    if [[ ! -f "$global_docs" ]]; then
        echo "$audit_section" > "$global_docs"
        ok "创建 ~/${DOT_DIR}/${DOCS_FILE}（含审计规范）"
    elif ! grep -q "\[AUDIT\]" "$global_docs" 2>/dev/null || ! grep -q "audit_pending" "$global_docs" 2>/dev/null; then
        {
            echo ""
            echo "---"
            echo ""
            echo "$audit_section"
        } >> "$global_docs"
        ok "审计规范已追加到 ~/${DOT_DIR}/${DOCS_FILE}"
    else
        ok "~/${DOT_DIR}/${DOCS_FILE} 已包含审计规范"
    fi

    # --- 总结 ---
    local hooks_loc
    if $HOOKS_IN_SETTINGS; then
        hooks_loc="~/${DOT_DIR}/settings.json         — Hooks 配置"
    else
        hooks_loc="~/${DOT_DIR}/hooks.json            — Hooks 配置（需 /hooks trust）"
    fi

    echo ""
    echo -e "${BOLD}============================================================${RESET}"
    echo -e "${GREEN}${BOLD}  全局安装完成！（平台: ${PLATFORM}）${RESET}"
    echo -e "${BOLD}============================================================${RESET}"
    echo ""
    echo "  已安装（全局生效，所有项目无需额外配置）:"
    echo "    ~/${DOT_DIR}/audit-harness/        — 核心代码 + 模板"
    echo "    ~/${DOT_DIR}/audit-harness/hooks/  — 3 个 Hooks（自动创建 ${DOT_DIR}/runs/）"
    echo "    ~/${DOT_DIR}/skills/               — 4 个 Skills"
    echo "    $hooks_loc"
    echo "    ~/${DOT_DIR}/${DOCS_FILE}             — 审计规范（[AUDIT] 格式 + Context 恢复）"
    echo ""
    echo "  Hooks 说明:"
    echo "    PostToolUse → 自动记录 Write/Edit/Bash 操作到 audit_buffer"
    echo "    Stop        → 每轮回复后刷写 buffer 到 session 审计文件"
    echo "    UserPrompt  → 每轮输入时注入 session 上下文提醒"
    echo ""
    if [[ "$PLATFORM" == "codex" ]]; then
        echo "  Codex 注意:"
        echo "    1. hooks 走环境变量 AUDIT_DOT_DIR=.codex（已写入 hooks.json command 中）"
        echo "    2. 启动 Codex 后立即运行 /hooks trust 这 3 个 hook"
        echo "    3. AGENTS.md 而非 CLAUDE.md（Codex 不读 CLAUDE.md）"
        echo ""
    fi
    local platform_flag=""
    [[ "$PLATFORM" != "claude" ]] && platform_flag="--$PLATFORM "
    echo "  下一步: 在项目中执行初始化:"
    echo "    bash install.sh ${platform_flag}--init /path/to/your/project"
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
}

# 配置 settings.json 中的 hooks
_install_hooks_config() {
    local settings="$1"
    local hooks_path="$2"

    # 如果有 python3，用 python 做精准 JSON 合并
    if command -v python3 &>/dev/null; then
        python3 << PYEOF
import json, os

settings_path = "$settings"
hooks_path = "$hooks_path"

# 加载现有 settings
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
else:
    settings = {}

# 构建 hooks 配置
audit_hooks = {
    "PostToolUse": [
        {
            "matcher": "Write|Edit|Bash|NotebookEdit",
            "hooks": [
                {
                    "type": "command",
                    "command": f"bash {hooks_path}/post_tool_audit.sh"
                }
            ]
        }
    ],
    "Stop": [
        {
            "matcher": "",
            "hooks": [
                {
                    "type": "command",
                    "command": f"bash {hooks_path}/stop_flush.sh"
                }
            ]
        }
    ],
    "UserPromptSubmit": [
        {
            "matcher": "",
            "hooks": [
                {
                    "type": "command",
                    "command": f"bash {hooks_path}/prompt_inject_session.sh"
                }
            ]
        }
    ]
}

# 合并：保留用户已有的 hooks，追加 audit hooks
# 幂等性策略：以 hook 脚本 basename 作为唯一标识（如 post_tool_audit.sh）
import re
AUDIT_HOOK_SCRIPTS = {"post_tool_audit.sh", "stop_flush.sh", "prompt_inject_session.sh"}

def _hook_script_name(cmd):
    m = re.search(r"([a-zA-Z0-9_]+\.sh)", cmd)
    return m.group(1) if m else ""

existing_hooks = settings.get("hooks", {})
for event, hook_list in audit_hooks.items():
    if event not in existing_hooks:
        existing_hooks[event] = hook_list
        continue
    for new_hook in hook_list:
        new_cmd = new_hook.get("hooks", [{}])[0].get("command", "")
        new_script = _hook_script_name(new_cmd)
        if not new_script:
            continue
        existing_cmds = [h.get("hooks", [{}])[0].get("command", "")
                         for h in existing_hooks[event]]
        # 替换同名脚本（如果命令路径变了）；不存在则追加
        replaced = False
        for i, ec in enumerate(existing_cmds):
            if _hook_script_name(ec) == new_script:
                existing_hooks[event][i] = new_hook
                replaced = True
                break
        if not replaced:
            existing_hooks[event].append(new_hook)

settings["hooks"] = existing_hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
PYEOF
    else
        # 无 python 时的 fallback：如果 settings.json 不存在，直接写入
        if [[ ! -f "$settings" ]]; then
            cat > "$settings" << JSONEOF
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|Bash|NotebookEdit",
        "hooks": [{"type": "command", "command": "bash ${hooks_path}/post_tool_audit.sh"}]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "bash ${hooks_path}/stop_flush.sh"}]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [{"type": "command", "command": "bash ${hooks_path}/prompt_inject_session.sh"}]
      }
    ]
  }
}
JSONEOF
        else
            warn "settings.json 已存在且无 python3，请手动配置 hooks"
        fi
    fi
}

# ============================================================
# 配置 Codex 的 hooks.json（独立文件，顶层 hooks key）
# ============================================================
#
# Codex hooks 文档：https://developers.openai.com/codex/hooks
# 差异点（vs Claude Code settings.json hooks 子树）：
#   1. 独立文件 ~/.codex/hooks.json，顶层结构 {"hooks": {...}}
#   2. command 必须带 AUDIT_DOT_DIR=.codex 前缀，否则 hook 会写到 .claude/
#   3. matcher 用 regex 形式 ^Bash$（与 Claude 字面 Bash|Edit 兼容）
#   4. 新 hook 启动后需在 Codex 内执行 /hooks trust 才会运行
_install_codex_hooks() {
    local hooks_json="$1"
    local hooks_path="$2"

    if ! command -v python3 &>/dev/null; then
        warn "未检测到 python3，无法精准合并 hooks.json"
        warn "请手动创建 $hooks_json，参考 https://developers.openai.com/codex/hooks"
        return 0
    fi

    python3 << PYEOF
import json, os, re

hooks_json_path = "$hooks_json"
hooks_path = "$hooks_path"

if os.path.exists(hooks_json_path):
    try:
        with open(hooks_json_path) as f:
            cfg = json.load(f)
        if not isinstance(cfg, dict):
            cfg = {}
    except Exception:
        cfg = {}
else:
    cfg = {}

# Codex command 必须显式声明 AUDIT_DOT_DIR=.codex，否则 hooks 会落到 .claude/runs/
_pre = "AUDIT_DOT_DIR=.codex "

audit_hooks = {
    "PostToolUse": [
        {
            "matcher": "^(Write|Edit|Bash|NotebookEdit)$",
            "hooks": [
                {"type": "command",
                 "command": f"{_pre}bash {hooks_path}/post_tool_audit.sh"}
            ]
        }
    ],
    "Stop": [
        {
            "hooks": [
                {"type": "command",
                 "command": f"{_pre}bash {hooks_path}/stop_flush.sh"}
            ]
        }
    ],
    "UserPromptSubmit": [
        {
            "hooks": [
                {"type": "command",
                 "command": f"{_pre}bash {hooks_path}/prompt_inject_session.sh"}
            ]
        }
    ],
}

AUDIT_HOOK_SCRIPTS = {"post_tool_audit.sh", "stop_flush.sh", "prompt_inject_session.sh"}

def _hook_script_name(cmd):
    m = re.search(r"([a-zA-Z0-9_]+\.sh)", cmd or "")
    return m.group(1) if m else ""

existing_hooks = cfg.get("hooks", {})
if not isinstance(existing_hooks, dict):
    existing_hooks = {}

for event, hook_list in audit_hooks.items():
    if event not in existing_hooks:
        existing_hooks[event] = hook_list
        continue
    for new_hook in hook_list:
        new_cmd = new_hook.get("hooks", [{}])[0].get("command", "")
        new_script = _hook_script_name(new_cmd)
        if not new_script:
            continue
        replaced = False
        for i, eh in enumerate(existing_hooks[event]):
            ec = eh.get("hooks", [{}])[0].get("command", "")
            if _hook_script_name(ec) == new_script:
                existing_hooks[event][i] = new_hook
                replaced = True
                break
        if not replaced:
            existing_hooks[event].append(new_hook)

cfg["hooks"] = existing_hooks

os.makedirs(os.path.dirname(hooks_json_path), exist_ok=True)
with open(hooks_json_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PYEOF
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

    local proj_dot="$PROJECT/$DOT_DIR"
    local proj_runs="$proj_dot/runs"

    # --- 检测 ---
    echo "  环境检测:"
    local has_git=false has_runs=false has_config=false has_docs=false has_audit=false
    [[ -d "$PROJECT/.git" ]] && has_git=true
    [[ -d "$proj_runs" ]] && has_runs=true
    [[ -f "$proj_dot/audit_config.py" ]] && has_config=true
    [[ -f "$PROJECT/$DOCS_FILE" ]] && has_docs=true
    $has_docs && grep -q "\[AUDIT\]" "$PROJECT/$DOCS_FILE" 2>/dev/null && has_audit=true

    _check() {
        if $2; then
            echo -e "    ${GREEN}✅ 已存在${RESET}    $1"
        else
            echo -e "    ${YELLOW}❌ 需要配置${RESET}  $1"
        fi
    }

    _check "Git 仓库"                       "$has_git"
    _check "${DOT_DIR}/audit_config.py"     "$has_config"
    _check "${DOT_DIR}/runs/"               "$has_runs"
    _check "${DOCS_FILE}"                   "$has_docs"
    _check "${DOCS_FILE} 审计规范"           "$has_audit"

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

    mkdir -p "$proj_dot"

    local dst_cfg="$proj_dot/audit_config.py"
    if $has_config; then
        ok "audit_config.py 已存在（保留）"
    else
        _gen_config "$dst_cfg"
        ok "audit_config.py → ${DOT_DIR}/"
    fi

    # --- 创建 runs/ ---
    mkdir -p "$proj_runs/daily"
    ok "${DOT_DIR}/runs/ 目录已创建"

    if [[ ! -f "$proj_runs/.gitignore" ]]; then
        cat > "$proj_runs/.gitignore" << 'GITIGNORE'
*.jsonl
*.json
!index.json
!daily/
!weekly/
GITIGNORE
        ok "${DOT_DIR}/runs/.gitignore"
    fi

    # --- 指令文件 (CLAUDE.md / AGENTS.md) ---
    header "配置 ${DOCS_FILE}"

    local audit_section
    audit_section=$(cat "$GLOBAL_DIR/audit-harness/templates/CLAUDE.md.audit-section" 2>/dev/null || cat "$TEMPLATES_SRC/CLAUDE.md.audit-section")

    if ! $has_docs; then
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
        } > "$PROJECT/$DOCS_FILE"
        ok "创建 ${DOCS_FILE}（含审计规范）"
    elif ! $has_audit; then
        {
            echo ""
            echo "---"
            echo ""
            echo "$audit_section"
        } >> "$PROJECT/$DOCS_FILE"
        ok "审计规范已追加到 ${DOCS_FILE}"
    else
        ok "${DOCS_FILE} 已包含审计规范"
    fi

    # --- 验证 ---
    header "验证"

    local passed=0 total=0

    _verify() {
        local label="$1"; shift
        total=$((total + 1))
        if "$@" 2>/dev/null; then
            ok "$label"
            passed=$((passed + 1))
        else
            fail "$label"
        fi
    }

    _verify "全局: audit_context.py"     test -f "$GLOBAL_DIR/audit-harness/audit_context.py"
    _verify "全局: Skills"               test -d "$GLOBAL_DIR/skills/audit-start"
    _verify "项目: audit_config.py"      test -f "$proj_dot/audit_config.py"
    _verify "项目: ${DOT_DIR}/runs/"     test -d "$proj_runs"
    _verify "项目: ${DOCS_FILE}"         grep -q "\[AUDIT\]" "$PROJECT/$DOCS_FILE"

    echo ""
    echo "    验证结果: $passed/$total 通过"

    # --- 总结 ---
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
    if [[ $passed -eq $total ]]; then
        echo -e "${GREEN}${BOLD}  项目初始化完成！（平台: ${PLATFORM}）${RESET}"
    else
        echo -e "${YELLOW}${BOLD}  项目初始化完成（部分验证未通过）${RESET}"
    fi
    echo -e "${BOLD}============================================================${RESET}"
    echo ""
    echo "  全局（所有项目共享）:"
    echo "    ~/${DOT_DIR}/audit-harness/   — 核心代码"
    echo "    ~/${DOT_DIR}/skills/          — /start /end /recover /report-daily"
    echo ""
    echo "  本项目:"
    echo "    ${DOT_DIR}/audit_config.py    — 项目配置（$n_scripts 个脚本, $n_assets 个资产）"
    echo "    ${DOT_DIR}/runs/              — 审计数据存储"
    echo "    ${DOCS_FILE}                  — 审计规范（已注入）"
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

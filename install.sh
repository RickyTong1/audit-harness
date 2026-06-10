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
        --cron)   MODE="cron";   shift ;;
        --help|-h)
            echo "用法:"
            echo "  bash install.sh                         智能模式（自动判断）"
            echo "  bash install.sh --global                仅全局安装"
            echo "  bash install.sh --init [project_dir]    仅项目初始化（默认当前目录）"
            echo "  bash install.sh --auto [project_dir]    全局 + 项目初始化"
            echo "  bash install.sh --cron [project_dir]    配置每日 08:03 launchd 定时（macOS）"
            echo "                                          并把项目注册进 daily_projects.conf"
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
if [[ "$MODE" == "init" || "$MODE" == "auto" || "$MODE" == "cron" ]]; then
    PROJECT="${PROJECT:-$(pwd)}"
    PROJECT="$(cd "$PROJECT" && pwd)"
    if [[ "$MODE" != "cron" && "$PROJECT" == "$HARNESS_ROOT" ]]; then
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
        installed=$((installed + 1))
    done
    echo ""
    echo "    已安装 $installed 个 Skills（全局可用）"

    # --- 安装 Hooks ---
    header "安装 Hooks → ~/.claude/audit-harness/hooks/"

    local hooks_dst="$install_dir/hooks"
    mkdir -p "$hooks_dst"

    cp "$HARNESS_ROOT/hooks/_audit_common.sh" "$hooks_dst/"
    cp "$HARNESS_ROOT/hooks/post_tool_audit.sh" "$hooks_dst/"
    cp "$HARNESS_ROOT/hooks/stop_flush.sh" "$hooks_dst/"
    cp "$HARNESS_ROOT/hooks/prompt_inject_session.sh" "$hooks_dst/"
    chmod +x "$hooks_dst"/*.sh
    ok "3 个 Hooks 已安装（+ _audit_common.sh 共享 helper）"

    # --- 配置 settings.json hooks ---
    header "配置 Hooks → ~/.claude/settings.json"

    local settings="$GLOBAL_DIR/settings.json"
    local hooks_path="$hooks_dst"

    # 生成 hooks 配置 JSON
    _install_hooks_config "$settings" "$hooks_path"
    ok "settings.json hooks 已配置"

    # --- 安装 engram 集成（可选，缺依赖时跳过不报错） ---
    header "安装 engram 集成 → ~/.claude/audit-harness/engram/"
    install_engram "$install_dir"

    # --- 注入全局 CLAUDE.md ---
    header "配置全局审计规范 → ~/.claude/CLAUDE.md"

    local global_claude="$GLOBAL_DIR/CLAUDE.md"
    local audit_section
    audit_section=$(cat "$TEMPLATES_SRC/CLAUDE.md.audit-section")

    if [[ ! -f "$global_claude" ]]; then
        echo "$audit_section" > "$global_claude"
        ok "创建 ~/.claude/CLAUDE.md（含审计规范）"
    elif ! grep -q "\[AUDIT\]" "$global_claude" 2>/dev/null || ! grep -q "audit_pending" "$global_claude" 2>/dev/null; then
        {
            echo ""
            echo "---"
            echo ""
            echo "$audit_section"
        } >> "$global_claude"
        ok "审计规范已追加到 ~/.claude/CLAUDE.md"
    else
        ok "~/.claude/CLAUDE.md 已包含审计规范"
    fi

    # --- 总结 ---
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
    echo -e "${GREEN}${BOLD}  全局安装完成！${RESET}"
    echo -e "${BOLD}============================================================${RESET}"
    echo ""
    echo "  已安装（全局生效，所有项目无需额外配置）:"
    echo "    ~/.claude/audit-harness/        — 核心代码 + 模板"
    echo "    ~/.claude/audit-harness/hooks/  — 3 个 Hooks（自动创建 .claude/runs/）"
    echo "    ~/.claude/audit-harness/engram/ — engram wrapper + consolidation"
    echo "    ~/.claude/skills/               — 4 个 Skills"
    echo "    ~/.claude/settings.json         — Hooks 配置"
    echo "    ~/.claude/CLAUDE.md             — 审计规范（[AUDIT] 格式 + Context 恢复）"
    echo "    mcp.json                        — engram MCP server（如检测到 engram CLI）"
    echo ""
    echo "  Hooks 说明:"
    echo "    PostToolUse → 自动记录 Write/Edit/Bash 操作到 audit_buffer"
    echo "    Stop        → 每轮回复后刷写 buffer 到 session 审计文件"
    echo "    UserPrompt  → 每轮输入时注入 session 上下文提醒"
    echo ""
    echo "  下一步: 在项目中执行初始化:"
    echo "    bash install.sh --init /path/to/your/project"
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
}

# ============================================================
# engram 集成（L2_engram §11.1.4）
# 铁律：engram 是可选依赖——任何检测失败都只 warn 不中断安装
# ============================================================
install_engram() {
    local install_dir="$1"
    local engram_dst="$install_dir/engram"

    # 1. 复制 wrapper（无论 engram 是否安装都复制——后装 engram 即可用）
    mkdir -p "$engram_dst"
    cp "$LIB_SRC/engram/client.py" "$engram_dst/"
    cp "$LIB_SRC/engram/wrapper.sh" "$engram_dst/"
    cp "$LIB_SRC/engram/consolidate_llm.py" "$engram_dst/"
    chmod +x "$engram_dst/wrapper.sh"
    ok "engram wrapper（client.py + wrapper.sh + consolidate_llm.py）"

    # 2. 检测 engram CLI
    local engram_bin
    engram_bin="$(command -v engram || true)"
    if [[ -z "$engram_bin" ]]; then
        warn "engram CLI 未安装，跳过 MCP 配置（安装后重跑 install.sh --global 即可）"
        return 0
    fi
    ok "engram CLI: $engram_bin"

    # 3. 检测 Ollama + embedding 模型（只 warn，不阻断 MCP 配置）
    local embed_model="${ENGRAM_OLLAMA_MODEL:-qwen3-embedding:4b}"
    local embed_dims="${ENGRAM_OLLAMA_DIMS:-2560}"
    if curl -s --max-time 2 "http://localhost:11434/api/tags" 2>/dev/null | grep -q "\"$embed_model\""; then
        ok "Ollama embedding 模型: $embed_model（$embed_dims dims）"
    else
        warn "Ollama 未运行或缺 $embed_model（语义检索将退化为关键词匹配）"
        warn "  修复: ollama pull $embed_model"
    fi

    # 4. 写入 MCP 配置（幂等：已有 engram 配置则保留用户的，绝不覆盖）
    if ! command -v python3 &>/dev/null; then
        warn "无 python3，请手动在 mcp.json 中配置 engram server"
        return 0
    fi
    local mcp_file
    for mcp_file in "$HOME/.cursor/mcp.json" "$GLOBAL_DIR/.mcp.json"; do
        python3 - "$mcp_file" "$engram_bin" "$embed_model" "$embed_dims" << 'PYEOF'
import json, os, sys

mcp_path, engram_bin, model, dims = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
config = {}
if os.path.exists(mcp_path):
    try:
        with open(mcp_path) as f:
            config = json.load(f)
    except (json.JSONDecodeError, OSError):
        print(f"    [skip] {mcp_path} 解析失败，不修改")
        sys.exit(0)

# 两种布局：mcpServers 包裹（~/.cursor/mcp.json）或顶层即 servers（~/.claude/.mcp.json）
if "mcpServers" in config:
    target = config["mcpServers"]
elif config:
    target = config
else:
    target = config.setdefault("mcpServers", {})
if "engram" in target:
    print(f"    [keep] {mcp_path} 已有 engram 配置（保留用户配置）")
    sys.exit(0)

target["engram"] = {
    "command": engram_bin,
    "args": ["mcp"],
    "env": {
        "ENGRAM_OLLAMA_MODEL": model,
        "ENGRAM_OLLAMA_DIMS": dims,
        "PATH": os.path.dirname(engram_bin) + ":/usr/local/bin:/usr/bin:/bin",
    },
}
os.makedirs(os.path.dirname(mcp_path), exist_ok=True)
with open(mcp_path, "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print(f"    [add] {mcp_path} engram server 已配置")
PYEOF
    done
    ok "MCP 配置完成（~/.cursor/mcp.json + ~/.claude/.mcp.json）"
}

# ============================================================
# cron 模式：每日 08:03 日报 + 晨间修正 + engram consolidate
# ============================================================
install_cron() {
    echo ""
    echo -e "${BOLD}============================================================${RESET}"
    echo -e "${BOLD}  audit-harness 每日定时配置（launchd）${RESET}"
    echo -e "${BOLD}============================================================${RESET}"
    echo ""

    if [[ "$(uname)" != "Darwin" ]]; then
        fail "cron 模式当前仅支持 macOS（launchd）。Linux 请手动配置 crontab:"
        echo "    3 8 * * * bash $GLOBAL_DIR/audit-harness/bin/audit_daily.sh"
        exit 1
    fi

    local install_dir="$GLOBAL_DIR/audit-harness"
    if [[ ! -f "$install_dir/audit_context.py" ]]; then
        fail "全局未安装，先执行: bash install.sh --global"
        exit 1
    fi

    # 1. 安装 bin/audit_daily.sh
    mkdir -p "$install_dir/bin" "$install_dir/logs"
    cp "$HARNESS_ROOT/bin/audit_daily.sh" "$install_dir/bin/"
    chmod +x "$install_dir/bin/audit_daily.sh"
    ok "bin/audit_daily.sh → ~/.claude/audit-harness/bin/"

    # 2. 注册项目到 daily_projects.conf（幂等）
    local conf="$install_dir/daily_projects.conf"
    touch "$conf"
    if grep -qxF "$PROJECT" "$conf" 2>/dev/null; then
        ok "项目已注册: $PROJECT"
    else
        echo "$PROJECT" >> "$conf"
        ok "项目已注册: $PROJECT"
    fi

    # 3. 生成并加载 launchd plist
    local plist="$HOME/Library/LaunchAgents/com.audit-harness.daily.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    sed "s|__HARNESS_DIR__|$install_dir|g" \
        "$TEMPLATES_SRC/com.audit-harness.daily.plist" > "$plist"
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist"
    ok "launchd 已加载: com.audit-harness.daily（每天 08:03）"

    echo ""
    echo "  验证: launchctl list | grep audit-harness"
    echo "  日志: ~/.claude/audit-harness/logs/daily_YYYYMMDD.log"
    echo "  手动触发测试: bash $install_dir/bin/audit_daily.sh"
    echo ""
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
        total=$((total + 1))
        if "$@" 2>/dev/null; then
            ok "$label"
            passed=$((passed + 1))
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
    cron)
        install_cron
        ;;
esac

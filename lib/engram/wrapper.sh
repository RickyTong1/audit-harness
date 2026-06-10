#!/usr/bin/env bash
# ============================================================
# L3 | lib/engram/wrapper.sh — engram 结构化注入层 (bash)
#
# 用途：为 engram MCP 操作提供结构化 bash CLI 接口。
#       底层通过 python3 lib/engram/client.py 与 engram MCP server 通信。
#       不操作 SQLite，不嵌入 engram 内部逻辑。
#
# 设计原则：
#   - 所有操作 try/catch，失败不阻断（exit 0）
#   - 参数通过 JSON 传递给 Python 客户端
#   - 内存后端可替换——只需换 MCP server，wrapper 不变
#
# 输入：子命令 + 对应参数
# 输出：JSON 格式结果（stdout），错误静默
#
# 关联文件：
#   上游：docs/L1_memory_architecture.md（双层记忆蓝图）
#         docs/L2_engram_memory_integration.md（集成设计）
#   下游：skills/audit-end/SKILL.md §7（写入管道调用本 wrapper）
#         skills/audit-start/SKILL.md §2a（双源恢复调用本 wrapper）
#         skills/audit-recover/SKILL.md（双源恢复调用本 wrapper）
#   内部：lib/engram/client.py（Python MCP 客户端）
#   外部：~/.engram/default.db（engram vault，间接访问）
#
# 用法示例：
#   source lib/engram/wrapper.sh
#
#   # 结构化写入
#   engram_remember \
#     --content "用户偏好纯 bash" \
#     --type semantic \
#     --topics "cross-project,correction" \
#     --salience 0.9
#
#   # 结构化召回
#   engram_recall \
#     --context "bash 开发偏好" \
#     --topics "cross-project" \
#     --limit 5
#
#   # 增强 consolidate
#   engram_consolidate --cleanup
#
#   # 记忆关联
#   engram_connect \
#     --source "id1" \
#     --target "id2" \
#     --type "causes"
# ============================================================

# --- 定位 client.py -------------------------------------------------
_get_client_py() {
    # 查找顺序：相对于本脚本 → 相对于 PWD → 全局安装路径
    local _wrapper_dir
    _wrapper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)"

    for _p in \
        "${_wrapper_dir}/client.py" \
        "${PWD}/lib/engram/client.py" \
        "${HOME}/.claude/audit-harness/lib/engram/client.py"; do
        if [[ -f "$_p" ]]; then
            echo "$_p"
            return 0
        fi
    done
    return 1
}

ENGRAM_CLIENT_PY="$(_get_client_py)"

# --- 内部 helper：构建 JSON 参数并调用 Python 客户端 -----------------
_engram_call() {
    local _cmd="$1"
    local _json_args="$2"

    if [[ -z "$ENGRAM_CLIENT_PY" ]] || ! command -v python3 &>/dev/null; then
        return 0
    fi

    python3 "$ENGRAM_CLIENT_PY" "$_cmd" "$_json_args" 2>/dev/null || true
}

# --- 拼接 JSON 数组 helper -------------------------------------------
_join_json_array() {
    # 将逗号分隔的字符串转为 JSON 数组
    # 用法: _join_json_array "a,b,c" → ["a","b","c"]
    local _input="$1"
    if [[ -z "$_input" ]]; then
        echo '[]'
        return
    fi
    python3 -c "
import sys, json
items = [x.strip() for x in sys.argv[1].split(',') if x.strip()]
print(json.dumps(items))
" "$_input" 2>/dev/null || echo '[]'
}

# ============================================================
# 公开 API — 每个函数对应一个 engram 操作
# ============================================================

# --- engram_remember — 结构化写入 -----------------------------------
# 参数：
#   --content    文本内容（必填）
#   --type       episodic|semantic|procedural（默认: episodic）
#   --topics     逗号分隔话题，如 "project:xxx,cross-project,correction"
#   --salience   重要性 0.0-1.0（默认: 0.5）
#   --entities   逗号分隔实体，如 "Ricky Tong,LoRA"
#   --status     active|pending|fulfilled|superseded|archived
engram_remember() {
    local _content="" _type="" _topics="" _salience="" _entities="" _status=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --content)  _content="$2"; shift 2 ;;
            --type)     _type="$2"; shift 2 ;;
            --topics)   _topics="$2"; shift 2 ;;
            --salience) _salience="$2"; shift 2 ;;
            --entities) _entities="$2"; shift 2 ;;
            --status)   _status="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$_content" ]]; then
        echo '{"ok":false,"error":"content is required"}'
        return 0
    fi

    # 构建 JSON 参数
    local _json
    _json=$(python3 -c "
import json, sys
args = {'content': sys.argv[1]}
if sys.argv[2]: args['type'] = sys.argv[2]
if sys.argv[3]: args['salience'] = float(sys.argv[3])
if sys.argv[4]: args['status'] = sys.argv[4]
print(json.dumps(args, ensure_ascii=False))
" "$_content" "$_type" "$_salience" "$_status" 2>/dev/null)

    # topics 和 entities 作为数组注入（需要 merge）
    local _topics_json _entities_json
    _topics_json=$(_join_json_array "$_topics")
    _entities_json=$(_join_json_array "$_entities")

    # merge topics/entities 到主 JSON
    _json=$(python3 -c "
import json, sys
args = json.loads(sys.argv[1])
topics = json.loads(sys.argv[2])
entities = json.loads(sys.argv[3])
if topics: args['topics'] = topics
if entities: args['entities'] = entities
print(json.dumps(args, ensure_ascii=False))
" "$_json" "$_topics_json" "$_entities_json" 2>/dev/null)

    _engram_call 'remember' "$_json"
}

# --- engram_recall — 结构化召回 -------------------------------------
# 参数：
#   --context    查询上下文（必填）
#   --topics     逗号分隔话题过滤
#   --entities   逗号分隔实体过滤
#   --type       类型过滤
#   --limit      最大返回数（默认 10）
engram_recall() {
    local _context="" _topics="" _entities="" _type="" _limit="10"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --context)  _context="$2"; shift 2 ;;
            --topics)   _topics="$2"; shift 2 ;;
            --entities) _entities="$2"; shift 2 ;;
            --type)     _type="$2"; shift 2 ;;
            --limit)    _limit="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$_context" ]]; then
        echo '{"ok":false,"error":"context is required"}'
        return 0
    fi

    local _topics_json _entities_json
    _topics_json=$(_join_json_array "$_topics")
    _entities_json=$(_join_json_array "$_entities")

    local _json
    _json=$(python3 -c "
import json, sys
args = {'context': sys.argv[1], 'limit': int(sys.argv[2])}
if sys.argv[3]: args['type'] = sys.argv[3]
topics = json.loads(sys.argv[4])
entities = json.loads(sys.argv[5])
if topics: args['topics'] = topics
if entities: args['entities'] = entities
print(json.dumps(args, ensure_ascii=False))
" "$_context" "$_limit" "$_type" "$_topics_json" "$_entities_json" 2>/dev/null)

    _engram_call 'recall' "$_json"
}

# --- engram_consolidate — 增强整理 -----------------------------------
# 参数：
#   --cleanup   整理后清理 procedural meta-memory 噪音
engram_consolidate() {
    local _cleanup=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cleanup) _cleanup=true; shift ;;
            *) shift ;;
        esac
    done

    _engram_call 'consolidate' '{}'
}

# --- engram_forget — 删除记忆 ---------------------------------------
# 参数：
#   $1          memory ID
#   --hard      物理删除（默认软删除）
engram_forget() {
    local _id=""
    local _hard=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hard) _hard=true; shift ;;
            --*) shift 2 ;;
            *)
                if [[ -z "$_id" ]]; then
                    _id="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$_id" ]]; then
        echo '{"ok":false,"error":"id is required"}'
        return 0
    fi

    local _json
    _json=$(python3 -c "
import json
print(json.dumps({'id': '${_id}', 'hard': ${_hard}}))
" 2>/dev/null)

    _engram_call 'forget' "$_json"
}

# --- engram_connect — 建立记忆关联 -----------------------------------
# 参数：
#   --source     源记忆 ID（必填）
#   --target     目标记忆 ID（必填）
#   --type       关系类型（必填）
#   --strength   关联强度 0.0-1.0
engram_connect() {
    local _source="" _target="" _type="" _strength=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)   _source="$2"; shift 2 ;;
            --target)   _target="$2"; shift 2 ;;
            --type)     _type="$2"; shift 2 ;;
            --strength) _strength="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$_source" || -z "$_target" || -z "$_type" ]]; then
        echo '{"ok":false,"error":"source, target, and type are required"}'
        return 0
    fi

    local _json
    _json=$(python3 -c "
import json, sys
args = {'sourceId': sys.argv[1], 'targetId': sys.argv[2], 'type': sys.argv[3]}
if sys.argv[4]: args['strength'] = float(sys.argv[4])
print(json.dumps(args, ensure_ascii=False))
" "$_source" "$_target" "$_type" "$_strength" 2>/dev/null)

    _engram_call 'connect' "$_json"
}

# --- engram_alerts — 待处理告警 --------------------------------------
engram_alerts() {
    local _stale_days="3" _limit="5"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stale-days) _stale_days="$2"; shift 2 ;;
            --limit)      _limit="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local _json
    _json=$(python3 -c "
import json
print(json.dumps({'staleDays': int('${_stale_days}'), 'limit': int('${_limit}')}))
" 2>/dev/null)

    _engram_call 'alerts' "$_json"
}

# --- engram_surface — 主动推送 ---------------------------------------
engram_surface() {
    local _context="" _entities="" _topics=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --context)  _context="$2"; shift 2 ;;
            --entities) _entities="$2"; shift 2 ;;
            --topics)   _topics="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local _entities_json _topics_json
    _entities_json=$(_join_json_array "$_entities")
    _topics_json=$(_join_json_array "$_topics")

    local _json
    _json=$(python3 -c "
import json, sys
args = {}
if sys.argv[1]: args['context'] = sys.argv[1]
entities = json.loads(sys.argv[2])
topics = json.loads(sys.argv[3])
if entities: args['activeEntities'] = entities
if topics: args['activeTopics'] = topics
print(json.dumps(args, ensure_ascii=False))
" "$_context" "$_entities_json" "$_topics_json" 2>/dev/null)

    _engram_call 'surface' "$_json"
}

# --- engram_briefing — 会话简报 --------------------------------------
engram_briefing() {
    local _context="" _project=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --context) _context="$2"; shift 2 ;;
            --project) _project="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local _json
    _json=$(python3 -c "
import json, sys
args = {}
if sys.argv[1]: args['context'] = sys.argv[1]
if sys.argv[2]: args['project'] = sys.argv[2]
print(json.dumps(args, ensure_ascii=False))
" "$_context" "$_project" 2>/dev/null)

    _engram_call 'briefing' "$_json"
}

# --- engram_stats — Vault 统计 ---------------------------------------
engram_stats() {
    _engram_call 'stats' '{}'
}

# --- engram_batch — 批量操作（复用 MCP 连接）---------------------------
# 用法：engram_batch '[
#   {"cmd":"remember","args":{"content":"...","type":"semantic","topics":["x"],"salience":0.9}},
#   {"cmd":"consolidate","args":{}}
# ]'
# 解决自动化场景下每次调用重启 MCP 进程的性能问题。
engram_batch() {
    local _json="$1"
    if [[ -z "$_json" ]]; then
        echo '{"ok":false,"error":"batch requires a JSON array of operations"}'
        return 0
    fi
    _engram_call 'batch' "$_json"
}

# --- engram_experience — 经验图谱检索 ----------------------------------
# 专为 bugfix / problem-solving / planning 场景设计。
# 语义召回 + 图谱遍历（1-hop邻居）+ 遗忘衰减排序。
#
# 参数：
#   --context       问题描述（必填）
#   --topics        话题过滤
#   --limit         语义召回数量（默认5）
#   --graph-hops    图谱跳数（默认1，最大2）
#   --forgetting-lambda  遗忘速率（默认0.05，越大遗忘越快）
engram_experience() {
    local _context="" _topics="" _limit="5" _graph_hops="1" _forgetting_lambda="0.05"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --context)           _context="$2"; shift 2 ;;
            --topics)            _topics="$2"; shift 2 ;;
            --limit)             _limit="$2"; shift 2 ;;
            --graph-hops)        _graph_hops="$2"; shift 2 ;;
            --forgetting-lambda) _forgetting_lambda="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$_context" ]]; then
        echo '{"ok":false,"error":"context is required"}'
        return 0
    fi

    local _topics_json
    _topics_json=$(_join_json_array "$_topics")

    local _json
    _json=$(python3 -c "
import json, sys
args = {'context': sys.argv[1], 'limit': int(sys.argv[2]), 'graphHops': int(sys.argv[3]), 'forgettingLambda': float(sys.argv[4])}
topics = json.loads(sys.argv[5])
if topics: args['topics'] = topics
print(json.dumps(args, ensure_ascii=False))
" "$_context" "$_limit" "$_graph_hops" "$_forgetting_lambda" "$_topics_json" 2>/dev/null)

    _engram_call 'experience' "$_json"
}

# ============================================================
# 直接执行模式（用于调试：bash wrapper.sh remember --content "..."）
# ============================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$_subcmd" in
        remember)    engram_remember "$@" ;;
        recall)      engram_recall "$@" ;;
        consolidate) engram_consolidate "$@" ;;
        forget)      engram_forget "$@" ;;
        connect)     engram_connect "$@" ;;
        alerts)      engram_alerts "$@" ;;
        surface)     engram_surface "$@" ;;
        briefing)    engram_briefing "$@" ;;
        stats)       engram_stats "$@" ;;
        batch)       engram_batch "$1" ;;
        experience)  engram_experience "$@" ;;
        *)
            echo "Usage: wrapper.sh <remember|recall|consolidate|forget|connect|alerts|surface|briefing|stats> [args...]"
            echo ""
            echo "Structured engram operations for audit-harness."
            echo "Typically sourced as a library: source lib/engram/wrapper.sh"
            ;;
    esac
fi

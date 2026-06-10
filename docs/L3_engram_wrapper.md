# L3 | engram Wrapper — 文件级文档

> **级别**：L3（文件级）
> **归属**：`lib/engram/` 模块
> **版本**：v4.0.0
> **日期**：2026-06-09

---

## 文件清单

| 文件 | 作用 | 行数 |
|------|------|------|
| `lib/engram/client.py` | Python MCP 客户端——通过 JSON-RPC 与 `engram mcp` 通信 | ~320 |
| `lib/engram/wrapper.sh` | Bash CLI 封装——参数解析 + 调用 client.py | ~300 |

---

## 数据流

```
Skills / Hooks / CLI
       │
       ▼
wrapper.sh (bash)
  - 参数解析（--type, --topics, --salience, --entities）
  - 逗号分隔字符串 → JSON 数组转换
  - 调用 python3 client.py <command> <json_args>
       │
       ▼
client.py (Python)
  - 启动 engram mcp 子进程
  - MCP JSON-RPC 握手（initialize → initialized）
  - 发送 tools/call 请求
  - 跳过 auto-ingest 噪音行
  - 返回 JSON 结果
       │
       ▼
engram mcp (Node.js)
  - StdioServerTransport
  - Vault.remember / Vault.recall / Vault.consolidate / ...
  - 生成 embedding（Qwen3-Embedding-4B via Ollama）
  - 写入 SQLite (~/.engram/default.db)
```

---

## API 参考

### client.py

```python
from lib.engram.client import EngramClient

client = EngramClient()

# 结构化写入
client.remember(
    content="用户偏好纯 bash",
    memory_type="semantic",
    topics=["cross-project", "correction"],
    salience=0.9,
)

# 结构化召回
client.recall(
    context="bash 开发偏好",
    topics=["cross-project"],
    limit=5,
)

# 整理
client.consolidate()

# 删除
client.forget("memory-id", hard=False)

# 关联
client.connect("src-id", "tgt-id", "causes", strength=0.7)

# 告警
client.alerts(stale_days=3, limit=5)

# 主动推送
client.surface(context="当前任务", active_topics=["project:audit-harness"])

# 简报
client.briefing(context="任务描述", project="audit-harness")

client.close()  # 清理子进程
```

### wrapper.sh

```bash
source lib/engram/wrapper.sh

engram_remember \
  --content "文本内容" \
  --type semantic \
  --topics "cross-project,correction" \
  --salience 0.9 \
  --entities "Ricky Tong,audit-harness"

engram_recall \
  --context "查询上下文" \
  --topics "project:audit-harness" \
  --limit 10

engram_consolidate --cleanup
engram_forget "memory-id" --hard
engram_connect --source "id1" --target "id2" --type "causes"
engram_alerts --stale-days 3 --limit 5
engram_surface --context "任务" --topics "project:xxx"
engram_briefing --context "任务" --project "my-project"
engram_stats
```

---

## 支持的类型/话题/权重

| 字段 | 可选值 | 来源 |
|------|--------|------|
| type | episodic, semantic, procedural | L2 §4.3 |
| topics | project:{name}, cross-project, correction, conclusion, change, session-summary, audit-trail | L2 §3.2 |
| salience | 0.0–1.0（默认0.5） | L2 §4.3 |
| status | active, pending, fulfilled, superseded, archived | engram MCP schema |
| entities | 人名、工具名、项目名等 | engram 自动提取 |

---

## 错误处理约定

1. 所有操作失败时 exit code = 0（不阻断主流程）
2. 错误信息包含在 JSON 响应中：`{"ok": false, "error": "..."}`
3. engram MCP 不可用时静默返回空结果
4. 不重试、不回滚、不抛异常

## 与 MCP 工具名的对应关系

wrapper.sh 的函数名与 engram MCP 工具名**完全相同**，符合 L1 §6 的"通过 MCP 工具名调用"原则：

| wrapper.sh 函数 | engram MCP 工具 | 参数映射 |
|----------------|----------------|---------|
| `engram_remember` | `engram_remember` | --content→content, --type→type, --topics→topics, --salience→salience, --entities→entities |
| `engram_recall` | `engram_recall` | --context→context, --topics→topics, --limit→limit |
| `engram_consolidate` | `engram_consolidate` | 无参数 |
| `engram_forget` | `engram_forget` | $1→id, --hard→hard |
| `engram_connect` | `engram_connect` | --source→sourceId, --target→targetId, --type→type |
| `engram_alerts` | `engram_alerts` | --stale-days→staleDays, --limit→limit |
| `engram_surface` | `engram_surface` | --context→context, --entities→activeEntities, --topics→activeTopics |
| `engram_briefing` | `engram_briefing` | --context→context, --project→project |
| `engram_stats` | `engram_stats` | 无参数 |

---

## 测试结果（2026-06-09）

| 测试 | 结果 |
|------|------|
| `engram_remember` (type=semantic, salience=0.9) | ✅ Type=semantic, salience=0.90 |
| `engram_remember` (type=procedural, topics, entities) | ✅ Type=procedural, entities 正确 |
| `engram_recall` (topics 过滤) | ✅ #1 命中目标记忆 |
| `engram_consolidate` | ✅ 处理 41 episodes, 165 connections |
| `engram_connect` | ✅ elaborates relation, strength=0.8 |
| `engram_alerts` | ✅ 无待处理告警 |
| `engram_surface` | ✅ 3 条推送，含 relevance + reasoning path |
| `engram_briefing` | ✅ 完整简报（changes, knowledge, depth map, activity） |
| `engram_forget` | ✅ 软删除 salience→0 |

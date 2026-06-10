# L1 | AI Agent 双层记忆架构蓝图

> **日期**：2026-06-09
> **级别**：L1（系统蓝图）
> **版本**：v1.0
> **归属**：audit-harness 项目

---

## 1. 愿景

> **让 AI Agent 像人类专家一样工作——有审计、有记忆、会反思、不重犯错误。**

人类专家的知识体系有两层：
- **工作日志**——不可篡改的事实记录，出了问题可以追溯
- **经验直觉**——从无数次实践中提炼出的模式，决定面对新问题时的第一反应

AI Agent 传统上只有 context window——一个会被压缩、截断、跨 session 清零的"短期记忆"。audit-harness 的使命是给 Agent 装上这两层持久化记忆。

---

## 2. 双层架构

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   事实层 (runs/)                  语义层 (engram)             │
│   ──────────────                  ──────────────             │
│   WORM（一次写入不可变）           有损（可遗忘、可改写）       │
│   per-project                     全局 vault                 │
│   结构化 JSONL/JSON                向量 embedding + 图谱       │
│   grep / 文件遍历                  语义检索 + 主动推送          │
│   审计证据、追责、日报              经验复用、纠错防重犯          │
│                                                             │
│   ┌─────────────────┐      单向 ETL      ┌──────────────┐  │
│   │ audit_trail     │ ─────────────────► │ episodic     │  │
│   │ manifest        │  /audit-end 时提取  │ semantic     │  │
│   │ checksums       │                    │ edges        │  │
│   │ index.json      │                    │ entities     │  │
│   │ session_summary │                    │ vec_memories │  │
│   └─────────────────┘                    └──────────────┘  │
│          ▲                                      ▲          │
│          │ 写入（hooks 自动）                     │ 读取       │
│          │                                      │          │
│   ┌──────┴──────────────────────────────────────┴──────┐   │
│   │                    AI Agent                        │   │
│   │  /audit-start: 双源恢复                             │   │
│   │  /audit-end:   归档 + 单向写入                      │   │
│   │  /audit-recover: 双源检索                           │   │
│   └────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.1 为什么是两层而不是一层

| 方案 | 缺陷 |
|------|------|
| 只有 runs/ | 无语义检索、无跨项目、无巩固——"上次 LoRA 怎么修的"找不到 |
| 只有 engram | 有损——遗忘后审计链断裂，日报数字不可信 |
| **双层** | 各取所长——runs/ 管"能证明的"，engram 管"能想起来的" |

### 2.2 铁律

1. **runs/ 永远是真相。** engram 是 runs/ 的派生语义索引，不是平行数据源。
2. **单向 ETL。** runs/ → engram，不回流。engram 的 consolidation 产出不回写 runs/。
3. **engram 故障不阻断。** 所有 engram 调用 try/catch 包裹。engram 宕机，审计完整性不受影响。
4. **数据 Record 永不进 engram。** 行级处理记录（日均 10,000+）属于 WORM 层。engram 只收语义级摘要。

---

## 3. 三层防线 + 双层记忆

audit-harness 的三层防线（审计生产）和双层记忆（审计消费）形成完整闭环：

```
生产侧（三层防线）                    消费侧（双层记忆）
─────────────────                    ─────────────────

层 1: Skill 硬编码 ──┐                ┌── engram 语义检索
  AuditContext       │                │   recall / surface / briefing
  record/finalize    │                │   跨项目 / 跨会话
                     │    runs/       │
层 2: [AUDIT] 格式 ──┤ ──────────── ──┤── runs/ 文件扫描
  CLAUDE.md 约束     │  (WORM 存储)   │   index.json / audit_trail
                     │                │   grep / 遍历
层 3: Hooks 兜底  ───┘                └── 日报 / 晨间修正
  PostToolUse                            /report-daily
  Stop                                   morning_review
  UserPromptSubmit
```

---

## 4. 记忆恢复优先级

无论从 runs/ 还是 engram 恢复，优先级固定不变：

| 优先级 | 内容 | 来源 | 丢失后果 |
|--------|------|------|---------|
| 🔴 最高 | 用户修正（correction） | engram `cross-project` + runs/ `user_correction` | **重犯已纠正的错误** |
| 🟡 高 | 任务状态 | runs/ `session.json` + `audit_trail` 最后 3 条 | 不知道做到哪了 |
| 🟢 中 | 分析结论 | engram `conclusion` + runs/ `audit_blocks` | 重复已完成的分析 |
| ⚪ 低 | 环境配置 | runs/ `manifest.json` environment | 重复环境排查 |

---

## 5. 跨项目记忆模型

```
Project A (runs/A)      Project B (runs/B)      Project C (runs/C)
     │                       │                       │
     └───── /audit-end ──────┴───── /audit-end ──────┘
                    │
            ┌───────▼────────┐
            │  engram vault  │
            │  (全局共享)     │
            │                │
            │  project:A ──┐ │
            │  project:B ──┤ │  ← topic 软隔离
            │  project:C ──┤ │
            │  cross-project │  ← 用户偏好、修正、红线
            └────────────────┘
                    │
     ┌──── /audit-start ─────┬──── /audit-start ────┐
     │                       │                      │
Project A                Project B              Project C
  日常: 只搜 project:A    bug fix: 全局搜        设计: surface 推送
```

---

## 6. 记忆后端的可替换性

audit-harness 的 Skills 通过 MCP 工具名（`engram_remember`, `engram_recall`, `engram_surface` 等）调用记忆层，不嵌入任何 engram 内部逻辑。

如果未来需要换 Mem0 / Zep / Letta：
1. 实现一个新的 MCP server，暴露相同工具名和参数
2. 修改 `mcp.json` 指向新 server
3. Skills 代码**一字不改**

当前 engram 对标业界的能力覆盖：

| engram 能力 | 对标 Mem0 | 对标 Zep | 对标 Letta |
|------------|-----------|---------|-----------|
| remember/recall | ✅ 自动抽取 | ✅ 知识图谱 | ✅ archival_memory |
| surface | — | — | ✅ core memory |
| consolidate | — | — | ✅ sleep-time compute |
| recall(asOf) | — | ✅ 双时态查询 | — |
| connect | — | ✅ 关系图谱 | — |
| forget(salience衰减) | ✅ dedup | — | ✅ 自动管理 |

---

## 7. 技术栈

| 组件 | 技术 | 部署 |
|------|------|------|
| 事实层 | JSONL + JSON + SHA256 | per-project `.claude/runs/` |
| 语义层 | engram-sdk (Node.js) + SQLite + sqlite-vec | 全局 `~/.engram/default.db` |
| Embedding | Qwen3-Embedding-4B (2560 dims) | Ollama 本地 `localhost:11434` |
| LLM consolidation | Gemini 2.5 Flash | API（保留 Gemini key） |
| 审计 hooks | Bash shell scripts | `~/.claude/audit-harness/hooks/` |
| Skills | Markdown（Claude Code/Cursor skill 格式） | `~/.claude/skills/audit-*/` |
| MCP 接口 | engram MCP server (stdio) | 与 IDE 同进程 |

---

## 8. 文档体系

| 级别 | 文件 | 内容 |
|------|------|------|
| **L1** | `docs/L1_memory_architecture.md`（本文） | 双层记忆蓝图、铁律、全景架构 |
| **L2** | `docs/L2_engram_memory_integration.md` | engram 集成详细设计——写入管道、读取管道、隔离、consolidation、测试、配置 |
| **L2** | `docs/L2_audit_enforcement_design.md` | 审计执行保障模块设计——三层防线、Record 体系、context 恢复、日报 |
| **L3** | 各文件头注释 | 文件级：用途、输入、输出、关联文件 |
| **README** | `README.md` | 项目概览、快速开始、架构图 |

---

## 9. 版本历程

| 版本 | 日期 | 里程碑 |
|------|------|--------|
| v1.0–v3.1 | 2026-03 | 三层防线 + hooks + AuditContext 基础类 |
| v3.2 | 2026-03-23 | Skills 审查修复 + 首份日报 |
| v3.4 | 2026-05-25 | 数据一致性修复（lib/hooks schema 统一） |
| **v4.0** | **2026-06-09** | **engram 长期记忆集成——双层架构、本地 embedding、跨项目记忆** |
| v4.1 | 2026-06-10 | 每日审计闭环自动化（launchd 日报 + 晨间修正 + consolidation）+ install.sh engram 集成 |

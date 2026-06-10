# L2 | Engram 长期记忆集成设计

> **日期**：2026-06-09
> **级别**：L2（模块设计）
> **版本**：v4.0.0
> **状态**：P0–P4 已完成，P5 持续
> **上游文档**：`docs/L1_memory_architecture.md`（双层记忆架构蓝图）
> **关联**：`docs/L2_audit_enforcement_design.md` §11.3（变更日志）

---

## 1. 模块定位

### 1.1 解决什么问题

audit-harness 的 `runs/` 提供了完整的审计追踪（WORM 事实层），但有三个结构性短板：

| 短板 | 表现 | 后果 |
|------|------|------|
| **无语义检索** | 只能 grep / 按 session 目录遍历 | "上次 LoRA 训练 nan loss 怎么修的"→ 找不到 |
| **无跨项目记忆** | `runs/` 是 per-project | A 项目的经验，B 项目里 `find_runs_dir()` 找不到 |
| **无自动巩固** | 靠 Agent 手工读文件恢复 context | 没人主动回顾 → 重犯已修正的错误 |

Engram 补齐这三个缺口——提供语义检索（embedding + 向量搜索）、跨项目全局记忆（单一 vault）、自动巩固（consolidation 提炼 semantic 知识）。

### 1.2 不做什么

- **不替代 runs/**：engram 有损（会遗忘、被 consolidate 改写），不可作审计证据
- **不做实时记录**：行级数据 Record / CompactRecord 永不进 engram
- **不引入新 hook**：所有 engram 调用仅在已有的 Skill 边界上挂载（/audit-start, /audit-end, /audit-recover）

### 1.3 设计约束

| 约束 | 来源 | 含义 |
|------|------|------|
| runs/ 是 source of truth | L2 审计设计 §1 | engram 是派生索引，不是平行数据源 |
| 单向 ETL | "数据结构第一"哲学 | runs/ → engram，不回流 |
| engram 故障不阻断 | "记录比完美更重要" | 所有 engram 调用 try/catch |
| 记忆后端可替换 | 开源/可迁移要求 | Skills 通过 MCP 工具名调用，不嵌入内部逻辑 |

---

## 2. 架构设计

### 2.1 双层记忆架构

```
┌─────────────────────────────────────────────────────────┐
│                    AI Agent                              │
│                                                         │
│  ┌─────────────────────┐   ┌─────────────────────────┐  │
│  │  /audit-start       │   │  /audit-end             │  │
│  │  双源恢复           │   │  归档 + 单向写入         │  │
│  └──────┬──────────────┘   └──────────┬──────────────┘  │
│         │ 读                          │ 写               │
│         ▼                             ▼                  │
│  ┌──────────────┐            ┌──────────────────┐       │
│  │ engram vault │ ◄──────── │ runs/{session}/   │       │
│  │ (语义层)     │  单向 ETL  │ (事实层, WORM)    │       │
│  │              │            │                  │       │
│  │ - 语义检索   │            │ - audit_trail    │       │
│  │ - 跨项目     │            │ - manifest       │       │
│  │ - 巩固/遗忘  │            │ - checksums      │       │
│  │ - 主动推送   │            │ - index.json     │       │
│  └──────────────┘            └──────────────────┘       │
└─────────────────────────────────────────────────────────┘
```

### 2.2 数据流

```
操作时（每轮）:
  Agent 执行 Write/Edit/Bash
    → PostToolUse hook → audit_buffer.jsonl
    → Stop hook → 归档到 runs/{session}/audit_trail.jsonl
    → 无 engram 交互

结束时（/audit-end）:
  1. 归档 runs/（不变）
  2. 审计完整性检查（不变）
  3. 生成 session_summary.md（不变）
  4. [新增] 单向写入 engram:
     a. 会话摘要 → episodic (salience=0.5)
     b. user_correction → semantic (salience=0.9)
     c. 关键结论 → semantic (salience=0.6)
     d. 变更记录 → episodic (salience=0.6)
     e. 因果链 → engram_connect

启动时（/audit-start）:
  1. [新增] engram_briefing → 全局上下文
  2. [新增] engram_alerts → 待处理告警
  3. [新增] engram_recall(correction) → 用户修正
  4. runs/index.json → 本项目事实（不变）
  5. 合并输出恢复摘要

恢复时（/audit-recover）:
  1. [新增] engram_recall(correction) → 最高优先级
  2. [新增] engram_surface → 相关经验推送
  3. runs/audit_trail.jsonl → 事实校准（不变）
```

### 2.3 不进入 engram 的内容

| 内容 | 理由 |
|------|------|
| 数据 Record（行级处理记录） | WORM 层，粒度太细，会压垮 vault |
| CompactRecord（压缩正确样本） | 同上 |
| 工具操作原始日志（tool_input detail） | 太细，无跨会话复用价值 |
| 文件哈希、checksums | 审计证据，不是记忆 |
| consolidation 自身日志 | engram 自动存的 "Consolidation completed..." 是噪音 |

---

## 3. 跨项目隔离设计

### 3.1 问题

engram 是单一全局 vault（`~/.engram/default.db`），而用户跨 7+ 个项目工作。需要在不加硬隔离的前提下，保证：
- 日常召回不被其他项目内容污染
- bug fix / 研究场景能跨项目搜索经验
- 用户偏好、红线等通用知识全局共享

### 3.2 topic 前缀约定

不在 engram schema 上加新字段（不改 engram 源码），用 **topic 命名约定**做软隔离：

| topic | 含义 | 示例 |
|-------|------|------|
| `project:{name}` | 项目专属记忆 | `project:data_distill`, `project:yolo` |
| `cross-project` | 全局共享知识 | 用户偏好、修正、红线、通用经验 |
| `correction` | 用户修正 | 必须带 `cross-project` |
| `session-summary` | 会话摘要 | 配合 `project:{name}` |
| `conclusion` | 跨会话可复用结论 | 配合 `project:{name}` 或 `cross-project` |
| `change` | 系统变更记录 | 配合 `project:{name}` |
| `audit-trail` | 审计数据灌入 | 配合 `project:{name}` |

### 3.3 过滤行为

engram `recall` 的 topics 参数是**软过滤**（排名提升），不是硬墙：

| 场景 | 调用方式 | 效果 |
|------|---------|------|
| 日常工作 | `recall(topics=["project:X"])` | 本项目结果排前，跨项目按语义衰减 |
| Bug fix | `recall(topics=[])` | 全局搜，按语义相关性排序 |
| 只看修正 | `recall(topics=["correction"])` | 所有项目的用户修正 |

**实测验证**：搜 `"LoRA training nan loss fix"` 能从 data_distill 项目精准召回 `--mask-prompt + 右截断 = nan loss` 经验。

### 3.4 entities 的角色

entities 标记**人和技术概念**（`Ricky Tong`, `DeepSeek-V3`, `LoRA`），不参与项目隔离。entity 类型已规范化：

| type | 示例 |
|------|------|
| person | Ricky Tong, Jerry Zhu, Zizek |
| project | data_distill |
| tool | Engram, Claude Code, conda |
| model | DeepSeek-V3, Qwen2.5-7B-Instruct-4bit, LoRA, mlx-lm, MLX |
| language | Python, Java, Go |

---

## 4. 写入管道设计（/audit-end §7）

### 4.1 触发点

在 `/audit-end` 的步骤 1–6（runs/ 归档、完整性检查、session_summary 生成）全部完成后，作为**最后一步**执行。

### 4.2 项目名推断

从 CWD 或 `.claude/` 所在目录取最后一级目录名：
- `/codes.nosync/data_distill/.claude/runs/` → `project:data_distill`
- `/codes.nosync/yolo/.claude/runs/` → `project:yolo`

### 4.3 写入过滤器

| 来源 | engram type | salience | topics | 写入条件 |
|------|------------|----------|--------|---------|
| 会话摘要 | episodic | 0.5 | `project:{name}`, `session-summary` | 每次 /audit-end 必写 |
| user_correction | semantic | **0.9** | `cross-project`, `correction` | 有用户纠正时写 |
| 关键结论 | semantic | 0.6 | `project:{name}`, `conclusion` | 有跨会话复用价值时写 |
| 变更记录 | episodic | 0.6 | `project:{name}`, `change` | 涉及 prompt/规则/模型变更时写 |
| 偏好/红线 | procedural | 0.8 | `cross-project` | 用户表达偏好时写 |

### 4.4 user_correction 产生机制

**旧方案**（已废弃）：指望 Agent 在每轮回复的 [AUDIT] 块中手写 `action_type: "user_correction"`。从未产出过一条记录。

**新方案**：`/audit-end` 时统一提取。Agent 回顾本次会话的 audit_trail，识别：
- 用户说了"不对"/"你错了"/"不是这样"/"别再…"
- 用户明确否定后 Agent 改变了方案
- 用户给出了"不要做 X"类指令

每条修正**同时写入两处**：
1. `runs/{session}/audit_trail.jsonl`（WORM 证据）
2. `engram_remember(type=semantic, salience=0.9, topics=["cross-project","correction"])`

### 4.5 因果链

使用 `engram_connect` 建立记忆间关系：

| 关系类型 | 场景 | 示例 |
|---------|------|------|
| `causes` | A 导致了 B | "brand prefix 问题 → prompt v27 修改" |
| `supersedes` | B 取代了 A | "新结论取代了旧结论" |
| `derived_from` | B 从 A 推导 | "修复方案从错误分析得出" |

只在有明确因果关系时建立，不强行关联。

### 4.6 容错

```
try:
    engram_remember(...)
except:
    print("[⚠️ engram 写入失败: ...]")
    # 不阻断，不重试，不回滚 runs/
```

---

## 5. 读取管道设计

### 5.1 /audit-start 双源恢复

#### 5.1a engram 侧（先执行，提供全局视角）

```
engram_briefing(context=任务描述)     → 全局上下文、最近变化、知识图谱
engram_alerts(staleDays=3, limit=5)   → 待处理告警、矛盾
engram_recall(topics=["correction"])  → 用户修正（跨项目）
```

#### 5.1b 按任务类型路由

| 任务类型 | 关键词 | engram 策略 |
|---------|--------|-----------|
| Bug fix / 修复 | "修复"/"bug"/"fix"/"error" | `recall(topics=[], limit=10)` 全局搜经验 |
| 设计 / 规划 | "设计"/"plan"/"方案"/"架构" | `surface()` + `recall(topics=[])` 跨项目 |
| 日常工作 | 其他 | `recall(topics=["project:{name}"], limit=5)` 仅本项目 |

#### 5.1c runs/ 侧（后执行，事实校准）

不变：读 index.json → 最近 sessions → daily report → 未完成会话检查

#### 5.1d 冲突处理

engram 和 runs/ 有矛盾时，**以 runs/ 为准**。engram 有损，可能被 consolidate 改写。

### 5.2 /audit-recover 双源恢复

| Level | 来源 | 内容 |
|-------|------|------|
| 0（最高优先级） | engram `recall(correction)` + runs/ `user_correction` | 合并去重 |
| 1 | runs/ `audit_trail.jsonl` 最后 3 条 | 任务状态 |
| 2 | engram `surface(context=任务)` + engram `recall(conclusion)` | 相关经验 |
| 3（仅 /recover full） | runs/ 完整 trail + engram 全局搜 | 完整上下文 |

---

## 6. Embedding 与基础设施

### 6.1 模型选择

| 属性 | 值 |
|------|-----|
| 模型 | Qwen3-Embedding-4B |
| 参数量 | 4B |
| MTEB 得分 | ~67（开源第 2 梯队） |
| 原生维度 | 2560 |
| MRL 支持 | 32–2560 可调 |
| 运行方式 | Ollama 本地（`http://localhost:11434`） |
| 磁盘占用 | 2.5GB（Q4 量化） |
| 内存占用 | ~3GB（Apple Silicon 统一内存） |
| 中英文支持 | 100+ 语言 |

**为什么选 4B 而非 8B**：
- 8B（4.7GB）在 32GB Mac 上也跑得动，但 4B 性价比更高——MTEB 只差 3 分，推理速度快一倍
- engram 的记忆数量级是百条，不是百万条，embedding 质量差异在小规模下不显著

**为什么不继续用 Gemini API**：
- 网络依赖——需要代理访问 Google API，CLI 模式下连不上（ConnectTimeoutError）
- 延迟——每次 embedding 需要网络往返 vs 本地 <100ms
- 费用——Gemini 免费层有速率限制（20 req/min）
- 离线可用——断网时仍能工作

### 6.2 向量存储

```sql
-- engram 使用 sqlite-vec 扩展（vec0 模块）
CREATE VIRTUAL TABLE vec_memories USING vec0(
  memory_id TEXT PRIMARY KEY,
  embedding float[2560]   -- 从 Gemini 的 3072 迁移到 Qwen3 的 2560
);
```

迁移步骤（v4.0.0 已执行）：
1. 清空旧 Gemini embedding（不同模型的向量空间不兼容）
2. 重建 vec_memories 表（3072 → 2560 维）
3. 用 Qwen3-Embedding-4B 重新生成所有 68 条记忆的 embedding
4. 验证：69/69 成功，0 失败

### 6.3 配置

Cursor 和 Claude Code 使用**同一套配置**，指向同一个 vault：

```json
// ~/.cursor/mcp.json 和 ~/.claude/.mcp.json
{
  "engram": {
    "env": {
      "ENGRAM_OLLAMA_MODEL": "qwen3-embedding:4b",
      "ENGRAM_OLLAMA_DIMS": "2560",
      "GEMINI_API_KEY": "..."
    }
  }
}
```

| 环境变量 | 作用 |
|---------|------|
| `ENGRAM_OLLAMA_MODEL` | 触发 Ollama 模式（优先于 Gemini/OpenAI） |
| `ENGRAM_OLLAMA_DIMS` | 向量维度 |
| `GEMINI_API_KEY` | 保留用于 LLM consolidation（非 embedding） |

### 6.4 共享 Vault

```
~/.engram/default.db (SQLite, ~19MB)
├── memories (89 条)
│   ├── episodic: 57 (含 31 条审计灌入)
│   └── semantic: 32
├── entities: 18
├── edges: 115
└── vec_memories: 90 (Qwen3-Embedding-4B, 2560 dims)
```

Cursor 和 Claude Code 共享同一个 `default.db`——在一个 IDE 中 remember 的内容，另一个 IDE 中 recall 能找到。

---

## 7. Consolidation 设计

### 7.1 机制

engram 的 consolidation 分两条路径：

| 路径 | 条件 | 产出 |
|------|------|------|
| **LLM-powered** | `config.llm` 存在（有 Gemini API key） | 提炼 semantic、发现矛盾、建 connections |
| **Rule-based** | 无 LLM | 只建 edges（temporal_next + associated_with），不产 semantic |

### 7.2 输入过滤

vault.js 第 894 行（原始阈值）：

```javascript
const oneDayAgo = new Date(Date.now() - 24 * 60 * 60 * 1000);
const episodes = this.store.getEpisodicSince(oneDayAgo)
    .filter(m => m.salience >= 0.2);
```

只处理**最近 24 小时**、**salience ≥ 0.2** 的 episodic 记忆。

### 7.3 调用时机

| 旧方案（已废弃） | 新方案 |
|-----------------|--------|
| Stop hook 每次 stop 都跑 `engram consolidate --json` | 从 Stop hook 移除 |
| → 每次空转产生 procedural 噪音（2,326 条） | `/audit-end` 或定时 cron 中执行 |

### 7.4 噪音问题

engram 自动将 consolidation 日志存为 procedural memory（`vault.js` 第 931 行）。这是 engram 的内置行为，无法从外部阻止。

**处理方式**：每次 consolidation 后清理：
```sql
DELETE FROM memories WHERE type='procedural' AND content LIKE 'Consolidation completed%';
```

### 7.5 已知限制

- **需要足够密度的 episode 才能产出 semantic**：当前 57 条 episodic 对 LLM consolidation 而言可能仍不够密集
- **LLM consolidation 依赖 Gemini 网络**：离线时退化为 rule-based（只建 edges）
- **首次有效产出待验证**：需要持续运行 /audit-end 灌入新鲜 episode 后复测

---

## 8. 业界对标

### 8.1 当前 Agent 长期记忆格局（2026）

| 系统 | 核心架构 | LongMemEval | audit-harness 的对标点 |
|------|---------|-------------|---------------------|
| Mem0 | 向量+图+KV，自动抽取 | ~49% | engram 的 remember/recall |
| Zep/Graphiti | 双时态知识图谱 | 63.8–71.2% | engram 的 `recall(asOf=...)` |
| Letta (MemGPT) | OS 式分层内存 + sleep-time compute | — | engram 的 consolidate |
| **audit-harness + engram** | 双层（WORM 事实 + 有损语义） | — | 独特：审计驱动的记忆 |

### 8.2 审计驱动记忆的差异化

业界方案把记忆当"个性化工具"——记住用户偏好、对话历史。audit-harness + engram 的独特之处：

1. **记忆有审计证据支撑**：每条 engram 记忆都能追溯到 runs/ 中的 WORM 原始数据
2. **user_correction 是一等公民**：salience=0.9，恢复时最高优先级——业界方案不区分"纠正"和"偏好"
3. **跨项目经验复用**：topic 软过滤 + 语义检索——不是 per-user-per-session 的扁平记忆
4. **事实层不可变**：runs/ 是 WORM，engram 挂了还有原始数据——业界方案多数是单层（丢了就没了）

### 8.3 上线指标（对标业界共识）

| 指标 | 目标 | 来源 |
|------|------|------|
| recall@5 | ≥ 0.85 | MAGMA / Mem0 论文 |
| precision | ≥ 0.95 | 同上 |
| contradiction | ≤ 0.02 | 同上 |
| staleness | ≥ 0.80 | 同上 |

---

## 9. 测试结果

### 9.1 engram 操作测试（2026-06-09）

| 测试 | 结果 | 详情 |
|------|------|------|
| remember（4 种类型写入） | ✅ | 4/4 成功，project: topic 和 salience 生效 |
| recall（项目过滤） | ✅ | 软过滤正确——匹配 topic 排前，语义相关自然衰减 |
| recall（跨项目 bug fix） | ✅ | 搜 "LoRA nan loss" 从 data_distill 找到 "--mask-prompt" 修复经验 |
| surface（主动推送） | ✅ | 3 条推送，标注了 entity→topic 推理路径 |
| consolidate（rule-based） | ⚠️ | 处理 26 episodes，建 41 connections，但 0 semantic（rule-based 不产 semantic） |
| consolidate（LLM） | ⚠️ | CLI 模式网络超时（Gemini API 需代理），MCP 模式下待复测 |
| briefing | ✅ | "What Changed Recently" 精准列出变化 |
| alerts | ✅ | 无 pending/stale/contradiction（正确） |
| forget | ✅ | hard delete 生效 |
| Ollama embedding | ✅ | 68/68 成功，2560 维，14 秒完成 |

### 9.2 数据迁移

| 指标 | 值 |
|------|-----|
| 审计数据总量 | 1,437 条（7 个项目，11 个 session） |
| 灌入 engram | 31 条（10 session 摘要 + 19 操作块 + 1 audit_pending + 1 buffer） |
| Embedding 迁移 | Gemini 3072 → Qwen3 2560，68/68 成功 |
| vault 噪音清理 | 2,330 procedural + 47 entities + 1,443 edges 删除 |

---

## 10. 配置清单

### 10.1 文件改动

| # | 文件 | 改动类型 | 描述 |
|---|------|---------|------|
| 1 | `~/.claude/settings.json` | hooks | 移除 Stop 中的 `engram consolidate --json` |
| 2 | `~/.engram/default.db` | 数据 | 清理噪音 + embedding 迁移 |
| 3 | `skills/audit-end/SKILL.md` | skill | 新增 §7 engram 写入管道 |
| 4 | `skills/audit-start/SKILL.md` | skill | 改为双源恢复 + 任务类型路由 |
| 5 | `skills/audit-recover/SKILL.md` | skill | 改为双源恢复 |
| 6 | `~/.claude/CLAUDE.md` | 规范 | engram 章节重写 + Context 恢复规则整合 |
| 7 | `~/.cursor/mcp.json` | 配置 | 添加 `ENGRAM_OLLAMA_MODEL` + `ENGRAM_OLLAMA_DIMS` |
| 8 | `~/.claude/.mcp.json` | 配置 | 新建，与 Cursor 配置一致 |
| 9 | `docs/L2_audit_enforcement_design.md` | 文档 | 新增 §11.3 变更日志 |
| 10 | `README.md` | 文档 | 更新架构概览 + 设计哲学 |

### 10.2 未改动

| 文件 | 理由 |
|------|------|
| `lib/audit_context.py` | 核心审计代码零改动——engram 集成纯在 Skill 层 |
| `hooks/*.sh` | 三个 hook 脚本零改动 |
| `install.sh` | 安装脚本零改动（engram 配置不在 install 范围内） |
| `runs/` 下所有数据 | 审计数据零影响 |

---

## 11. 遗留与未来

### 11.1 未完成

| # | 项目 | 状态 | 备注 |
|---|------|------|------|
| 1 | 日报 cron 自动化 | ✅ v4.1.0 | `install.sh --cron`：launchd 08:03 + `bin/audit_daily.sh`（headless claude） |
| 2 | LLM consolidation 首次有效产出 | ⬜ | cron 已每日触发 `consolidate_llm.py`，待 episode 积累后复核产出质量 |
| 3 | consolidation 噪音自动清理 | ⬜ | /audit-end 中加一步 SQL 清理 |
| 4 | install.sh 集成 engram 配置 | ✅ v4.1.0 | `install_engram()`：检测 engram CLI + Ollama 模型，幂等写入 mcp.json |

### 11.2 可迁移性

Skills 通过 MCP 工具名调用 engram（`engram_remember`, `engram_recall` 等），不嵌入 engram 内部逻辑。如果未来换 Mem0/Zep/Letta：

1. 实现一个新的 MCP server，暴露相同的工具名和参数 schema
2. 修改 `mcp.json` 指向新 server
3. Skills 代码**一字不改**

### 11.3 扩展方向

| 方向 | 对标 | 价值 |
|------|------|------|
| 双时态查询 | Zep/Graphiti | `recall(asOf="2026-03-15")` 查"那时候的知识" |
| 遗忘策略 | SCM / Letta | 基于 salience 衰减自动 archive 旧记忆 |
| 多模态记忆 | Cohere Embed v4 | 存图片/截图的 embedding |
| 记忆安全 | MINJA | 防止 prompt injection 污染 vault |

---

## 12. 关联文件

| 文件 | 级别 | 关系 |
|------|------|------|
| `docs/L1_memory_architecture.md` | L1 | 上游：双层记忆蓝图 |
| `docs/L2_audit_enforcement_design.md` §11.3 | L2 | 平行：审计模块变更日志 |
| `skills/audit-end/SKILL.md` §7 | Skill | 下游：engram 写入管道实现 |
| `skills/audit-start/SKILL.md` §2a | Skill | 下游：双源恢复实现 |
| `skills/audit-recover/SKILL.md` | Skill | 下游：双源恢复实现 |
| `~/.claude/CLAUDE.md` | 规范 | 平行：engram 使用规范 |
| `~/.cursor/mcp.json` | 配置 | 下游：Cursor engram MCP 配置 |
| `~/.claude/.mcp.json` | 配置 | 下游：Claude Code engram MCP 配置 |
| `~/.engram/default.db` | 外部 | 运行时：共享 vault |

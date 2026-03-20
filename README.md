# audit-harness

> AI Agent 的审计执行保障框架：三层防线 + Context 恢复 + 审计驱动日报

## 解决什么问题

1. **Agent 不遵守审计规范**：靠 CLAUDE.md 写"请记得写审计" → Agent 会忘。本框架用三层防线（Skill 硬编码 + 格式强制 + 会话包裹）把审计从"建议"变成"格式约束"。
2. **Context 丢失导致重犯错误**：LLM 的 context window 会被压缩/截断。审计记录作为 Agent 的外部"硬盘"，在 context 丢失时恢复工作状态和用户修正历史。
3. **没有人看审计数据**：审计数据只有被消费才有价值。自动生成的日报 + 晨间自我修正闭环，让审计数据持续驱动系统改进。

## 快速开始

### 1. 复制文件到你的项目

```bash
# 复制核心代码
cp audit-harness/lib/audit_context.py your-project/

# 复制项目配置模板
cp audit-harness/templates/audit_config.example.py your-project/audit_config.py

# 复制 Skills
cp -r audit-harness/skills/* your-project/.claude/skills/

# 创建 runs 目录
mkdir -p your-project/runs
```

### 2. 定制项目配置

编辑 `your-project/audit_config.py`：

```python
CORE_SCRIPTS = ["main.py", "pipeline.py"]  # 你的关键脚本
CORE_ASSETS = ["model.pkl"]                 # 你的关键资产
PROMPT_TEMPLATE_GLOB = "prompts/*.txt"      # 你的 prompt 模板

ALERT_RULES = [
    # 根据你的业务定义告警规则
]
```

### 3. 更新 CLAUDE.md

将 `templates/CLAUDE.md.audit-section` 的内容粘贴到你的项目 CLAUDE.md 中。

### 4. 开始使用

```
/start "你的第一个任务"

... 工作（每次涉及数据/代码变更的操作自动附带 [AUDIT] 块）...

/end
```

## 包含内容

### Skills（4 个）

| Skill | 命令 | 作用 |
|-------|------|------|
| audit-start | `/start "任务描述"` | 创建审计会话 + 自动恢复历史 context |
| audit-end | `/end` | 汇总审计 + 完整性检查 + 保存 |
| audit-recover | `/recover` | 从审计记录恢复丢失的 context |
| audit-report-daily | `/report-daily` | 基于审计数据生成工作日报 |

### 核心代码

| 文件 | 作用 |
|------|------|
| `lib/audit_context.py` | AuditContext、RecordEntry、CompactRecord、hashchain、异常检测 |

### 模板

| 文件 | 作用 |
|------|------|
| `templates/audit_config.example.py` | 项目配置模板（CORE_SCRIPTS, ALERT_RULES 等） |
| `templates/CLAUDE.md.audit-section` | CLAUDE.md 审计规范模板 |

## 架构概览

### 三层防线

```
层 1: Skill 硬编码（100% 可靠）
  → /start, /end 内置审计逻辑
  → Skill 间 hashchain 校验

层 2: [AUDIT] 输出格式规范（~90% 可靠）
  → CLAUDE.md 规定回复必须包含 [AUDIT] 块
  → 格式约束 > 行为建议

层 3: /start + /end 会话包裹（兜底检测）
  → /end 检查审计完整性
  → 发现遗漏则告警
```

### Context 恢复

```
新 session 启动 → /start 自动加载历史审计记录
Session 内压缩 → Claude 主动调用 /recover
跨 session 断裂 → 下次 /start 恢复上下文

恢复优先级：
  🔴 用户修正 (user_correction) — 最先恢复，丢了会重犯错误
  🟡 任务状态 — 做到哪了
  🟢 分析结论 — 得出了什么
  ⚪ 环境配置 — 什么版本的规则/模型
```

### 审计驱动日报

```
每日 08:03 → 自动生成日报 (runs/daily/)
每日 08:05 → 自动生成晨间修正报告
        → 回顾异常、用户反馈、指标趋势
        → 推荐今日优先级
```

## Record 类型

审计框架同时追踪三种 Record 类型，它们可以在同一任务中共存：

| 类型 | 含义 | 粒度 | 频率 |
|------|------|------|------|
| 数据 Record | 每条业务数据的处理链 | 行级 | 高（日均 10,000+） |
| 变更 Record | 代码/配置/Prompt 的修改 | 变更级 | 低（日均 0-5） |
| 对话 Record | 人与 Agent 的每轮对话 | 交互级 | 中（日均 10-50） |

## 设计哲学

1. **今天正确不代表明天正确** — 正确样本也保留审计，支持回溯重新评估
2. **每个 pipeline node 都是一个 Record** — hashchain 是 Agent 间信任链的基础
3. **完善、轻量、可迭代、可扩展** — 正确样本压缩存储，审计结构版本化
4. **审计即记忆** — 审计记录是 Agent 的外部持久化存储，context 丢失时的恢复来源

## 许可

MIT

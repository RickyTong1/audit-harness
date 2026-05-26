# audit-harness

> AI Agent 的审计执行保障框架：三层防线 + Context 恢复 + 审计驱动日报 + 自我修正闭环

## 解决什么问题

1. **Agent 不遵守审计规范** — 在 CLAUDE.md 里写"请记得写审计" → Agent 会忘。本框架用三层防线（Skill 硬编码 + 格式强制 + 会话包裹）把审计从"建议"变成"格式约束"。
2. **Context 丢失导致重犯错误** — LLM 的 context window 会被压缩/截断。审计记录作为 Agent 的外部"硬盘"，在 context 丢失时恢复工作状态和用户修正历史。
3. **没有人看审计数据** — 审计数据只有被消费才有价值。自动生成的日报 + 晨间自我修正闭环，让审计数据持续驱动系统改进。

## 快速开始

```bash
# 一条命令安装（零参数，自动判断）
cd /your/project
bash /path/to/audit-harness/install.sh

# 首次运行：自动全局安装 + 当前项目初始化
# 后续新项目：自动仅项目初始化
# 不需要记任何参数
```

安装完成后立即可用：

```
/start "你的任务描述"
... 工作（每次 Write/Edit/Bash 自动被 hooks 记录）...
/end
```

## 安装后的结构

### 全局（`~/.claude/`，所有项目共享）

| 组件 | 路径 | 用途 |
|------|------|------|
| 核心引擎 | `~/.claude/audit-harness/audit_context.py` | AuditContext、RecordEntry、hashchain |
| Hooks ×3 | `~/.claude/audit-harness/hooks/` | 自动捕获工具操作 |
| Skills ×4 | `~/.claude/skills/audit-*` | /start、/end、/recover、/report-daily |
| 审计规范 | `~/.claude/CLAUDE.md` | [AUDIT] 格式 + context 恢复规则 |
| Hook 配置 | `~/.claude/settings.json` | Hook 绑定 |

### 项目级（`$PROJECT/.claude/`，项目专属）

| 组件 | 路径 | 用途 |
|------|------|------|
| 项目配置 | `.claude/audit_config.py` | 告警规则、核心脚本列表 |
| 审计数据 | `.claude/runs/` | Hooks 自动创建，存储所有审计记录 |

## 架构

### 三层防线

```
层 1：Skill 硬编码（结构化任务，100% 可靠）
  → AuditContext 内置 record/finalize/save 流程
  → /start、/end 会话级审计

层 2：[AUDIT] 输出格式规范（非结构化任务，~90% 可靠）
  → CLAUDE.md 规定回复必须包含 [AUDIT] 块
  → 格式约束 > 行为建议

层 3：Hooks 自动兜底（黑盒拦截，~100% 可靠）
  → PostToolUse 自动记录工具调用到 audit_buffer.jsonl
  → Stop 自动归档 buffer + pending 到 session 审计文件
  → UserPromptSubmit 自动注入 session_id
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

### 三个 Hooks

| Hook | 触发时机 | 作用 | 依赖 Claude？ |
|------|---------|------|-------------|
| **PostToolUse** | 每次 Write/Edit/Bash 后 | 自动记录到 audit_buffer | **否**（完全自动） |
| **Stop** | 每轮回复结束后 | 归档 buffer → session 审计文件 + 更新 index.json | **否**（完全自动） |
| **UserPromptSubmit** | 每轮用户输入时 | 注入 session_id 提醒 | 部分（提醒 Claude 写 [AUDIT]） |

### 审计驱动日报

```
每日 08:03 → 自动生成日报 (.claude/runs/daily/)
每日 08:05 → 自动生成晨间修正报告
        → 回顾异常、用户反馈、指标趋势
        → 推荐今日优先级
```

## Record 类型

三种 Record 类型可在同一任务中共存：

| 类型 | 含义 | 粒度 | 频率 |
|------|------|------|------|
| 数据 Record | 每条业务数据的处理链 | 行级 | 高（日均 10,000+） |
| 变更 Record | 代码/配置/Prompt 的修改 | 变更级 | 低（日均 0-5） |
| 对话 Record | 人与 Agent 的每轮对话 | 交互级 | 中（日均 10-50） |

## 项目术语配置

使用 `--init` 安装时，框架自动扫描项目并生成 `audit_config.py`。你可以在其中定义项目专属的术语和告警规则：

```python
# .claude/audit_config.py

CORE_SCRIPTS = ["pipeline.py", "classifier.py"]   # 环境快照追踪的核心脚本
CORE_ASSETS = ["model.pkl"]                        # 环境快照追踪的核心资产
PROMPT_TEMPLATE_GLOB = "prompts/*.txt"             # Prompt 模板 glob 模式

ALERT_RULES = [
    {
        "id": "error_rate",
        "condition": lambda m: m.get("metrics", {}).get("error_rate", 0) > 0.05,
        "level": "WARNING",
        "message": "错误率超过 5%",
    },
]
```

告警规则和核心脚本列表让框架适配你的业务领域，无需修改核心引擎。

> v3.4.0 起，`audit_context.py` 启动时按 `<project>/.claude/audit_config.py` → `<project>/audit_config.py` 顺序自动加载并覆盖默认值。修改 `audit_config.py` 立即生效。

## 设计哲学

1. **今天正确不代表明天正确** — 业务跟随客户变动。正确样本也保留审计，支持回溯性重新评估。
2. **审计即记忆** — 审计记录是 Agent 的外部持久化存储，context 丢失时的唯一可靠恢复来源。
3. **数据结构第一** — `index.json` schema 单一定义（v1.1），lib 与 hooks 共享，杜绝双写不一致。
4. **完善、轻量、可迭代、可扩展** — 正确样本压缩存储；审计结构版本化。

## 安装模式

```bash
bash install.sh                    # 智能模式（自动判断）
bash install.sh --global           # 仅全局安装
bash install.sh --init [path]      # 仅项目初始化
bash install.sh --auto [path]      # 全局 + 项目初始化
bash install.sh --help             # 查看帮助
```

## 文档

| 文档 | 级别 | 内容 |
|------|------|------|
| `docs/L2_audit_enforcement_design.md` | L2（模块设计） | 审计框架完整设计（1500+ 行） |
| `README.md` | 概览 | 英文版本 |
| `README_zh.md` | 概览 | 本文件（中文版） |
| `CHANGELOG.md` | 变更历史 | 版本变更记录 |
| `CONTRIBUTING.md` | 贡献指南 | 开发规范 |

## 许可

MIT

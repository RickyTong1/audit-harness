# audit-harness

> AI Agent 的审计执行保障框架：三层防线 + Context 恢复 + 审计驱动日报

## 解决什么问题

1. **Agent 不遵守审计规范**：靠 CLAUDE.md 写"请记得写审计" → Agent 会忘。本框架用三层防线（Skill 硬编码 + 格式强制 + 会话包裹）把审计从"建议"变成"格式约束"。
2. **Context 丢失导致重犯错误**：LLM 的 context window 会被压缩/截断。审计记录作为 Agent 的外部"硬盘"，在 context 丢失时恢复工作状态和用户修正历史。
3. **没有人看审计数据**：审计数据只有被消费才有价值。自动生成的日报 + 晨间自我修正闭环，让审计数据持续驱动系统改进。

## 快速开始

```bash
# 1. 克隆/下载本仓库
git clone <repo> ~/src/audit-harness

# 2. 在目标项目中执行安装（智能模式）
cd /path/to/your/project
bash ~/src/audit-harness/install.sh
```

`install.sh` 一条命令完成：

- **全局安装**（首次）到 `~/.claude/`：核心代码 + Skills + Hooks + 全局 CLAUDE.md
- **项目初始化**：在当前项目创建 `.claude/audit_config.py`、`.claude/runs/`、注入 `CLAUDE.md` 审计规范

后续在其他项目里直接 `bash ~/src/audit-harness/install.sh` 即可自动识别"全局已装"并仅做项目初始化。

### 进阶用法

```bash
bash install.sh --global              # 仅全局安装
bash install.sh --init [project_dir]  # 仅项目初始化（默认当前目录）
bash install.sh --auto [project_dir]  # 全局 + 项目初始化
```

### 定制项目配置

`install.sh --init` 会在项目下生成 `.claude/audit_config.py`，根据你的项目实际情况修改：

```python
CORE_SCRIPTS = ["main.py", "pipeline.py"]   # 关键脚本（环境快照计算 SHA256）
CORE_ASSETS = ["model.pkl"]                 # 关键资产
PROMPT_TEMPLATE_GLOB = "prompts/*.txt"      # prompt 模板 glob

ALERT_RULES = [
    # 业务相关的告警规则（参考 templates/audit_config.example.py）
]
```

> `audit_context.py` 启动时按 `<project>/.claude/audit_config.py` → `<project>/audit_config.py` 顺序查找并加载，未找到则使用模块默认值（全部为空）。

### 开始使用

```
/start "你的第一个任务"

... 工作（每次涉及数据/代码变更的操作自动附带 [AUDIT] 块）...

/end
```

## 包含内容

### Skills（4 个，全局安装到 `~/.claude/skills/`）

| Skill | 命令 | 作用 |
|-------|------|------|
| audit-start | `/start "任务描述"` | 创建审计会话 + 自动恢复历史 context |
| audit-end | `/end` | 汇总审计 + 完整性检查 + 保存 |
| audit-recover | `/recover` | 从审计记录恢复丢失的 context |
| audit-report-daily | `/report-daily` | 基于审计数据生成工作日报 |

### Hooks（3 个，全局安装到 `~/.claude/audit-harness/hooks/`）

| Hook | 事件 | 作用 |
|------|------|------|
| `post_tool_audit.sh` | PostToolUse | 自动记录 Write/Edit/Bash 操作到 `audit_buffer.jsonl` |
| `stop_flush.sh` | Stop | 每轮回复结束后归档 buffer + pending 到 session 审计文件 |
| `prompt_inject_session.sh` | UserPromptSubmit | 每轮输入时注入当前 session 上下文 |

> 所有 hook 通过共享 helper `_audit_common.sh` 加载 lib，使用 `python3 audit_context.py update-index ...` CLI 写 `index.json`，与 `AuditContext.save()` 共享同一份 schema。

### 核心代码

| 文件 | 作用 |
|------|------|
| `lib/audit_context.py` | AuditContext、RecordEntry、CompactRecord、索引 schema、CLI 入口 |

### 模板

| 文件 | 作用 |
|------|------|
| `templates/audit_config.example.py` | 项目配置模板（CORE_SCRIPTS、ALERT_RULES 等） |
| `templates/CLAUDE.md.audit-section` | CLAUDE.md 审计规范模板 |

## 架构概览

### 数据存储

所有审计数据集中在 **`<project>/.claude/runs/`** 下：

```
.claude/runs/
├── index.json              # 统一索引（schema_version=1.1）
├── audit_buffer.jsonl      # PostToolUse 写入缓冲（每轮被 Stop 清空）
├── audit_pending.jsonl     # Agent 主动写入的 [AUDIT] 块缓冲
├── .current_session        # /start 与 hooks 间的握手协议
├── {session_id}/
│   ├── session.json
│   ├── audit_trail.jsonl   # 归档后的完整审计记录
│   ├── manifest.json       # AuditContext.save() 产出（结构化 batch）
│   ├── anomalies.json
│   └── checksums.json
└── daily/                  # /report-daily 输出
```

### 三层防线

```
层 1: Skill 硬编码（结构化任务，100% 可靠）
  → AuditContext 内置 record/finalize/save 流程
  → /start /end 会话级审计

层 2: [AUDIT] 输出格式规范（非结构化任务，~90% 可靠）
  → CLAUDE.md 规定回复必须包含 [AUDIT] 块
  → 格式约束 > 行为建议

层 3: Hooks 自动兜底（黑盒拦截，~100% 可靠）
  → PostToolUse 自动记录工具调用
  → Stop 自动归档 buffer + pending
  → UserPromptSubmit 自动注入 session_id
```

### Context 恢复

```
新 session 启动 → /start 自动加载 index.json + 最近 daily report
Session 内压缩 → Agent 主动调用 /recover

恢复优先级：
  🔴 用户修正 (user_correction) — 最先恢复，丢了会重犯错误
  🟡 任务状态 — 做到哪了
  🟢 分析结论 — 得出了什么
  ⚪ 环境配置 — 什么版本的规则/模型
```

### Record 类型

审计框架同时追踪三种 Record，可在同一任务中共存：

| 类型 | 含义 | 粒度 | 频率 |
|------|------|------|------|
| 数据 Record | 每条业务数据的处理链 | 行级 | 高（日均 10,000+） |
| 变更 Record | 代码/配置/Prompt 的修改 | 变更级 | 低（日均 0-5） |
| 对话 Record | 人与 Agent 的每轮对话 | 交互级 | 中（日均 10-50） |

## 设计哲学

1. **今天正确不代表明天正确** — 正确样本也保留审计，支持回溯重新评估
2. **审计即记忆** — 审计记录是 Agent 的外部持久化存储，context 丢失时的恢复来源
3. **数据结构第一** — index.json schema 单一定义，lib 与 hooks 共享，杜绝双写不一致
4. **完善、轻量、可迭代、可扩展** — 正确样本压缩存储，审计结构版本化

## 许可

MIT

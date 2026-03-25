---
name: audit-init
description: 审计框架安装向导。在新项目中首次使用 audit-harness 时调用。自动完成文件复制、配置生成、CLAUDE.md 注入、目录创建，开箱即用。
user-invocable: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
  - Edit
  - AskUserQuestion
---

# /audit-init — 审计框架安装向导

## 触发方式

```
/audit-init
```

## 概述

本 Skill 是一个交互式安装向导（wizard），引导用户在当前项目中完成 audit-harness 的全部配置。安装完成后，`/start`、`/end`、`/recover`、`/report-daily` 四个 Skill 立即可用。

## 执行步骤

### Step 1：环境检测

检查当前项目状态，判断是全新安装还是升级：

```python
checks = {
    "audit_context_exists": 项目根目录是否已有 audit_context.py,
    "audit_config_exists": 项目根目录是否已有 audit_config.py,
    "runs_dir_exists": runs/ 目录是否存在,
    "claude_md_exists": CLAUDE.md 是否存在,
    "claude_md_has_audit": CLAUDE.md 中是否已有 [AUDIT] 格式规范,
    "skills_dir_exists": .claude/skills/ 是否存在,
    "is_git_repo": 是否在 git 仓库中,
}
```

根据检测结果输出状态：

```
=== audit-harness 安装向导 ===

环境检测：
  [✅] Git 仓库: 是
  [❌] audit_context.py: 不存在 → 需要安装
  [❌] audit_config.py: 不存在 → 需要创建
  [❌] runs/ 目录: 不存在 → 需要创建
  [✅] CLAUDE.md: 存在
  [❌] CLAUDE.md 审计规范: 未配置 → 需要注入
  [❌] .claude/skills/: 不存在 → 需要创建
```

如果检测到已有组件（升级场景），提示用户是否覆盖。

### Step 2：收集项目信息

通过 AskUserQuestion 向用户收集项目专属配置。每个问题都附带说明和默认值。

**问题 1：关键脚本**

```
你的项目中哪些 Python 脚本是核心脚本？
（这些脚本的哈希会被记录在环境快照中，用于追踪配置变化）

请列出文件名，用逗号分隔，或输入 "scan" 让我自动扫描。
```

如果用户选择 "scan"：
- 扫描项目根目录下所有 .py 文件
- 按修改时间排序，展示前 20 个
- 让用户选择哪些是核心脚本

**问题 2：关键资产文件**

```
你的项目中有哪些关键模型/配置文件？
（如 .pkl、.yaml、.json 等，变更需要被追踪的）

请列出文件名，用逗号分隔，或输入 "none"。
```

**问题 3：Prompt 模板**

```
你的项目是否使用 AI Prompt 模板？
如果是，请提供 glob 模式（如 "prompts/*.txt" 或 "docs/prompt_*.md"）。
如果否，输入 "none"。
```

**问题 4：告警规则**

```
你想设置哪些告警规则？

选项：
1. 使用默认规则（仅数据完整性校验）
2. 稍后手动编辑 audit_config.py
3. 帮我根据项目内容自动生成建议规则
```

如果用户选择 3：
- 扫描项目中的数据处理脚本
- 分析可能的告警点（错误率、空值率、处理量异常等）
- 生成建议规则，让用户确认

### Step 3：安装核心文件

```python
# 3.1 复制 audit_context.py
source = "{audit-harness}/lib/audit_context.py"
target = "{project_root}/audit_context.py"
# 复制文件

# 3.2 生成 audit_config.py（基于 Step 2 收集的信息）
# 写入用户提供的 CORE_SCRIPTS、CORE_ASSETS、PROMPT_TEMPLATE_GLOB、ALERT_RULES

# 3.3 创建 runs/ 目录
mkdir -p runs/daily

# 3.4 创建 .gitignore（runs/ 中的大文件不入库，但保留目录结构）
# runs/下的 .jsonl 文件可能很大，建议 gitignore
```

输出：

```
安装核心文件：
  [✅] audit_context.py → {project_root}/audit_context.py
  [✅] audit_config.py → {project_root}/audit_config.py (已填入你的配置)
  [✅] runs/ 目录已创建
  [✅] runs/.gitignore 已创建
```

### Step 4：安装 Skills

```python
# 4.1 创建 .claude/skills/ 目录（如果不存在）
mkdir -p .claude/skills/

# 4.2 复制所有 Skill
# audit-start, audit-end, audit-recover, audit-report-daily
# 从 {audit-harness}/skills/ 复制到 {project_root}/.claude/skills/
```

输出：

```
安装 Skills：
  [✅] /start → .claude/skills/audit-start/SKILL.md
  [✅] /end → .claude/skills/audit-end/SKILL.md
  [✅] /recover → .claude/skills/audit-recover/SKILL.md
  [✅] /report-daily → .claude/skills/audit-report-daily/SKILL.md
```

### Step 5：注入 CLAUDE.md

检查 CLAUDE.md 是否已存在审计规范部分。

**如果 CLAUDE.md 不存在**：
- 创建新的 CLAUDE.md，包含审计规范部分

**如果 CLAUDE.md 存在但没有审计规范**：
- 在 CLAUDE.md 末尾追加审计规范部分
- 追加前展示将要添加的内容，让用户确认

**如果 CLAUDE.md 已有审计规范**：
- 对比版本，提示是否需要更新

审计规范内容来自 `templates/CLAUDE.md.audit-section`。

输出：

```
配置 CLAUDE.md：
  [✅] 审计规范已注入 CLAUDE.md
  [✅] [AUDIT] 格式规范已配置
  [✅] Context 恢复规则已配置
  [✅] 决策红线已配置
```

### Step 6：验证安装

运行快速验证，确保所有组件正常工作：

```python
# 6.1 验证 audit_context.py 可导入
from audit_context import AuditContext, create_batch_context, create_adhoc_context

# 6.2 验证 audit_config.py 可加载
from audit_config import CORE_SCRIPTS, CORE_ASSETS

# 6.3 验证环境快照可执行
ctx = create_adhoc_context("安装验证")
ctx.snapshot_environment()

# 6.4 验证 runs/ 可写入
manifest = ctx.finalize()
ctx.save()

# 6.5 清理验证数据
# 删除验证产生的 runs/{验证session}/
```

输出：

```
验证安装：
  [✅] audit_context.py 导入成功
  [✅] audit_config.py 加载成功 (CORE_SCRIPTS: 7 个, ALERT_RULES: 5 条)
  [✅] 环境快照执行成功 (prompt_template: docs/long_text_*.txt)
  [✅] runs/ 写入成功
  [✅] 验证数据已清理
```

### Step 7：输出安装总结

```
============================================================
  audit-harness 安装完成！
============================================================

已安装组件：
  📦 audit_context.py    — 审计引擎
  ⚙️  audit_config.py     — 项目配置（7 个核心脚本, 5 条告警规则）
  📂 runs/               — 审计数据存储
  📝 CLAUDE.md           — 审计规范（[AUDIT] 格式 + Context 恢复规则）

可用 Skills：
  /start "任务描述"      — 创建审计会话 + 恢复历史上下文
  /end                   — 结束会话 + 审计完整性检查
  /recover               — 恢复丢失的 Context
  /report-daily          — 生成审计驱动的工作日报

推荐设置 cron（每日自动日报 + 晨间修正）：
  cron "3 8 * * *" → /report-daily {yesterday}
  cron "5 8 * * *" → /report-daily review

现在可以开始使用了：
  /start "你的第一个任务"
============================================================
```

## 幂等性

本 Skill 可以重复执行。重复执行时：
- 已存在的文件会提示用户是否覆盖
- 已存在的 CLAUDE.md 审计规范会对比版本
- runs/ 目录中的历史数据不会被删除
- 验证步骤始终执行

## 注意事项

- 安装向导需要知道 audit-harness 包的位置（即本 Skill 所在的目录）
- 如果项目不是 git 仓库，会建议初始化 git（审计记录的版本追踪依赖 git）
- audit_config.py 中的 ALERT_RULES 使用 lambda 表达式，不能序列化为 JSON——这是有意设计，确保规则的灵活性

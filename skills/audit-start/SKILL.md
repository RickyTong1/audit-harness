---
name: audit-start
description: 创建审计会话并自动恢复历史上下文。当用户开始新任务、说"帮我做X"、"分析Y"、"修改Z"、"开始工作"等，或当你检测到当前没有活跃的审计会话时，主动使用此 Skill。即使用户没有显式说 /start，只要涉及数据处理、代码修改、分析决策、文档编写，都应建议或自动启动审计会话。
user-invocable: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
---

<!--
L3 | audit-start Skill
用途：创建审计会话，从 runs/ + engram 双源恢复历史上下文，按任务类型路由记忆源
输入：用户任务描述 → .claude/runs/index.json + engram vault
输出：runs/{session}/session.json + .current_session + 恢复摘要
关联：
  - docs/L2_engram_memory_integration.md §5（读取管道设计）
  - docs/L2_audit_enforcement_design.md §6.1（/start 详细设计）
  - skills/audit-end/SKILL.md（结束侧）
  - hooks/prompt_inject_session.sh（session_id 注入）
版本：v4.0.0 — §2 改为双源恢复 + 任务类型路由
-->

# /start — 审计会话启动 + Context 恢复

## 触发方式

```
/start "任务描述"
```

## 为什么需要 /start

每次工作都应该在审计会话中进行。没有会话意味着：
- hooks 产出的审计数据归入自动创建的 `auto_` session，缺少任务描述
- /end 无法做完整性检查
- 日报中的任务总览缺少描述

/start 的成本极低（创建一个目录 + 一个 JSON 文件），收益是让所有后续操作都有上下文。

## 执行步骤

### 1. 创建审计会话

```bash
# 1. 生成 session_id
SESSION_ID="adhoc_$(date +%Y%m%d_%H%M)"

# 2. 创建目录
mkdir -p .claude/runs/${SESSION_ID}

# 3. 写入 session.json
cat > .claude/runs/${SESSION_ID}/session.json << EOF
{
    "session_id": "${SESSION_ID}",
    "task": "用户提供的任务描述",
    "start_time": "ISO 8601",
    "status": "in_progress",
    "expected_record_types": []
}
EOF

# 4. 写入 .current_session（Stop hook 依赖此文件确定归档目标）
echo "${SESSION_ID}" > .claude/runs/.current_session
```

> ⚠️ 第 4 步是关键：`.current_session` 文件是 /start 和 Stop hook 之间的握手协议。
> Stop hook 读取此文件来确定 audit_buffer 归档到哪个 session 目录。
> 如果不写这个文件，Stop hook 会创建一个 `auto_` session，与 /start 的 session 脱节。

### 2. Context 恢复（双源：runs/ + engram）

从两个数据源恢复上下文，**冲突时以 runs/ 为准**（engram 有损）。engram 调用失败时静默跳过，不影响启动流程。

#### 2a. engram 全局记忆（先于 runs/，提供跨项目视角）

```
# 1. 全局 briefing —— 待办、修正、告警
engram_briefing(context = "即将开始: {任务描述}")

# 2. 检查待处理告警
engram_alerts(staleDays = 3, limit = 5)

# 3. 按任务类型路由：
#    - 如果任务含"修复"/"bug"/"fix" → 跨项目召回相关经验
#      engram_recall(context = "{任务描述}", topics = [], limit = 10)
#    - 如果任务含"设计"/"plan"/"方案"/"架构" → 主动推送
#      engram_surface(context = "{任务描述}", activeTopics = ["project:{项目名}"])
#    - 其他日常任务 → 只拉本项目
#      engram_recall(context = "{任务描述}", topics = ["project:{项目名}"], limit = 5)

# 4. 最高优先级：用户修正记忆
engram_recall(context = "user corrections", topics = ["correction"], limit = 10)
```

#### 2b. runs/ 本项目记录（事实层，最终权威）

**Level 0 — 索引摘要**:
- 读取 `.claude/runs/index.json`，获取最近 5 条 entry 的 id + task + status

**Level 1 — 任务状态**:
- 读取最新的 `.claude/runs/daily/*_daily.md`（如果存在）
  - §四 异常告警：有没有未解决的问题？
  - §六 昨日待办：有没有未完成的任务？
  - §七 明日待办：今天该优先做什么？
- 读取最新的 `.claude/runs/daily/*_morning_review.md`（如果存在）

**Level 2 — 用户修正（runs/ 侧补充）**:
- 在最近的 `audit_trail.jsonl` 中搜索 `user_correction`
- 与 engram 召回的修正记录合并去重

**检查未完成会话**:
- 扫描 `.claude/runs/adhoc_*/session.json`，找 `status: "in_progress"` 的会话
- 如果有，提示用户是否继续上次未完成的任务（如果继续，复用旧 session_id 而非创建新的）

### 3. 输出上下文恢复摘要

```
审计会话已创建: adhoc_20260320_1400
任务: {用户的任务描述}
项目: {项目名}

上下文恢复（runs/ + engram）：

最近活动（runs/）：
  - {最近 3 条完成的任务}

⚠️ 用户修正记录（必须遵守，来源标注 runs/engram）：
  - {合并去重后的所有 correction 记录}

engram 洞察：
  - {briefing/surface/recall 返回的相关经验，标注来源项目}

待解决问题（runs/ + engram_alerts）：
  - {合并后的未关闭异常/待办}

预期 Record 类型：
  [数据] / [变更] / [对话] — 根据任务描述预判

所有后续 [AUDIT] 块请使用 batch_id = {session_id}
```

### 4. 注意事项

- 如果 `.claude/runs/` 目录不存在，自动创建，跳过 context 恢复
- 如果没有历史审计数据，正常启动，不报错
- session_id 在整个会话期间保持不变，所有 [AUDIT] 块共享此 id
- 如果已有活跃 session（`.current_session` 文件存在且对应 session 状态为 in_progress），提示用户是否要结束旧 session 再创建新的

---
name: audit-start
description: 创建审计会话并自动恢复历史上下文。在开始任何涉及数据处理、代码修改、分析决策的任务时使用。
user-invocable: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
---

# /start — 审计会话启动 + Context 恢复

## 触发方式

```
/start "任务描述"
```

## 执行步骤

### 1. 创建审计会话

- 生成 session_id: `adhoc_{YYYYMMDD}_{HHMM}`
- 创建目录: `runs/{session_id}/`
- 写入 `runs/{session_id}/session.json`:

```json
{
    "session_id": "adhoc_YYYYMMDD_HHMM",
    "task": "用户提供的任务描述",
    "start_time": "ISO 8601",
    "status": "in_progress",
    "expected_record_types": [],
    "operations": []
}
```

### 2. Context 恢复（如果 runs/ 目录存在历史数据）

按以下优先级加载：

**Level 0 — 索引摘要**:
- 读取 `runs/index.json`，获取最近 5 条 entry 的 id + task + status

**Level 2 — 用户修正（最重要）**:
- 在最近 3 天的 `audit_blocks.jsonl` 中搜索 `action_type: "user_correction"`
- 这些记录必须最先恢复——丢了会重犯错误

**Level 1 — 任务状态**:
- 读取最新的 `runs/daily/*_daily.md`（如果存在）
  - §四 异常告警：有没有未解决的问题？
  - §六 昨日待办：有没有未完成的任务？
  - §七 明日待办：今天该优先做什么？
- 读取最新的 `runs/daily/*_morning_review.md`（如果存在）

**检查未完成会话**:
- 扫描 `runs/adhoc_*/session.json`，找 `status: "in_progress"` 的会话
- 如果有，提示用户是否继续上次未完成的任务

### 3. 输出上下文恢复摘要

```
审计会话已创建: adhoc_20260320_1400
任务: {用户的任务描述}

上下文恢复摘要（基于 runs/ 审计记录）：

最近活动：
  - {最近 3 条完成的任务}

⚠️ 用户修正记录（必须遵守）：
  - {所有 user_correction 记录}

待解决问题：
  - {未关闭的异常/告警}

今日推荐优先级：
  - {morning_review 中的推荐}

预期 Record 类型：
  [数据] / [变更] / [对话] — 根据任务描述预判

所有后续 [AUDIT] 块请使用 batch_id = {session_id}
```

### 4. 注意事项

- 如果 `runs/` 目录不存在，创建它，跳过 context 恢复
- 如果没有历史审计数据，正常启动，不报错
- session_id 在整个会话期间保持不变，所有 [AUDIT] 块共享此 id

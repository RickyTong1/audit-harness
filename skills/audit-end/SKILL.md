---
name: audit-end
description: 结束审计会话，汇总审计数据，执行完整性检查，保存到 .claude/runs/。当用户说"完成了"、"结束"、"暂停"、"今天到这"，或当前任务已完成需要保存审计记录时使用。
user-invocable: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
---

<!--
L3 | audit-end Skill
用途：结束审计会话，归档 runs/，执行完整性检查，单向写入 engram 长期记忆
输入：.claude/runs/.current_session → session_id → audit_buffer/pending/trail
输出：runs/{session}/ 下的完整审计文件 + engram vault 中的 episodic/semantic 记忆
关联：
  - docs/L2_engram_memory_integration.md §4（写入管道设计）
  - docs/L2_audit_enforcement_design.md §6（/end 详细设计）
  - skills/audit-start/SKILL.md（启动侧）
  - hooks/stop_flush.sh（归档依赖）
版本：v4.0.0 — 新增 §7 engram 写入管道
-->

# /end — 审计会话结束 + 完整性检查

## 触发方式

```
/end
```

## 执行步骤

### 1. 确定当前 session

读取 `.claude/runs/.current_session` 获取 session_id。

如果文件不存在：
- 检查是否有 `auto_` session（Stop hook 自动创建的）
- 如果有，使用最近的 auto session
- 如果没有，提示用户"当前没有活跃的审计会话"

### 2. 收集审计数据

**不是"扫描对话历史"**——Skill 无法访问对话历史。
实际数据来源是 hooks 已经收集好的文件：

```
来源 1: .claude/runs/audit_buffer.jsonl
  → PostToolUse hook 自动记录的 Write/Edit/Bash 操作
  → 每条包含 timestamp, tool, files, detail

来源 2: .claude/runs/audit_pending.jsonl
  → Claude 主动写入的 [AUDIT] 块（JSON 格式）
  → 每条包含 batch, action, input, output

来源 3: .claude/runs/{session_id}/audit_trail.jsonl
  → Stop hook 已归档的历史记录（之前轮次的 buffer + pending）
```

汇总步骤：
1. 读取 `audit_buffer.jsonl` 和 `audit_pending.jsonl` 中的剩余数据（Stop hook 可能还没来得及归档最后一轮）
2. 追加到 `.claude/runs/{session_id}/audit_trail.jsonl`
3. 清空 buffer 和 pending

### 3. 提取用户修正

在 `audit_trail.jsonl` 和 `audit_pending.jsonl` 中搜索 `user_correction` 类型的记录。如果本次会话中有用户纠正 Claude 的判断，标记为高优先级恢复项并写入 audit_trail：

```json
{
    "record_type": "conversation",
    "action_type": "user_correction",
    "priority": "critical_for_recovery",
    "original_claim": "Claude 的原始判断",
    "correction": "用户的修正",
    "principle_extracted": "提取的通用原则",
    "persisted_to": ["写入了哪些文件"]
}
```

### 4. 审计完整性检查

从 `audit_trail.jsonl` 和 `audit_buffer.jsonl` 中提取信息执行检查：

| 检查项 | 数据源 | 通过条件 | 失败处理 |
|--------|--------|---------|---------|
| 有审计记录 | audit_trail.jsonl 行数 | > 0 | ⚠️ "审计性为 0" |
| 文件修改有记录 | audit_trail 中 tool=Write/Edit 的条目 | 每个修改过的文件都有记录 | ⚠️ 列出未审计的文件 |
| Prompt 修改有验证 | audit_trail 中含 "prompt" 的条目 | 必须有包含 "回归测试" 或 "10000" 的条目 | ❌ "Prompt 修改未验证" |
| Prompt 修改有 Harness 日志 | L1 附录 D | 已更新 | ⚠️ 提醒补充 |
| 用户修正已持久化 | user_correction 条目 | 已写入 CLAUDE.md 或文档 | ⚠️ 提醒持久化 |

输出格式：

```
=== 会话审计检查 ===
会话: {session_id}
任务: {session.json 中的 task}
时长: {start → end}

[✅] 审计记录: {N} 条
[✅] 文件修改已记录 ({M} 个文件)
[⚠️] L1 附录 D 需要更新
[✅] 用户修正已持久化 (2 条)

Record 统计:
  工具操作:    {tool_use 记录数} 条
  [AUDIT] 块:  {pending 记录数} 条
  user_correction: {修正记录数} 条
```

### 5. 生成会话总结

写入 `.claude/runs/{session_id}/session_summary.md`：

```markdown
# 会话总结 | {session_id}

## 任务: {描述}
## 时间: {start} → {end}
## 状态: completed

## 完成的工作
- {audit_trail 中的 action 列表}

## 关键结论
- {audit_pending 中的 output 字段}

## 用户修正
- {user_correction 记录}

## 遗留问题
- {检查中发现的问题}
```

### 6. 更新状态文件

```bash
# 更新 session.json
# status = "completed", end_time = now()

# 更新 .claude/runs/index.json（如果 Stop hook 已创建）

# 清除 .current_session（会话已结束）
rm -f .claude/runs/.current_session
```

### 7. 写入 engram 长期记忆（runs/ 归档完成后执行）

> **铁律**：本步骤在所有 runs/ 写入完成后最后执行。engram 写入失败**不得阻断**前面的审计保存——记录比记忆更重要。所有 engram 调用都应 try/catch，失败只输出 `[⚠️ engram 写入失败: ...]`。

#### 7.1 确定当前项目名

从 CWD 或 `.claude/` 所在目录推断项目名（最后一级目录名），用作 `project:` topic 前缀。例如 `/codes.nosync/data_distill` → `project:data_distill`。

#### 7.2 写入会话摘要（episodic）

基于 session_summary.md 的内容，调用 `engram_remember`：

```
engram_remember(
  content = "会话 {session_id}: {task}。完成了：{1-2句话摘要}。{如有遗留问题则写明}",
  type = "episodic",
  entities = [涉及的项目/人/工具],
  topics = ["project:{项目名}", "session-summary"],
  salience = 0.5
)
```

#### 7.3 提取并写入用户修正（semantic，最高优先级）

回顾本次会话的审计记录和对话，**主动识别**以下情形：
- 用户否定了 Agent 的判断
- 用户纠正了 Agent 的结论
- 用户指出了 Agent 的错误假设
- 用户给出了"不要做 X"类指令

对每条修正，同时写入 runs/ 和 engram：

```
# 1. 写入 runs/（WORM 证据）
追加到 audit_trail.jsonl:
{
    "record_type": "conversation",
    "action_type": "user_correction",
    "priority": "critical_for_recovery",
    "original_claim": "Agent 的原始判断",
    "correction": "用户的修正",
    "principle_extracted": "提取的通用原则",
    "timestamp": "ISO 8601"
}

# 2. 写入 engram（可检索记忆）
engram_remember(
  content = "用户修正: {原始判断} → {修正内容}。原则: {提取的通用原则}",
  type = "semantic",
  entities = [涉及的项目/人/概念],
  topics = ["cross-project", "correction"],
  salience = 0.9,
  status = "active"
)
```

> 判断标准：如果用户说了"不对"、"你错了"、"不是这样"、"我告诉过你"、"别再…"等表达，或者用户明确否定后 Agent 改变了方案——都算 correction。

#### 7.4 写入关键结论（semantic）

从 session_summary 的"关键结论"中提取跨会话有复用价值的知识：

```
engram_remember(
  content = "{自包含的结论描述}",
  type = "semantic",
  entities = [...],
  topics = ["project:{项目名}", "conclusion"],
  salience = 0.6
)
```

> 只写**自包含**的结论（仅凭该条记忆本身就能理解含义）。不写"同上"、"如前所述"这类依赖上下文的内容。

#### 7.5 写入变更记录（episodic，仅 prompt/规则/模型变更）

如果本次会话涉及 prompt 模板、清洗规则、模型参数等**影响后续处理结果**的变更：

```
engram_remember(
  content = "变更 {文件路径}: {变更内容摘要}。影响范围: {哪些下游会受影响}",
  type = "episodic",
  entities = [...],
  topics = ["project:{项目名}", "change"],
  salience = 0.6
)
```

#### 7.6 建立因果链（connect）

如果本次会话的修正或结论与之前的 engram 记忆有因果关系（例如"之前的 bug 导致了这次的修复"），用 `engram_connect` 建立关系：

```
engram_connect(
  sourceId = "{新记忆 ID}",
  targetId = "{旧记忆 ID}",
  type = "causes" | "supersedes" | "derived_from",
  strength = 0.7
)
```

> 只在有明确因果关系时才建立 connect，不要为了"看起来完整"而强行关联。

#### 7.7 不写入 engram 的内容

以下内容**绝不进 engram**：
- 数据 Record（行级处理记录）——属于 WORM 层，用 runs/ 存
- CompactRecord（正确样本压缩行）——同上
- 工具操作的原始日志（tool=Bash/Write/Edit 的 detail）——太细粒度
- 文件哈希、checksums——审计证据，不是记忆

### 8. 注意事项

- 即使检查发现问题，也要完成保存——记录比完美更重要
- ⚠️ 是建议（不阻止保存），❌ 是严重警告（仍然保存，但必须提醒用户）
- /end 之后 Stop hook 仍会触发一次（归档 /end 本身的操作），这是正常的
- engram 写入是"最优努力"——失败不阻断、不重试、不回滚 runs/

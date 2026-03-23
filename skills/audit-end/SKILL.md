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

### 7. 注意事项

- 即使检查发现问题，也要完成保存——记录比完美更重要
- ⚠️ 是建议（不阻止保存），❌ 是严重警告（仍然保存，但必须提醒用户）
- /end 之后 Stop hook 仍会触发一次（归档 /end 本身的操作），这是正常的

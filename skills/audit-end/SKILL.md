---
name: audit-end
description: 结束审计会话，汇总所有 [AUDIT] 块，执行审计完整性检查，保存到 runs/ 目录。在任务完成或需要暂停时使用。
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

### 1. 收集本次会话的所有 [AUDIT] 块

扫描本次会话中 Claude 输出的所有 `[AUDIT]` 块，解析为结构化数据，写入：

```
runs/{session_id}/audit_blocks.jsonl
```

每个 [AUDIT] 块解析为一行 JSON:

```json
{
    "batch": "adhoc_20260320_1400",
    "action": "修改 prompt 模板 v26→v27",
    "input": "docs/long_text_*.txt (v26.0)",
    "output": "docs/long_text_*.txt (v27.0, +243 chars)",
    "hash_in": "N/A",
    "hash_out": "N/A",
    "record_type": "change",
    "timestamp": "2026-03-20T14:30:00Z"
}
```

### 2. 提取并标记用户修正

在会话历史中搜索用户纠正 Claude 判断的对话。标记为高优先级恢复项：

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

### 3. 审计完整性检查

执行以下检查，输出检查报告：

| 检查项 | 通过条件 | 失败处理 |
|--------|---------|---------|
| 审计块数量 > 0 | 至少有一个 [AUDIT] 块 | ⚠️ 警告："本次操作无审计记录，审计性为 0" |
| 文件修改全覆盖 | 会话中每个被 Edit/Write 的文件都有对应 [AUDIT] | ⚠️ 列出未审计的文件 |
| Prompt/规则修改 → 验证 | 如果改了 Prompt/规则，必须有 ≥10,000 条回归测试的 [AUDIT] | ❌ 阻断："审计性为 0，Prompt 修改未验证" |
| Prompt/规则修改 → Harness 日志 | 如果改了 Prompt/规则，L1 附录 D 必须已更新 | ⚠️ 提醒补充 |
| 用户修正已持久化 | 每条 user_correction 都已写入 CLAUDE.md 或 L1/L2 文档 | ⚠️ 提醒持久化 |

输出格式：

```
=== 会话审计检查 ===
会话: adhoc_20260320_1400
任务: {任务描述}
时长: {start → end}

[✅] 审计块数量: 5
[✅] 所有文件修改已审计 (3 个文件)
[✅] Prompt 修改已附带 ≥10,000 条回归测试
[⚠️] L1 附录 D 需要更新
[✅] 用户修正已持久化 (2 条)

Record 统计:
  数据 Record:   10,003 条
  变更 Record:   4 条
  对话 Record:   7 条 (含 2 条 user_correction)
```

### 4. 生成会话总结

写入 `runs/{session_id}/session_summary.md`：

```markdown
# 会话总结 | {session_id}

## 任务: {描述}
## 时间: {start} → {end}
## 状态: completed

## 完成的工作
- {audit_blocks 的 action 列表}

## 关键结论
- {audit_blocks 中的 conclusions}

## 用户修正
- {user_correction 记录}

## 遗留问题
- {检查中发现的问题}
```

### 5. 更新 session.json 和 index.json

- `session.json`: `status = "completed"`, `end_time = now()`
- `runs/index.json`: 追加本次会话的索引条目

### 6. 注意事项

- 如果没有活跃的 session（没有先执行 /start），提示用户
- 即使检查发现问题，也要完成保存（记录比完美更重要）
- 检查报告中的 ⚠️ 是建议，❌ 是阻断（但不阻止保存）

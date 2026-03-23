---
name: audit-recover
description: 从审计记录恢复丢失的 Context。当你无法回忆前期讨论内容、不确定当前任务进度、要提出可能已被用户否定的方案、或用户说"你之前说的是什么"、"回忆一下"、"我们之前讨论了什么"时使用。更重要的是：当你感觉自己的回答变得笼统、缺少具体数字和文件名时，应主动触发此 Skill，而不是凭印象继续工作。
user-invocable: true
allowed-tools:
  - Read
  - Glob
  - Grep
---

# /recover — Context 恢复

## 触发方式

```
/recover              # 恢复当前 session 的 context
/recover full         # 恢复当前 session + 最近 3 天的完整 context
/recover {session_id} # 恢复指定 session 的 context
```

## 核心原则

**不确定就查审计记录，不要凭印象工作。**

这不是一个"可选的辅助工具"——当 context 丢失时，/recover 是唯一可靠的恢复手段。
凭印象工作会导致重犯已被用户否定的错误，这比不工作更糟糕。

## 何时触发

### 用户手动触发
用户说"你刚才说的什么来着"、"回忆一下之前的讨论"等。

### Claude 主动触发（更重要）

| 信号 | 判断方式 |
|------|---------|
| 无法回忆会话前期的具体内容 | 用户引用了"之前讨论的"，但你找不到对应内容 |
| 不确定当前任务做到哪一步了 | 要继续工作但不知道上次停在哪 |
| 要提出的方案可能已被用户否定 | 不确定某个判断是否被纠正过 |
| 回答变得笼统，缺少具体细节 | 无法说出具体的数字、文件名、结论 |

## 执行步骤

### 分级加载

按以下优先级渐进加载，避免一次性占满 context：

**Level 0 — 索引摘要（~200 tokens）**

```
读取 .claude/runs/index.json → 最近 5 条 entry 的 id + task + status
```

**Level 1 — 任务状态（~500 tokens）**

```
读取 .claude/runs/.current_session → 获取当前 session_id
读取 .claude/runs/{session_id}/session.json → task + start_time
读取 .claude/runs/{session_id}/audit_trail.jsonl → 最后 3 条记录的 action + output
→ "当前做到哪了"
```

**Level 2 — 用户修正 + 决策上下文（~1,000 tokens）⚠️ 最重要**

```
在 .claude/runs/ 下所有 audit_trail.jsonl 中搜索 "user_correction"
搜索所有 conclusions 字段
读取最新 .claude/runs/daily/ 下的日报 §四异常 + §六待办
→ "用户否定了什么、得出了什么结论、有什么未解决的问题"
```

**Level 3 — 完整上下文（~3,000 tokens，仅在 /recover full 时加载）**

```
完整的 audit_trail.jsonl
完整的 audit_pending.jsonl（如果还有未归档的）
```

### 输出恢复报告

```
=== Context 恢复报告 ===
来源: .claude/runs/{session_id}/
恢复级别: Level 2

当前任务: {session.task}
任务状态: {最后一个 audit 记录的 output}

⚠️ 用户修正记录（必须遵守）:
  1. [时间] 原始判断: "..."
     修正: "..."
     原则: ...

关键结论:
  - ...

未解决问题:
  - ...

⚠️ 以上内容从审计记录恢复，不是从记忆中回忆的。
```

## 注意事项

- 恢复的 user_correction 记录具有**最高优先级**——后续工作中不得违反
- 如果恢复后发现当前想法与 user_correction 矛盾，必须修正想法
- 恢复报告应简洁，避免把整个审计记录复制到 context
- 优先恢复"为什么"和"不要做什么"，而非"做了什么"

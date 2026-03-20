---
name: audit-recover
description: 从审计记录恢复丢失的 Context。当无法回忆前期讨论内容、不确定任务进度、或要提出可能已被否定的方案时使用。Claude 也应在检测到 context 丢失时主动调用此 Skill。
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

## 何时触发

### 用户手动触发
用户说"你刚才说的什么来着"、"回忆一下之前的讨论"等。

### Claude 主动触发（更重要）
当 Claude 检测到以下信号时，应**主动**调用 /recover：

| 信号 | 判断方式 |
|------|---------|
| 无法回忆会话前期的具体内容 | 用户引用了"之前讨论的"，但 Claude 找不到 |
| 不确定当前任务做到哪一步了 | 要继续工作但不知道上次停在哪 |
| 要提出的方案可能已被用户否定 | 不确定某个判断是否被纠正过 |
| 回答变得笼统，缺少具体细节 | 无法说出具体的数字、文件名、结论 |

**⚠️ 关键原则：不确定就查审计记录，不要凭印象工作。**

## 执行步骤

### 分级加载

按以下优先级渐进加载，避免一次性占满 context：

**Level 0 — 索引摘要（~200 tokens）**

```
读取 runs/index.json → 最近 5 条 entry 的 id + task + status
```

**Level 1 — 任务状态（~500 tokens）**

```
读取当前 session 的 session.json
读取最后 3 条 audit_block 的 action + output
→ "当前做到哪了"
```

**Level 2 — 用户修正 + 决策上下文（~1,000 tokens）⚠️ 最重要**

```
搜索所有 audit_blocks.jsonl 中 action_type = "user_correction" 的记录
搜索所有 conclusions 字段
读取最新 daily report 的 §四异常 + §六待办
→ "用户否定了什么、得出了什么结论、有什么未解决的问题"
```

**Level 3 — 完整上下文（~3,000 tokens，仅在 /recover full 时加载）**

```
完整的 audit_blocks.jsonl
完整的 manifest.json（如有）
完整的 anomalies.json
```

### 输出恢复报告

```
=== Context 恢复报告 ===
来源: runs/{session_id}/
恢复级别: Level 2

当前任务: {session.task}
任务状态: {最后一个 audit_block 的 output}

⚠️ 用户修正记录（必须遵守）:
  1. [2026-03-19 13:30] 原始判断: "Record audit 是过度设计"
     修正: "不是过度设计，hashchain 是 Agent 间信任基础"
     原则: 每个 pipeline node 都是 Record

  2. [2026-03-19 13:30] 原始判断: "API 模型版本漂移"
     修正: "这是臆测，数据不足以断言"
     原则: 不要做任何猜测，除非有十足的把握

关键结论:
  - v27 修改未引入退化（10k 验证 + 2k 对照组）
  - 品牌前缀错误基本消除（仅 2 条残留）

未解决问题:
  - prompt2 空率连续上升（50.0%）
  - 长安 CS75PLUS 品牌前缀残留

⚠️ 以上内容从审计记录恢复，不是从记忆中回忆的。
```

## 注意事项

- 恢复的 user_correction 记录具有**最高优先级**——后续工作中不得违反
- 如果恢复后发现当前想法与 user_correction 矛盾，必须修正想法
- 恢复报告应简洁，避免把整个审计记录复制到 context（那样会更快耗尽 context）
- 优先恢复"为什么"和"不要做什么"，而非"做了什么"

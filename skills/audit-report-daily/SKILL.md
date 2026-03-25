---
name: audit-report-daily
description: 基于 .claude/runs/ 目录的审计数据自动生成工作日报。日报每个数字都可追溯到审计记录。当用户说"生成日报"、"今天做了什么"、"写报告"、"总结一下今天的工作"，或通过 cron 每日 08:03 自动触发时使用。
user-invocable: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
---

# /report-daily — 审计驱动工作日报

## 触发方式

```
/report-daily              # 生成今天的日报（截止到当前时刻）
/report-daily 20260319     # 生成指定日期的日报
/report-daily review       # 生成日报 + 晨间自我修正报告
```

## 数据源

日报的**每个数字**都有明确的数据源，不允许"凭记忆"填写。

所有数据来自 `.claude/runs/` 目录：

| 日报板块 | 数据源 |
|---------|--------|
| 任务总览 | `.claude/runs/index.json` |
| 工具操作统计 | `.claude/runs/*/audit_trail.jsonl` 中的 tool 记录 |
| 变更记录 | `.claude/runs/*/audit_trail.jsonl` 中含 "change"/"prompt"/"edit" 的条目 |
| [AUDIT] 块汇总 | `.claude/runs/audit_pending.jsonl` + 各 session 的 audit_trail |
| 异常与告警 | `.claude/runs/*/anomalies.json`（如果存在） |
| 用户反馈与修正 | audit_trail 中含 "user_correction" 的条目 |
| 昨日待办跟进 | 前一天日报（`.claude/runs/daily/` 下） |

## 执行步骤

### 1. 收集数据

```bash
target_date="${1:-$(date +%Y%m%d)}"

# 1. 读取 index.json，筛选 target_date 相关的 session
# 2. 逐个读取各 session 的 audit_trail.jsonl
# 3. 读取 audit_pending.jsonl（可能有未归档的最新数据）
# 4. 如果有前一天的日报，提取 §七 待办（用于跟进）
```

### 2. 生成日报

按以下结构填充，每个数字旁标注数据来源：

```markdown
# 工作日报 | {DATE}

> 自动生成时间: {NOW}
> 数据来源: .claude/runs/index.json + 各 session audit_trail
> 覆盖时间段: {DATE} 00:00 — {DATE} 23:59

---

## 一、任务总览

| # | 类型 | session_id | 任务描述 | 状态 | 审计记录数 |
|---|------|-----------|---------|------|-----------|

> 来源: .claude/runs/index.json

---

## 二、操作统计

| 指标 | 数量 | 来源 |
|------|------|------|
| Write/Edit 操作 | {N} | audit_trail tool=Write/Edit |
| Bash 执行 | {N} | audit_trail tool=Bash |
| [AUDIT] 块 | {N} | audit_pending + audit_trail |

---

## 三、变更记录

| # | 时间 | 变更对象 | 变更内容 | 来源 |
|---|------|---------|---------|------|

> 从 audit_trail 和 audit_pending 中提取涉及文件修改的条目

---

## 四、用户反馈与修正

| # | 反馈内容 | 修正后 | 已固化到 |
|---|---------|-------|---------|

> 从 audit_trail 中提取 user_correction 类型条目

---

## 五、昨日待办跟进

| # | 昨日待办 | 今日状态 | 说明 |
|---|---------|---------|------|

---

## 六、明日待办

- [ ] ...

---

## 七、审计完整性

| 检查项 | 结果 |
|--------|------|
| 所有 session 有审计记录 | {结果} |
| [AUDIT] 块已持久化 | {结果} |
| 用户修正已固化 | {结果} |
```

### 3. 保存

```bash
mkdir -p .claude/runs/daily
# 写入 .claude/runs/daily/{YYYYMMDD}_daily.md
```

### 4. 如果是 /report-daily review：晨间自我修正

在日报生成后，额外执行自我审视：

1. 昨日异常是否都有处理方案？
2. 用户反馈是否已转化为系统改进？
3. 昨日待办是否都完成了？
4. 生成修正报告：`.claude/runs/daily/{YYYYMMDD}_morning_review.md`
5. 输出今日推荐优先级

## 注意事项

- 如果某天没有任何 session 记录，生成空日报并标注"当日无活动"
- 日报本身也应写一条 [AUDIT] 块
- 历史日报不可修改（append-only），如有错误则发布更正日报
- 日报中所有数字**必须**来自 `.claude/runs/` 下的文件，禁止凭记忆填写

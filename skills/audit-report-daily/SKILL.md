---
name: audit-report-daily
description: 基于 runs/ 目录的审计数据自动生成工作日报。日报每个数字都可追溯到审计记录。也可通过 cron 每日 08:03 自动触发。
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

日报的**每个数字**都有明确的数据源，不允许"凭记忆"填写：

| 日报板块 | 数据源 |
|---------|--------|
| 任务总览 | `runs/index.json` |
| 数据处理指标 | `runs/batch_*/manifest.json` |
| 变更记录 | `runs/*/audit_trail.jsonl` (step="change") |
| 异常与告警 | `runs/*/anomalies.json` |
| 用户反馈与修正 | `runs/adhoc_*/audit_blocks.jsonl` (action_type="user_correction") |
| 昨日待办跟进 | 前一天日报的 §七 |
| 明日待办 | 当日异常 + 未完成任务 |
| 审计完整性检查 | 全量扫描 runs/ |

## 日报模板

读取 `references/report_template.md` 获取完整模板。

## 执行步骤

### 1. 收集数据

```
target_date = 参数日期 或 今天

1. 从 runs/index.json 筛选 target_date 的所有 batch + adhoc 条目
2. 逐个读取 manifest.json / session.json / audit_blocks.jsonl / anomalies.json
3. 从最近 7 天的 manifest 中提取历史数据（用于趋势对比）
4. 从前一天的日报中提取 §七 待办（用于跟进）
```

### 2. 生成日报

按模板填充所有板块，每个数字旁标注 `来源字段`。

### 3. 保存

```
runs/daily/{YYYYMMDD}_daily.md
```

### 4. 如果是 /report-daily review：晨间自我修正

在日报生成后，额外执行：

1. 审视昨日异常是否都有处理方案
2. 审视用户反馈是否已转化为系统改进
3. 审视关键指标是否有持续恶化趋势
4. 生成修正报告：`runs/daily/{YYYYMMDD}_morning_review.md`
5. 输出今日推荐优先级

## cron 自动化

建议在每日首次启动 Claude Code 时设置 cron：

```
cron "3 8 * * *"   → /report-daily {yesterday}
cron "5 8 * * *"   → /report-daily review
```

## 注意事项

- 如果某天没有任何 batch 或 adhoc 记录，生成空日报并标注"当日无活动"
- 日报本身也是一条审计记录——保存后自动更新 index.json
- 历史日报不可修改（append-only），如果发现错误，发布更正日报

# 工作日报 | {DATE}

> 自动生成时间: {GENERATED_AT}
> 数据来源: runs/batch_{DATE}_* + runs/adhoc_{DATE}_*
> 覆盖时间段: {DATE} 00:00 — {DATE} 23:59

---

## 一、任务总览

| # | 类型 | batch_id | 任务描述 | 状态 | Record 统计 |
|---|------|----------|---------|------|------------|
| {n} | {batch/adhoc} | {id} | {task} | {status} | {record_counts} |

> 来源: runs/index.json

---

## 二、数据处理指标

### 2.1 今日处理量

| 指标 | 今日 | 昨日 | 7日均值 | 变化趋势 | 来源 |
|------|------|------|--------|---------|------|
| {metric} | {today} | {yesterday} | {avg_7d} | {trend} | {source_field} |

### 2.2 清洗规则触发分布

| 规则 | 触发次数 | 占比 | vs 昨日 | 来源 |
|------|---------|------|--------|------|
| {rule} | {count} | {pct} | {change} | {source} |

### 2.3 品牌级错误率分布（如有）

| 品牌 | 样本量 | 错误数 | 错误率 | vs 昨日 | 来源 |
|------|-------|-------|-------|--------|------|
| {brand} | {total} | {errors} | {rate} | {change} | {source} |

---

## 三、变更记录

| # | 时间 | 变更对象 | 变更内容 | 影响范围 | 验证状态 |
|---|------|---------|---------|---------|---------|
| {n} | {time} | {file} | {description} | {scope} | {validation} |

> 来源: runs/*/audit_trail.jsonl (step="change") 或 audit_blocks.jsonl

---

## 四、异常与告警

| 级别 | 告警内容 | 触发批次 | 处理状态 |
|------|---------|---------|---------|
| {level} | {message} | {batch_id} | {status} |

> 来源: runs/*/anomalies.json

---

## 五、用户反馈与修正

| # | 时间 | 反馈内容 | Claude 的原始判断 | 修正后 | 影响 |
|---|------|---------|-----------------|-------|------|
| {n} | {time} | {feedback} | {original} | {corrected} | {impact} |

> 来源: runs/adhoc_*/audit_blocks.jsonl (action_type="user_correction")

---

## 六、昨日待办跟进

| # | 昨日待办 | 今日状态 | 说明 |
|---|---------|---------|------|
| {n} | {todo} | {status_emoji} | {note} |

> 来源: 前一天日报的 §七

---

## 七、明日待办

- [ ] {todo_item}

---

## 八、审计完整性检查

| 检查项 | 结果 |
|--------|------|
| 所有 batch 有 manifest | {result} |
| 所有 adhoc 有 audit_blocks | {result} |
| 所有文件变更有审计记录 | {result} |
| 所有 Prompt 变更有 ≥10k 验证 | {result} |
| 用户修正已持久化 | {result} |
| 无遗漏的 [AUDIT] 块 | {result} |

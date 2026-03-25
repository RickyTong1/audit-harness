# L2 | 审计执行保障模块设计

> **日期**：2026-03-19
> **级别**：L2（模块设计）
> **优先级**：**最高** — 本模块是整个 Harness 的核心基础设施
> **状态**：P0/P1 已实现，P2/P3 待实施
> **上游文档**：`docs/L1_platform_blueprint.md` §8（可审计性架构）
> **归属项目**：`audit-harness`

---

## 1. 模块定位

### 1.1 为什么这是最重要的模块

本平台的目标是支持**无监督 Agent 运行**。在无人值守的环境中：

- 没有人盯着 Agent 看它做了什么
- 没有人检查 Agent 是否跳过了某个步骤
- 没有人确认 Agent 的输出是否合理

**审计执行保障是唯一能在事后回答"发生了什么"的机制。** 如果审计断了，整个系统就变成了一个黑盒——你不知道里面发生了什么，也不知道该信任什么。

### 1.2 设计约束（来自 L1 §8.0）

| 约束 | 含义 |
|------|------|
| 完善 | 每条记录、每个批次、每份报告都有追踪 |
| 轻量 | 正确样本压缩存储；存储占用和审计价值成正比 |
| 可迭代 | 审计结构本身可以版本化演进 |
| 可扩展 | 新增 pipeline 节点时，审计框架无需重构 |

### 1.3 核心问题

> **如何保证所有操作（包括非结构化任务）都按审计框架执行？**

已证伪的方案：
- ❌ "在 CLAUDE.md 里写审计规范，靠 Claude 自觉遵守" — Case #001 已证伪

正解：
- ✅ **三层防线**：Skill 硬编码 + 输出格式强制 + 会话级兜底

---

## ⚠️ 2. Record 的识别与分类体系（核心章节）

> **本节是审计框架中最关键的设计决策之一。**
>
> 在回答"如何增加 Record 级审计记录"之前，必须先回答一个更根本的问题：
> **什么是 Record？在不同的工作场景下，Record 的含义完全不同。**

### 2.1 核心判定标准

Record 的定义取决于你当前在做什么：

| 工作场景 | Record 的含义 | 粒度 | 示例 |
|---------|-------------|------|------|
| **数据处理** | 每条数据就是一个 Record | 行级 | 一条数据从拉取→清洗→分类→筛选→导出的完整处理链 |
| **代码/文件改写** | 每个代码块、每次文件改动就是一条 Record | 变更级 | 修改 `filter_rules.py` 的第 45 行，新增一条规则 |
| **非结构化工作** | 每次对话就是一条 Record | 交互级 | "帮我分析 Category-A 的错误模式" → Claude 的分析结论 |

**⚠️ 关键认知：这些 Record 不是互斥的，也不是互相独占的。**

在一个复杂的数据处理任务中，Record 可能会**同时存在多种类型**，交织在同一个工作流中。审计框架必须能够同时识别和追踪所有这些 Record，而不是假设"一次只做一件事"。

### 2.2 Record 类型的深入定义

#### 类型 A：数据 Record（Data Record）

**定义**：pipeline 中流经的每一条业务数据。

**特征**：
- 有明确的唯一标识（`hash_code` 或自生成 `record_id`）
- 有确定的生命周期：从进入系统（pull）到最终处置（accepted / flagged / deleted）
- 每经过一个 pipeline 节点，就追加一个 transform 条目
- 是最高频的 Record 类型（日均 12,000+ 条）

**审计内容**：
```
record_id → 哪条数据
step      → 在哪个节点
rule      → 触发了什么规则
action    → 做了什么（keep/delete/modify/flag）
reason    → 为什么
before    → 变更前的值
after     → 变更后的值
```

**完整生命周期示例**：

一条数据记录 `record_id=abc123` 经过完整 pipeline：

```jsonl
{"record_id":"abc123","step":"pull","rule":"dedup","action":"keep","reason":"hash 未重复"}
{"record_id":"abc123","step":"clean","rule":"Rule0_whitelist","action":"keep","reason":"source_level 不在白名单"}
{"record_id":"abc123","step":"clean","rule":"Rule1_freq_filter","action":"keep","reason":"未触发"}
{"record_id":"abc123","step":"clean","rule":"Rule3_sentiment_fix","action":"modify","reason":"type=complaint AND sentiment=neutral","before":{"sentiment_label":"neutral"},"after":{"sentiment_label":"negative"}}
{"record_id":"abc123","step":"ai_classify","rule":"ai-model","action":"classify","reason":"tag=Category-A, confidence=92"}
{"record_id":"abc123","step":"screen","rule":"ml_screen_v3","action":"flag","reason":"ml_score=0.73 >= threshold=0.134"}
{"record_id":"abc123","step":"disposition","rule":"final","action":"human_review","reason":"flagged by screening"}
```

**这 7 条审计条目共同构成了一条数据 Record 的完整追踪。** 缺少任何一条，这条数据的审计链就是不完整的。

#### 类型 B：变更 Record（Change Record）

**定义**：对代码、配置文件、Prompt 模板、模型参数等的每一次修改。

**特征**：
- 不是业务数据，而是**系统本身的变化**
- 修改可能影响后续所有数据 Record 的处理结果
- 是 Harness 演进的审计追踪
- 频率较低（每天 0-5 次），但每次影响面可能极大

**审计内容**：
```
file_path     → 修改了哪个文件
change_type   → 修改类型（code/config/prompt/model/rule）
description   → 做了什么改动
diff_summary  → 变更摘要（新增/删除/修改的行数或字符数）
before_hash   → 修改前文件哈希
after_hash    → 修改后文件哈希
impact_scope  → 影响范围（哪些 pipeline 节点、哪些类别、哪些规则）
validation    → 是否经过验证（如 Prompt 修改必须有 ≥10,000 条回归测试）
```

**示例**：

```json
{
    "record_type": "change",
    "file_path": "docs/long_text_*.txt",
    "change_type": "prompt",
    "description": "v1.0→v2.0: 新增标签前缀约束 6 处",
    "diff_summary": "+243 chars, 6 locations modified",
    "before_hash": "sha256:aee096...",
    "after_hash": "sha256:f3c21a...",
    "impact_scope": "所有类别的 AI 分类步骤",
    "validation": {
        "test_samples": 10000,
        "control_samples": 2000,
        "result": "未引入退化",
        "details_file": "test_v2_prefix_results.jsonl"
    }
}
```

#### 类型 C：对话 Record（Conversation Record）

**定义**：在非结构化工作中，人与 Claude 之间的每一轮有实质内容的对话。

**特征**：
- 无法提前预知内容和结构
- 可能包含分析、决策、结论、假设——这些都是审计的重要信息
- 是**决策过程**的追踪，而非数据处理过程
- 一次对话可能同时触发类型 B（修改了文件）和类型 A（处理了数据）

**审计内容**：
```
turn_id          → 对话轮次
role             → user / assistant
action_type      → query / analysis / decision / modification / verification
summary          → 本轮对话的核心内容（一句话）
artifacts        → 本轮产出的文件或数据
conclusions      → 得出的结论（如有）
assumptions      → 做出的假设（如有）——特别重要，假设可能是错的
```

**示例**：

```json
{
    "record_type": "conversation",
    "turn_id": 3,
    "role": "assistant",
    "action_type": "analysis",
    "summary": "分析 error_samples.csv 中 3 条 Item-X 错误样本，归因为 label prefix pollution",
    "artifacts": [],
    "conclusions": ["AI 在 tag 中添加了标签前缀 'Category-B'", "根因是 v1.0 prompt 缺少前缀约束示例"],
    "assumptions": []
}
```

### 2.3 Record 的共存与交织

**⚠️ 这是审计框架中最容易被忽视的设计难点。**

在真实的工作场景中，一个任务往往**同时产生多种类型的 Record**。它们不是串行出现的，而是交织在同一个工作流中。审计框架必须能同时追踪所有类型。

#### 示例：一个完整的错误修复任务

```
任务："修复 Item-X 标签前缀错误"

┌─────────────────────────────────────────────────────────────┐
│ 阶段 1：分析                                                 │
│                                                             │
│   对话 Record:  用户说"帮我分析 error_samples.csv"                     │
│   对话 Record:  Claude 分析 3 条样本，得出"label prefix pollution"结论  │
│   数据 Record:  读取了 error_samples.csv 中的 3 条数据 (abc, def, ghi)  │
│                                                             │
│   → 此阶段同时产生 2 条对话 Record + 3 条数据 Record          │
├─────────────────────────────────────────────────────────────┤
│ 阶段 2：修复                                                 │
│                                                             │
│   对话 Record:  用户说"改 prompt 模板"                       │
│   变更 Record:  修改 docs/long_text_*.txt（6 处, +243 chars） │
│   对话 Record:  Claude 说明修改内容和理由                     │
│                                                             │
│   → 此阶段同时产生 2 条对话 Record + 1 条变更 Record          │
├─────────────────────────────────────────────────────────────┤
│ 阶段 3：验证                                                 │
│                                                             │
│   对话 Record:  用户说"跑回归测试"                           │
│   数据 Record:  处理了 10,000 条测试数据（每条都有 before/after）│
│   变更 Record:  生成了 test_v2_prefix_results.jsonl            │
│   对话 Record:  Claude 报告测试结果"未引入退化"               │
│                                                             │
│   → 此阶段同时产生 2 条对话 + 10,000 条数据 + 1 条变更 Record │
├─────────────────────────────────────────────────────────────┤
│ 阶段 4：记录                                                 │
│                                                             │
│   变更 Record:  更新 L1 附录 D（Harness 案例日志）            │
│   变更 Record:  更新 L2 任务文档                              │
│   对话 Record:  Claude 总结整个任务                           │
│                                                             │
│   → 此阶段同时产生 1 条对话 + 2 条变更 Record                │
└─────────────────────────────────────────────────────────────┘

整个任务共产生：
  - 对话 Record:   7 条
  - 数据 Record:   10,003 条
  - 变更 Record:   4 条
  - 合计:          10,014 条 Record，横跨 3 种类型
```

### 2.4 Record 识别的职责分配

在每次任务开始时，需要**主动识别当前任务可能涉及的 Record 类型**。这个识别工作本身就是审计的一部分。

| 识别时机 | 由谁识别 | 识别方式 |
|---------|---------|---------|
| Skill 启动时 | Skill 代码（自动） | 根据 Skill 类型预定义：`/pull` 产生数据 Record，`/clean` 产生数据+变更 Record |
| /start 启动时 | Claude（引导） | 在创建会话时分析任务描述，列出可能涉及的 Record 类型 |
| 任务执行中 | Claude（实时） | 当发现新的 Record 类型出现时（如分析中发现需要改代码），在 [AUDIT] 块中标注 |

**具体实现**：/start 创建会话时，Claude 应输出预期 Record 类型：

```
/start "修复 Item-X 标签前缀错误"

会话已创建，batch_id = adhoc_20260319_1000。

预期 Record 类型：
  [数据] 需要读取错误样本进行分析（error_samples.csv）
  [对话] 分析过程和结论
  [变更] 可能修改 Prompt 模板
  [数据] 如果修改 Prompt，需要跑 ≥10,000 条回归测试
```

### 2.5 Record 在 AuditContext 中的实现映射

三种 Record 类型在 `audit_context.py` 中的对应关系：

| Record 类型 | AuditContext API | 存储文件 |
|------------|-----------------|---------|
| 数据 Record | `audit.record(RecordEntry(...))` 或 `audit.record_compact(CompactRecord(...))` | `audit_trail.jsonl` / `audit_compact.jsonl` |
| 变更 Record | `audit.record(RecordEntry(step="change", ...))` | `audit_trail.jsonl` |
| 对话 Record | `[AUDIT]` 块（格式规范） → `/end` 收集到 `audit_blocks.jsonl` | `audit_blocks.jsonl` |

**一个 AuditContext 实例可以同时包含所有三种类型的 Record。** 它们在同一个 `batch_id` 下共存，但通过 `step` 字段（或 `record_type` 字段）区分。

### 2.6 Record 类型的扩展

当未来出现新的 Record 类型（如"模型训练 Record"、"部署 Record"）时，只需要：

1. 在本节中定义新类型的含义、特征、审计内容
2. 在 `audit_context.py` 中用现有的 `record()` API 记录（不需要新增 API）
3. 用 `step` 字段区分新类型（如 `step="train"`, `step="deploy"`）

**审计框架的核心 API 不需要任何修改。** 新增类型只是 `step` 字段的新枚举值 + 文档更新。

---

## 3. 三层防线架构

```
┌─────────────────────────────────────────────────────────────┐
│ 层 3：会话级包裹（/start + /end）                            │
│   检测遗漏、汇总审计、兜底拦截                                │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ 层 2：[AUDIT] 输出格式规范                              │  │
│  │   非结构化任务的格式约束（~90% 可靠）                    │  │
│  │                                                       │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │ 层 1：Skill 硬编码                               │  │  │
│  │  │   结构化任务的代码级强制（100% 可靠）              │  │  │
│  │  │   + Skill 间 hashchain 校验                      │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. 层 1 详细设计：Skill 硬编码

### 4.1 审计骨架

每个 Skill 内部强制执行以下审计流程：

```python
class AuditContext:
    """Skill 执行期间的审计上下文"""

    def __init__(self, skill_name: str, batch_id: str = None):
        self.skill_name = skill_name
        self.batch_id = batch_id or f"batch_{datetime.now().strftime('%Y%m%d_%H%M')}"
        self.start_time = datetime.utcnow()
        self.records: list[dict] = []        # Record-Level 审计条目
        self.environment: dict = {}           # 环境快照
        self.input_hash: str = None           # 输入数据的哈希
        self.output_hash: str = None          # 输出数据的哈希

    def record(self, entry: dict):
        """追加一条 Record-Level 审计条目"""
        entry["timestamp"] = datetime.utcnow().isoformat() + "Z"
        entry["skill"] = self.skill_name
        self.records.append(entry)

    def snapshot_environment(self):
        """快照当前环境配置"""
        self.environment = {
            "rules_version": get_rules_version(),
            "rules_config_hash": hash_file("filter_rules.py"),
            "ml_model_hash": hash_file("ml_screen_v3.pkl"),
            "prompt_template_hash": hash_file("docs/long_text_*.txt"),
            "script_hashes": {
                f: hash_file(f) for f in CORE_SCRIPTS
            }
        }

    def finalize(self) -> dict:
        """生成 BatchManifest"""
        self.output_hash = compute_output_hash()
        return {
            "batch_id": self.batch_id,
            "skill": self.skill_name,
            "start_time": self.start_time.isoformat() + "Z",
            "end_time": datetime.utcnow().isoformat() + "Z",
            "environment": self.environment,
            "input_hash": self.input_hash,
            "output_hash": self.output_hash,
            "record_count": len(self.records),
            "manifest_hash": None  # 最后填充（自签名）
        }
```

### 4.2 Skill 间 Hashchain

```
Skill A 输出:
  manifest_A.output_hash = sha256(所有输出文件的内容拼接)

Skill B 启动时:
  expected_hash = load_previous_manifest().output_hash
  actual_hash = sha256(当前输入文件的内容拼接)

  if expected_hash != actual_hash:
      raise HashchainBroken(
          f"输入数据在 Skill A 和 Skill B 之间被修改。"
          f"期望: {expected_hash}, 实际: {actual_hash}"
      )
```

**Hashchain 校验的场景**：

| 上游 Skill | 下游 Skill | 校验内容 |
|-----------|-----------|---------|
| /pull | /clean | data_export/ 目录内容未被修改 |
| /clean | /audit | 清洗后数据未被修改 |
| /audit | /report | 筛选结果未被修改 |

**Hashchain 不校验的场景**：
- adhoc（非结构化）操作不参与 hashchain
- 用户手动修改数据时（此时需要创建新的 batch，而非续接旧 batch）

### 4.3 存储策略

**正确样本压缩存储**：

| 记录类型 | 审计详细度 | 存储格式 | 保留时长 |
|---------|----------|---------|---------|
| 异常/flagged 样本 | 完整 transforms 链 | 完整 JSON | 永久 |
| 正确样本 | 摘要行（id, rule_hits, disposition） | 压缩行 | 90 天 |
| 被删除样本 | 完整 transforms 链（记录删除原因） | 完整 JSON | 180 天 |

**摘要行格式**（正确样本的压缩审计）：

```jsonl
{"id":"hash_abc","batch":"batch_20260319_0600","rules":"0/0/0/0/0/0/0/0/0","disp":"ai_accepted","ml":0.023}
```

每条约 120 字节，12,000 条/天 ≈ 1.4 MB/天 ≈ 42 MB/月。可接受。

---

## 5. 层 2 详细设计：[AUDIT] 输出格式规范

### 5.1 设计原理

**为什么格式约束比行为建议更可靠？**

LLM 对两类指令的遵从性有本质差异：

| 指令类型 | 示例 | 遵从机制 | 可靠性 |
|---------|------|---------|--------|
| 行为建议 | "完成后请写审计记录" | 需要 Agent 主动发起额外动作 | 低 |
| 输出格式 | "回复末尾附带 [AUDIT] 块" | 格式模板匹配，LLM 强项 | **高** |

这就像函数签名的返回类型声明——不是建议你返回什么，是规定你必须返回什么。

### 5.2 [AUDIT] 块规范

**触发条件**（满足任一即触发）：

| 条件 | 示例 |
|------|------|
| 修改了文件 | Edit/Write 工具被调用 |
| 执行了脚本 | Bash 中运行了 python / conda run |
| 分析了数据 | 读取了 JSONL/CSV/Excel 并给出结论 |
| 修改了配置 | 修改了 Prompt / 规则 / 模型参数 |

**字段定义**：

```
[AUDIT]
batch: string       # 批次标识
                     # Skill 内：自动填充 batch_id
                     # 非 Skill：adhoc_YYYYMMDD_HHMM
                     # 同一会话内的多个操作共享同一个 batch

action: string       # 一句话描述做了什么
                     # 例："修改 prompt 模板 v1.0→v2.0，新增标签前缀约束"
                     # 例："分析 Category-A 错误样本 522 条，归因为实体/类别混淆"

input: string        # 输入来源
                     # 例："dataset/export_diff/Category-A_diff.jsonl (522 条)"
                     # 例："docs/long_text_*.txt (v1.0)"

output: string       # 输出产物
                     # 例："docs/long_text_*.txt (v2.0), 6 处修改, +243 字符"
                     # 例："结论：实体/类别混淆占错误的 68%"

hash_in: string      # 输入标识（文件哈希、记录数、或 "N/A"）
hash_out: string     # 输出标识（文件哈希、记录数、或 "N/A"）
```

**示例**：

```
[AUDIT]
batch: adhoc_20260319_1000
action: 修改 prompt 模板 v1.0→v2.0，新增标签前缀约束 6 处
input: docs/long_text_*.txt (v1.0)
output: docs/long_text_*.txt (v2.0, +243 chars)
hash_in: N/A
hash_out: N/A
```

```
[AUDIT]
batch: adhoc_20260319_1100
action: 运行 v2.0 标签前缀回归测试，10,000 条样本
input: dataset/export + dataset/export_diff (10,000 条抽样)
output: test_v2_prefix_results.jsonl (10,000 条结果)
hash_in: seed=42, correct=9579, diff=421
hash_out: 回退率 18.5%, 标签前缀错误 2 条, 无新增系统性退化
```

### 5.3 [AUDIT] 块的收集与持久化

[AUDIT] 块在 Claude 的回复中输出后，需要被收集到 `runs/` 目录。

**方式 1：/end Skill 自动收集**

`/end` 在会话结束时扫描会话历史中的所有 [AUDIT] 块，汇总写入：

```
runs/adhoc_20260319_1000/
├── session.json           # 会话元数据（task, start, end）
├── audit_blocks.jsonl     # 所有 [AUDIT] 块的结构化版本
└── session_summary.md     # 会话总结
```

**方式 2：Claude 主动写入**

在 CLAUDE.md 中规定：当 [AUDIT] 块涉及文件修改时，Claude 应同时将审计信息追加到 `runs/` 目录。

**推荐方式 1**（/end 自动收集），因为方式 2 仍然依赖 Claude "记得"。

---

## 6. 层 3 详细设计：/start + /end 会话包裹

### 6.1 /start Skill

```
/start "分析 Category-A 错误模式"
```

执行：
1. 生成 session_id：`adhoc_{YYYYMMDD}_{HHMM}`
2. 创建目录：`runs/{session_id}/`
3. 创建 `session.json`：

```json
{
    "session_id": "adhoc_20260319_1400",
    "task": "分析 Category-A 错误模式",
    "start_time": "2026-03-19T14:00:00Z",
    "status": "in_progress",
    "operations": []
}
```

4. 告知 Claude：`"当前会话已创建，batch_id = adhoc_20260319_1400。所有 [AUDIT] 块请使用此 batch_id。"`

### 6.2 /end Skill

```
/end
```

执行：
1. 扫描会话中的所有 [AUDIT] 块
2. 解析并写入 `runs/{session_id}/audit_blocks.jsonl`
3. 检查完整性：

```python
checks = {
    "has_audit_blocks": len(audit_blocks) > 0,
    "files_modified": list_modified_files_in_session(),
    "all_modifications_audited": check_coverage(audit_blocks, modified_files),
    "prompt_or_rule_changed": any("prompt" in a.action or "规则" in a.action for a in audit_blocks),
    "harness_log_updated": check_l1_appendix_d_updated() if prompt_or_rule_changed else True,
}
```

4. 输出检查报告：

```
=== 会话审计检查 ===
[✅] 审计块数量: 3
[✅] 所有文件修改已审计
[⚠️] 涉及 Prompt 修改，但 L1 附录 D 未更新
[建议] 请运行 /harness-log 更新 Harness 案例日志
```

5. 更新 `session.json`：`status = "completed"`

### 6.3 /end 的异常处理

| 检查项 | 通过条件 | 失败处理 |
|--------|---------|---------|
| 审计块数量 > 0 | 至少有一个 [AUDIT] 块 | ⚠️ 警告："本次操作无审计记录" |
| 文件修改全覆盖 | 每个被修改的文件都有对应的 [AUDIT] | ⚠️ 列出未审计的文件 |
| Prompt/规则修改 → L1 附录 D | 如果改了 Prompt/规则，附录 D 必须更新 | ⚠️ 提醒补充 |
| 回归测试 | 如果改了 Prompt，必须有 ≥10,000 条测试的 [AUDIT] | ❌ 阻断：审计性为 0 |

---

## 7. 非结构化任务的审计流程（完整示例）

### 场景：分析 Category-A 标签前缀错误 → 修改 Prompt → 验证

```
用户：/start "修复 Item-X 标签前缀错误"
Claude：会话已创建，batch_id = adhoc_20260319_1000

用户："帮我分析 error_samples.csv 中的错误模式"
Claude：[分析...]
  3 条样本，AI 输出 tag="Category-B/Item-X"，列表中是「Item-X」。
  根因：label prefix pollution。

  [AUDIT]
  batch: adhoc_20260319_1000
  action: 分析 error_samples.csv 中 3 条 Item-X 错误样本，归因为 label prefix pollution
  input: error_samples.csv (3 条)
  output: 结论：AI 在 tag 中添加了标签前缀 "Category-B"
  hash_in: N/A
  hash_out: N/A

用户："改 prompt 模板"
Claude：[修改 docs/long_text_*.txt，6 处改动]

  [AUDIT]
  batch: adhoc_20260319_1000
  action: 修改 prompt 模板 v1.0→v2.0，新增标签前缀约束 6 处
  input: docs/long_text_*.txt (v1.0)
  output: docs/long_text_*.txt (v2.0, +243 chars)
  hash_in: N/A
  hash_out: N/A

用户："跑回归测试"
Claude：[运行 test_v2_prefix.py，10,000 条]

  [AUDIT]
  batch: adhoc_20260319_1000
  action: v2.0 回归测试 10,000 条 + v1.0 对照组 2,000 条
  input: dataset (Correct=9579, Diff=421)
  output: test_v2_prefix_results.jsonl
  hash_in: seed=42
  hash_out: v2.0 未引入退化，标签前缀错误 2 条残留

用户：/end
Claude：
  === 会话审计检查 ===
  [✅] 审计块数量: 3
  [✅] 所有文件修改已审计
  [✅] Prompt 修改已附带 ≥10,000 条回归测试
  [⚠️] L1 附录 D 的 Harness 案例日志需要更新
  会话已保存至 runs/adhoc_20260319_1000/
```

---

## 8. 审计驱动的工作日报与自我修正机制

> **核心理念**：审计数据不应该只是被动的"事后追溯"工具。
> 它应该被主动消费——每天自动汇总为日报，每天早晨自动回顾，
> 形成**"执行→记录→回顾→修正→执行"**的闭环。

### 8.1 为什么需要审计驱动的日报

当前的审计数据散落在 `runs/` 目录下的 manifest、audit_trail、session 文件中。
它们是结构化的、完整的——但没有人看。

**审计数据只有被消费才有价值。** 日报就是审计数据的消费形态。

日报解决的问题：

| 问题 | 日报如何解决 |
|------|------------|
| "今天做了什么？" | 汇总所有 batch 和 adhoc 会话的任务清单 |
| "处理了多少数据？" | 聚合所有数据 Record 的计数和分布 |
| "有没有异常？" | 汇总所有 anomalies.json 中的告警 |
| "Prompt/规则改了什么？" | 汇总所有变更 Record |
| "昨天的问题修了没？" | 对照前一天日报的待办事项 |
| "指标趋势怎么样？" | 对比最近 7 天的关键指标 |
| "用户有什么反馈？" | 记录用户在对话中的修正和反馈 |

### 8.2 日报内容结构

日报由以下板块组成，每个板块的数据源都来自审计记录：

```markdown
# 工作日报 | 2026-03-19

> 自动生成时间: 2026-03-20T08:00:00Z
> 数据来源: runs/batch_20260319_* + runs/adhoc_20260319_*
> 覆盖时间段: 2026-03-19 00:00 — 2026-03-19 23:59

---

## 一、任务总览

| # | 类型 | batch_id | 任务描述 | 状态 | Record 统计 |
|---|------|----------|---------|------|------------|
| 1 | batch | batch_20260319_0600 | 每日数据拉取+清洗+筛选 | ✅ 完成 | 数据:12,847 变更:0 |
| 2 | adhoc | adhoc_20260319_1000 | 修复 Item-X 标签前缀错误 | ✅ 完成 | 数据:10,003 变更:4 对话:7 |
| 3 | adhoc | adhoc_20260319_1500 | 设计审计执行保障模块 | ✅ 完成 | 变更:6 对话:12 |

> 来源: runs/index.json

---

## 二、数据处理指标

### 2.1 今日处理量

| 指标 | 今日 | 昨日 | 7日均值 | 变化趋势 | 来源 |
|------|------|------|--------|---------|------|
| 拉取量 | 12,847 | 12,218 | 12,500 | ↗ +5.2% | batch_*.input.records_pulled |
| 去重后 | 12,503 | 11,965 | 12,100 | ↗ +4.5% | batch_*.input.records_deduplicated |
| input 空率 | 50.0% | 47.9% | 45.2% | ⚠️ ↗ +2.1pp | batch_*.input.empty_rate |
| 清洗删除 | 1,299 | 1,187 | 1,200 | ↗ +9.4% | batch_*.cleaning.total_deleted |
| 清洗修改 | 356 | 320 | 310 | ↗ +11.3% | batch_*.cleaning.total_modified |
| 人审量 | 1,893 (16.9%) | 1,722 (16.0%) | 1,750 | ↗ +0.9pp | batch_*.screening.flagged |

### 2.2 清洗规则触发分布

| 规则 | 触发次数 | 占比 | vs 昨日 | 来源 |
|------|---------|------|--------|------|
| R1_freq_filter | 847 | 65.2% | +12.3% | batch_*.cleaning.per_rule_summary |
| R4_keyword_filter | 56 | 4.3% | -8.2% | ... |
| R3_sentiment_fix | 122 | 9.4% | +2.1% | ... |
| ... | | | | |

### 2.3 类别级错误率分布

| 类别 | 样本量 | 错误数 | 错误率 | vs 昨日 | 来源 |
|------|-------|-------|-------|--------|------|
| Category-A | 3,412 | 78 | 2.29% | -0.3pp | batch_*.ai_classify.top_errors_by_category |
| Category-B | 2,105 | 52 | 2.47% | +0.1pp | ... |
| ... | | | | | |

---

## 三、变更记录

| # | 时间 | 变更对象 | 变更内容 | 影响范围 | 验证状态 |
|---|------|---------|---------|---------|---------|
| 1 | 10:30 | docs/long_text_*.txt | v1.0→v2.0: 标签前缀约束 | 全量 AI 分类 | ✅ 10k回归+对照组 |
| 2 | 14:00 | L1_platform_blueprint.md | §8.7 审计执行保障机制 | 审计框架 | N/A（文档） |
| 3 | 15:30 | audit_context.py | 新建审计基础模块 | 全系统 | ✅ 单元测试通过 |

> 来源: runs/adhoc_*/audit_trail.jsonl (step="change")

---

## 四、异常与告警

| 级别 | 告警内容 | 触发批次 | 处理状态 |
|------|---------|---------|---------|
| ⚠️ WARNING | input 空率连续 3 天上升 (45.8%→47.9%→50.0%) | batch_20260319_0600 | 🔴 未解决 |
| ℹ️ INFO | Prompt 模板哈希变更 | adhoc_20260319_1000 | ✅ 已验证 |

> 来源: runs/*/anomalies.json

---

## 五、用户反馈与修正

> 本节记录用户在对话中对 Claude 的修正、否定、补充。
> 这些反馈是 Harness 改进的直接驱动力。

| # | 时间 | 反馈内容 | Claude 的原始判断 | 修正后 | 影响 |
|---|------|---------|-----------------|-------|------|
| 1 | 11:00 | "你的改进没有验证，审计性为 0" | 修改 Prompt 后宣布完成 | 补充 10k 回归测试 | → 硬约束: §12.4 |
| 2 | 13:30 | "Record-Level audit 不是过度设计" | 建议简化 Record 审计 | 保留完整 Record + hashchain | → §8.0 哲学修正 |
| 3 | 13:30 | "API 漂移结论是臆测" | 断言"API 模型已更新" | 修正为"原因未知，数据不足" | → Case #001 结论修正 |

> 来源: runs/adhoc_*/audit_blocks.jsonl (conclusions + assumptions 字段)

---

## 六、昨日待办跟进

| # | 昨日待办 | 今日状态 | 说明 |
|---|---------|---------|------|
| 1 | input 空率持续上升需排查 | 🔴 未解决 | 需协调上游接口 |
| 2 | Category-C Item-Y 标签前缀残留 | 🟡 已识别 | 需补充 Category-C 相关示例 |

---

## 七、明日待办

- [ ] 排查 input 空率上升根因（连续 3 天）
- [ ] 补充 Category-C 标签前缀示例到 v2.0 模板
- [ ] 实现 /start + /end Skill（P1）
- [ ] 改造 /pull Skill 接入审计（P1）

---

## 八、附录：审计完整性检查

| 检查项 | 结果 |
|--------|------|
| 所有 batch 有 manifest | ✅ 1/1 |
| 所有 adhoc 有 audit_blocks | ✅ 2/2 |
| 所有文件变更有审计记录 | ✅ |
| 所有 Prompt 变更有 ≥10k 验证 | ✅ |
| L1 附录 D 已更新 | ✅ |
| 无遗漏的 [AUDIT] 块 | ✅ |
```

### 8.3 日报的数据源映射

日报的每个板块都有明确的数据源，不允许"凭记忆"填写：

| 日报板块 | 主要数据源 | 辅助数据源 |
|---------|----------|----------|
| 一、任务总览 | `runs/index.json` | 各 session.json |
| 二、数据处理指标 | `runs/batch_*/manifest.json` | 最近 7 天 manifest |
| 三、变更记录 | `runs/*/audit_trail.jsonl` (step="change") | git diff |
| 四、异常与告警 | `runs/*/anomalies.json` | ALERT_RULES |
| 五、用户反馈 | `runs/adhoc_*/audit_blocks.jsonl` | 对话 Record 中的 corrections |
| 六、昨日待办 | 前一天日报的§七 | runs/index.json |
| 七、明日待办 | 当日异常 + 未完成任务 | L2 实施优先级 |
| 八、审计完整性 | 全量扫描 runs/ 目录 | — |

### 8.4 日报生成时机与方式

**方式**：`/report daily` Skill 或 cron 自动触发

**时机**：

| 触发方式 | 时间 | 用途 |
|---------|------|------|
| **cron 自动生成** | 每天 08:00 | 自动生成前一天的日报 |
| **手动触发** | 随时 `/report daily` | 生成截止到当前时刻的日报 |

**cron 设置**（在 /start 或会话初始化时自动创建）：

```
# 每天早上 8:03 自动生成前一天的日报
cron: "3 8 * * *"
prompt: |
  请执行以下操作：
  1. 扫描 runs/ 目录下昨天（{yesterday}）的所有 batch 和 adhoc 记录
  2. 按照 L2 §8.2 的日报模板生成日报
  3. 保存到 runs/daily/{yesterday}_daily.md
  4. 然后执行晨间自我修正（见 §8.5）
```

### 8.5 晨间自我修正机制（Morning Self-Review）

> **核心理念**：Agent 不应该只是"做完就走"。
> 每天早上，Agent 应该主动回顾前一天的日报，识别问题，提出改进。
> 这是 Harness Engineering 中"Agent 自我演化"的具体实践。

**晨间自我修正流程**：

```
每天 08:05（日报生成后 2 分钟）：

1. 读取昨日日报（runs/daily/{yesterday}_daily.md）

2. 自我审视清单：
   ├── 昨天的异常/告警是否都有处理方案？
   │   └── 没有 → 列为今日第一优先级
   ├── 昨天的用户反馈是否已转化为系统改进？
   │   └── 没有 → 检查是否需要更新 CLAUDE.md / 规则 / Prompt
   ├── 昨天的待办是否都完成了？
   │   └── 没有 → 滚动到今日待办，标注延期原因
   ├── 关键指标是否有持续恶化趋势？
   │   └── 有 → 触发深度分析
   └── 审计完整性检查是否全部通过？
       └── 没有 → 补充缺失的审计记录

3. 生成晨间修正报告：
   runs/daily/{today}_morning_review.md

4. 输出修正建议：
   "基于昨日日报，今日需优先处理：
    [1] input 空率连续 3 天上升（CRITICAL 级别未解决）
    [2] Category-C 标签前缀残留修复
    [3] /start + /end Skill 实现（P1 任务）"
```

**晨间修正报告模板**：

```markdown
# 晨间修正报告 | 2026-03-20

> 基于: runs/daily/20260319_daily.md
> 生成时间: 2026-03-20T08:05:00Z

## 待解决问题

### 🔴 CRITICAL（必须今日处理）
1. input 空率连续 3 天上升 (45.8%→47.9%→50.0%)
   - 来源: 日报 §四
   - 影响: AI 分类能力持续下降，Recall 天花板被压低
   - 建议动作: 联系上游接口负责人排查

### 🟡 WARNING（今日关注）
2. Category-C 标签前缀残留（Item-Y, Item-Z）
   - 来源: Case #001 验证数据
   - 建议动作: 在 v2.0 模板中补充 Category-C 相关示例

## 用户反馈转化检查

| 反馈 | 是否已固化为系统改进？ | 状态 |
|------|---------------------|------|
| "审计性为 0" | ✅ → §12.4 硬约束 | 已完成 |
| "Record audit 不是过度设计" | ✅ → §8.0 哲学修正 | 已完成 |
| "API 漂移是臆测" | ✅ → Case #001 结论修正 | 已完成 |
| "今天正确不代表明天正确" | ✅ → §8.0 第1条 + CLAUDE.md 红线 | 已完成 |

## 指标趋势（7 天）

input 空率:  45.8% → 46.2% → 45.8% → 47.9% → 50.0%  ⚠️ 连续上升
AI 错误率:     2.4%  → 2.3%  → 2.1%  → 2.3%  → 2.29%  ✅ 稳定
人审量:        16.2% → 16.0% → 15.8% → 16.0% → 16.9%  ↗ 轻微上升

## 今日推荐优先级

1. 🔴 排查 input 空率根因
2. 🟡 补充 Category-C 标签前缀示例
3. 🟢 实现 /start + /end Skill（P1）
```

### 8.6 自我修正的反馈闭环

```
执行 → 审计记录 → 日报汇总 → 晨间回顾 → 修正计划 → 执行
  │                                              │
  └──────────────────────────────────────────────┘
                   持续迭代闭环
```

**闭环中的每个节点都是可审计的**：

| 节点 | Record 类型 | 存储位置 |
|------|------------|---------|
| 执行 | 数据/变更/对话 Record | runs/batch_* / runs/adhoc_* |
| 日报 | 报告 Record（自动生成） | runs/daily/{date}_daily.md |
| 晨间回顾 | 报告 Record（自动生成） | runs/daily/{date}_morning_review.md |
| 修正计划 | 对话 Record（Claude 输出） | 当日 adhoc 会话 |
| 执行 | 下一轮循环 | ... |

### 8.7 业务变化的适配机制

> **"今天正确不代表明天正确"**——业务跟随客户变动。
> 日报 + 晨间回顾的闭环是**发现业务变化的第一道防线**。

**业务变化的信号检测**：

| 信号 | 在日报中的体现 | 触发的修正动作 |
|------|--------------|-------------|
| 新类别/新实体上线 | §二中出现未见过的类别/实体名 | 更新可选列表 + 规则适配 |
| 错误模式变化 | §二类别级错误率某类别突然升高 | 分析新错误模式 → 更新 Prompt/规则 |
| 上游字段变更 | §四 fields_count ≠ 52 告警 | 查字段矩阵 → 修改受影响规则 |
| 标签体系变化 | §三中出现标签修改的变更 Record | 更新清洗规则 + 回归测试 |
| 客户需求变化 | §五中出现用户多次修正同一类结论 | 抽象为新规则/新约束 |

**日报是被动发现。晨间回顾是主动追踪。** 两者结合才能确保系统不会在业务变化中"悄悄地变错"。

---

## ⚠️ 9. 审计即记忆：基于审计记录的 Context 恢复机制（核心章节）

> **本节揭示了审计框架的第二重身份：它不仅是"事后追责"的工具，更是 Agent 的外部持久化记忆系统。**
>
> 当 context window 被压缩、截断、或跨 session 丢失时，`runs/` 目录中的审计记录就是 Claude 唯一可靠的"回忆"来源。

### 9.1 问题：Context 丢失的三种场景

LLM Agent 的根本局限是：**它的记忆是易失的。** 以下三种场景会导致 context 丢失：

| 场景 | 触发条件 | 丢失内容 | 严重性 |
|------|---------|---------|--------|
| **Session 内压缩** | 对话过长，系统自动压缩早期消息 | 会话前期的分析结论、用户修正、中间决策 | 🟡 部分丢失 |
| **跨 Session 断裂** | 用户关闭 Claude Code 后重新打开 | 整个上一次会话的所有信息 | 🔴 完全丢失 |
| **长任务中断** | 网络断连、超时、崩溃 | 当前任务的执行状态和中间结果 | 🔴 完全丢失 |

**丢失的不只是"聊天记录"，而是：**

- 任务进行到哪一步了？（执行状态）
- 分析过程中得出了什么结论？（决策上下文）
- 用户纠正过什么错误判断？（修正历史——**最危险的丢失，因为丢了就会重犯**）
- 当前的环境配置是什么？（规则版本、模型哈希、阈值）
- 上一次跑的数据指标是什么？（baseline 参照）

### 9.2 解法：审计记录 = Agent 的外部"硬盘"

CLAUDE.md 是 Agent 的"基因"——它定义了 Agent 是谁、该怎么做。
但 CLAUDE.md 不记录**发生过什么**。

**审计记录填补了这个空白。** 它是 Agent 的持久化存储：

```
┌─────────────────────────────────────────────────┐
│ Agent 的记忆体系                                  │
│                                                 │
│  ┌───────────────┐   ┌───────────────────────┐  │
│  │ CLAUDE.md     │   │ runs/ 审计记录          │  │
│  │               │   │                       │  │
│  │ "我是谁"      │   │ "发生过什么"            │  │
│  │ "该怎么做"    │   │ "做过什么决策"          │  │
│  │ "什么是红线"  │   │ "用户纠正过什么"        │  │
│  │               │   │ "当前状态是什么"        │  │
│  │ 静态、不变    │   │ 动态、持续增长          │  │
│  │ 自动加载     │   │ 需要主动查询            │  │
│  └───────────────┘   └───────────────────────┘  │
│         │                       │               │
│     基因（不可变）          记忆（可查询）         │
└─────────────────────────────────────────────────┘
```

**关键区别**：CLAUDE.md 会被自动加载到 context，但审计记录不会。Agent 必须**主动查询**审计记录来恢复丢失的 context。这个"主动查询"的行为就是本节要设计的机制。

### 9.3 Context 恢复的分层策略

不同场景下，需要恢复的信息量和紧迫度不同。恢复策略分三层：

#### 第一层：Session 启动恢复（每次新会话必执行）

**触发时机**：每次 Claude Code 启动新会话
**目的**：让 Agent 快速获取"我在哪、之前做了什么、接下来该做什么"
**恢复来源**：`runs/index.json` + 最新的 `daily_report` + `morning_review`

**恢复流程**：

```
新会话启动
    │
    ▼
读取 runs/index.json
    │
    ├── 最近 3 天的 batch/adhoc 列表
    │   → 快速了解"最近在做什么"
    │
    ├── 最新的 daily report (runs/daily/{latest}_daily.md)
    │   → §四 异常告警：有没有未解决的问题？
    │   → §六 昨日待办：有没有未完成的任务？
    │   → §七 明日待办：今天该优先做什么？
    │
    └── 最新的 morning review (runs/daily/{latest}_morning_review.md)
        → 推荐优先级：今天最重要的是什么？
        → 指标趋势：有没有持续恶化的信号？
```

**恢复产出**：Agent 在会话开始时输出一段简短的"上下文恢复摘要"：

```
上下文恢复摘要（基于 runs/ 审计记录）：

最近活动：
  - 昨天完成了 v2.0 标签前缀修复（已验证，可上线）
  - 昨天设计了审计执行保障模块（L2 文档已完成）

待解决问题：
  - 🔴 input 空率连续 3 天上升（45.8%→50.0%）— 未解决
  - 🟡 Category-C Item-Y 标签前缀残留 — 未修复

今日推荐优先级：
  1. 排查 input 空率根因
  2. 补充 Category-C 标签前缀示例到 v2.0 模板
  3. 实现 /start + /end Skill（P1）
```

**在 CLAUDE.md 中固化**：

```markdown
## Session 启动规则

每次新会话开始时，如果 runs/ 目录存在，必须：
1. 读取 runs/index.json 获取最近活动
2. 读取最新的 daily report 和 morning review
3. 输出上下文恢复摘要
4. 确认用户今日的工作方向
```

#### 第二层：Session 内压缩恢复（context 被压缩时执行）

**触发时机**：Claude 感知到早期 context 被压缩（典型信号：无法回忆会话前期的细节）
**目的**：恢复当前任务的关键决策和用户修正
**恢复来源**：当前 session 的 `audit_blocks.jsonl` + `session.json`

**触发信号检测**：

Claude 应在以下情况主动检测 context 丢失并触发恢复：

| 信号 | 检测方式 | 示例 |
|------|---------|------|
| 用户引用了"之前说过的"内容但 Claude 不记得 | 用户说"按我们之前讨论的方式" | 用户提到"之前你分析的结论"但 Claude 找不到 |
| Claude 重复了之前已被否定的方案 | Claude 提出的建议与审计记录中的用户修正矛盾 | 再次建议"简化 Record audit"（已被用户否定） |
| Claude 不确定当前任务的状态 | 无法回忆"做到哪一步了" | 不知道 v2.0 测试已经跑过了 |
| 长时间对话后 Claude 的回答质量下降 | 回答变得笼统、缺少具体细节 | 无法说出具体数字/文件名 |

**恢复流程**：

```
检测到 context 可能丢失
    │
    ▼
读取当前 session 的审计记录
    │
    ├── runs/{current_session}/session.json
    │   → task 描述 + 开始时间
    │
    ├── runs/{current_session}/audit_blocks.jsonl
    │   → 所有 [AUDIT] 块（按时间排序）
    │   → 每个块包含：action, input, output, conclusions
    │
    └── 如果是 adhoc 会话且涉及用户修正：
        → 搜索 conclusions 和 assumptions 字段
        → 特别关注被否定的假设（这些最容易在压缩后重犯）
    │
    ▼
重建关键 context：
    1. 当前任务是什么？（session.json.task）
    2. 做了哪些操作？（audit_blocks 的 action 列表）
    3. 得出了什么结论？（audit_blocks 的 conclusions）
    4. 用户否定了什么？（审计记录中的修正历史 ⚠️ 最重要）
    5. 当前进度到哪了？（最后一个 audit_block 的 output）
```

**⚠️ 最危险的丢失：用户修正历史**

在所有可能丢失的 context 中，**用户的修正和否定**是最关键的。因为：

- 丢了执行状态 → 大不了重做
- 丢了分析结论 → 大不了重新分析
- **丢了用户修正 → 会重犯同样的错误，用户会极度不满**

Case #001 的教训：
- 用户说"Record audit 不是过度设计" → 如果 context 丢失，Claude 可能又建议"简化 Record audit"
- 用户说"API 漂移是臆测" → 如果 context 丢失，Claude 可能又断言"API 模型已更新"
- 用户说"今天正确不代表明天正确" → 如果 context 丢失，Claude 可能又假设"已通过 = 永远正确"

**这些修正必须被审计记录捕获，并在 context 恢复时优先加载。**

在审计记录中，用户修正应被标记为高优先级恢复项：

```json
{
    "record_type": "conversation",
    "action_type": "user_correction",
    "priority": "critical_for_recovery",
    "original_claim": "API 模型版本漂移是系统性风险",
    "correction": "这是臆测，数据不足以断言",
    "principle_extracted": "不要做任何猜测，除非有十足的把握",
    "persisted_to": ["CLAUDE.md 红线", "L1 Case#001 教训4"]
}
```

#### 第三层：深度恢复（跨多日/多 session 的历史查询）

**触发时机**：需要回溯历史数据、对比趋势、重新评估过去的决策
**目的**：恢复特定时间段或特定任务的完整上下文
**恢复来源**：`runs/index.json` → 定位具体 batch/adhoc → 加载 manifest + audit_trail

**使用场景**：

| 场景 | 查询方式 | 示例 |
|------|---------|------|
| "上次改 Prompt 是什么时候？改了什么？" | 搜索 audit_trail 中 step="change" + change_type="prompt" | → 定位到 Case #001 |
| "Category-A 错误率最近一周的趋势？" | 聚合最近 7 天 manifest 的 ai_classify.top_errors_by_category | → 生成趋势表 |
| "为什么 R1 的触发量突然增加了？" | 对比两天的 manifest.cleaning.per_rule_summary | → 发现输入数据分布变化 |
| "上次跑回归测试用的是什么参数？" | 搜索 audit_blocks 中 action 包含"回归测试" | → 找到 seed=42, 10000 条 |

### 9.4 恢复策略在 Skill 和 CLAUDE.md 中的实现

#### CLAUDE.md 中新增：Context 恢复规则

```markdown
## Context 恢复规则

### 新会话启动
每次新会话开始时，如果 runs/ 目录存在：
1. 读取 runs/index.json 和最新 daily report
2. 输出上下文恢复摘要（最近活动 + 待解决问题 + 今日优先级）
3. 确认用户工作方向

### Context 丢失检测
如果你发现自己：
- 无法回忆会话前期讨论的内容
- 不确定当前任务做到哪一步了
- 要提出一个方案但不确定是否已被用户否定过
则立即执行 context 恢复：
1. 读取当前 session 的 audit_blocks.jsonl
2. 优先恢复 user_correction 类型的记录（⚠️ 最重要）
3. 恢复后明确告知用户："我重新加载了审计记录，恢复了以下上下文..."

### 绝对禁止
- 不要在 context 丢失后"凭印象"继续工作
- 不要假装记得之前的内容
- 不要重复已被用户否定的判断——如果不确定，先查审计记录
```

#### /start Skill 中新增：自动 context 恢复

```
/start "今天的任务"

Skill 执行：
1. 创建新 session
2. 自动检查 runs/ 中的历史：
   ├── 有最新 daily report → 加载并摘要
   ├── 有未完成的 adhoc session → 提示用户是否继续
   └── 有未解决的 CRITICAL 告警 → 优先展示
3. 输出上下文恢复摘要
4. 进入工作状态
```

#### /recover Skill：手动触发 context 恢复

当 Claude 在 session 中途丢失 context 时，用户或 Claude 自身可以触发：

```
/recover

Skill 执行：
1. 读取当前 session 的所有审计记录
2. 按优先级排序恢复：
   ├── 🔴 用户修正（user_correction）— 最先恢复
   ├── 🟡 任务状态（最后的 audit_block）— 然后恢复
   ├── 🟢 分析结论（conclusions）— 最后恢复
   └── ⚪ 环境配置（environment snapshot）— 按需恢复
3. 输出恢复报告，标注"这些是从审计记录恢复的，不是从记忆中回忆的"
```

### 9.5 审计记录的"可恢复性"设计要求

为了让审计记录能有效充当 context 恢复的数据源，记录本身需要满足额外的设计要求：

#### 5.1 自包含性

每条审计记录必须**自包含**——仅凭该记录本身就能理解它的含义，不依赖"之前的对话上下文"。

| 反例（不自包含） | 正例（自包含） |
|----------------|--------------|
| action: "修改了那个文件" | action: "修改 docs/long_text_*.txt v1.0→v2.0，新增标签前缀约束 6 处" |
| output: "结论同上" | output: "结论：label prefix pollution 是根因，AI 把 'Category-B' 粘在 'Item-X' 前面" |
| conclusion: "用户同意了" | conclusion: "用户确认 Record-Level audit 不是过度设计，hashchain 是 Agent 间信任基础" |

#### 5.2 用户修正的显式标记

当用户纠正 Claude 的判断时，审计记录必须用 `action_type: "user_correction"` 显式标记，并记录：

```json
{
    "record_type": "conversation",
    "action_type": "user_correction",
    "priority": "critical_for_recovery",
    "original_claim": "Claude 的原始判断（被否定的）",
    "correction": "用户的修正内容",
    "principle_extracted": "从这次修正中提取的通用原则",
    "persisted_to": ["写入了哪些文件（CLAUDE.md / L1 / L2）"]
}
```

**这条记录在 context 恢复时必须最先被加载。**

#### 5.3 决策链的可重建性

对于多步骤决策（如"分析错误→修改 Prompt→验证→上线"），审计记录应包含决策之间的因果关系：

```json
{
    "action": "决定修改 Prompt v1.0→v2.0",
    "caused_by": "分析 error_samples.csv 发现 label prefix pollution 模式",
    "leads_to": "需要跑 ≥10,000 条回归测试验证",
    "depends_on": "v1.0 模板缺少'加前缀'示例（Case #001 根因）"
}
```

这样，即使 context 完全丢失，Claude 也能从审计记录中重建完整的决策链：
**为什么改 → 改了什么 → 怎么验证 → 结果如何 → 能否上线。**

### 9.6 Context 恢复的分级加载策略

恢复 context 时不应一次性加载所有审计记录（会占用太多新的 context），而应按需分级加载：

```
Level 0：索引摘要（~200 tokens）
    └── runs/index.json 最近 5 条 entry 的 id + task + status

Level 1：任务状态（~500 tokens）
    └── 当前/最近 session 的 session.json + 最后 3 条 audit_block 的 action + output

Level 2：决策上下文（~1,000 tokens）
    └── 所有 user_correction 记录
    └── 所有 conclusions 字段
    └── 最新 daily report 的 §四异常 + §六待办

Level 3：完整上下文（~3,000 tokens）
    └── 完整的 audit_blocks.jsonl
    └── 完整的 manifest.json
    └── 完整的 anomalies.json

Level 4：深度回溯（按需，可能 5,000+ tokens）
    └── 跨多日的 manifest 对比
    └── 完整的 audit_trail.jsonl（数据 Record 级别）
    └── 历史 daily reports
```

**加载策略**：

| 场景 | 加载级别 | 理由 |
|------|---------|------|
| 新 session 启动 | Level 0 + Level 2 的 user_corrections | 快速恢复关键 context，不浪费 tokens |
| Session 内 context 压缩 | Level 1 + Level 2 | 恢复当前任务状态和决策上下文 |
| 用户问"之前做了什么" | Level 2 + Level 3 | 完整回顾 |
| 用户问"上周的趋势" | Level 4 | 深度回溯，只在明确需要时加载 |
| /recover 手动触发 | Level 1 → Level 2 → 按需 Level 3 | 渐进式恢复 |

### 9.7 与晨间自我修正的协同

§8.5 的晨间自我修正机制和本节的 context 恢复机制是**同一个闭环的两个面**：

- **晨间修正**：Agent 主动回顾昨天的工作，发现问题，制定今日计划 → **面向未来**
- **Context 恢复**：Agent 在 context 丢失时回溯审计记录，重建工作状态 → **面向过去**

两者共享同一套审计数据源（`runs/`），但消费方式不同：

```
晨间修正（主动、定时、面向改进）：
    日报 → 趋势分析 → 问题识别 → 修正计划

Context 恢复（被动、按需、面向连续性）：
    审计记录 → 状态重建 → 决策恢复 → 继续工作
```

**在 cron 08:03 日报 + 08:05 晨间修正的基础上，新增：**

```
cron 08:07（晨间修正后 2 分钟）：
    检查是否有昨天未完成的 adhoc session（status != "completed"）
    如果有 → 生成恢复摘要，提示用户是否继续
```

### 9.8 实现清单

| 优先级 | 任务 | 产出 | 依赖 |
|--------|------|------|------|
| **P1** | CLAUDE.md 新增 Context 恢复规则 | CLAUDE.md 更新 | 无 |
| **P1** | /start Skill 内置 context 恢复 | 新 session 启动时自动加载历史 | runs/ + index.json |
| **P2** | /recover Skill | 手动触发 context 恢复 | audit_blocks.jsonl |
| **P2** | audit_blocks 新增 user_correction 标记 | [AUDIT] 格式扩展 | 无 |
| **P2** | audit_blocks 新增 caused_by / leads_to 因果链 | [AUDIT] 格式扩展 | 无 |
| **P3** | 分级加载策略实现 | context_recovery.py | AuditContext |

---

## 10. 存储结构扩展

在 L1 §8.5 基础上扩展，支持非结构化会话：

```
runs/
├── batch_20260319_0600/           # 结构化批次（Skill 产出）
│   ├── manifest.json
│   ├── audit_trail.jsonl
│   ├── audit_compact.jsonl
│   ├── anomalies.json
│   └── checksums.json
│
├── adhoc_20260319_1000/           # 非结构化会话（/start + /end 产出）
│   ├── session.json               # 会话元数据
│   ├── audit_blocks.jsonl         # [AUDIT] 块汇总
│   └── session_summary.md         # 会话总结
│
├── daily/                         # 日报 + 晨间修正（§8 产出）
│   ├── 20260319_daily.md          # 当日工作日报（cron 08:03 自动生成）
│   ├── 20260320_morning_review.md # 次日晨间修正报告（cron 08:05 自动生成）
│   └── ...
│
├── weekly/
│   └── 20260317_week.md
│
└── index.json                     # 所有批次+会话的索引
```

### index.json 格式

```json
{
    "entries": [
        {
            "id": "batch_20260319_0600",
            "type": "batch",
            "skill": "/pull + /clean + /report",
            "created": "2026-03-19T06:05:00Z",
            "status": "completed",
            "anomalies": 0
        },
        {
            "id": "adhoc_20260319_1000",
            "type": "adhoc",
            "task": "修复 Item-X 标签前缀错误",
            "created": "2026-03-19T10:00:00Z",
            "status": "completed",
            "audit_blocks": 3
        }
    ]
}
```

---

## 9. 可迭代性设计

### 10.1 审计结构版本化

```json
{
    "audit_schema_version": "1.0",
    "batch_id": "...",
    ...
}
```

每条审计记录和每个 manifest 都带 `audit_schema_version`。当审计结构演进时（如新增字段、修改格式），旧版记录仍可被正确解析。

### 10.2 向前兼容规则

| 场景 | 处理方式 |
|------|---------|
| 新版审计读旧版记录 | 缺失的新字段填 null，不报错 |
| 旧版工具读新版记录 | 忽略未知字段，不报错 |
| schema 版本跳跃 | 只要 batch_id 和 record_id 存在就可索引 |

### 9.3 审计框架自身的审计

每次修改审计框架本身（如新增字段、修改告警规则），需要：
1. 在 L1 §8 中更新审计结构定义
2. 更新 `audit_schema_version`
3. 在 L1 附录 D 中记录修改原因

---

## 10. 可扩展性设计

### 10.1 新增 Pipeline 节点

当新增一个 pipeline 节点（如新的清洗规则、新的筛选模型）时：

```
1. 在 AuditContext 中注册新节点
2. 为新节点定义 audit_entry 格式（遵循现有 schema）
3. 在 Skill 代码中调用 audit.record(entry)
4. hashchain 自动包含新节点的输入/输出
```

**不需要修改审计框架本身。** 这就是可扩展性。

### 10.2 新增 Skill

新 Skill 只需要：
1. 继承 `AuditContext` 的审计骨架
2. 在核心逻辑中插入 `audit.record()` 调用
3. 在 `finalize()` 时生成 manifest

模板：

```python
def new_skill(args):
    audit = AuditContext(skill_name="/new-skill")
    audit.snapshot_environment()
    audit.input_hash = compute_input_hash(args)

    # ... 核心逻辑 ...
    audit.record({"action": "...", "reason": "..."})

    manifest = audit.finalize()
    save_to_runs(manifest, audit.records)
```

---

## 11. 实施优先级

| 优先级 | 任务 | 产出 | 状态 |
|--------|------|------|------|
| **P0** | CLAUDE.md 中实施 [AUDIT] 格式规范 | CLAUDE.md 更新 | ✅ 已完成 |
| **P0** | 实现 AuditContext 基础类 | `audit_context.py` (350 行) | ✅ 已完成 |
| **P0** | 实现 3 个 Hooks（PostToolUse + Stop + UserPromptSubmit） | `~/.claude/audit-harness/hooks/` | ✅ 已完成 (v3.1.0) |
| **P0** | 全局 CLAUDE.md 审计规范注入 | `~/.claude/CLAUDE.md` | ✅ 已完成 (v3.1.0) |
| **P1** | 实现 /start + /end + /recover + /report-daily Skills | `~/.claude/skills/audit-*` | ✅ 已完成 (v3.2.0) |
| **P1** | Skills 审查修复（路径统一 + 握手协议 + 不可执行步骤） | 7 个 P0-P2 问题 | ✅ 已完成 (v3.2.0) |
| **P1** | install.sh 安装向导（全局+项目+智能模式） | `audit-harness/install.sh` | ✅ 已完成 (v2.1.0) |
| **P1** | 改造 /pull Skill 接入审计 | `download.py` 改造 | ⬜ 待实施 |
| **P1** | 改造 /clean Skill 接入审计 | `clean_data_v4.py` | ⬜ 待实施 |
| **P2** | 改造 /audit Skill 接入审计 | `filter_rules.py` 改造 | ⬜ 待实施 |
| **P2** | 实现晨间自我修正 cron | cron 08:03 日报 + 08:05 晨间回顾 | ⬜ 待实施 |
| **P3** | 实现 hashchain 校验 | AuditContext 扩展 | ⬜ 待实施 |

### 11.1 Skills 审查记录（2026-03-23）

对 4 个全局 Skills + 3 个 Hooks 执行了 skill-creator 审查，发现 7 个问题：

| # | 级别 | 问题 | 修复 |
|---|------|------|------|
| 1 | P0 | 路径不一致：Skills 写 `runs/`，Hooks 写 `.claude/runs/` | 全部统一为 `.claude/runs/` |
| 2 | P0 | /start 不写 `.current_session` → Stop hook 归档目标脱节 | 新增 `.current_session` 写入 + 解释握手协议 |
| 3 | P0 | /end "扫描对话历史"不可执行（Skill 无法访问对话历史） | 改为读取 hooks 产出的 `audit_buffer` + `audit_pending` + `audit_trail` |
| 4 | P0 | /report-daily 依赖不存在的 `manifest.json` | 重写数据源为 hooks 实际产出的文件 |
| 5 | P1 | 所有 description 触发范围太窄，Claude undertrigger | 增强触发词覆盖 |
| 6 | P2 | prompt_inject 无 session 时静默 | 新增：提示建议 `/start` |
| 7 | P2 | [AUDIT] 持久化命令缺 timestamp | 追加 ISO 8601 |

---

## 12. 关联文件

| 文件 | 类型 | 关系 |
|------|------|------|
| `docs/L1_platform_blueprint.md` §8 | L1 | 上游：审计架构定义 |
| `CLAUDE.md` 审计规范节 | Harness | 上游：[AUDIT] 格式定义 |
| `~/.claude/CLAUDE.md` | 全局 Harness | 上游：全局审计规范 |
| `audit_context.py` | 代码 | ✅ 已实现：审计基础类 |
| `~/.claude/skills/audit-start/` | Skill | ✅ 已实现：会话启动 + context 恢复 |
| `~/.claude/skills/audit-end/` | Skill | ✅ 已实现：会话结束 + 完整性检查 |
| `~/.claude/skills/audit-recover/` | Skill | ✅ 已实现：context 恢复 |
| `~/.claude/skills/audit-report-daily/` | Skill | ✅ 已实现：审计驱动日报 |
| `~/.claude/audit-harness/hooks/` | Hooks | ✅ 已实现：PostToolUse + Stop + UserPromptSubmit |
| `~/.claude/settings.json` | 配置 | ✅ 已配置：hooks 绑定 |
| `/path/to/audit-harness/` | 独立仓库 | ✅ v3.2.0：Plugin 源码 + install.sh |
| `docs/L2_task_20260319_brand_prefix.md` | L2 | 参考：Case #001 审计教训 |

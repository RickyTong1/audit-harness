"""
audit-harness | 审计执行保障基础模块（通用版）
==============================================
为 AI Agent 的 Skill 和 adhoc 操作提供统一的审计上下文，
包括 Record-Level 追踪、BatchManifest 生成、hashchain 校验、
异常检测、审计存储。

本模块是 audit-harness Plugin 的核心引擎。
项目专属配置（CORE_SCRIPTS、CORE_ASSETS、ALERT_RULES）通过外部传入或
audit_config.py 定义。

安装：将本文件复制到项目根目录，或 pip install audit-harness
使用：见 README.md
"""
from __future__ import annotations

import glob
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path

# ==========================================
# 配置
# ==========================================

AUDIT_SCHEMA_VERSION = "1.0"

PROJECT_ROOT = Path(__file__).parent
RUNS_DIR = PROJECT_ROOT / "runs"

# ==========================================
# 项目专属配置（可通过 audit_config.py 覆盖）
# 如果项目根目录存在 audit_config.py，自动加载其中的配置。
# 否则使用以下默认值（空列表 = 不做环境快照的脚本/资产哈希）。
# ==========================================

CORE_SCRIPTS: list[str] = []
CORE_ASSETS: list[str] = []
PROMPT_TEMPLATE_GLOB: str = ""

# 尝试加载项目专属配置
try:
    from audit_config import (  # type: ignore
        CORE_SCRIPTS as _cs,
        CORE_ASSETS as _ca,
        PROMPT_TEMPLATE_GLOB as _ptg,
    )
    CORE_SCRIPTS = _cs
    CORE_ASSETS = _ca
    PROMPT_TEMPLATE_GLOB = _ptg
except ImportError:
    pass  # 没有 audit_config.py，使用默认空值

# 告警规则（项目专属，通过 audit_config.py 定义）
# 默认只包含一条通用规则：输出完整性校验
ALERT_RULES: list[dict] = [
    {
        "id": "output_integrity",
        "condition": lambda m: (
            m.get("output", {}).get("total_records") is not None
            and m.get("cleaning", {}).get("total_input") is not None
            and m.get("cleaning", {}).get("total_deleted") is not None
            and m["output"]["total_records"]
            != m["cleaning"]["total_input"] - m["cleaning"]["total_deleted"]
        ),
        "level": "CRITICAL",
        "message": "输出记录数 ≠ 输入 - 删除，存在数据丢失",
    },
]

# 尝试加载项目专属告警规则
try:
    from audit_config import ALERT_RULES as _ar  # type: ignore
    ALERT_RULES = _ar
except ImportError:
    pass


# ==========================================
# 工具函数
# ==========================================

def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _safe_div(a, b):
    return a / b if b else 0


def hash_file(path: str | Path) -> str | None:
    """计算文件的 SHA256 哈希。文件不存在返回 None。"""
    p = PROJECT_ROOT / path if not Path(path).is_absolute() else Path(path)
    if not p.exists():
        return None
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def hash_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def hash_dir(dir_path: str | Path, pattern: str = "*.jsonl") -> str | None:
    """对目录下所有匹配文件按名称排序后计算联合哈希。"""
    p = PROJECT_ROOT / dir_path if not Path(dir_path).is_absolute() else Path(dir_path)
    if not p.is_dir():
        return None
    files = sorted(p.glob(pattern))
    if not files:
        return None
    h = hashlib.sha256()
    for f in files:
        h.update(f.name.encode())
        with open(f, "rb") as fh:
            for chunk in iter(lambda: fh.read(8192), b""):
                h.update(chunk)
    return h.hexdigest()


def _find_prompt_template() -> str | None:
    """查找当前 prompt 模板文件路径。"""
    if not PROMPT_TEMPLATE_GLOB:
        return None
    matches = list(PROJECT_ROOT.glob(PROMPT_TEMPLATE_GLOB))
    return str(matches[0].relative_to(PROJECT_ROOT)) if matches else None


# ==========================================
# RecordAudit: 单条记录的审计条目
# ==========================================

class RecordEntry:
    """单条 Record-Level 审计条目。

    用于追踪一条数据在某个处理步骤中的变化。
    """

    __slots__ = ("record_id", "step", "rule", "action", "reason",
                 "before", "after", "timestamp", "extra")

    def __init__(
        self,
        record_id: str,
        step: str,
        rule: str,
        action: str,
        reason: str,
        before: dict | None = None,
        after: dict | None = None,
        **extra,
    ):
        self.record_id = record_id
        self.step = step          # "pull" | "clean" | "ai_classify" | "screen" | "export"
        self.rule = rule          # 如 "Rule1_词频删除"
        self.action = action      # "keep" | "delete" | "modify" | "flag"
        self.reason = reason      # 人类可读原因
        self.before = before or {}
        self.after = after or {}
        self.timestamp = _now_iso()
        self.extra = extra

    def to_dict(self) -> dict:
        d = {
            "record_id": self.record_id,
            "step": self.step,
            "rule": self.rule,
            "action": self.action,
            "reason": self.reason,
            "before": self.before,
            "after": self.after,
            "timestamp": self.timestamp,
        }
        if self.extra:
            d.update(self.extra)
        return d


# ==========================================
# CompactRecord: 正确样本的压缩审计行
# ==========================================

class CompactRecord:
    """正确样本的压缩审计行（~120 字节/条）。"""

    __slots__ = ("record_id", "batch_id", "rule_hits", "disposition", "xgb_score")

    def __init__(
        self,
        record_id: str,
        batch_id: str,
        rule_hits: str,
        disposition: str,
        xgb_score: float | None = None,
    ):
        self.record_id = record_id
        self.batch_id = batch_id
        self.rule_hits = rule_hits      # "0/0/0/0/0/0/0/0/0" 各规则触发标记
        self.disposition = disposition  # "ai_accepted" | "human_review"
        self.xgb_score = xgb_score

    def to_line(self) -> str:
        d = {
            "id": self.record_id,
            "batch": self.batch_id,
            "rules": self.rule_hits,
            "disp": self.disposition,
        }
        if self.xgb_score is not None:
            d["xgb"] = round(self.xgb_score, 4)
        return json.dumps(d, ensure_ascii=False)


# ==========================================
# HashchainError
# ==========================================

class HashchainBroken(Exception):
    """上下游 Skill 之间的 hashchain 校验失败。"""

    def __init__(self, expected: str, actual: str, context: str = ""):
        self.expected = expected
        self.actual = actual
        self.context = context
        super().__init__(
            f"Hashchain 断裂{(' (' + context + ')') if context else ''}。"
            f"期望: {expected[:16]}..., 实际: {actual[:16]}..."
        )


# ==========================================
# AuditContext: 核心审计上下文
# ==========================================

class AuditContext:
    """Skill 或 adhoc 操作的审计上下文。

    使用方式:
        audit = AuditContext("/clean")
        audit.snapshot_environment()
        audit.set_input_hash(hash_dir("data_export"))

        # 核心逻辑中调用 audit.record(...)
        audit.record(RecordEntry(
            record_id="abc123",
            step="clean",
            rule="Rule1_词频删除",
            action="delete",
            reason="标题命中关键词'五菱星光'"
        ))

        # 正确样本用压缩格式
        audit.record_compact(CompactRecord(
            record_id="def456",
            batch_id=audit.batch_id,
            rule_hits="0/0/0/0/0/0/0/0/0",
            disposition="ai_accepted",
            xgb_score=0.023,
        ))

        manifest = audit.finalize()
        audit.save()
    """

    def __init__(
        self,
        skill_name: str,
        batch_id: str | None = None,
        batch_type: str = "batch",
    ):
        self.skill_name = skill_name
        self.batch_type = batch_type  # "batch" | "adhoc"
        self.batch_id = batch_id or self._gen_batch_id()
        self.start_time = _now_iso()
        self.environment: dict = {}
        self.input_hash: str | None = None
        self.output_hash: str | None = None
        self.manifest: dict = {}

        # 审计记录
        self._full_records: list[dict] = []
        self._compact_lines: list[str] = []

        # manifest 附加数据 (由调用方填充)
        self.extra_manifest: dict = {}

        # 确保 runs 目录存在
        self._runs_dir = RUNS_DIR / self.batch_id
        self._runs_dir.mkdir(parents=True, exist_ok=True)

    def _gen_batch_id(self) -> str:
        prefix = "adhoc" if self.batch_type == "adhoc" else "batch"
        return f"{prefix}_{datetime.now().strftime('%Y%m%d_%H%M')}"

    # ---------- 环境快照 ----------

    def snapshot_environment(self):
        """快照当前环境配置：规则版本、模型哈希、脚本哈希。"""
        prompt_path = _find_prompt_template()
        self.environment = {
            "audit_schema_version": AUDIT_SCHEMA_VERSION,
            "snapshot_time": _now_iso(),
            "prompt_template": prompt_path,
            "prompt_template_hash": hash_file(prompt_path) if prompt_path else None,
            "core_script_hashes": {
                s: hash_file(s) for s in CORE_SCRIPTS
            },
            "core_asset_hashes": {
                a: hash_file(a) for a in CORE_ASSETS
            },
        }

    # ---------- 输入/输出哈希 ----------

    def set_input_hash(self, h: str | None):
        self.input_hash = h

    def set_output_hash(self, h: str | None):
        self.output_hash = h

    # ---------- 记录追踪 ----------

    def record(self, entry: RecordEntry | dict):
        """追加一条完整的 Record-Level 审计条目。"""
        if isinstance(entry, RecordEntry):
            self._full_records.append(entry.to_dict())
        else:
            if "timestamp" not in entry:
                entry["timestamp"] = _now_iso()
            entry.setdefault("skill", self.skill_name)
            self._full_records.append(entry)

    def record_compact(self, compact: CompactRecord | str):
        """追加一条压缩审计行（正确样本）。"""
        if isinstance(compact, CompactRecord):
            self._compact_lines.append(compact.to_line())
        else:
            self._compact_lines.append(compact)

    @property
    def full_record_count(self) -> int:
        return len(self._full_records)

    @property
    def compact_record_count(self) -> int:
        return len(self._compact_lines)

    @property
    def total_record_count(self) -> int:
        return self.full_record_count + self.compact_record_count

    # ---------- Hashchain 校验 ----------

    def verify_input_hashchain(self, previous_batch_id: str | None = None):
        """校验输入数据的 hashchain 是否与上游 Skill 的输出一致。

        Args:
            previous_batch_id: 上游 batch 的 ID。如果为 None，尝试自动找最近的 batch。

        Raises:
            HashchainBroken: hashchain 不一致
        """
        if self.input_hash is None:
            return  # 无输入哈希则跳过校验

        prev_manifest = self._load_previous_manifest(previous_batch_id)
        if prev_manifest is None:
            return  # 无上游 manifest 则跳过

        expected = prev_manifest.get("output_hash")
        if expected is None:
            return  # 上游没记录输出哈希

        if expected != self.input_hash:
            raise HashchainBroken(
                expected=expected,
                actual=self.input_hash,
                context=f"上游 batch={prev_manifest.get('batch_id', '?')} → 当前 skill={self.skill_name}",
            )

    def _load_previous_manifest(self, batch_id: str | None = None) -> dict | None:
        """加载上一个 batch 的 manifest。"""
        if batch_id:
            p = RUNS_DIR / batch_id / "manifest.json"
            if p.exists():
                with open(p) as f:
                    return json.load(f)
            return None

        # 自动查找最近的 batch manifest
        index_path = RUNS_DIR / "index.json"
        if not index_path.exists():
            return None
        with open(index_path) as f:
            index = json.load(f)
        entries = index.get("entries", [])
        # 找到最近的、已完成的、类型为 batch 的
        batch_entries = [
            e for e in entries
            if e.get("type") == "batch" and e.get("status") == "completed"
        ]
        if not batch_entries:
            return None
        latest = max(batch_entries, key=lambda e: e.get("created", ""))
        p = RUNS_DIR / latest["id"] / "manifest.json"
        if p.exists():
            with open(p) as f:
                return json.load(f)
        return None

    # ---------- 异常检测 ----------

    def check_anomalies(self, manifest: dict | None = None) -> list[dict]:
        """基于 ALERT_RULES 检测异常。"""
        m = manifest or self.manifest
        anomalies = []
        for rule in ALERT_RULES:
            try:
                if rule["condition"](m):
                    anomalies.append({
                        "rule_id": rule["id"],
                        "level": rule["level"],
                        "message": rule["message"],
                        "detected_at": _now_iso(),
                    })
            except Exception:
                pass  # 条件计算出错时跳过该规则
        return anomalies

    # ---------- 对比上一批次 ----------

    def diff_from_previous(self, previous_batch_id: str | None = None) -> dict:
        """计算当前 manifest 与上一批次的差异。"""
        prev = self._load_previous_manifest(previous_batch_id)
        if prev is None:
            return {"previous_batch": None, "note": "无上一批次数据"}

        def _pct_change(curr, prev_val):
            if prev_val is None or prev_val == 0:
                return None
            if curr is None:
                return None
            return f"{(curr - prev_val) / prev_val * 100:+.1f}%"

        def _pp_change(curr, prev_val):
            if curr is None or prev_val is None:
                return None
            return f"{(curr - prev_val) * 100:+.1f}pp"

        m = self.manifest
        p_input = prev.get("input", {})
        c_input = m.get("input", {})

        return {
            "previous_batch": prev.get("batch_id"),
            "volume_change": _pct_change(
                c_input.get("records_pulled"),
                p_input.get("records_pulled"),
            ),
            "prompt2_empty_rate_change": _pp_change(
                c_input.get("prompt2_empty_rate"),
                p_input.get("prompt2_empty_rate"),
            ),
        }

    # ---------- Finalize ----------

    def finalize(self, **extra) -> dict:
        """生成 BatchManifest。

        调用方可以在 finalize 前通过 self.extra_manifest 填充额外字段
        （如 input、cleaning、ai_classify、screening、output 等摘要）。
        """
        self.extra_manifest.update(extra)

        self.manifest = {
            "audit_schema_version": AUDIT_SCHEMA_VERSION,
            "batch_id": self.batch_id,
            "batch_type": self.batch_type,
            "skill": self.skill_name,
            "start_time": self.start_time,
            "end_time": _now_iso(),
            "environment": self.environment,
            "input_hash": self.input_hash,
            "output_hash": self.output_hash,
            "record_count": {
                "full": self.full_record_count,
                "compact": self.compact_record_count,
                "total": self.total_record_count,
            },
        }
        self.manifest.update(self.extra_manifest)

        # 自签名
        manifest_bytes = json.dumps(self.manifest, ensure_ascii=False, sort_keys=True).encode()
        self.manifest["manifest_hash"] = hash_bytes(manifest_bytes)

        return self.manifest

    # ---------- 持久化 ----------

    def save(self):
        """将审计数据保存到 runs/{batch_id}/ 目录。"""
        self._runs_dir.mkdir(parents=True, exist_ok=True)

        # manifest.json
        with open(self._runs_dir / "manifest.json", "w") as f:
            json.dump(self.manifest, f, ensure_ascii=False, indent=2)

        # audit_trail.jsonl (完整审计条目)
        if self._full_records:
            with open(self._runs_dir / "audit_trail.jsonl", "w") as f:
                for rec in self._full_records:
                    f.write(json.dumps(rec, ensure_ascii=False) + "\n")

        # audit_compact.jsonl (压缩审计行)
        if self._compact_lines:
            with open(self._runs_dir / "audit_compact.jsonl", "w") as f:
                for line in self._compact_lines:
                    f.write(line + "\n")

        # anomalies.json
        anomalies = self.check_anomalies()
        with open(self._runs_dir / "anomalies.json", "w") as f:
            json.dump(anomalies, f, ensure_ascii=False, indent=2)

        # checksums.json
        checksums = {}
        for p in self._runs_dir.iterdir():
            if p.name != "checksums.json" and p.is_file():
                checksums[p.name] = hash_file(p)
        with open(self._runs_dir / "checksums.json", "w") as f:
            json.dump(checksums, f, ensure_ascii=False, indent=2)

        # 更新 index.json
        self._update_index()

        return self._runs_dir

    def _update_index(self):
        """更新 runs/index.json 索引。"""
        index_path = RUNS_DIR / "index.json"
        if index_path.exists():
            with open(index_path) as f:
                index = json.load(f)
        else:
            index = {"entries": []}

        # 删除同 batch_id 的旧条目
        index["entries"] = [
            e for e in index["entries"] if e.get("id") != self.batch_id
        ]

        # 追加新条目
        entry = {
            "id": self.batch_id,
            "type": self.batch_type,
            "skill": self.skill_name,
            "created": self.start_time,
            "status": "completed",
            "record_count": self.total_record_count,
        }
        anomalies = self.check_anomalies()
        if anomalies:
            entry["anomaly_count"] = len(anomalies)
            entry["max_anomaly_level"] = max(
                a["level"] for a in anomalies
            )
        index["entries"].append(entry)

        with open(index_path, "w") as f:
            json.dump(index, f, ensure_ascii=False, indent=2)


# ==========================================
# 便捷工厂函数
# ==========================================

def create_batch_context(skill_name: str, batch_id: str | None = None) -> AuditContext:
    """创建一个结构化批次的审计上下文。"""
    ctx = AuditContext(skill_name, batch_id, batch_type="batch")
    ctx.snapshot_environment()
    return ctx


def create_adhoc_context(task_description: str) -> AuditContext:
    """创建一个非结构化会话的审计上下文。"""
    ctx = AuditContext(
        skill_name=f"adhoc: {task_description}",
        batch_type="adhoc",
    )
    ctx.snapshot_environment()
    return ctx

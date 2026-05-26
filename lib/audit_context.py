"""
L3 | 审计执行保障基础模块
用途：为所有 Skill 和 adhoc 操作提供统一的审计上下文（AuditContext），
     包括 Record-Level 追踪、BatchManifest 生成、异常检测、审计存储、
     index.json 统一 schema 维护。

输入：任何 Skill 或 adhoc 操作的执行上下文
输出：.claude/runs/{batch_id}/ 下的 manifest.json, audit_trail.jsonl, anomalies.json
关联：
  - docs/L2_audit_enforcement_design.md  审计模块详细设计
  - templates/audit_config.example.py    项目配置模板（业务规则、关键脚本）
  - templates/CLAUDE.md.audit-section    [AUDIT] 格式规范
  - hooks/                               PostToolUse / Stop / UserPromptSubmit
                                         通过 update_index_entry() 与 lib 共享 schema
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# ==========================================
# 版本
# ==========================================

AUDIT_SCHEMA_VERSION = "1.1"
INDEX_SCHEMA_VERSION = "1.1"


# ==========================================
# 路径解析（运行时定位，lib 与 hooks 共享）
# ==========================================

def find_runs_dir(start: Path | str | None = None) -> Path:
    """从给定目录（默认 CWD）上溯，查找最近的 ``{platform}/runs/``。

    平台目录名按以下优先级解析：
      1. 环境变量 ``AUDIT_DOT_DIR``（显式指定，如 ``.claude`` 或 ``.codex``）
      2. 上溯路径中第一个存在的 ``.claude/runs`` 或 ``.codex/runs``
      3. 找不到时，默认创建 ``CWD/.claude/runs``

    这与 hooks ``${PWD}/${AUDIT_DOT_DIR:-.claude}/runs`` 的行为保持一致，
    确保 lib 与 hooks 在同一项目目录下永远写到同一份审计数据。
    """
    cur = (Path(start) if start else Path.cwd()).resolve()
    explicit = os.environ.get("AUDIT_DOT_DIR", "").strip()
    candidates_basename = [explicit] if explicit else [".claude", ".codex"]

    for p in [cur, *cur.parents]:
        for basename in candidates_basename:
            candidate = p / basename / "runs"
            if candidate.is_dir():
                return candidate
    default_basename = explicit or ".claude"
    return cur / default_basename / "runs"


def find_project_root(start: Path | str | None = None) -> Path:
    """``find_runs_dir`` 的祖父目录。"""
    return find_runs_dir(start).parent.parent


# ==========================================
# 项目配置加载（audit_config.py）
# ==========================================

# 默认值——项目可通过 audit_config.py 覆盖（见 templates/audit_config.example.py）
CORE_SCRIPTS: list[str] = []
CORE_ASSETS: list[str] = []
PROMPT_TEMPLATE_GLOB: str = ""
ALERT_RULES: list[dict] = []


def _load_project_config(start: Path | str | None = None) -> Path | None:
    """加载 ``audit_config.py``，覆盖模块级默认值。

    查找顺序：
      1. ``<project_root>/.claude/audit_config.py``
      2. ``<project_root>/audit_config.py``

    返回成功加载的文件路径，未加载则返回 ``None``。
    """
    global CORE_SCRIPTS, CORE_ASSETS, PROMPT_TEMPLATE_GLOB, ALERT_RULES

    root = find_project_root(start)
    candidates = [
        root / ".claude" / "audit_config.py",
        root / "audit_config.py",
    ]

    for cfg_path in candidates:
        if not cfg_path.is_file():
            continue
        try:
            spec = importlib.util.spec_from_file_location("audit_config", cfg_path)
            if spec is None or spec.loader is None:
                continue
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)

            CORE_SCRIPTS = list(getattr(mod, "CORE_SCRIPTS", CORE_SCRIPTS))
            CORE_ASSETS = list(getattr(mod, "CORE_ASSETS", CORE_ASSETS))
            PROMPT_TEMPLATE_GLOB = str(getattr(mod, "PROMPT_TEMPLATE_GLOB", PROMPT_TEMPLATE_GLOB))
            ALERT_RULES = list(getattr(mod, "ALERT_RULES", ALERT_RULES))
            return cfg_path
        except Exception as e:
            print(f"[audit_context] warning: failed to load {cfg_path}: {e}",
                  file=sys.stderr)
            continue
    return None


_load_project_config()


# ==========================================
# 工具函数
# ==========================================

def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _safe_div(a, b):
    return a / b if b else 0


def _resolve(path: str | Path) -> Path:
    p = Path(path)
    return p if p.is_absolute() else find_project_root() / p


def hash_file(path: str | Path) -> str | None:
    """计算文件 SHA256；不存在返回 None。"""
    p = _resolve(path)
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
    """对目录下匹配文件按名称排序后计算联合哈希。

    使用 NUL 分隔符区分文件名与内容、不同文件之间，
    避免 ``name1+content1+name2`` 与 ``name1+content1name2`` 产生同哈希的
    拼接歧义。
    """
    p = _resolve(dir_path)
    if not p.is_dir():
        return None
    files = sorted(p.glob(pattern))
    if not files:
        return None
    h = hashlib.sha256()
    for f in files:
        h.update(b"\x00FILE\x00")
        h.update(f.name.encode("utf-8"))
        h.update(b"\x00DATA\x00")
        with open(f, "rb") as fh:
            for chunk in iter(lambda: fh.read(8192), b""):
                h.update(chunk)
        h.update(b"\x00END\x00")
    return h.hexdigest()


def _find_prompt_template() -> str | None:
    if not PROMPT_TEMPLATE_GLOB:
        return None
    root = find_project_root()
    matches = list(root.glob(PROMPT_TEMPLATE_GLOB))
    return str(matches[0].relative_to(root)) if matches else None


# ==========================================
# Index Schema（lib 与 hooks 共享）
# ==========================================

# 一条 entry 的合法字段。hooks 通过 update_index_entry() 写入，
# 必须遵守这套 schema，避免 hooks 与 lib 写出两套不兼容的数据。
INDEX_ENTRY_REQUIRED = ("id", "type", "status")
INDEX_ENTRY_OPTIONAL = (
    "task", "skill", "created", "last_updated",
    "record_count", "anomaly_count", "max_anomaly_level",
)


def update_index_entry(runs_dir: str | Path, entry: dict) -> Path:
    """在 ``runs_dir/index.json`` 中 upsert 一条 entry。

    - 同 id 已存在 → 合并字段（新值覆盖、未提供字段保留）
    - 不存在 → 追加
    - 原子写入（先写 .tmp 再 rename）

    Returns:
        index.json 文件路径
    """
    runs_dir = Path(runs_dir)
    runs_dir.mkdir(parents=True, exist_ok=True)
    index_path = runs_dir / "index.json"

    if "id" not in entry:
        raise ValueError("index entry must have 'id' field")

    if index_path.exists():
        try:
            with open(index_path, encoding="utf-8") as f:
                idx = json.load(f)
        except Exception:
            idx = {}
    else:
        idx = {}

    idx.setdefault("schema_version", INDEX_SCHEMA_VERSION)
    idx.setdefault("entries", [])

    found = False
    for e in idx["entries"]:
        if e.get("id") == entry["id"]:
            e.update(entry)
            found = True
            break
    if not found:
        missing = [k for k in INDEX_ENTRY_REQUIRED if k not in entry]
        if missing:
            raise ValueError(f"new index entry missing required fields: {missing}")
        idx["entries"].append(dict(entry))

    tmp = index_path.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(idx, f, ensure_ascii=False, indent=2)
    os.replace(tmp, index_path)
    return index_path


# ==========================================
# RecordEntry: 单条记录的审计条目
# ==========================================

class RecordEntry:
    """单条 Record-Level 审计条目。"""

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
        self.rule = rule
        self.action = action      # "keep" | "delete" | "modify" | "flag"
        self.reason = reason
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
# CompactRecord: 压缩审计行（正确样本）
# ==========================================

class CompactRecord:
    """正确样本的压缩审计行（~120 字节/条）。"""

    __slots__ = ("record_id", "batch_id", "rule_hits", "disposition", "score")

    def __init__(
        self,
        record_id: str,
        batch_id: str,
        rule_hits: str,
        disposition: str,
        score: float | None = None,
    ):
        self.record_id = record_id
        self.batch_id = batch_id
        self.rule_hits = rule_hits
        self.disposition = disposition
        self.score = score

    def to_line(self) -> str:
        d = {
            "id": self.record_id,
            "batch": self.batch_id,
            "rules": self.rule_hits,
            "disp": self.disposition,
        }
        if self.score is not None:
            d["score"] = round(self.score, 4)
        return json.dumps(d, ensure_ascii=False)


# ==========================================
# AuditContext: 核心审计上下文
# ==========================================

class AuditContext:
    """Skill 或 adhoc 操作的审计上下文。

    使用方式::

        audit = create_batch_context("/clean")
        audit.set_input_hash(hash_dir("data_export"))
        audit.record(RecordEntry(record_id="abc123", step="clean",
                                 rule="freq_filter", action="delete",
                                 reason="title 命中关键词"))
        audit.finalize()
        audit.save()
    """

    def __init__(
        self,
        skill_name: str,
        batch_id: str | None = None,
        batch_type: str = "batch",
    ):
        self.skill_name = skill_name
        self.batch_type = batch_type
        self.batch_id = batch_id or self._gen_batch_id()
        self.start_time = _now_iso()
        self.environment: dict = {}
        self.input_hash: str | None = None
        self.output_hash: str | None = None
        self.manifest: dict = {}

        self._full_records: list[dict] = []
        self._compact_lines: list[str] = []
        self.extra_manifest: dict = {}

        self._runs_dir = find_runs_dir()
        self._session_dir = self._runs_dir / self.batch_id
        self._session_dir.mkdir(parents=True, exist_ok=True)

    @property
    def runs_dir(self) -> Path:
        return self._runs_dir

    @property
    def session_dir(self) -> Path:
        return self._session_dir

    def _gen_batch_id(self) -> str:
        prefix = "adhoc" if self.batch_type == "adhoc" else "batch"
        return f"{prefix}_{datetime.now().strftime('%Y%m%d_%H%M')}"

    # ---------- 环境快照 ----------

    def snapshot_environment(self):
        """快照规则版本、模型哈希、脚本哈希、prompt 模板。"""
        prompt_path = _find_prompt_template()
        self.environment = {
            "audit_schema_version": AUDIT_SCHEMA_VERSION,
            "snapshot_time": _now_iso(),
            "prompt_template": prompt_path,
            "prompt_template_hash": hash_file(prompt_path) if prompt_path else None,
            "core_script_hashes": {s: hash_file(s) for s in CORE_SCRIPTS},
            "core_asset_hashes": {a: hash_file(a) for a in CORE_ASSETS},
        }

    # ---------- 输入/输出哈希 ----------

    def set_input_hash(self, h: str | None):
        self.input_hash = h

    def set_output_hash(self, h: str | None):
        self.output_hash = h

    # ---------- 记录追踪 ----------

    def record(self, entry: RecordEntry | dict):
        if isinstance(entry, RecordEntry):
            self._full_records.append(entry.to_dict())
        else:
            if "timestamp" not in entry:
                entry["timestamp"] = _now_iso()
            entry.setdefault("skill", self.skill_name)
            self._full_records.append(entry)

    def record_compact(self, compact: CompactRecord | str):
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

    # ---------- 异常检测 ----------

    def check_anomalies(self, manifest: dict | None = None) -> list[dict]:
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
                continue
        return anomalies

    # ---------- Finalize ----------

    def finalize(self, **extra) -> dict:
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
        manifest_bytes = json.dumps(
            self.manifest, ensure_ascii=False, sort_keys=True
        ).encode("utf-8")
        self.manifest["manifest_hash"] = hash_bytes(manifest_bytes)
        return self.manifest

    # ---------- 持久化 ----------

    def save(self) -> Path:
        """将审计数据保存到 ``runs/{batch_id}/`` 并更新 index.json。"""
        self._session_dir.mkdir(parents=True, exist_ok=True)

        with open(self._session_dir / "manifest.json", "w", encoding="utf-8") as f:
            json.dump(self.manifest, f, ensure_ascii=False, indent=2)

        if self._full_records:
            with open(self._session_dir / "audit_trail.jsonl", "a", encoding="utf-8") as f:
                for rec in self._full_records:
                    f.write(json.dumps(rec, ensure_ascii=False) + "\n")

        if self._compact_lines:
            with open(self._session_dir / "audit_compact.jsonl", "a", encoding="utf-8") as f:
                for line in self._compact_lines:
                    f.write(line + "\n")

        anomalies = self.check_anomalies()
        with open(self._session_dir / "anomalies.json", "w", encoding="utf-8") as f:
            json.dump(anomalies, f, ensure_ascii=False, indent=2)

        checksums = {}
        for p in self._session_dir.iterdir():
            if p.name != "checksums.json" and p.is_file():
                checksums[p.name] = hash_file(p)
        with open(self._session_dir / "checksums.json", "w", encoding="utf-8") as f:
            json.dump(checksums, f, ensure_ascii=False, indent=2)

        entry = {
            "id": self.batch_id,
            "type": self.batch_type,
            "skill": self.skill_name,
            "created": self.start_time,
            "last_updated": _now_iso(),
            "status": "completed",
            "record_count": self.total_record_count,
        }
        if anomalies:
            entry["anomaly_count"] = len(anomalies)
            entry["max_anomaly_level"] = max(a["level"] for a in anomalies)
        update_index_entry(self._runs_dir, entry)

        return self._session_dir


# ==========================================
# 便捷工厂
# ==========================================

def create_batch_context(skill_name: str, batch_id: str | None = None) -> AuditContext:
    ctx = AuditContext(skill_name, batch_id, batch_type="batch")
    ctx.snapshot_environment()
    return ctx


def create_adhoc_context(task_description: str) -> AuditContext:
    ctx = AuditContext(
        skill_name=f"adhoc: {task_description}",
        batch_type="adhoc",
    )
    ctx.snapshot_environment()
    return ctx


# ==========================================
# CLI（供 hooks 调用，避免在 shell 中拼 python 源码）
# ==========================================

def _cli_update_index(argv: list[str]) -> int:
    """命令行入口：``python3 audit_context.py update-index --runs-dir X --id Y ...``

    所有 ``--key value`` 对会被收集为 entry 字段。``--record-count`` 会
    自动转为 int。这样 hooks 不需要在 shell 中嵌入 Python 源码就能写
    index.json，彻底消除变量注入风险。
    """
    runs_dir = None
    entry: dict = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--runs-dir":
            runs_dir = argv[i + 1]
            i += 2
        elif a.startswith("--"):
            key = a[2:].replace("-", "_")
            val = argv[i + 1] if i + 1 < len(argv) else ""
            if key in ("record_count", "anomaly_count"):
                try:
                    val = int(val)
                except ValueError:
                    val = 0
            entry[key] = val
            i += 2
        else:
            i += 1

    if not runs_dir:
        runs_dir = str(find_runs_dir())
    update_index_entry(runs_dir, entry)
    print(runs_dir)
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:]) if argv is None else argv
    if not argv:
        print("usage: audit_context.py <command> [args]", file=sys.stderr)
        print("  commands: update-index, find-runs-dir", file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "update-index":
        return _cli_update_index(rest)
    if cmd == "find-runs-dir":
        print(str(find_runs_dir()))
        return 0
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

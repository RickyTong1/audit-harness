# audit-harness

**[中文文档](README_zh.md)** | English

> Audit enforcement framework for AI Agents: three-layer defense, context recovery, audit-driven daily reports, and self-correction loops.

## What Problem Does This Solve?

1. **Agents don't follow audit rules** — Telling Claude "remember to write audit records" in CLAUDE.md doesn't work. This framework turns audit from a "suggestion" into a "format constraint" using three defense layers.

2. **Context loss causes repeated mistakes** — LLM context windows get compressed/truncated. Audit records serve as the agent's external persistent memory, recovering work state and user corrections when context is lost.

3. **Audit data sits unread** — Audit data only has value when consumed. Auto-generated daily reports + morning self-correction loops keep the system continuously improving.

## Quick Start

```bash
# One command to install globally
cd /your/project
bash /path/to/audit-harness/install.sh

# First run: auto global install + project init
# Subsequent projects: auto project init only
# No arguments needed
```

After install, start using immediately:

```
/start "your task description"
... work (every Write/Edit/Bash auto-captured by hooks) ...
/end
```

## What Gets Installed

### Global (`~/.claude/`, shared across all projects)

| Component | Path | Purpose |
|-----------|------|---------|
| Core engine | `~/.claude/audit-harness/audit_context.py` | AuditContext, RecordEntry, hashchain |
| Hooks ×3 | `~/.claude/audit-harness/hooks/` | Auto-capture tool operations |
| Skills ×4 | `~/.claude/skills/audit-*` | /start, /end, /recover, /report-daily |
| Audit rules | `~/.claude/CLAUDE.md` | [AUDIT] format + context recovery rules |
| Hook config | `~/.claude/settings.json` | Hook bindings |

### Per-project (`$PROJECT/.claude/`, project-specific)

| Component | Path | Purpose |
|-----------|------|---------|
| Config | `.claude/audit_config.py` | Project alert rules, core scripts list |
| Audit data | `.claude/runs/` | Auto-created by hooks, stores all audit records |

## Architecture

### Three-Layer Defense

```
Layer 1: Skill hardcode (100% reliable)
  → /start, /end embed audit logic in code
  → Hashchain verification between Skills

Layer 2: [AUDIT] output format constraint (~90% reliable)
  → CLAUDE.md mandates [AUDIT] blocks in responses
  → Format constraint > behavioral suggestion

Layer 3: /start + /end session wrapper (fallback detection)
  → /end checks audit completeness
  → Alerts on missing records
```

### Context Recovery

```
New session start → /start auto-loads historical audit records
In-session compression → Claude proactively calls /recover
Cross-session break → Next /start recovers context

Recovery priority:
  🔴 User corrections (user_correction) — recovered first
  🟡 Task state — what step are we on
  🟢 Conclusions — what was decided
  ⚪ Environment config — which rules/models version
```

### Three Hooks

| Hook | Trigger | Action | Depends on Claude? |
|------|---------|--------|-------------------|
| **PostToolUse** | After every Write/Edit/Bash | Auto-record to audit_buffer | **No** (fully automatic) |
| **Stop** | After each response turn | Archive buffer → session audit file + update index.json | **No** (fully automatic) |
| **UserPromptSubmit** | Each user input | Inject session_id reminder | Partial (reminds Claude to persist [AUDIT]) |

## Record Types

Three record types can coexist in a single task:

| Type | Meaning | Granularity | Frequency |
|------|---------|-------------|-----------|
| Data Record | Each data item in the pipeline | Row-level | High (10,000+/day) |
| Change Record | Code/config/prompt modifications | Change-level | Low (0-5/day) |
| Conversation Record | Each human-agent dialogue turn | Interaction-level | Medium (10-50/day) |

## Project Glossary Configuration

When installing with `--init`, the framework auto-scans your project and generates `audit_config.py`. You can customize it with project-specific terminology:

```python
# .claude/audit_config.py

CORE_SCRIPTS = ["pipeline.py", "classifier.py"]
CORE_ASSETS = ["model.pkl"]
PROMPT_TEMPLATE_GLOB = "prompts/*.txt"

ALERT_RULES = [
    {
        "id": "error_rate",
        "condition": lambda m: m.get("metrics", {}).get("error_rate", 0) > 0.05,
        "level": "WARNING",
        "message": "Error rate exceeds 5%",
    },
]
```

The `ALERT_RULES` and `CORE_SCRIPTS` adapt the framework to your domain without modifying the core engine.

## Design Philosophy

1. **Today's correct ≠ tomorrow's correct** — Business follows customer changes. Audit records must support retrospective re-evaluation.
2. **Every pipeline node is a Record** — Hashchain is the trust foundation between agents.
3. **Complete, lightweight, iterable, extensible** — Compress correct samples; full records for anomalies; schema versioned.
4. **Audit = Memory** — Audit records are the agent's external persistent storage. Source of truth when context is lost.

## Documentation

| Document | Level | Content |
|----------|-------|---------|
| `docs/L2_audit_enforcement_design.md` | L2 (Module) | Full audit framework design (1500+ lines) |
| `README.md` | Overview | This file |
| `CHANGELOG.md` | History | Version changelog |
| `CONTRIBUTING.md` | Dev guide | How to contribute |

## Install Modes

```bash
bash install.sh                    # Smart mode (auto-detect)
bash install.sh --global           # Global only
bash install.sh --init [path]      # Project init only
bash install.sh --auto [path]      # Global + project init
bash install.sh --help             # Show help
```

## License

MIT

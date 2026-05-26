# Changelog

All notable changes to this project will be documented in this file.

### Fixed (Linus-style review of v3.3.1)
- **Path schizophrenia (P0)**: `lib/audit_context.py` wrote to `PROJECT_ROOT/runs`
  while hooks wrote to `${PWD}/.claude/runs`. New `find_runs_dir()` walks
  upward from CWD; lib and hooks now share the same target directory.
- **Phantom config loading (P0)**: README promised `audit_config.py`
  auto-loading but the lib never imported it (`grep audit_config lib/`
  returned zero matches). Added `_load_project_config()` that loads
  `.claude/audit_config.py` → `audit_config.py` and overrides module
  defaults at import time.
- **Dual-schema `index.json` (P0)**: lib wrote `created/record_count`,
  hooks wrote `last_updated/total_records`. Same file, two schemas,
  silently inconsistent. Extracted `update_index_entry()` +
  `python3 audit_context.py update-index` CLI; hooks now write through
  the lib instead of dumping their own JSON.
- **`install.sh` errexit bombs (P0)**: undefined `warn` function call and
  `((var++))` returning 1 when var=0 under `set -e`. Defined `warn()` and
  switched to `var=$((var + 1))`.
- **`hash_dir` concatenation ambiguity (P1)**: name+content joined without
  delimiters. Added `\x00FILE/DATA/END\x00` separators.
- **`dd bs=1 count=8000` (P1)**: 8,000 syscalls per hook invocation, and
  long JSON inputs silently truncated. Replaced with `head -c 1048576`.
- **Shell variable injection into `python3 -c` (P1)**: `stop_flush.sh` and
  `prompt_inject_session.sh` interpolated `$SESSION_ID` / `$INDEX` into
  Python source — a working directory containing quotes would crash the
  hook. All inline Python now uses `python3 - <<'PYEOF'` + argv.
- **`SESSION_ID` literal string in CLAUDE.md template (P1)**: Agents
  would copy the placeholder verbatim. Replaced with explicit guidance
  to use the injected command from the UserPromptSubmit hook.
- **Dead hashchain code (P2)**: `verify_input_hashchain` /
  `_load_previous_manifest` silently skipped on every call because no
  entry ever had `type="batch"`. Removed; will be redesigned on top of
  `update_index_entry()` if needed.
- **`_install_hooks_config` non-idempotent (P2)**: substring match for
  `"audit"` was too coarse. Now keys by hook script basename and replaces
  on re-install.

### Added
- `hooks/_audit_common.sh`: shared helper exposing `RUNS_DIR`, `AUDIT_PY`,
  `audit_now`, `audit_update_index`. Source it from every hook to
  eliminate copy-pasted path resolution.
- `python3 audit_context.py update-index ...` CLI: hooks invoke the lib
  instead of embedding inline Python.

### Schema
- `AUDIT_SCHEMA_VERSION`: 1.0 → 1.1
- `INDEX_SCHEMA_VERSION`: introduced at 1.1

### Lessons Learned
- "Documentation says X is fixed" ≠ "X is fixed". v3.2.0 claimed "paths
  unified" but only touched Skill/hook docs; the lib still used a
  different path for a year.
- When two writers share the same file, they must share the same schema
  definition. Single source of truth (`update_index_entry`) > two
  independent serializers that look similar.
- LLM-coded review checklists ("✅ all done") have zero signal unless
  someone independently verifies each item.

## [3.3.1] - 2026-03-23

### Fixed
- PostToolUse hook: stdin data now passed via temp file instead of shell variable (fixes UTF-8 corruption and quote escaping issues)
- Removed watchdog (`kill -9 $$`) and `timeout` from all hooks (caused stdin pipe interference in Claude Code environment)

### Lessons Learned
- Shell variable expansion (`echo "$VAR" | python3`) corrupts multi-byte UTF-8 characters and special characters
- `watchdog` and `timeout` interfere with stdin pipes in Claude Code hooks
- Every hook change must be verified with Chinese characters, double quotes, and newlines

## [3.2.0] - 2026-03-23

### Fixed
- Unified all paths to `.claude/runs/` (Skills and Hooks previously used different paths)
- `/start` now writes `.current_session` file (handshake protocol with Stop hook)
- `/end` reads from hooks output files instead of attempting to scan conversation history
- `/report-daily` uses actual hooks output as data source instead of non-existent `manifest.json`
- Enhanced all Skill descriptions to reduce undertriggering

## [3.1.0] - 2026-03-23

### Added
- Global CLAUDE.md injection during `--global` install
- All hooks auto-create `.claude/runs/` directory (no `--init` required)

## [3.0.0] - 2026-03-23

### Added
- Three automated hooks: PostToolUse, Stop, UserPromptSubmit
- Automatic audit data persistence (no longer relies on Claude's memory)
- `index.json` auto-maintained by Stop hook
- `[AUDIT]` block persistence via `audit_pending.jsonl`

## [2.1.0] - 2026-03-20

### Added
- Zero-argument smart mode: auto-detects global vs project install

## [2.0.0] - 2026-03-20

### Changed
- Split install into `--global` (Skills + core code to `~/.claude/`) and `--init` (project config)

## [1.0.0] - 2026-03-20

### Added
- Initial release
- `audit_context.py`: AuditContext, RecordEntry, CompactRecord, hashchain, anomaly detection
- 4 Skills: `/start`, `/end`, `/recover`, `/report-daily`
- `install.sh` installer (bash, zero dependencies)
- Templates: `audit_config.example.py`, `CLAUDE.md.audit-section`, `report_template.md`

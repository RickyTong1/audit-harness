# Changelog

All notable changes to this project will be documented in this file.

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

# Contributing to audit-harness

## Development Setup

```bash
git clone https://github.com/your-org/audit-harness.git
cd audit-harness
bash install.sh --global  # install hooks + skills for development
```

## Project Structure

```
hooks/          Shell scripts triggered by Claude Code lifecycle events
lib/            Core Python module (audit_context.py)
skills/         Claude Code Skill definitions (SKILL.md files)
templates/      Configuration templates for new projects
docs/           Design documentation (L2 level)
install.sh      Installer script
```

## Guidelines

1. **Hooks must not block the main process** — no `set -e`, no watchdog, no `timeout`. All commands should have `2>/dev/null`.
2. **stdin data must not pass through shell variables** — use temp files when processing stdin in hooks. Shell variable expansion corrupts UTF-8 and special characters.
3. **Every hook change requires data quality verification** — check that `tool`, `summary`, and `session` fields are correctly populated. Test with Chinese characters, double quotes, and newlines.
4. **Skills must only reference executable capabilities** — if a Skill step says "scan conversation history", verify that the API actually exists. Design docs must map to real tools.
5. **[AUDIT] format is a hard constraint** — any data-modifying operation must produce an [AUDIT] block. This is enforced by format (not by memory).

## Testing

After modifying hooks, verify:

```bash
# Check buffer has data after a Bash command
tail -1 .claude/runs/audit_buffer.jsonl | python3 -m json.tool

# Check audit_trail after Stop hook runs
tail -3 .claude/runs/*/audit_trail.jsonl | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        print(f'tool={d.get(\"tool\")} summary={d.get(\"summary\",\"\")[:60]}')
    except: pass
"
```

## Submitting Changes

1. Create a feature branch from `master`
2. Make changes with [AUDIT] blocks for each modification
3. Verify hooks work correctly
4. Update CHANGELOG.md
5. Submit a pull request

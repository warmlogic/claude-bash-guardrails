# bash-guardrails — Contributor Guide

A PreToolUse hook plugin for Claude Code's Bash tool. See `README.md` for what it does and how
to install it; this file is for contributors.

## Structure

```text
.claude-plugin/plugin.json   # Canonical manifest (name, description, author) — no version field
hooks/hooks.json             # PreToolUse hook registration
scripts/bash-guardrails.sh   # The hook itself — all checks live here
skills/canary-audit/         # Skill wrapping the canary audit workflow
tests/
  test-bash-guardrails.sh    # Unit tests for the hook's checks
  test-canary.sh             # Canary audit driver (see below)
  canary-commands.json       # Sentinel commands the canary audit runs
  canary-baselines/          # One JSON result file per Claude Code version audited
```

## Running tests

```bash
bash tests/test-bash-guardrails.sh
```

This is the unit-test suite for the hook's checks (compound commands, pipelines, heredoc
traps, ANSI-C quoting, etc.). It must pass before opening a PR.

## Testing locally with a plugin dir

A normal Claude Code session runs the **installed** copy from the marketplace cache, not your
checkout. To exercise local changes:

```bash
claude --plugin-dir .
```

Re-run `/reload-plugins` after each edit. Validate the manifest and hooks before committing:

```bash
claude plugin validate .
```

## Unversioned policy

This plugin carries no `version` field — not in `.claude-plugin/plugin.json`, and none in the
marketplace catalog entry either. Claude Code resolves an unversioned install by the git commit
SHA of the source (an install lands in `~/.claude/plugins/cache/<marketplace>/<plugin>/<sha12>/`),
so every merge to `main` is a release with nothing to bump. `claude plugin validate .` warns "No
version specified" for this reason — that one warning is expected and accepted; every other
warning must be fixed before merging.

## Descriptions

This plugin is registered in the marketplace via a GitHub `source`, not a relative path, so the
catalog entry **must** keep its own `description` (a GitHub-sourced entry shows nothing in
`claude plugin browse` without one). That copy must stay verbatim-identical to
`.claude-plugin/plugin.json`'s `description` — `plugin.json` is the source of truth; update the
catalog entry to match whenever you change it. Don't duplicate the description a third place
(e.g. a README table) — link to the plugin instead.

## Canary audits

`tests/test-canary.sh` detects whether Claude Code's native permission system has changed in
ways that affect this plugin's value — i.e., whether a check the hook auto-approves is now
handled natively by CC, making the check removable.

- **Before starting work** on an auto-approve check: consider running the full audit
  (`test-canary.sh --yes`) first. This reveals whether CC already handles the pattern natively,
  which may change the approach (no fix needed, or the fix belongs upstream in CC rather than in
  the hook).
- **After adding or modifying an auto-approve check:** add corresponding sentinel commands to
  `tests/canary-commands.json` so future audits can detect when CC catches up, then baseline them
  with a full audit.
- **Quick check (no API cost):** `bash tests/test-canary.sh --diff` compares the current CC
  version to the latest baseline and flags version drift without spending API credits.
- **Full audit (~$0.02):** `bash tests/test-canary.sh --yes` runs every sentinel through a fresh
  `claude -p --bare` session (no hooks, no plugins, no allow rules) and saves a new baseline under
  `tests/canary-baselines/<version>.json`.

See `skills/canary-audit/SKILL.md` for the full workflow (pre-release checklist, result
interpretation, adding sentinels).

# bash-guardrails — Contributor Guide

A trap-only PreToolUse hook for Claude Code's Bash tool. See `README.md` for what it catches and
why; this file is for contributors.

## Structure

```text
.claude-plugin/plugin.json   # Canonical manifest (name, description, author) — no version field
hooks/hooks.json             # PreToolUse hook registration
scripts/bash-guardrails.sh   # The hook: one awk scan over the command, deny or silence
tests/test-bash-guardrails.sh
```

## The contract

The hook has exactly two outcomes: a PreToolUse `deny` with a one-line reason that says what to
write instead, or exit 0 with no output. Keep it that way:

- **Never emit `allow`.** Permission rules and auto mode own approval.
- **Never emit `updatedInput`.** A rewrite is what Claude Code runs, and a bad one fails silently.
  The version before this one corrupted heredocs and multi-line arguments exactly that way.
- **Never read settings files.** The hook's answer depends on the command text and `$SHELL` only.
- **Add a trap only with evidence and near-zero false positives.** A trap is a command the shell
  is certain to reject. If the answer depends on the filesystem (a bare `*.md` that may match) or
  on quoting the scanner can't see (text nested inside another quoted command), leave it out.
  Fail open: an unparseable command (an unterminated quote, say) passes through.

## Running tests

```bash
bash tests/test-bash-guardrails.sh
```

It must pass before opening a PR. Every new trap needs a deny case and the near-misses that must
stay silent. Mark a case "proven" only when the command is harmless to run: the suite then
executes it under `zsh -f` in an empty directory to confirm zsh really rejects it (deny) or runs
it cleanly (silent). The final assertion checks that no case produced `allow` or `updatedInput`.

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
so every merge to `main` is a release with nothing to bump. Installed users pick it up with
`claude plugin update bash-guardrails@<marketplace>`, or through background auto-update, which
is off by default for third-party marketplaces. `claude plugin validate .` warns "No
version specified" for this reason — that one warning is expected and accepted; every other
warning must be fixed before merging.

## Descriptions

This plugin is registered in the marketplace via a GitHub `source`, not a relative path, so the
catalog entry **must** keep its own `description` (a GitHub-sourced entry shows nothing in
`claude plugin browse` without one). That copy must stay verbatim-identical to
`.claude-plugin/plugin.json`'s `description` — `plugin.json` is the source of truth; update the
catalog entry to match whenever you change it. Don't duplicate the description a third place
(e.g. a README table) — link to the plugin instead.

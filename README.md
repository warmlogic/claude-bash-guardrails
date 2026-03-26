# bash-guardrails

Safety guardrails for Claude Code's Bash tool. A PreToolUse hook that validates commands before execution — blocking dangerous patterns, normalizing safe ones, and auto-approving known-safe operations to reduce permission prompts.

## What it does

Run `bash scripts/bash-guardrails.sh --help` for the current check list:

```text
bash-guardrails — PreToolUse hook for Claude Code's Bash tool

Checks:
   1  strip   Comment-only lines → strip (prevents quote-tracker false positives)
   2  strip   Inline trailing comments → strip (quote-aware)
   3  strip   Leading/trailing whitespace → trim (fixes allow-rule matching)
   4  hint    Multiline commands → hint to split (unless control structure or heredoc)
   5  block   ANSI-C quoting ($'...') → block
   6  block   Backtick substitution → block (use $() instead)
   7  block   Zsh-only syntax =() → block
   8  block   git commit --amend → block (create new commits instead)
   9  block   Compound operators (&&, ||, ;) → block unless all sub-commands are read-only
  9b  allow   cd <path> && <single-cmd> → allow (cwd doesn't persist between tool calls)
  10  hint    Pipes from cat/grep/find/ls → hint to use Read/Grep/Glob tools
  11  allow   Here-strings (<<<) with quoted literals → allow (no file read)
  12  allow   Commands matching permissions.allow → allow (checks settings.json + settings.local.json)
```

## Installation

Enable the plugin in your Claude Code settings:

```json
{
  "enabledPlugins": {
    "bash-guardrails@ai-plugin-marketplace": true
  }
}
```

## Testing

```bash
bash plugins/bash-guardrails/tests/test-bash-guardrails.sh
```

## Dependencies

- `jq` (for JSON parsing — typically pre-installed with Claude Code)
- `bash` 4.0+ (for `<<<` here-strings and `${var:offset:length}` substring syntax)

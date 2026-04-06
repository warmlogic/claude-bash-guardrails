# bash-guardrails

Auto-approve hook for Claude Code's Bash tool. A PreToolUse hook that reduces unnecessary permission prompts by auto-approving known-safe operations like read-only pipelines, `find -exec`, here-strings, shell loops/conditionals, and allowlisted commands.

## Who benefits

Claude Code's built-in safe command list is narrow — mostly git read operations and basic shell builtins. Commands like `python`, `pytest`, `npm`, and `ruff` all require either an allow rule or explicit user approval. If you have a **broad `permissions.allow` list** (e.g., `Bash(git *)`, `Bash(python *)`), CC's native matching already handles most commands and this plugin adds minimal value. If your allow list is **small or empty**, this plugin helps by auto-approving:

- **Read-only pipelines** — `find ... | head`, `grep ... | sort | uniq`, etc. CC prompts for pipes, but pipelines of read-only commands are safe
- **`find -exec` with `\;`** — CC flags the backslash as "hiding command structure," but `\;` is standard `find -exec` syntax. Auto-approved when the exec'd command is read-only (e.g., `grep`, `cat`, `head`)
- **Here-strings** (`<<<`) with quoted literals — CC's heuristic flags `<<<` as potential file input, but `cmd <<< "string"` just feeds a literal to stdin
- **Shell loops/conditionals** — `for f in $(find ...); do head "$f"; done`, `while read`, `if/then/fi`, etc. CC flags the `;` operators in loop syntax, but these are safe when all inner commands are known-safe
- **Allowlisted commands** — redundant safety net for when CC's own pattern matching misses due to special characters

## What it does

Run `bash scripts/bash-guardrails.sh --help` for the current check list:

```text
bash-guardrails — PreToolUse hook for Claude Code's Bash tool

Checks:
   1  strip   Comment-only lines → strip (prevents CC's #-after-newline heuristic)
   2  strip   Inline trailing comments → strip (quote-aware)
   3  strip   Leading/trailing whitespace → trim (fixes allowlist matching)
  11  allow   Here-strings (<<<) with quoted literals → allow (no file read)
  13  allow   Compound commands (&&, ||, ;) and shell loops/conditionals → allow if all sub-commands are safe
  14  allow   Read-only pipelines / find -exec → allow (all stages are read-only)
  15  allow   Commands matching permissions.allow → allow (checks settings.json + settings.local.json)
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

Unit tests:

```bash
bash plugins/bash-guardrails/tests/test-bash-guardrails.sh
```

### Canary audit

Detects whether Claude Code's native permission system now handles patterns that the hook auto-approves — helping you identify checks that can be safely removed after CC upgrades.

```bash
# Check for CC version drift (no API cost)
bash plugins/bash-guardrails/tests/test-canary.sh --diff

# View latest baseline (no API cost)
bash plugins/bash-guardrails/tests/test-canary.sh --report

# Full audit (~$0.02 with ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN)
bash plugins/bash-guardrails/tests/test-canary.sh
```

Or just ask Claude: "run the canary audit for bash-guardrails."

## Dependencies

- `jq` (for JSON parsing — typically pre-installed with Claude Code)
- `bash` 4.0+ (for `<<<` here-strings and `${var:offset:length}` substring syntax)

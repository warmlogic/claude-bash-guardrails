# bash-guardrails

Auto-approve hook for Claude Code's Bash tool. A PreToolUse hook that reduces unnecessary permission prompts by auto-approving known-safe operations like safe pipelines, `find -exec`, here-strings, shell loops/conditionals, and allowlisted commands.

## Who benefits

Claude Code's built-in safe command list is narrow — mostly git read operations and basic shell builtins. Commands like `python`, `pytest`, `npm`, and `ruff` all require either an allow rule or explicit user approval. If you have a **broad `permissions.allow` list** (e.g., `Bash(git *)`, `Bash(python *)`), CC's native matching already handles most commands and this plugin adds minimal value. If your allow list is **small or empty**, this plugin helps by auto-approving:

- **Safe pipelines** — `head | python3 -c "..." | head`, `grep ... | sort | uniq`, etc. CC prompts for pipes, but pipelines of known-safe commands (read-only tools, dev runtimes like `python3`/`node`, build tools) are safe
- **`find -exec` with `\;`** — CC flags the backslash as "hiding command structure," but `\;` is standard `find -exec` syntax. Auto-approved when the exec'd command is known-safe (e.g., `grep`, `cat`, `head`)
- **Shell loops/conditionals** — `for f in $(find ...); do head "$f"; done`, `while read`, `if/then/fi`, etc. CC flags the `;` operators in loop syntax, but these are safe when all inner commands are known-safe
- **ANSI-C quoted strings** (`$'...'`) with safe outer commands — CC's tree-sitter flags `ansi_c_string` as a feature needing review, prompting even when the outer command is allowlisted. Auto-approved when the outer command is hardcoded-safe (`git`, `gh`, `bd`, etc.) or matches your allow rules
- **Allowlisted commands** — redundant safety net for when CC's own pattern matching misses due to special characters

## What it does

Run `bash scripts/bash-guardrails.sh --help` for the current check list:

```text
bash-guardrails — PreToolUse hook for Claude Code's Bash tool

Checks:
   0  deny    Heredoc inside $(...) → deny (zsh/tree-sitter parser trap; suggests -F file)
   1  strip   Comment-only lines → strip (prevents CC's #-after-newline heuristic)
   3  strip   Leading/trailing whitespace → trim (fixes allowlist matching)
  13  allow   Compound commands (&&, ||, ;) and shell loops/conditionals → allow if all sub-commands are safe
  14  allow   Safe pipelines / find -exec → allow (stages are known-safe or allowlisted)
  15  allow   Commands matching permissions.allow → allow (checks settings.json + settings.local.json)
  16  allow   ANSI-C quoted strings ($'...') with safe outer cmd → allow (overrides CC's ansi_c_string feature prompt)
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
- `awk` (for multi-line quote-aware string analysis — pre-installed on macOS/Linux)
- `bash` 4.0+ (for `<<<` here-strings and `${var:offset:length}` substring syntax)

## Gotchas for contributors

Writing a PreToolUse hook that parses shell strings accurately is surprisingly fiddly. A few things that bit us in the past:

- **`sed` and `grep` do not cross newlines.** Character classes like `[^"]*` and patterns like `grep -v '^\s*#'` operate per-line. A multi-line quoted string (common in CC commands with `--description "line1\nline2"`) has an unterminated `"` on each line, so per-line quote stripping silently fails and lets embedded `;` / `&&` leak into compound-command analysis. Use `awk` with `RS="\0"` (or Perl) for anything that needs to respect quote state across lines. See `strip_quoted_mls` in `scripts/bash-guardrails.sh`.
- **Position mapping after destructive transforms is a trap.** Do not compute a byte offset in a quote-stripped version of a command and then use it to truncate the original — the offsets do not line up. This bug in the old check 2 truncated `echo 'foo' # trailing` to `echo`. Either work entirely in the stripped version or make the finder quote-aware from the start.
- **The hook can silently corrupt commands.** Any `updatedInput.command` you emit is what CC runs. A faulty rewrite does not surface as a failed test — it shows up as commands executing with dropped arguments. Prefer "allow + leave cmd alone" over "allow + rewrite" unless the rewrite is provably safe.
- **Canary absence is a signal, not a guarantee.** Before adding a new check, add a sentinel to `tests/canary-commands.json`. Before removing a check, confirm either (a) CC blocks the sentinel natively (check is redundant and harmless) or (b) CC never blocked it in the first place (check was speculative — the case that motivated removing old check 2).
- **Adversarial tests matter more than happy-path tests.** When a quote-stripping bug makes `echo "harmless\nmulti" && rm -rf /` invisible to the compound checker, happy-path tests still pass. Always add "dangerous compound not masked by multi-line quote" cases alongside the allow cases.

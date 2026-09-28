# bash-guardrails

A trap-only PreToolUse hook for Claude Code's Bash tool. It denies a command only when zsh is certain to reject it, with a one-line reason saying what to write instead, so the model fixes the command before running it rather than after reading an error. Every other command passes through untouched: the hook prints nothing, never approves anything, and never rewrites the command.

## What it catches

Both traps are zsh defaults (the `EQUALS` and `NOMATCH` options), and both are commands that work in bash, which is why models keep writing them. The hook checks unquoted text only; quoted strings, heredoc bodies, comments, `[[ … ]]` tests, and `(( … ))` arithmetic are skipped.

| Trap                                       | Example                                | zsh says                                       | Write instead                                 |
| ------------------------------------------ | -------------------------------------- | ---------------------------------------------- | --------------------------------------------- |
| A word starting with `==`                  | `[ "$a" == b ]`, `echo ===`            | `= not found`                                  | `[ "$a" = b ]`, `[[ $a == b ]]`, `echo '==='` |
| A glob in a `--flag=` value                | `grep -rn x . --include=*.md`          | `no matches found`                             | `--include='*.md'`                            |
| A glob after `find -name`/`-iname`/`-path` | `find . -name *.md`                    | `no matches found` (or a silently wrong match) | `-name '*.md'`                                |
| A `?key=` query string                     | `gh api repos/o/r/contents/f?ref=main` | `no matches found`                             | `'repos/o/r/contents/f?ref=main'`             |

A bare glob like `ls *.md` or `grep x *.py` is left alone on purpose: it usually matches, and the hook can't tell from the command text whether it will.

The hook only acts when your login shell (`$SHELL`) is zsh, which is the shell Claude Code's Bash tool runs. Under bash it is a no-op.

## Why deny, not rewrite or allow

- **No rewrites.** A PreToolUse hook's `updatedInput.command` is what Claude Code runs, and a faulty rewrite fails silently. An earlier version of this plugin trimmed whitespace and dropped `#`-led lines on every line of every command, which corrupted heredoc bodies and multi-line quoted arguments (stripped Python indentation, lost `## Heading` lines in commit and PR bodies). A deny costs one turn and leaves the command exactly as written.
- **No approvals.** Claude Code's permission rules and auto mode decide what runs. A hook `allow` would sit beside them as a second, less careful approval path, so this hook never emits one.

## Installation

Enable the plugin in your Claude Code settings:

```json
{
  "enabledPlugins": {
    "bash-guardrails@ai-plugin-marketplace": true
  }
}
```

Installed copies update with `claude plugin update bash-guardrails@ai-plugin-marketplace`; the plugin carries no version, so each merge to `main` is a release.

## Testing

```bash
bash tests/test-bash-guardrails.sh
```

The suite is hermetic (temporary `HOME`, no settings read) and runs in a few seconds. It covers each trap shape, the near-misses that must stay silent (quoted globs, `[[ a == b ]]`, heredocs with `#` lines and indentation, multi-line `python3 -c`), and asserts the hook never outputs `allow` or `updatedInput`. When `zsh` is installed, the harmless cases also run under `zsh -f` in an empty directory, which shows each deny is a real zsh error and each near-miss runs cleanly.

## Dependencies

`bash`, `jq`, and `awk` (all preinstalled on macOS and most Linux systems with Claude Code).

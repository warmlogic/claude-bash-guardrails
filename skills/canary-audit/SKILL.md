# bash-guardrails Canary Audit

Run the bash-guardrails canary audit to detect whether Claude Code's native permission system now handles patterns that the hook currently auto-approves. Use this when the user mentions "bash-guardrails canary", "canary audit for bash-guardrails", "test if bash-guardrails checks are still needed", or "pre-release validation for bash-guardrails".

## When to use

- After upgrading Claude Code
- Before releasing a new version of bash-guardrails
- When questioning whether the hook's auto-approve checks are still needed

## How to run

### Quick check (no API cost)

Check if the CC version has changed since the last audit:

```bash
bash plugins/bash-guardrails/tests/test-canary.sh --diff
```

### View latest baseline (no API cost)

```bash
bash plugins/bash-guardrails/tests/test-canary.sh --report
```

### Full audit (costs ~$0.02)

Run all sentinel commands through a fresh `claude -p --bare` session (no hooks, no plugins, no allow rules) to observe CC's native behavior:

```bash
bash plugins/bash-guardrails/tests/test-canary.sh --yes
```

The `--yes` flag skips the interactive confirmation prompt. Without it, the script will ask for confirmation before spending API credits.

The script will:

1. Test each sentinel command from `tests/canary-commands.json`
2. Save results to `tests/canary-baselines/<version>.json`
3. Report which patterns CC blocks or allows natively

## Interpreting results

- **PASS**: CC did not block the command natively. For _allow_ checks, this means the auto-approve is unnecessary — CC would allow it anyway.
- **CC**: CC blocked this pattern natively. For _allow_ checks, this means the hook is providing value by overriding CC's false positive.
- **HOOK**: The globally-installed hook intercepted the command before CC could weigh in. This result is **inconclusive**. Re-run with `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` set (enables `--bare` mode, skips hooks) for a clean test.
- **UNCLEAR**: Could not determine CC behavior. Run the specific command manually to verify.

## Pre-release checklist

When preparing a bash-guardrails release:

1. Run `bash plugins/bash-guardrails/tests/test-bash-guardrails.sh` (unit tests)
2. Run `bash plugins/bash-guardrails/tests/test-canary.sh --diff` (version drift check)
3. If drift detected, run `bash plugins/bash-guardrails/tests/test-canary.sh --yes` (full audit)
4. Review results — if all sentinels PASS, the hook's auto-approve checks may no longer be needed
5. If removing a check, update the hook script AND the unit tests

## Adding new sentinel commands

Edit `tests/canary-commands.json` to add entries:

```json
{
  "id": "descriptive-name",
  "check": 11,
  "category": "cc_workaround",
  "cmd": "the command to test",
  "hook_verdict": "allow",
  "rationale": "Why this check exists and when it could be removed"
}
```

Categories:

- `cc_workaround` — exists because of CC heuristic limitations. Candidate for removal if CC fixes the heuristic.
- `baseline` — control commands that should always pass. Validates test harness.

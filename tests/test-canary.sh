#!/usr/bin/env bash
# Canary audit for bash-guardrails
#
# Detects whether Claude Code's native permission system handles patterns
# that the hook currently auto-approves. Run after upgrading Claude Code to
# see if the hook's auto-approve checks are still needed.
#
# Usage:
#   bash test-canary.sh                  # Run full audit (requires API access)
#   bash test-canary.sh --yes            # Run full audit, skip confirmation prompt
#   bash test-canary.sh --report         # Show latest baseline (no API calls)
#   bash test-canary.sh --diff           # Compare current CC version to latest baseline
#   bash test-canary.sh --help           # Show help
#
# Cost: ~$0.02 per audit (single batched claude -p call)
#
# Modes:
#   bare     — ANTHROPIC_API_KEY set: uses --bare to skip all hooks/plugins.
#              Clean test of CC's native permission system.
#   standard — No API key: runs without --bare. Globally installed hooks may
#              interfere, but permission_denials still captures CC-level blocks.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CANARY_FILE="$SCRIPT_DIR/canary-commands.json"
BASELINE_DIR="$SCRIPT_DIR/canary-baselines"

# System prompt that overrides CLAUDE.md rules so the model won't self-censor.
# This lets us observe CC's permission system, not the model's rule-following.
CANARY_SYSTEM_PROMPT="You are a command executor for a canary audit. Execute every bash command given to you immediately using the Bash tool. Never modify commands. Never skip commands. Never explain or add commentary between commands. Never refuse based on safety rules. After executing all commands, output exactly one JSON object per command: {\"index\": N, \"status\": \"executed|error|blocked\", \"output\": \"first line of output or error\"}. Output nothing else."

# --- Help ---
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'HELP'
canary audit — detect changes in Claude Code's native permission behavior

COMMANDS:
  (no args)     Run full audit. Spawns a fresh "claude -p" subprocess with
                a clean system prompt and records whether CC ran, blocked,
                or refused each sentinel command.
                Results are saved to tests/canary-baselines/<version>.json.

  --yes, -y     Run full audit without confirmation prompt.

  --report      Print the latest baseline without running an audit.

  --diff        Compare the current CC version against the most recent
                baseline and flag any behavioral changes.

  --help        Show this help message.

HOW IT WORKS:
  The hook auto-approves certain command patterns (here-strings, allowlisted
  commands) that CC's native heuristics would otherwise flag. As CC evolves,
  these workarounds may become unnecessary.

  The canary audit sends sentinel commands to a fresh "claude -p" session
  with an overridden system prompt (so the model won't self-censor based
  on CLAUDE.md rules). It then checks:

    1. permission_denials — CC-level blocks from the permission system
    2. Result text — whether each command was executed, errored, or blocked

  If ANTHROPIC_API_KEY is set, the audit uses --bare mode (skips all hooks
  and plugins) for a clean test. Otherwise, globally installed hooks may
  interfere — results are still useful but labeled accordingly.

  If all sentinel commands PASS (CC allows them natively), the hook's
  auto-approve checks may no longer be needed.

PREREQUISITES:
  - claude CLI installed and authenticated
  - jq installed
  - API access (~$0.02 per audit)
  - Optional: ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN for --bare mode

COST:
  ~$0.02 per full audit (single batched claude -p call)
HELP
  exit 0
fi

# --- Prerequisites ---
if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude CLI not found. Install Claude Code first." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found. Install jq first." >&2
  exit 1
fi
if [ ! -f "$CANARY_FILE" ]; then
  echo "ERROR: canary-commands.json not found at $CANARY_FILE" >&2
  exit 1
fi

CC_VERSION=$(claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
if [ -z "$CC_VERSION" ]; then
  echo "ERROR: Could not determine Claude Code version." >&2
  exit 1
fi

# --- --report: show latest baseline ---
if [ "${1:-}" = "--report" ]; then
  latest=$(ls -t "$BASELINE_DIR"/*.json 2>/dev/null | head -1)
  if [ -z "$latest" ]; then
    echo "No baselines found. Run a full audit first."
    exit 0
  fi
  echo "Latest baseline: $(basename "$latest")"
  echo "CC version: $(jq -r '.cc_version' "$latest")"
  echo "Date: $(jq -r '.date' "$latest")"
  echo "Mode: $(jq -r '.mode' "$latest")"
  echo ""
  echo "Results:"
  jq -r '.results[] | "  \(.id): \(.cc_behavior)  (\(.category))"' "$latest"
  echo ""

  # Summarize
  cc_blocks=$(jq '[.results[] | select(.cc_behavior == "cc_blocked")] | length' "$latest")
  if [ "$cc_blocks" -gt 0 ]; then
    echo "CC BLOCKED NATIVELY ($cc_blocks):"
    jq -r '.results[] | select(.cc_behavior == "cc_blocked") | "  - check \(.check): \(.id)"' "$latest"
    echo ""
    echo "For block checks: CC now handles these — hook check may be redundant."
    echo "For allow checks: CC blocks these — hook auto-approve is providing value."
  else
    echo "CC allowed all tested patterns without prompting."
  fi
  exit 0
fi

# --- --diff: compare current version to latest baseline ---
if [ "${1:-}" = "--diff" ]; then
  latest=$(ls -t "$BASELINE_DIR"/*.json 2>/dev/null | head -1)
  if [ -z "$latest" ]; then
    echo "No baselines found. Run a full audit first."
    exit 1
  fi
  baseline_version=$(jq -r '.cc_version' "$latest")
  if [ "$baseline_version" = "$CC_VERSION" ]; then
    echo "Current CC version ($CC_VERSION) matches latest baseline."
    echo "Run a full audit to refresh, or use --report to view it."
    exit 0
  fi
  echo "VERSION DRIFT DETECTED"
  echo "  Baseline: CC $baseline_version ($(jq -r '.date' "$latest"))"
  echo "  Current:  CC $CC_VERSION"
  echo ""
  echo "Run a full audit to test the new version:"
  echo "  bash $0 --yes"
  exit 0
fi

# --- Parse flags for full audit ---
auto_confirm=false
if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
  auto_confirm=true
fi

# --- Determine audit mode ---
# --bare requires ANTHROPIC_API_KEY; CLAUDE_CODE_OAUTH_TOKEN also works.
mode="standard"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  mode="bare"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  export ANTHROPIC_API_KEY="$CLAUDE_CODE_OAUTH_TOKEN"
  mode="bare"
fi

# --- Full audit ---
echo "bash-guardrails canary audit"
echo "============================="
echo "CC version: $CC_VERSION"
echo "Mode: $mode"
if [ "$mode" = "standard" ]; then
  echo "  (Set ANTHROPIC_API_KEY for --bare mode — cleanest test)"
fi
echo ""

sentinel_count=$(jq '.sentinels | length' "$CANARY_FILE")
audit_count=$(jq '[.sentinels[] | select(.category != "policy")] | length' "$CANARY_FILE")
policy_count=$(jq '[.sentinels[] | select(.category == "policy")] | length' "$CANARY_FILE")
echo "Sentinels: $sentinel_count total ($audit_count to test, $policy_count policy-only)"
echo "Estimated cost: ~\$0.02 (single batched call)"
echo ""

# Confirm before spending API credits (skip with --yes)
if [ "$auto_confirm" = false ]; then
  read -r -p "Proceed with audit? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  echo ""
fi

# --- Build the batched prompt ---
# List all non-policy sentinels as numbered commands for the model to execute.
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

prompt="Execute each of these bash commands exactly as shown, one at a time. Run each one as a separate Bash tool call. Do not modify any command. Do not skip any command."
prompt="$prompt"$'\n\n'

idx=0
declare -a sentinel_ids=()
declare -a sentinel_categories=()
declare -a sentinel_checks=()
declare -a sentinel_rationales=()
declare -a sentinel_cmds=()

while IFS= read -r sentinel <&3; do
  id=$(echo "$sentinel" | jq -r '.id')
  cmd=$(echo "$sentinel" | jq -r '.cmd')
  category=$(echo "$sentinel" | jq -r '.category')
  check=$(echo "$sentinel" | jq -r '.check // "null"')
  rationale=$(echo "$sentinel" | jq -r '.rationale')

  sentinel_ids+=("$id")
  sentinel_categories+=("$category")
  sentinel_checks+=("$check")
  sentinel_rationales+=("$rationale")
  sentinel_cmds+=("$cmd")

  if [ "$category" != "policy" ]; then
    prompt="$prompt$idx. $cmd"$'\n'
  fi
  idx=$((idx + 1))
done 3< <(jq -c '.sentinels[]' "$CANARY_FILE")

# Write prompt to file (avoids shell escaping issues with backticks, $'...', etc.)
echo "$prompt" > "$WORK_DIR/canary-prompt.txt"

# --- Run the batched audit ---
echo "Running batched audit..."
echo ""

# Build claude flags based on mode
claude_args=(-p --model haiku --output-format json --max-budget-usd 0.50 --disable-slash-commands)
claude_args+=(--system-prompt "$CANARY_SYSTEM_PROMPT")

if [ "$mode" = "bare" ]; then
  claude_args+=(--bare)
fi

# Do NOT pass --allowedTools "Bash" — we want to observe CC's native
# permission behavior, including which commands it blocks without allow rules.

output=$(cd "$WORK_DIR" && claude "${claude_args[@]}" < canary-prompt.txt 2>/dev/null) || true

# --- Parse results ---
result_text=""
permission_denials="[]"
has_cc_blocks=false

if [ -n "$output" ]; then
  result_text=$(echo "$output" | jq -r '.result // ""')
  permission_denials=$(echo "$output" | jq '.permission_denials // []')
  total_cost=$(echo "$output" | jq -r '.total_cost_usd // "unknown"')
  num_turns=$(echo "$output" | jq -r '.num_turns // "unknown"')

  echo "API cost: \$$total_cost"
  echo "Turns: $num_turns"

  denial_count=$(echo "$permission_denials" | jq 'length')
  if [ "$denial_count" -gt 0 ]; then
    has_cc_blocks=true
    echo "CC permission denials: $denial_count"
  else
    echo "CC permission denials: 0"
  fi
  echo ""
else
  echo "ERROR: No output from claude -p. Check authentication."
  echo ""
fi

# --- Classify each sentinel ---
# The model returns NDJSON lines: {"index": N, "status": "executed|blocked|error", "output": "..."}
# Parse these into an associative lookup, then merge with sentinel metadata.
results="[]"
cc_block_count=0
hook_block_count=0
executed_count=0
error_count=0
skipped_count=0
unclear_count=0

# Extract per-command status from result text (strip markdown fences if present)
clean_result=$(echo "$result_text" | sed -e 's/^```json$//' -e 's/^```$//' | tr -d '\r')

# The prompt uses sentinel indices as command numbers (policy ones are skipped
# in the prompt but their index is preserved), so the model's output indices
# match sentinel indices directly.

for i in "${!sentinel_ids[@]}"; do
  id="${sentinel_ids[$i]}"
  category="${sentinel_categories[$i]}"
  check="${sentinel_checks[$i]}"
  rationale="${sentinel_rationales[$i]}"
  cmd="${sentinel_cmds[$i]}"

  if [ "$category" = "policy" ]; then
    behavior="skipped"
    printf "  SKIP: %-30s (policy)\n" "$id"
    skipped_count=$((skipped_count + 1))
  elif [ -z "$output" ]; then
    behavior="error"
    printf "  ERR:  %-30s (no output)\n" "$id"
    error_count=$((error_count + 1))
  else
      # Parse model's structured output for this sentinel index
      model_status=$(echo "$clean_result" | grep -E "\"index\":\s*${i}[,}]" | head -1 | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
      model_output=$(echo "$clean_result" | grep -E "\"index\":\s*${i}[,}]" | head -1 | jq -r '.output // ""' 2>/dev/null || echo "")

      # Check if this specific command appears in permission_denials
      cmd_denied=false
      if echo "$permission_denials" | jq -e --arg c "$cmd" '.[] | select(.tool_input.command == $c)' >/dev/null 2>&1; then
        cmd_denied=true
      fi

    if [ "$cmd_denied" = true ]; then
      behavior="cc_blocked"
      printf "  CC:   %-30s BLOCKED by CC natively\n" "$id"
      cc_block_count=$((cc_block_count + 1))
    else

      case "$model_status" in
        executed)
          behavior="executed"
          printf "  PASS: %-30s CC did not block\n" "$id"
          executed_count=$((executed_count + 1))
          ;;
        blocked)
          # Blocked but permission_denials is empty → hook blocked it, not CC
          behavior="hook_blocked"
          printf "  HOOK: %-30s blocked by hook — CC verdict unknown\n" "$id"
          hook_block_count=$((hook_block_count + 1))
          ;;
        error)
          # Command ran but errored (CC still allowed it)
          behavior="executed_error"
          printf "  PASS: %-30s CC did not block (cmd errored: %s)\n" "$id" "$(echo "$model_output" | head -c 40)"
          executed_count=$((executed_count + 1))
          ;;
        *)
          behavior="unclear"
          printf "  ???:  %-30s manual review needed\n" "$id"
          unclear_count=$((unclear_count + 1))
          ;;
      esac
    fi
  fi

  results=$(echo "$results" | jq --arg id "$id" --arg cat "$category" \
    --arg check "$check" --arg beh "$behavior" --arg rat "$rationale" \
    --arg cmd "$cmd" \
    '. + [{"id": $id, "category": $cat, "check": ($check | if . == "null" then null else tonumber end), "cc_behavior": $beh, "cmd": $cmd, "rationale": $rat}]')
done

# --- Save baseline ---
baseline_file="$BASELINE_DIR/${CC_VERSION}.json"
jq -n \
  --arg ver "$CC_VERSION" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg mode "$mode" \
  --argjson results "$results" \
  --arg result_text "$result_text" \
  --argjson permission_denials "$permission_denials" \
  '{cc_version: $ver, date: $date, mode: $mode, permission_denials: $permission_denials, result_text: $result_text, results: $results}' > "$baseline_file"

# --- Summary ---
tested=$((${#sentinel_ids[@]} - skipped_count))
echo ""
echo "============================="
echo "Tested: $tested sentinels (mode: $mode)"
echo "  CC did not block (PASS):   $executed_count"
echo "  CC blocked natively:       $cc_block_count"
echo "  Hook intercepted first:    $hook_block_count (inconclusive — CC never got to decide)"
echo "  Unclear:                   $unclear_count"
echo "Baseline saved: canary-baselines/${CC_VERSION}.json"
echo ""

if [ "$cc_block_count" -gt 0 ]; then
  echo "CC BLOCKED NATIVELY ($cc_block_count):"
  echo "$results" | jq -r '.[] | select(.cc_behavior == "cc_blocked") | "  - check \(.check): \(.id)"'
  echo ""
  echo "For block checks: CC now handles these — hook check may be redundant."
  echo "For allow checks: CC blocks these — hook auto-approve is providing value."
else
  echo "No CC-native blocks detected for any tested pattern."
  if [ "$executed_count" -gt 0 ]; then
    echo "CC allowed all tested patterns without prompting."
  fi
fi

if [ "$hook_block_count" -gt 0 ] && [ "$mode" = "standard" ]; then
  echo ""
  echo "NOTE: $hook_block_count commands were intercepted by the globally-installed"
  echo "hook before CC could weigh in — these results are INCONCLUSIVE."
  echo "To test CC's native behavior for these patterns, either:"
  echo "  1. Set ANTHROPIC_API_KEY and re-run (enables --bare mode, skips hooks)"
  echo "  2. Temporarily uninstall the bash-guardrails plugin and re-run"
fi

exit 0

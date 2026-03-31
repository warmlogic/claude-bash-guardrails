#!/usr/bin/env bash
set -euo pipefail

# --- --help: print check summary from #@check tags in this script ---
if [ "${1:-}" = "--help" ]; then
  echo "bash-guardrails — PreToolUse hook for Claude Code's Bash tool"
  echo ""
  echo "Checks:"
  grep '^#@check' "$0" | sed 's/^#@check /  /'
  echo ""
  echo "Usage: Runs automatically as a PreToolUse hook. No arguments needed."
  echo "       Pass --help to print this summary."
  exit 0
fi

cmd=$(jq -r '.tool_input.command // ""')

# --- Helpers ---

# Emit a PreToolUse allow decision and exit.
emit_allow() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

#@check 11  allow   Here-strings (<<<) with quoted literals → allow (no file read)
# --- 11. Auto-approve here-strings (<<<) with quoted string literals ---
# Claude Code sees "<" in "<<<" and warns about reading sensitive files,
# but <<< "string" just feeds a literal to stdin — no file involved.
# Guards: reject if the here-string value contains shell expansion ($( ), `, ${ ),
# or if the command prefix contains shell operators (&&, ||, ;, |).
if echo "$cmd" | grep -q '<<<'; then
  herestring_val=$(echo "$cmd" | sed -n 's/.*<<<[[:space:]]*//p')
  if echo "$herestring_val" | grep -Eq '^["'"'"']'; then
    # Reject values containing shell expansion syntax
    if echo "$herestring_val" | grep -Eq '\$\(|`|\$\{'; then
      : # Fall through — let CC handle it
    else
      # Reject if command prefix (before <<<) contains shell operators
      cmd_prefix=$(echo "$cmd" | sed 's/<<<.*//')
      if echo "$cmd_prefix" | grep -Eq '&&|\|\||;|\|'; then
        : # Fall through — let CC handle it
      else
        emit_allow "Here-string (<<<) with quoted literal is safe — no file read"
      fi
    fi
  fi
fi

#@check 12  allow   Commands matching permissions.allow → allow (checks settings.json + settings.local.json)
# --- 12. Auto-approve commands already in permissions.allow ---
# CC's built-in safe command list is narrow (git read ops, echo, basic builtins).
# Most commands (python, pytest, npm, etc.) need an allow rule or user approval.
# This check provides a redundant safety net for when CC's own pattern matching
# misses due to special characters — if CC's matching works, this is a no-op.
# Guard: skip if command contains shell operators outside quotes — glob-to-regex
# would be too permissive for compound commands, and emitting allow bypasses CC's prompt.
cmd_no_quotes=$(echo "$cmd" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')
if echo "$cmd_no_quotes" | grep -Eq '&&|\|\||[|;]'; then
  exit 0
fi
allowlisted=false
settings_candidates=("$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json")
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  settings_candidates+=("$CLAUDE_PROJECT_DIR/.claude/settings.json" "$CLAUDE_PROJECT_DIR/.claude/settings.local.json")
fi
for settings_file in "${settings_candidates[@]}"; do
  [ -f "$settings_file" ] || continue
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    pattern=$(printf '%s' "$rule" | sed -e 's/[.+?^${}()|[\]\\]/\\&/g' -e 's/\*/.*/g')
    if echo "$cmd" | grep -Eq "^${pattern}$"; then
      allowlisted=true
      break 2
    fi
  done < <(jq -r '.permissions.allow[]? // empty | select(startswith("Bash(")) | sub("^Bash\\("; "") | sub("\\)$"; "")' "$settings_file" 2>/dev/null)
done

# --- Emit result ---
if [ "$allowlisted" = true ]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "Command matches existing permissions.allow rule"
    }
  }'
fi

exit 0

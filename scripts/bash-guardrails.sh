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

#@check 13  allow   Read-only pipelines / find -exec → allow (all stages are read-only)
# --- 13. Auto-approve read-only pipelines ---
# Handles commands that check 12 skips due to shell operators (|, \;, \(, etc).
# Splits on pipe, verifies every stage is a known read-only command.
# Also covers unpipelined find -exec with \; (which CC flags for backslash).

# Check if a command is read-only (cannot modify filesystem state).
is_readonly_cmd() {
  local c
  c=$(echo "$1" | sed 's/^[[:space:]]*//')
  local first
  first=$(echo "$c" | awk '{print $1}')
  [ -z "$first" ] && return 1
  case "$first" in
    cat|head|tail|less|more|wc|file|stat|du|df|tree|ls) return 0 ;;
    grep|egrep|fgrep|rg|ag) return 0 ;;
    find)
      # find is read-only unless -delete or -exec with a non-readonly command
      echo "$c" | grep -Eq '(^|[[:space:]])-delete([[:space:]]|$)' && return 1
      if echo "$c" | grep -Eq '(^|[[:space:]])-exec(dir)?[[:space:]]'; then
        local exec_cmd
        exec_cmd=$(echo "$c" | grep -oE '[-]exec(dir)?[[:space:]]+[^[:space:]]+' | awk '{print $NF}')
        [ -z "$exec_cmd" ] && return 1
        while IFS= read -r ecmd; do
          is_readonly_cmd "$ecmd" || return 1
        done <<< "$exec_cmd"
      fi
      return 0 ;;
    sort|uniq|tr|cut|diff|comm|join|paste|column|fold|rev|tac|nl|seq|bc) return 0 ;;
    jq|yq) return 0 ;;
    awk) return 0 ;;
    sed) echo "$c" | grep -Eq '(^|[[:space:]])-i' && return 1; return 0 ;;
    date|uname|hostname|id|groups|env|printenv|locale) return 0 ;;
    echo|printf|pwd|whoami|which|type|test|true) return 0 ;;
    git)
      local sub
      sub=$(echo "$c" | awk '{print $2}')
      case "$sub" in
        log|status|diff|show|branch|tag|rev-parse|describe) return 0 ;;
        ls-files|ls-remote|remote|shortlog|blame|reflog|count-objects) return 0 ;;
      esac
      return 1 ;;
    *) return 1 ;;
  esac
}

cmd_no_quotes=$(echo "$cmd" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')

# Only trigger for commands with operators CC might flag (\;, \|, \(, or real |)
if echo "$cmd_no_quotes" | grep -Eq '[|\\]'; then
  # Strip escaped operators (\;, \|, \(, etc.) — these are arguments, not shell syntax
  cmd_no_escapes=$(echo "$cmd_no_quotes" | sed 's/\\[;|&<>()]//g')
  # Bail if real compound operators remain (&&, ||, ;) — too complex to auto-approve
  if ! echo "$cmd_no_escapes" | grep -Eq '&&|\|\||;'; then
    all_readonly=true
    while IFS= read -r segment; do
      segment=$(echo "$segment" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      [ -z "$segment" ] && continue
      if ! is_readonly_cmd "$segment"; then
        all_readonly=false
        break
      fi
    done < <(echo "$cmd_no_escapes" | tr '|' '\n')
    if [ "$all_readonly" = true ]; then
      emit_allow "Read-only pipeline: all commands are read-only"
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

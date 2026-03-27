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
needs_rewrite=false

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

# Is a command read-only / safe for compounding?
# Only includes commands that CANNOT modify state regardless of flags.
# This is intentionally a strict subset of permissions.allow — commands
# like rm, mv, git push are trusted individually but not in chains.
is_safe_for_compound() {
  local c="$1"
  local first=$(echo "$c" | awk '{print $1}')
  [ -z "$first" ] && return 1
  case "$first" in
    cd|echo|printf|true|:|test|pwd|whoami|which|type|\[|\[\[) return 0 ;;
    cat|head|tail|less|more|wc|file|stat|du|df|tree|ls|ll|find) return 0 ;;
    grep|rg|ag) return 0 ;;
    sort|uniq|tr|cut|diff|comm|join|paste|column|fold|rev|tac|nl|seq|bc) return 0 ;;
    jq|yq) return 0 ;;
    date|uname|hostname|id|groups|env|printenv|locale) return 0 ;;
    git)
      local sub=$(echo "$c" | awk '{print $2}')
      case "$sub" in
        log|status|diff|show|branch|tag|rev-parse|describe) return 0 ;;
        ls-files|ls-remote|remote|shortlog|blame|reflog|count-objects) return 0 ;;
        config) echo "$c" | grep -Eq '\s--(get|list)\b' && return 0 ;;
        stash) echo "$c" | grep -Eq '\slist\b' && return 0 ;;
      esac
      return 1 ;;
    *)
      echo "$c" | grep -Eq '\s--version(\s|$)' && return 0
      echo "$c" | grep -Eq '^\s*\S+\s+version(\s|$)' && return 0
      return 1 ;;
  esac
}

# Check if a command matches any permissions.askForPermission Bash rule.
# Returns 0 (true) if the command would trigger a permission prompt.
matches_ask_permission() {
  local c="$1"
  local _candidates=("$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json")
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    _candidates+=("$CLAUDE_PROJECT_DIR/.claude/settings.json" "$CLAUDE_PROJECT_DIR/.claude/settings.local.json")
  fi
  for _sf in "${_candidates[@]}"; do
    [ -f "$_sf" ] || continue
    while IFS= read -r _rule; do
      [ -z "$_rule" ] && continue
      _pat=$(printf '%s' "$_rule" | sed -e 's/[.+?^${}()|[\]\\]/\\&/g' -e 's/\*/.*/g')
      if echo "$c" | grep -Eq "^${_pat}$"; then
        return 0
      fi
    done < <(jq -r '.permissions.askForPermission[]? // empty | select(startswith("Bash(")) | sub("^Bash\\("; "") | sub("\\)$"; "")' "$_sf" 2>/dev/null)
  done
  return 1
}

# Split a quote-stripped command on compound operators (||, &&, ;, |)
# into one sub-command per line. || before | to avoid partial matching.
split_on_operators() {
  echo "$1" | sed -E \
    -e 's/\s*\|\|\s*/\n/g' \
    -e 's/\s*&&\s*/\n/g' \
    -e 's/\s*;\s*/\n/g' \
    -e 's/\s*\|\s*/\n/g' | sed '/^\s*$/d'
}

#@check  1  strip   Comment-only lines → strip (prevents quote-tracker false positives)
# --- 1. Strip comment-only lines ---
# Prevents Claude Code's built-in quote tracker from flagging
# apostrophes/quotes inside # comments (e.g., "# don't do this")
cmd_stripped=$(echo "$cmd" | grep -v '^\s*#' || true)

if [ "$cmd_stripped" != "$cmd" ]; then
  if [ -z "$(echo "$cmd_stripped" | tr -d '[:space:]')" ]; then
    echo "BLOCKED: No command — only comments." >&2
    exit 2
  fi
  cmd="$cmd_stripped"
  needs_rewrite=true
fi

#@check  2  strip   Inline trailing comments → strip (quote-aware)
# --- 2. Strip inline trailing comments (quote-aware) ---
# Remove "# ..." at end of line when # follows whitespace and is outside quotes.
line="$cmd"
no_quotes=$(echo "$line" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')
if echo "$no_quotes" | grep -q ' #'; then
  pos=$(echo "$no_quotes" | grep -bo ' #' | head -1 | cut -d: -f1)
  if [ -n "$pos" ]; then
    cmd="${line:0:$((pos))}"
    needs_rewrite=true
  fi
fi

#@check  3  strip   Leading/trailing whitespace → trim (fixes allow-rule matching)
# --- 3. Trim leading/trailing whitespace ---
cmd_trimmed=$(echo "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
if [ "$cmd_trimmed" != "$cmd" ]; then
  cmd="$cmd_trimmed"
  needs_rewrite=true
fi

#@check  4  hint    Multiline commands → hint to split (unless control structure or heredoc)
# --- 4. Detect multiline, control structures, and heredocs ---
non_empty_lines=$(echo "$cmd" | grep -c '\S' || true)
is_control_structure=false
echo "$cmd" | head -1 | grep -Eq '^\s*(if|for|while|until|case)\b' && is_control_structure=true
has_heredoc=false
echo "$cmd" | grep -q '<<' && has_heredoc=true

if [ "$non_empty_lines" -gt 1 ] && [ "$is_control_structure" = false ] && [ "$has_heredoc" = false ]; then
  echo "HINT: Multiline command — prefer separate Bash tool calls." >&2
fi

# Extract command portion only (before heredoc body) for syntax checks.
# Heredoc bodies are stdin data — backticks, &&, $'...' there are literal text.
cmd_for_syntax="$cmd"
if [ "$has_heredoc" = true ]; then
  heredoc_line=$(echo "$cmd" | grep -n '<<' | head -1 | cut -d: -f1)
  cmd_for_syntax=$(echo "$cmd" | head -n "$heredoc_line")
fi

#@check  5  block   ANSI-C quoting ($'...') → block
#@check  6  block   Backtick substitution → block (use $() instead)
# --- 5–6. Block ANSI-C quoting and backtick substitution ---
# Strip single-quoted strings so patterns inside quotes aren't false positives.
no_sq=$(echo "$cmd_for_syntax" | sed -e "s/'[^']*'//g")
if echo "$no_sq" | grep -Eq "\\\$'"; then
  echo "BLOCKED: ANSI-C quoting (\$'...') triggers permission prompts. Use printf or regular quotes instead." >&2
  exit 2
fi
if echo "$no_sq" | grep -q '`'; then
  echo 'BLOCKED: Use $() instead of backticks, or separate Bash tool calls.' >&2
  exit 2
fi

#@check  7  block   Zsh-only syntax =() → block
# --- 7. Block Zsh-only syntax ---
if echo "$cmd" | grep -Eq '=\(' ; then
  echo 'BLOCKED: =() is Zsh-only. Use bash-compatible syntax (<(), mktemp, or arr=( ) with space).' >&2
  exit 2
fi

#@check  8  block   git commit --amend → block (create new commits instead)
# --- 8. Block git commit --amend ---
if echo "$cmd" | grep -Eq '^\s*git\s+commit\s.*--amend'; then
  echo 'BLOCKED: Do not amend — create a new commit instead.' >&2
  exit 2
fi

#@check  9  block   Compound operators (&&, ||, ;) → block unless all sub-commands are read-only
#@check 9b  allow   cd <path> && <single-cmd> → allow (cwd doesn't persist between tool calls)
# --- 9. Block compound command operators: &&, ||, ; ---
# Use cmd_for_syntax so heredoc bodies don't trigger false positives.
stripped=$(echo "$cmd_for_syntax" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')

# Remove shell control keywords after semicolons ("; then", "; do", etc.)
stripped_no_keywords=$(echo "$stripped" | sed -E 's/;[[:space:]]*(then|do|done|fi|else|elif|esac|in)([[:space:]]|$)/  \1\2/g')

# Allow "cd <path> && <cmd>" — cwd doesn't persist between tool calls.
stripped_no_cd=$(echo "$stripped_no_keywords" | sed -E 's/^[[:space:]]*cd[[:space:]]+[^&]*&&/ /')
cd_prefix_stripped=false
[ "$stripped_no_cd" != "$stripped_no_keywords" ] && cd_prefix_stripped=true

# Allow "|| true", "|| :", and "|| echo ..." (error suppression / default values).
stripped_no_fallback=$(echo "$stripped_no_cd" | sed -E \
  -e 's/[[:space:]]+\|\|[[:space:]]+(true|:)([[:space:]);)&]|$)/ \2/g' \
  -e 's/[[:space:]]+\|\|[[:space:]]+echo[[:space:]]+[^|;& ]*[[:space:]]*$//')

if echo "$stripped_no_fallback" | grep -Eq '(\s&&\s|\s\|\|\s|;\s*\S)'; then
  # Compound operators found — allow if every sub-command is read-only.
  compound_safe=true
  while IFS= read -r subcmd; do
    trimmed=$(echo "$subcmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$trimmed" ] && continue
    if echo "$trimmed" | grep -Eq 'git\s+commit\s.*--amend'; then
      compound_safe=false; break
    fi
    if ! is_safe_for_compound "$trimmed"; then
      compound_safe=false; break
    fi
  done < <(split_on_operators "$stripped")

  if [ "$compound_safe" = true ]; then
    # Don't auto-allow if any sub-command matches askForPermission rules.
    ask_match=false
    while IFS= read -r subcmd; do
      trimmed=$(echo "$subcmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      [ -z "$trimmed" ] && continue
      if matches_ask_permission "$trimmed"; then
        ask_match=true; break
      fi
    done < <(split_on_operators "$stripped")
    [ "$ask_match" = false ] && emit_allow "Compound command: all sub-commands are read-only"
    # Fall through — let Claude Code's native permission system handle it.
  else
    # List the unsafe sub-commands in the block message.
    echo "BLOCKED: Compound command — split into separate Bash tool calls:" >&2
    while IFS= read -r subcmd; do
      trimmed=$(echo "$subcmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      [ -z "$trimmed" ] && continue
      is_safe_for_compound "$trimmed" || echo "  → $trimmed" >&2
    done < <(split_on_operators "$stripped")
    if [ "$cd_prefix_stripped" = true ]; then
      cd_path=$(echo "$cmd" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^&]+)&&.*/\1/p' | sed 's/[[:space:]]*$//')
      echo "TIP: Use 'git -C $cd_path <subcommand>' instead of cd + git." >&2
    fi
    exit 2
  fi
fi

# --- 9b. Auto-allow "cd <path> && <single-command>" ---
# When section 9 stripped "cd <path> &&" and no compound operators remain,
# the command is a single command in a different directory.
if [ "$cd_prefix_stripped" = true ]; then
  remaining=$(echo "$stripped_no_cd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -n "$remaining" ] && ! matches_ask_permission "$remaining"; then
    emit_allow "cd + single command: cd prefix is safe, individual command passes all checks"
  fi
  # If remaining matches askForPermission, fall through to native permission system.
fi

#@check 10  hint    Pipes from cat/grep/find/ls → hint to use Read/Grep/Glob tools
# --- 10. Warn on pipe usage (only when dedicated tools exist) ---
pipe_source=$(echo "$cmd" | grep -oE '^\s*(cat|head|tail|grep|rg|find|ls)\s' | head -1 | tr -d '[:space:]' || true)
if [ -n "$pipe_source" ]; then
  echo "HINT: Consider using Read/Grep/Glob tools instead of piping from $pipe_source." >&2
fi

#@check 11  allow   Here-strings (<<<) with quoted literals → allow (no file read)
# --- 11. Auto-approve here-strings (<<<) with quoted string literals ---
# Claude Code sees "<" in "<<<" and warns about reading sensitive files,
# but <<< "string" just feeds a literal to stdin — no file involved.
if echo "$cmd" | grep -q '<<<'; then
  herestring_val=$(echo "$cmd" | sed -n 's/.*<<<[[:space:]]*//p')
  echo "$herestring_val" | grep -Eq '^["'"'"']' && \
    emit_allow "Here-string (<<<) with quoted literal is safe — no file read"
fi

#@check 12  allow   Commands matching permissions.allow → allow (checks settings.json + settings.local.json)
# --- 12. Auto-approve commands already in permissions.allow ---
# Claude Code sometimes re-prompts for already-trusted commands (e.g., quoted
# characters). If the command matches an allow rule, suppress the prompt.
# This runs AFTER all blocking checks, so dangerous patterns are still caught.
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

# --- 13. Emit result ---
if [ "$needs_rewrite" = true ]; then
  jq -n --arg cmd "$cmd" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "Command cleaned (comments stripped / whitespace trimmed) to avoid heuristic triggers",
      updatedInput: {
        command: $cmd
      }
    }
  }'
elif [ "$allowlisted" = true ]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: "Command matches existing permissions.allow rule"
    }
  }'
fi

exit 0

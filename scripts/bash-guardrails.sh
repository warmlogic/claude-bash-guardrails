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

# Load permissions.allow and permissions.deny rules from settings files.
# Populates bash arrays: allow_rules[] and deny_rules[].
allow_rules=()
deny_rules=()
settings_candidates=("$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json")
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  settings_candidates+=("$CLAUDE_PROJECT_DIR/.claude/settings.json" "$CLAUDE_PROJECT_DIR/.claude/settings.local.json")
fi
for settings_file in "${settings_candidates[@]}"; do
  [ -f "$settings_file" ] || continue
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    allow_rules+=("$rule")
  done < <(jq -r '.permissions.allow[]? // empty | select(startswith("Bash(")) | sub("^Bash\\("; "") | sub("\\)$"; "")' "$settings_file" 2>/dev/null)
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    deny_rules+=("$rule")
  done < <(jq -r '.permissions.deny[]? // empty | select(startswith("Bash(")) | sub("^Bash\\("; "") | sub("\\)$"; "")' "$settings_file" 2>/dev/null)
done

# Check if a command matches any rule in a list.
# Usage: matches_rule "command" "${rules[@]}"
matches_rule() {
  local cmd_to_check="$1"; shift
  local rule
  for rule in "$@"; do
    [ -z "$rule" ] && continue
    local pattern
    pattern=$(printf '%s' "$rule" | sed -e 's/[.+?^${}()|[\]\\]/\\&/g' -e 's/\*/.*/g')
    if echo "$cmd_to_check" | grep -Eq "^${pattern}$"; then
      return 0
    fi
  done
  return 1
}

# Emit a PreToolUse allow decision and exit.
# Automatically includes updatedInput if the command was rewritten.
emit_allow() {
  if [ "$needs_rewrite" = true ]; then
    jq -n --arg reason "$1" --arg cmd "$cmd" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: $reason,
        updatedInput: { command: $cmd }
      }
    }'
  else
    jq -n --arg reason "$1" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: $reason
      }
    }'
  fi
  exit 0
}

#@check  1  strip   Comment-only lines → strip (prevents CC's #-after-newline heuristic)
# --- 1. Strip comment-only lines ---
# CC flags commands with # after a newline in quotes as potential argument hiding.
# Comments are no-ops — stripping them changes nothing about execution.
cmd_stripped=$(echo "$cmd" | grep -v '^\s*#' || true)

if [ "$cmd_stripped" != "$cmd" ]; then
  if [ -z "$(echo "$cmd_stripped" | tr -d '[:space:]')" ]; then
    # Command was only comments — nothing to run, let CC handle it
    exit 0
  fi
  cmd="$cmd_stripped"
  needs_rewrite=true
fi

#@check  2  strip   Inline trailing comments → strip (quote-aware)
# --- 2. Strip inline trailing comments (quote-aware) ---
# Remove "# ..." at end of line when # follows whitespace and is outside quotes.
line="$cmd"
no_quotes_for_comments=$(echo "$line" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')
if echo "$no_quotes_for_comments" | grep -q ' #'; then
  pos=$(echo "$no_quotes_for_comments" | grep -bo ' #' | head -1 | cut -d: -f1)
  if [ -n "$pos" ]; then
    cmd="${line:0:$((pos))}"
    needs_rewrite=true
  fi
fi

#@check  3  strip   Leading/trailing whitespace → trim (fixes allowlist matching)
# --- 3. Trim leading/trailing whitespace ---
cmd_trimmed=$(echo "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
if [ "$cmd_trimmed" != "$cmd" ]; then
  cmd="$cmd_trimmed"
  needs_rewrite=true
fi

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

#@check 13  allow   Compound commands (&&, ||, ;) and shell loops/conditionals → allow if all sub-commands are safe
# --- 13. Auto-approve safe compound commands ---
# CC blocks compound operators to prevent chaining attacks, but common
# patterns like "cd <path> && git commit" are safe.
# Also handles shell control flow (for/while/until/if/case) — extracts
# inner commands and command substitutions, verifies each is safe.
# Splits on compound operators, verifies every sub-command is known-safe.

# Check if a command is approved for compounding — hardcoded safe list, then
# deny/allow rules. Used for inner command checks (command substitutions in
# for iterators, variable assignments, find -exec, and flow-control conditions)
# so that allow rules apply uniformly at every nesting level.
is_cmd_approved() {
  local cmd="$1"
  # Deny rules take priority
  if [ ${#deny_rules[@]} -gt 0 ] && matches_rule "$cmd" "${deny_rules[@]}"; then
    return 1
  fi
  is_safe_for_compound "$cmd" && return 0
  [ ${#allow_rules[@]} -gt 0 ] && matches_rule "$cmd" "${allow_rules[@]}" && return 0
  return 1
}

# Is a command safe for compounding?
# Broader than is_readonly_cmd — includes write ops that are normal dev workflow.
is_safe_for_compound() {
  local c
  c=$(echo "$1" | sed 's/^[[:space:]]*//')
  local first
  first=$(echo "$c" | awk '{print $1}')
  [ -z "$first" ] && return 1
  case "$first" in
    cd|echo|printf|true|:|test|\[|pwd|whoami|which|type|read) return 0 ;;
    # Shell control-flow keywords
    done|fi|esac) return 0 ;;  # closing keywords — no-ops
    do|then|else|elif)
      # Keyword followed by a command — strip keyword, check the command
      local rest
      rest=$(echo "$c" | sed "s/^${first}[[:space:]]*//" )
      [ -z "$rest" ] && return 0
      is_cmd_approved "$rest"
      return $? ;;
    for|select)
      # for VAR in EXPR — check command substitutions in EXPR
      local expr
      expr=$(echo "$c" | sed -n 's/^[a-z]*[[:space:]]*[^[:space:]]*[[:space:]]*in[[:space:]]*//p')
      if echo "$expr" | grep -q '\$('; then
        local inner
        while IFS= read -r inner; do
          [ -z "$inner" ] && continue
          is_cmd_approved "$inner" || return 1
        done < <(echo "$expr" | grep -oE '\$\([^)]+\)' | sed -e 's/^\$(//' -e 's/)$//')
      fi
      if echo "$expr" | grep -q '`'; then
        local inner_bt
        while IFS= read -r inner_bt; do
          [ -z "$inner_bt" ] && continue
          is_cmd_approved "$inner_bt" || return 1
        done < <(echo "$expr" | grep -oE '`[^`]+`' | sed -e 's/^`//' -e 's/`$//')
      fi
      return 0 ;;
    while|until|if)
      # Check the condition command
      local cond
      cond=$(echo "$c" | sed "s/^${first}[[:space:]]*//" )
      [ -z "$cond" ] && return 0
      is_cmd_approved "$cond"
      return $? ;;
    cat|head|tail|less|more|wc|file|stat|du|df|tree|ls) return 0 ;;
    basename|dirname|realpath|readlink) return 0 ;;
    grep|egrep|fgrep|rg|ag) return 0 ;;
    find)
      echo "$c" | grep -Eq '(^|[[:space:]])-delete([[:space:]]|$)' && return 1
      if echo "$c" | grep -Eq '(^|[[:space:]])-exec(dir)?[[:space:]]'; then
        local exec_cmd
        exec_cmd=$(echo "$c" | grep -oE '[-]exec(dir)?[[:space:]]+[^[:space:]]+' | awk '{print $NF}')
        [ -z "$exec_cmd" ] && return 1
        while IFS= read -r ecmd; do
          is_cmd_approved "$ecmd" || return 1
        done <<< "$exec_cmd"
      fi
      return 0 ;;
    sort|uniq|tr|cut|diff|comm|join|paste|column|fold|rev|tac|nl|seq|bc) return 0 ;;
    jq|yq) return 0 ;;
    awk) return 0 ;;
    sed) echo "$c" | grep -Eq '(^|[[:space:]])-i' && return 1; return 0 ;;
    date|uname|hostname|id|groups|env|printenv|locale) return 0 ;;
    md5sum|sha256sum|sha512sum|shasum|b2sum) return 0 ;;
    nproc|getconf) return 0 ;;
    xxd|od|hexdump|strings) return 0 ;;
    mkdir|touch) return 0 ;;
    cp|mv|ln) return 0 ;;
    tee) return 0 ;;
    tar|zip|unzip|gzip|gunzip|bzip2|xz) return 0 ;;
    python|python3|node|ruby|perl)
      # Inline scripts (-c) and module runs (-m) are typical dev commands
      return 0 ;;
    pip|pip3|npm|npx|yarn|pnpm|cargo|go|make|cmake) return 0 ;;
    pytest|jest|vitest|mocha) return 0 ;;
    chmod) return 0 ;;
    rm)
      # Allow rm in compound commands, but block dangerous targets.
      # Strip flags to isolate path arguments for safety checks.
      local rm_args
      rm_args=$(echo "$c" | sed -E 's/^rm[[:space:]]*//' | sed -E 's/(^|[[:space:]])-[a-zA-Z]+//g' | sed 's/^[[:space:]]*//')
      # Block if no path arguments remain (bare "rm -rf" is a mistake)
      [ -z "$rm_args" ] && return 1
      # Block targeting root, home, parent dir, or .git
      echo "$rm_args" | grep -Eq '(^|[[:space:]])(\/[[:space:]]*$|~([[:space:]]|\/[[:space:]]*$|$)|\.\.|\.git)' && return 1
      return 0 ;;
    gh) return 0 ;;
    git)
      local sub
      sub=$(echo "$c" | awk '{print $2}')
      case "$sub" in
        # Read-only
        log|status|diff|show|branch|tag|rev-parse|describe) return 0 ;;
        ls-files|ls-remote|remote|shortlog|blame|reflog|count-objects) return 0 ;;
        cat-file|name-rev|for-each-ref|merge-base|rev-list) return 0 ;;
        config) echo "$c" | grep -Eq '(^|[[:space:]])--(get|list)([[:space:]]|$)' && return 0 ;;
        stash) return 0 ;;  # all stash ops (push, pop, apply, list, show, drop)
        clone) return 0 ;;
        # Write ops — standard dev workflow, safe in compound commands
        add|commit|push|pull|fetch|checkout|switch|restore|merge|rebase|cherry-pick) return 0 ;;
        rm|mv) return 0 ;;
        # git clean, git reset --hard are destructive — not auto-approved
      esac
      return 1 ;;
    *)
      # Variable assignments: VAR=value or VAR=$(cmd)
      if echo "$first" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then
        local val
        val=$(echo "$c" | sed 's/^[A-Za-z_][A-Za-z0-9_]*=//')
        # Check command substitutions within the value
        if echo "$val" | grep -q '\$('; then
          local inner
          while IFS= read -r inner; do
            [ -z "$inner" ] && continue
            is_cmd_approved "$inner" || return 1
          done < <(echo "$val" | grep -oE '\$\([^)]+\)' | sed -e 's/^\$(//' -e 's/)$//')
        fi
        if echo "$val" | grep -q '`'; then
          local inner_bt
          while IFS= read -r inner_bt; do
            [ -z "$inner_bt" ] && continue
            is_cmd_approved "$inner_bt" || return 1
          done < <(echo "$val" | grep -oE '`[^`]+`' | sed -e 's/^`//' -e 's/`$//')
        fi
        return 0
      fi
      # Allow --version / version checks
      echo "$c" | grep -Eq '(^|[[:space:]])--version([[:space:]]|$)' && return 0
      echo "$c" | grep -Eq '^\s*\S+\s+version([[:space:]]|$)' && return 0
      return 1 ;;
  esac
}

# Split a quote-stripped command on compound operators (&&, ||, ;)
# into one sub-command per line.
split_on_compound() {
  echo "$1" | sed -E \
    -e 's/[[:space:]]*\|\|[[:space:]]*/\n/g' \
    -e 's/[[:space:]]*&&[[:space:]]*/\n/g' \
    -e 's/[[:space:]]*;[[:space:]]*/\n/g' | sed '/^[[:space:]]*$/d'
}

cmd_no_quotes=$(echo "$cmd" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')

# Strip escaped operators (\;, \|, etc.) before checking for compound operators —
# these are arguments (e.g., find -exec {} \;), not shell syntax.
cmd_no_escapes_compound=$(echo "$cmd_no_quotes" | sed 's/\\[;|&<>()]//g')

if echo "$cmd_no_escapes_compound" | grep -Eq '&&|\|\||;'; then
  compound_safe=true
  compound_denied=false
  while IFS= read -r subcmd; do
    subcmd=$(echo "$subcmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$subcmd" ] && continue
    # Strip leading flow-control keywords for rule matching.
    # is_safe_for_compound handles these internally via is_cmd_approved, but
    # the outer loop also needs the actual command for its own rule fallback.
    subcmd_for_rules="$subcmd"
    case "$(echo "$subcmd_for_rules" | awk '{print $1}')" in
      do|then|else|elif|while|until|if)
        subcmd_for_rules=$(echo "$subcmd_for_rules" | sed 's/^[[:space:]]*[a-z]*[[:space:]]*//')
        ;;
    esac
    # Deny rules take priority — if any sub-command is denied, block immediately
    if [ ${#deny_rules[@]} -gt 0 ] && matches_rule "$subcmd_for_rules" "${deny_rules[@]}"; then
      compound_denied=true
      break
    fi
    # Check hardcoded safe list first, then fall back to allow rules
    if ! is_safe_for_compound "$subcmd"; then
      if [ ${#allow_rules[@]} -gt 0 ] && matches_rule "$subcmd_for_rules" "${allow_rules[@]}"; then
        continue  # Allowed by user's permissions
      fi
      compound_safe=false
      break
    fi
  done < <(split_on_compound "$cmd_no_escapes_compound")

  if [ "$compound_denied" = true ]; then
    exit 0  # Fall through — let CC handle the denied command
  elif [ "$compound_safe" = true ]; then
    emit_allow "Compound command: all sub-commands are known-safe or allowlisted"
  fi
fi

#@check 14  allow   Safe pipelines / find -exec → allow (all stages are known-safe)
# --- 14. Auto-approve safe pipelines ---
# Handles commands that check 15 skips due to shell operators (|, \;, \(, etc).
# Splits on pipe, verifies every stage passes is_cmd_approved (deny → safe → allow).
# Pipelines are more constrained than && chains (stages communicate only via
# stdin/stdout), so using the same safety check as compound commands is sound.
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
    basename|dirname|realpath|readlink) return 0 ;;
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
    md5sum|sha256sum|sha512sum|shasum|b2sum) return 0 ;;
    nproc|getconf) return 0 ;;
    xxd|od|hexdump|strings) return 0 ;;
    echo|printf|pwd|whoami|which|type|test|true) return 0 ;;
    git)
      local sub
      sub=$(echo "$c" | awk '{print $2}')
      case "$sub" in
        log|status|diff|show|branch|tag|rev-parse|describe) return 0 ;;
        ls-files|ls-remote|remote|shortlog|blame|reflog|count-objects) return 0 ;;
        cat-file|name-rev|for-each-ref|merge-base|rev-list) return 0 ;;
      esac
      return 1 ;;
    *) return 1 ;;
  esac
}

# Only trigger for commands with operators CC might flag (\;, \|, \(, or real |)
if echo "$cmd_no_quotes" | grep -Eq '[|\\]'; then
  # Strip escaped operators (\;, \|, \(, etc.) — these are arguments, not shell syntax
  cmd_no_escapes=$(echo "$cmd_no_quotes" | sed 's/\\[;|&<>()]//g')
  # Bail if real compound operators remain (&&, ||, ;) — too complex to auto-approve
  if ! echo "$cmd_no_escapes" | grep -Eq '&&|\|\||;'; then
    all_safe=true
    while IFS= read -r segment; do
      segment=$(echo "$segment" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      [ -z "$segment" ] && continue
      if ! is_safe_for_compound "$segment"; then
        all_safe=false
        break
      fi
    done < <(echo "$cmd_no_escapes" | tr '|' '\n')
    if [ "$all_safe" = true ]; then
      emit_allow "Safe pipeline: all stages are known-safe"
    fi
  fi
fi

#@check 15  allow   Commands matching permissions.allow → allow (checks settings.json + settings.local.json)
# --- 15. Auto-approve commands already in permissions.allow ---
# CC's built-in safe command list is narrow (git read ops, echo, basic builtins).
# Most commands (python, pytest, npm, etc.) need an allow rule or user approval.
# This check provides a redundant safety net for when CC's own pattern matching
# misses due to special characters — if CC's matching works, this is a no-op.
# Guard: skip if command contains shell operators outside quotes — glob-to-regex
# would be too permissive for compound/piped commands. Compound operators are
# handled by check 13 above.
allowlisted=false
if echo "$cmd_no_quotes" | grep -Eq '&&|\|\||[|;]'; then
  : # Skip allowlist matching — glob-to-regex is too permissive for compound/piped commands
elif [ ${#allow_rules[@]} -gt 0 ] && matches_rule "$cmd" "${allow_rules[@]}"; then
  allowlisted=true
fi

# --- Emit result ---
if [ "$allowlisted" = true ]; then
  emit_allow "Command matches existing permissions.allow rule"
elif [ "$needs_rewrite" = true ]; then
  # Command was cleaned but no check approved it — emit the rewrite
  # without an allow decision so CC re-evaluates the cleaned command.
  jq -n --arg cmd "$cmd" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      updatedInput: { command: $cmd }
    }
  }'
fi

exit 0

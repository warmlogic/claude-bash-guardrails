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

#@check  0  deny    Heredoc inside $(...) → deny with guidance (shell parser trap)
# --- 0. Deny heredoc-in-command-substitution ---
# The pattern `git commit -m "$(cat <<'EOF' ... EOF)" && ...` is a common
# LLM instinct for multi-line commit messages, but it trips two parsers:
#   - zsh -c eval: "(eval):N: unmatched \"" when chained with &&
#   - CC's bash tree-sitter parser: "Unhandled node type: string"
# Both cause the command to fail or to require a permission prompt.
# Writing the content to a temp file and using -F / --body-file is
# strictly cleaner and works universally — so deny this pattern early
# with a clear message that the model can act on.
if printf '%s' "$cmd" | grep -qF '$(cat <<'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Heredoc inside command substitution (`$(cat <<EOF ... EOF)`) is a shell-parser trap in Claude Code — it fails zsh -c eval when chained with `&&` and trips CC bash tool parser with `Unhandled node type: string`. Write the content to a temp file with the Write tool, then pass it via a file flag: `git commit -F /tmp/msg.txt`, `gh pr create --body-file /tmp/body.txt`, etc. Do NOT delete the temp file afterward — /tmp is self-cleaning and `rm /tmp/...` triggers a permission prompt."
    }
  }'
  exit 0
fi

#@check  4  deny    Interpreter heredoc (python3/node/ruby/perl <<EOF) → deny with guidance (CC strips indentation)
# --- 4. Deny interpreter + heredoc ---
# CC's Bash tool strips ALL leading whitespace from every line of the command
# string before execution, including heredoc body lines. Python code in a
# heredoc silently loses indentation and fails with IndentationError at
# runtime — with no clear signal of the root cause from CC.
# The fix is always to write the script to a temp file with the Write tool
# and run the interpreter on the file directly.
# Uses (^|[[:space:]])<<-?[[:space:]]*[A-Za-z_'"] to require a valid heredoc
# delimiter character after << — excludes arithmetic << (e.g. 1 << 4 has a
# digit after <<) and <<< here-strings (< after <<). The [[:space:]]* allows
# for `<< 'EOF'` (space between << and delimiter), which LLMs commonly emit.
if printf '%s' "$cmd" | grep -Eq '^\s*(python3?|node|ruby|perl)\b' && \
   printf '%s' "$cmd" | grep -Eq "(^|[[:space:]])<<-?[[:space:]]*[A-Za-z_'\"]"; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Interpreter heredoc (e.g. `python3 <<EOF`) will silently break indentation — CC'\''s Bash tool strips all leading whitespace from every heredoc body line before execution, causing `IndentationError` in Python (and equivalent failures in other interpreters). Write the script to a temp file with the Write tool (`/tmp/script.py`), then run `python3 /tmp/script.py`. Do NOT delete the temp file afterward — /tmp is self-cleaning and `rm /tmp/...` triggers a permission prompt."
    }
  }'
  exit 0
fi

#@check  4b deny    Multi-line python3 -c with indented body → deny with guidance (CC strips indentation)
# --- 4b. Deny multi-line python3 -c with indented lines ---
# Same root cause as check 4: CC strips leading whitespace from every line of
# the command string. A multi-line `python3 -c "..."` loses all indentation
# before the interpreter sees it, causing IndentationError on any control flow.
# Verified: `python3 -c "\nfor i in range(3):\n    print(i)\n"` fails in CC.
# Only fires when there are indented lines (leading whitespace on a non-first
# line) — top-level-only scripts (no for/if/def body) work fine after stripping.
# Uses awk: reads all lines, returns true if any line after line 1 starts with
# a space or tab (i.e., there is an indented block).
if printf '%s' "$cmd" | grep -Eq '^\s*python3?\b[^|;&]*[[:space:]]-c[[:space:]]' && \
   printf '%s' "$cmd" | awk 'NR>1 && /^[[:space:]]/{found=1; exit} END{exit !found}'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Multi-line `python3 -c` script will silently break indentation — CC'\''s Bash tool strips all leading whitespace from every line of the command string before execution, causing `IndentationError` on any indented control flow. Write the script to a temp file with the Write tool (`/tmp/script.py`), then run `python3 /tmp/script.py`. Do NOT delete the temp file afterward — /tmp is self-cleaning and `rm /tmp/...` triggers a permission prompt."
    }
  }'
  exit 0
fi

# --- Helpers ---

# Strip quoted content ('...' and "...") across newlines.
# sed's [^"]* can't match across newlines, so multi-line quoted strings
# (e.g. bd create --description "line1\nline2") would leak operators
# like ; or && into compound detection. awk with RS="\0" reads the
# entire input as one record so character classes can match newlines.
# Respects backslash escapes (\", \', \\).
strip_quoted_mls() {
  printf '%s' "$1" | awk 'BEGIN { RS="\0" } {
    sq = 0; dq = 0
    out = ""
    n = length($0)
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (c == "\\" && i < n) {
        if (sq == 0 && dq == 0) { out = out c substr($0, i+1, 1) }
        i++
        continue
      }
      if (dq == 0 && c == "\x27") { sq = 1 - sq; continue }
      if (sq == 0 && c == "\"")  { dq = 1 - dq; continue }
      if (sq == 0 && dq == 0) out = out c
    }
    printf "%s", out
  }'
}

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

#@check  3  strip   Leading/trailing whitespace → trim (fixes allowlist matching)
# --- 3. Trim leading/trailing whitespace ---
cmd_trimmed=$(echo "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
if [ "$cmd_trimmed" != "$cmd" ]; then
  cmd="$cmd_trimmed"
  needs_rewrite=true
fi

#@check 13  allow   Compound commands (&&, ||, ;, |, &, newlines) and shell loops/conditionals → allow if every sub-command is safe
# --- 13. Auto-approve safe compound commands ---
# CC blocks compound operators to prevent chaining attacks, but common
# patterns like "cd <path> && git commit" are safe.
# Also handles shell control flow (for/while/until/if/case) — extracts
# inner commands and command substitutions, verifies each is safe.
# Splits on every top-level separator (split_on_compound: &&, ||, ;, |, &,
# newline; heredoc bodies dropped first), verifies every sub-command is safe.

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
  allow_rule_fallback "$cmd" && return 0
  return 1
}

# Allow-rule fallback for a command is_safe_for_compound rejected. Fires only
# when the first token is NOT hardcoded: for a hardcoded token, the rejection
# is a safety carveout (rm on /, ~, .., .git; find -delete; find -exec rm;
# sed -i; git clean) and a broad user rule like `Bash(rm *)` or `Bash(find *)`
# must not override it. Declining here never denies — the hook just emits no
# allow, and Claude Code's own permission check decides. Used at every level
# (compound sub-commands, nested conditions/substitutions, pipeline stages)
# so no sub-command of a multi-part command gets past a hardcoded carveout.
# A lone command matching a rule is check 15's job: there the rule names the
# whole command, so the hook allows only what the user's rule already covers.
# Limits: the carveouts read quote-stripped text, so a path hidden in quotes
# (`rm -rf "$HOME"`, `rm -rf $'/'`) or a nested $(...) isn't seen — they
# catch commands a model plausibly emits, not deliberate obfuscation.
allow_rule_fallback() {
  is_first_token_hardcoded "$1" && return 1
  [ ${#allow_rules[@]} -gt 0 ] && matches_rule "$1" "${allow_rules[@]}"
}

# Approve every unquoted $(...) and `...` in a command (non-nested; arithmetic
# $((...)) is not a substitution and is dropped first).
vet_substitutions() {
  local s inner piece
  s=$(echo "$1" | sed -E 's/\$\(\([^)]*\)\)//g')
  while IFS= read -r inner; do
    [ -z "$inner" ] && continue
    # A substitution can itself be a pipeline or compound — vet every piece
    while IFS= read -r piece; do
      is_cmd_approved "$piece" || return 1
    done < <(split_on_compound "$inner")
  done < <(echo "$s" | grep -oE '\$\([^)]+\)|`[^`]+`' | sed -E -e 's/^\$\(//' -e 's/\)$//' -e 's/^`//' -e 's/`$//')
  return 0
}

# Is a command safe for compounding?
# Broader than is_readonly_cmd — includes write ops that are normal dev workflow.
is_safe_for_compound() {
  local c
  c=$(echo "$1" | sed 's/^[[:space:]]*//')
  local first
  first=$(echo "$c" | awk '{print $1}')
  [ -z "$first" ] && return 1
  # Unquoted command substitutions run wherever they appear (a for list, an
  # assignment value, an echo argument) — each must itself be approved.
  vet_substitutions "$c" || return 1
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
    for|select) return 0 ;;  # for VAR in EXPR — EXPR's substitutions vetted above
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
    # In-place edit in any spelling: -i, -i.bak, clustered -Ei / -ni, --in-place
    sed) echo "$c" | grep -Eq '(^|[[:space:]])(-[a-zA-Z]*i|--in-place)' && return 1; return 0 ;;
    env)
      # `env [-flags] [VAR=val ...] cmd` runs cmd — strip the prefix, vet cmd
      local rest
      rest=$(echo "$c" | sed -E -e 's/^env[[:space:]]*//' -e 's/^((-[^[:space:]]*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]*)*//')
      [ -z "$rest" ] && return 0
      is_cmd_approved "$rest"
      return $? ;;
    date|uname|hostname|id|groups|printenv|locale) return 0 ;;
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
      # Variable assignments: VAR=value or VAR=$(cmd) — substitutions in the
      # value were vetted above. An env-prefixed command (`FOO=1 cmd ...`)
      # runs cmd: once the substitutions are dropped, whatever follows the
      # first word of the value must itself be approved.
      if echo "$first" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then
        local rest
        rest=$(echo "$c" | sed -E -e 's/^[A-Za-z_][A-Za-z0-9_]*=//' -e 's/\$\([^)]*\)//g' -e 's/`[^`]*`//g' -e 's/^[^[:space:]]*[[:space:]]*//')
        [ -z "$rest" ] && return 0
        is_cmd_approved "$rest"
        return $?
      fi
      # Allow --version / version checks
      echo "$c" | grep -Eq '(^|[[:space:]])--version([[:space:]]|$)' && return 0
      echo "$c" | grep -Eq '^\s*\S+\s+version([[:space:]]|$)' && return 0
      return 1 ;;
  esac
}

# Is the first token of a command one of the cases in is_safe_for_compound?
# When true, is_safe_for_compound's verdict is authoritative for this segment —
# a `return 1` means a safety carveout fired (e.g., `find -delete`, `sed -i`,
# `find -exec rm`) and callers must NOT override via allow-rule fallback.
# When false, the token is simply unknown and allow-rule fallback is safe.
is_first_token_hardcoded() {
  local first
  first=$(echo "$1" | sed 's/^[[:space:]]*//' | awk '{print $1}')
  [ -z "$first" ] && return 1
  # VAR=value assignments are handled by is_safe_for_compound's * branch
  echo "$first" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=' && return 0
  case "$first" in
    cd|echo|printf|true|:|test|\[|pwd|whoami|which|type|read) return 0 ;;
    done|fi|esac|do|then|else|elif|for|select|while|until|if) return 0 ;;
    cat|head|tail|less|more|wc|file|stat|du|df|tree|ls) return 0 ;;
    basename|dirname|realpath|readlink) return 0 ;;
    grep|egrep|fgrep|rg|ag) return 0 ;;
    find) return 0 ;;
    sort|uniq|tr|cut|diff|comm|join|paste|column|fold|rev|tac|nl|seq|bc) return 0 ;;
    jq|yq|awk|sed) return 0 ;;
    date|uname|hostname|id|groups|env|printenv|locale) return 0 ;;
    md5sum|sha256sum|sha512sum|shasum|b2sum) return 0 ;;
    nproc|getconf) return 0 ;;
    xxd|od|hexdump|strings) return 0 ;;
    mkdir|touch|cp|mv|ln|tee|chmod|rm) return 0 ;;
    tar|zip|unzip|gzip|gunzip|bzip2|xz) return 0 ;;
    python|python3|node|ruby|perl) return 0 ;;
    pip|pip3|npm|npx|yarn|pnpm|cargo|go|make|cmake) return 0 ;;
    pytest|jest|vitest|mocha) return 0 ;;
    gh|git) return 0 ;;
    *) return 1 ;;
  esac
}

# Split a quote-stripped command into one sub-command per line. Separators, at
# the top level only: &&, ||, ;, newline, pipes (|, |&), and background (&) —
# every piece runs, so every piece must be vetted. Text inside $(...) and
# backticks stays with its piece (vet_substitutions handles it); redirections
# (2>&1, &>f, >&2) are not separators; backslash-escaped characters (\;) are
# arguments, and a backslash-newline continuation joins its lines.
split_on_compound() {
  printf '%s' "$1" | awk 'BEGIN { RS = "\0" }
    function emit() { gsub(/^[ \t]+|[ \t]+$/, "", out); if (out != "") print out; out = "" }
    {
      out = ""; depth = 0; bt = 0; n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1); nx = substr($0, i + 1, 1)
        if (bt) { out = out c; if (c == "`") bt = 0; continue }
        if (c == "`") { bt = 1; out = out c; continue }
        if (c == "$" && nx == "(") { depth++; out = out "$("; i++; continue }
        if (depth > 0) {
          if (c == "(") depth++; else if (c == ")") depth--
          out = out c; continue
        }
        if (c == "\\") { if (nx == "\n") out = out " "; else out = out c nx; i++; continue }
        if (c == "\n" || c == ";") { emit(); continue }
        if (c == "|") { if (nx == "|" || nx == "&") i++; emit(); continue }
        if (c == "&") {
          if (nx == "&") { i++; emit(); continue }
          last = substr(out, length(out), 1)
          if (last == ">" || last == "<" || nx == ">") { out = out c; continue }
          emit(); continue
        }
        out = out c
      }
      emit()
    }'
}

# Drop heredoc bodies (the lines after `<<DELIM` up to the DELIM line): they
# are data, not commands, and an apostrophe in one would unbalance the quote
# stripping. `<<<` here-strings are left alone.
strip_heredocs() {
  printf '%s' "$1" | awk '
    delim != "" { t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t); if (t == delim) delim = ""; next }
    {
      print
      if (match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/) && substr($0, RSTART - 1, 1) != "<") {
        d = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*["\047]?/, "", d); delim = d
      }
    }'
}

cmd_no_quotes=$(strip_quoted_mls "$(strip_heredocs "$cmd")")

# Strip escaped operators (\;, \|, etc.) before checking for compound operators —
# these are arguments (e.g., find -exec {} \;), not shell syntax.
cmd_no_escapes_compound=$(echo "$cmd_no_quotes" | sed 's/\\[;|&<>()]//g')

# More than one piece (compound, pipeline, background, or multi-line) → vet each
if [ "$(split_on_compound "$cmd_no_escapes_compound" | wc -l)" -gt 1 ]; then
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
    # Check hardcoded safe list first, then fall back to allow rules (guarded:
    # never overrides a hardcoded carveout — see allow_rule_fallback)
    if ! is_safe_for_compound "$subcmd"; then
      if allow_rule_fallback "$subcmd_for_rules"; then
        continue  # Unknown command, user has explicit allow rule
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

#@check 14  allow   Safe pipelines / find -exec → allow (stages are known-safe or allowlisted)
# --- 14. Auto-approve safe pipelines ---
# Check 13 already vets any multi-piece command, pipelines included; what
# reaches here with an allow still possible is a single piece carrying an
# escaped operator (find -exec ... \;), which check 15's guard skips.
# Every stage must pass: deny → hardcoded safe → allow rule.
# Allow-rule fallback only fires when the first token is NOT in the hardcoded
# list — ensures safety carveouts (find -delete, sed -i, find -exec rm) are
# never overridden by a broad user rule like `Bash(find *)`. Unknown commands
# (curl, wget, bd, etc.) still pass when explicitly allowlisted.
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
    pipeline_denied=false
    while IFS= read -r segment; do
      segment=$(echo "$segment" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      [ -z "$segment" ] && continue
      # Deny rules take priority
      if [ ${#deny_rules[@]} -gt 0 ] && matches_rule "$segment" "${deny_rules[@]}"; then
        pipeline_denied=true
        break
      fi
      # Check hardcoded safe list first, then the guarded allow-rule fallback
      if ! is_safe_for_compound "$segment"; then
        if allow_rule_fallback "$segment"; then
          continue  # Unknown command, user has explicit allow rule
        fi
        all_safe=false
        break
      fi
    done < <(split_on_compound "$cmd_no_escapes")
    [ "$pipeline_denied" = true ] && all_safe=false
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
# Guard: skip unless the command is a single piece outside quotes (after
# backslash-newline continuations collapse) — a `*` in a rule would otherwise
# match across &&, ;, |, &, or a newline and approve a second command the rule
# never named. Compound commands are handled by checks 13/14 above.
allowlisted=false
if echo "$cmd_no_quotes" | grep -Eq '&&|\|\||[|;]' \
   || [ "$(split_on_compound "$cmd_no_quotes" | wc -l)" -gt 1 ]; then
  : # Skip allowlist matching — more than one command
elif [ ${#allow_rules[@]} -gt 0 ] && matches_rule "$cmd" "${allow_rules[@]}"; then
  allowlisted=true
fi

#@check 16  allow   ANSI-C quoted strings ($'...') with safe outer cmd → allow (overrides CC's ansi_c_string feature prompt)
# --- 16. Auto-approve ANSI-C quoted strings with safe outer commands ---
# CC's tree-sitter flags $'...' (ANSI-C quoting) as a feature needing user review.
# This fires independent of allowlist match — a `bd create --description $'...'`
# prompts even when permissions.allow has Bash(bd *). Empirically, a hook
# PreToolUse `allow` decision pre-empts this prompt.
# Gate: first non-assignment token must be hardcoded-safe or match an allow rule.
# Rejects cases where check 13/14/15 haven't already approved the cmd.
if [ "$allowlisted" = false ] && printf '%s' "$cmd" | grep -qE "\\\$'"; then
  # Split on compound ops and pipes; EVERY piece must pass, and at least one
  # must carry a command token. A piece passes when it isn't denied, its first
  # non-assignment/non-keyword token is in the list below or allowlisted, and
  # a hardcoded token's carveouts (is_safe_for_compound) still hold. rm, cp,
  # mv etc. are deliberately absent from the list: $'...' arguments are opaque
  # to the carveouts once quotes are stripped.
  ansi_safe=false
  # Strip backslash-newline continuations so multi-line cmds collapse to one
  # line, then escaped operators (find -exec {} \;), which are arguments
  cmd_ansi=$(printf '%s' "$cmd_no_quotes" | awk 'BEGIN{RS="\0"}{gsub(/\\\n/," "); print}' | sed 's/\\[;|&<>()]//g')
  while IFS= read -r piece; do
    piece=$(echo "$piece" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$piece" ] && continue
    if [ ${#deny_rules[@]} -gt 0 ] && matches_rule "$piece" "${deny_rules[@]}"; then
      ansi_safe=false; break
    fi
    tok=$(echo "$piece" | awk '{
      for (i = 1; i <= NF; i++) {
        t = $i
        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
        if (t == "do" || t == "then" || t == "else" || t == "elif" || \
            t == "while" || t == "until" || t == "if" || t == "for" || \
            t == "done" || t == "fi" || t == "esac") continue
        print t; exit
      }
    }')
    if [ -z "$tok" ]; then
      # Assignments / closing keywords only — still vet any substitutions
      is_safe_for_compound "$piece" || { ansi_safe=false; break; }
      continue
    fi
    tok_ok=false
    case "$tok" in
      echo|printf|cat|head|tail|grep|egrep|fgrep|rg|ag|awk|sed|jq|yq|tr|cut|sort|uniq|wc|find|git|gh|bd|npm|npx|yarn|pnpm|pip|pip3|python|python3|node|ruby|make|cargo|go|pytest|jest|vitest|mocha)
        tok_ok=true ;;
      *)
        if ! is_first_token_hardcoded "$tok" && [ ${#allow_rules[@]} -gt 0 ] \
           && { matches_rule "$tok" "${allow_rules[@]}" || matches_rule "$tok arg" "${allow_rules[@]}"; }; then
          tok_ok=true
        fi ;;
    esac
    if [ "$tok_ok" = true ] && is_first_token_hardcoded "$tok"; then
      is_safe_for_compound "$piece" || tok_ok=false
    fi
    [ "$tok_ok" = true ] || { ansi_safe=false; break; }
    ansi_safe=true
  done < <(split_on_compound "$cmd_ansi")
  if [ "$ansi_safe" = true ]; then
    emit_allow "ANSI-C quoted string (\$'...') with safe outer cmd — overrides CC's ansi_c_string feature prompt"
  fi
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

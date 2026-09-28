#!/usr/bin/env bash
# Tests for scripts/bash-guardrails.sh. Run: bash tests/test-bash-guardrails.sh
#
# Each case feeds the hook a PreToolUse payload and checks for a deny or for
# no output at all. Cases marked "proven" also run the command under `zsh -f`
# in an empty directory, to show the trap is a real zsh error (for a deny) or
# runs cleanly (for a near-miss). Only harmless commands are marked proven.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/scripts/bash-guardrails.sh"
TEST_HOME="$(mktemp -d)"   # hermetic HOME; the hook should never read it
EMPTY_DIR="$(mktemp -d)"   # no files, so every glob fails to match
ALL_OUT="$TEST_HOME/all-output.txt"
: > "$ALL_OUT"
HAS_ZSH=false
command -v zsh >/dev/null 2>&1 && HAS_ZSH=true
pass=0
fail=0

run_hook() { # <command> [login shell]
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' |
    HOME="$TEST_HOME" SHELL="${2:-/bin/zsh}" bash "$HOOK"
}

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; }

prove() { # <name> <command> <want: error|clean>
  $HAS_ZSH || return 0
  local err
  err=$(cd "$EMPTY_DIR" && zsh -fc "$2" 2>&1 >/dev/null)
  if grep -qE 'no matches found|= not found' <<<"$err"; then
    [ "$3" = error ] && ok || bad "$1 (zsh proof)" "zsh errored: $err"
  else
    [ "$3" = clean ] && ok || bad "$1 (zsh proof)" "zsh did not reject it"
  fi
}

expect_deny() { # <name> <command> [proven]
  local out
  out=$(run_hook "$2")
  printf '%s\n' "$out" >> "$ALL_OUT"
  if [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" = deny ] &&
     [ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" | wc -l)" -eq 1 ]; then
    ok
  else
    bad "$1" "expected a one-line deny, got: ${out:-<nothing>}"
  fi
  [ -n "${3:-}" ] && prove "$1" "$2" error
}

expect_silent() { # <name> <command> [proven] [login shell]
  local out
  out=$(run_hook "$2" "${4:-}")
  printf '%s\n' "$out" >> "$ALL_OUT"
  [ -z "$out" ] && ok || bad "$1" "expected no output, got: $out"
  [ -n "${3:-}" ] && prove "$1" "$2" clean
}

echo "== eq trap: words starting with =="
expect_deny  "single-bracket ==" '[ "$a" == b ] && echo same' proven
expect_deny  "test builtin ==" 'test a == b || echo differ' proven
expect_deny  "echo === separator" 'cat a.txt; echo ===; cat b.txt'
expect_deny  "echo ===== alone" 'echo =====' proven
expect_deny  "== after &&" 'cd /tmp && [ x == y ]'
expect_deny  "== inside \$(...)" 'v=$([ a == b ] && echo y)'
expect_silent "double-bracket ==" '[[ a == b ]] || echo differ' proven
expect_silent "single-bracket =" '[ a = b ] || echo differ' proven
expect_silent "quoted ===" "echo '==='; echo \"=====\"" proven
expect_silent "== inside a string" 'echo "a == b"' proven
expect_silent "== inside single quotes" "awk '\$1 == \"x\"' /dev/null" proven
expect_silent "arithmetic (( ))" '(( 1 == 1 )) && echo y' proven
expect_silent "arithmetic \$(( ))" 'echo $(( 2 == 2 ))' proven
expect_silent "== mid-word" 'echo a==b x===' proven
expect_silent "escaped =" 'echo \==' proven
expect_silent "== in a comment" 'echo hi # [ a == b ]' proven

echo "== glob trap: --flag=*pattern"
expect_deny  "grep --include=*.md" 'grep -rn foo . --include=*.md'
expect_deny  "--include=*.md proof" 'echo --include=*.md' proven
expect_deny  "second of two --include" "grep -rn foo . --include='*.sh' --include=*.py"
expect_deny  "--exclude-dir=node*" 'grep -rn foo . --exclude-dir=node*'
expect_deny  "? in flag value" 'echo --x=a?b' proven
expect_deny  "[..] in flag value" 'echo --jq=.a[0]' proven
expect_silent "single-quoted flag glob" "grep -rn foo . --include='*.md'" proven
expect_silent "double-quoted flag glob" 'grep -rn foo . --include="*.md"' proven
expect_silent "quoted whole flag" "echo '--include=*.md'" proven
expect_silent "escaped flag glob" 'echo --include=\*.md' proven
expect_silent "flag without glob" 'git log --format=%H -n1 --since=yesterday'
expect_silent "assignment with glob" 'x=--include=*.md; echo "$x"' proven

echo "== glob trap: find -name *pattern"
expect_deny  "find -name *.md" 'find . -name *.md' proven
expect_deny  "find -iname" 'find . -type f -iname *readme*'
expect_deny  "find -path" 'find . -path ./src/*'
expect_silent "find -name quoted" "find . -name '*.md'" proven
expect_silent "find -name escaped" 'find . -name \*.md' proven
expect_silent "find -name literal" 'find . -name README.md' proven

echo "== glob trap: unquoted ?key= query strings"
expect_deny  "gh api ?ref=" 'gh api repos/o/r/contents/a.yml?ref=main --jq .content'
expect_deny  "escaped & still has ?" 'gh api repos/o/r/actions/runs?event=pull_request\&per_page=40'
expect_deny  "query proof" 'echo repos/x?ref=y' proven
expect_silent "quoted query" "gh api 'repos/o/r/contents/a.yml?ref=main'"
expect_silent "double-quoted query" 'curl -s "https://h/p?a=1&b=2"'
expect_silent "query in assignment" 'U=https://h/p?a=1; echo "$U"' proven
expect_silent "export query" 'export U=https://h/p?a=1' proven

echo "== out of scope on purpose (usually matches, so silent)"
expect_silent "bare glob to ls" 'ls *.md'
expect_silent "bare glob to grep" 'grep -n foo *.py'
expect_silent "path glob" 'cat plugins/*/README.md'

echo "== pass-through: heredocs, multi-line, quoting"
expect_silent "heredoc with # lines and indentation" "$(printf '%s\n' \
  "cat > out.md <<'EOF'" '## Summary' '    indented line' '# not a comment' \
  '[ a == b ] --include=*.md find -name *.x repos/x?ref=y' '=====' 'EOF')" proven
expect_silent "heredoc <<- with tabs" "$(printf '%s\n' 'cat <<-EOF' $'\t=====' $'\tEOF')" proven
expect_silent "commit message via \$(cat <<EOF)" "$(printf '%s\n' \
  'git commit -m "$(cat <<'"'"'EOF'"'"'' 'feat: x' '' 'He said "=== is bad" and --include=*.md' 'EOF' ')"')"
expect_silent "multi-line python3 -c" "$(printf '%s\n' 'python3 -c "' 'for i in range(3):' '    if i == 1:' '        print(i)' '"')"
expect_silent "python heredoc" "$(printf '%s\n' "python3 - <<'PY'" 'import glob' 'x = glob.glob(\"*.md\")' '# comment' '    y == 2' 'PY')"
expect_silent "here-string" 'grep -c x <<< "a == b"'
expect_silent "multi-line quoted arg" "$(printf '%s\n' 'gh pr create --title t --body "## Summary' '' '    - [ ] == check' '--include=*.md"')"
expect_silent "ANSI-C string" "printf \$'a == b\\\\n*.md\\\\n'"
expect_silent "plain command" 'git status'
expect_silent "empty command" ''

echo "== when the hook stays out of it"
expect_silent "bash login shell" '[ a == b ] && grep x --include=*.md' "" /bin/bash
out=$(printf 'not json' | HOME="$TEST_HOME" SHELL=/bin/zsh bash "$HOOK" 2>&1); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok || bad "invalid JSON input" "rc=$rc out=$out"
out=$(jq -n '{tool_name: "Bash", tool_input: {}}' | HOME="$TEST_HOME" SHELL=/bin/zsh bash "$HOOK"); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok || bad "no command field" "rc=$rc out=$out"

echo "== invariant: never allow, never rewrite"
if grep -qE '"allow"|updatedInput' "$ALL_OUT"; then
  bad "hook emitted allow or updatedInput" "$(grep -E '"allow"|updatedInput' "$ALL_OUT" | head -3)"
else
  ok
fi
$HAS_ZSH || echo "note: zsh not found, zsh proofs skipped"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED: $pass tests"
else
  echo "FAILED: $fail of $((pass + fail)) tests"
  exit 1
fi

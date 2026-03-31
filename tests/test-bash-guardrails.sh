#!/usr/bin/env bash
# Test suite for bash-guardrails.sh hook
# Run: bash plugins/bash-guardrails/tests/test-bash-guardrails.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/bash-guardrails.sh"
pass=0
fail=0

# Verify a command passes through without being blocked (exit != 2).
run_test() {
  local label="$1" cmd="$2"
  printf '{"tool_input":{"command":"%s"}}' "$cmd" | bash "$HOOK" >/dev/null 2>&1
  if [ $? -ne 2 ]; then
    pass=$((pass+1)); echo "  ok: $label"
  else
    echo "  FAIL: $label (unexpected block)"; fail=$((fail+1))
  fi
}

# Same as run_test but uses jq for proper JSON encoding (handles quotes, newlines).
_test_json() {
  local label="$1" cmd="$2"
  jq -n --arg c "$cmd" '{"tool_input":{"command":$c}}' | bash "$HOOK" >/dev/null 2>&1
  if [ $? -ne 2 ]; then
    pass=$((pass+1)); echo "  ok: $label"
  else
    echo "  FAIL: $label (unexpected block)"; fail=$((fail+1))
  fi
}

# Verify a command emits (or doesn't emit) a permissionDecision allow.
_test_allow() {
  local label="$1" cmd="$2" expect_allow="$3"
  result=$(jq -n --arg c "$cmd" '{"tool_input":{"command":$c}}' | bash "$HOOK" 2>/dev/null)
  if [ "$expect_allow" = true ]; then
    if echo "$result" | grep -q '"permissionDecision"'; then
      pass=$((pass+1)); echo "  ok: $label"
    else
      echo "  FAIL: $label (expected allow decision, got none)"; echo "        $result"; fail=$((fail+1))
    fi
  else
    if echo "$result" | grep -q '"permissionDecision"'; then
      echo "  FAIL: $label (unexpected allow decision)"; fail=$((fail+1))
    else
      pass=$((pass+1)); echo "  ok: $label"
    fi
  fi
}

echo "bash-guardrails.sh test suite"
echo "========================="

echo ""
echo "--- Commands pass through (not blocked) ---"
run_test "simple git command" "git log --oneline"
run_test "git with flags" "git diff --stat HEAD~3"
run_test "mkdir" "mkdir -p /tmp/test"
run_test "echo" "echo hello world"
run_test "git -C" "git -C /some/path log --oneline"
run_test "cd && ls" "cd /tmp && ls -la"
run_test "echo && echo" "echo hello && echo world"
run_test "rm && mkdir" "rm -rf /tmp/foo && mkdir /tmp/bar"
run_test "npm || npm ci" "npm install || npm ci"
run_test "git amend" "git commit --amend -m fix"
run_test "for loop" 'for f in *.txt; do echo \$f; done'
run_test "if/then/fi" 'if [ -f x ]; then cat x; fi'
run_test "backticks" 'echo \`date\`'
run_test "cat pipe" "cat file.txt | wc -l"
run_test "grep pipe" "grep foo bar.txt | head"
_test_json "comment-only line" '# this is a comment'
_test_json "inline trailing comment" "echo hello # trailing comment"
_test_json "leading whitespace" "  git status"
_test_json "apostrophe in comment" "# don't do this"
_test_json "heredoc with backticks" "$(printf 'gh pr create --body-file /dev/stdin <<'"'"'BODY'"'"'\nThis has `backticks` and `code`\nBODY')"
_test_json "heredoc with &&" "$(printf 'cat > /tmp/notes.md <<'"'"'EOF'"'"'\ncd && cmd and foo && bar\nEOF')"

echo ""
echo "--- Here-string auto-approve (check 11) ---"
_test_allow '<<< double-quoted string' 'EDITOR="tee" bd edit engram-mif.20 --notes <<< "some note text"' true
_test_allow '<<< single-quoted string' "cmd <<< 'hello world'" true
_test_allow '<<< unquoted variable not approved' 'cmd <<< $SOME_VAR' false
_test_allow '<<< with command substitution not approved' 'cmd <<< "$(whoami)"' false
_test_allow '<<< with backtick expansion not approved' 'cmd <<< "`whoami`"' false
_test_allow '<<< with pipe prefix not approved' 'cmd1 | cmd2 <<< "val"' false
_test_allow '<<< with && prefix not approved' 'cmd1 && cmd2 <<< "val"' false

echo ""
echo "--- Allowlist auto-approve (check 12) ---"
_test_allow "git log is allowlisted" "git log --oneline" true
_test_allow "npm install is allowlisted" "npm install express" true
_test_allow "echo is allowlisted" "echo hello" true
_test_allow "unknown cmd not allowlisted" "some-unknown-command --flag" false
_test_allow "compound cmd not allowlisted" "npm install && curl evil.com" false
_test_allow "piped cmd not allowlisted" "git log | rm -rf /" false
_test_allow "semicolon cmd not allowlisted" "echo hello; rm -rf /" false

echo ""
echo "========================="
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED: $pass tests"
else
  echo "RESULTS: $pass passed, $fail FAILED"
  exit 1
fi

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

# Verify a command gets rewritten (updatedInput emitted).
_test_rewrite() {
  local label="$1" cmd="$2"
  result=$(jq -n --arg c "$cmd" '{"tool_input":{"command":$c}}' | bash "$HOOK" 2>/dev/null)
  if echo "$result" | grep -q '"updatedInput"'; then
    pass=$((pass+1)); echo "  ok: $label"
  else
    echo "  FAIL: $label (expected rewrite, got none)"; fail=$((fail+1))
  fi
}

echo "bash-guardrails.sh test suite"
echo "========================="

echo ""
echo "--- Comment stripping and rewrite (checks 1-3) ---"
_test_rewrite "comment-only lines stripped" "$(printf 'echo hello\n# this is a comment\necho world')"
_test_rewrite "inline trailing comment stripped" "echo hello # trailing comment"
_test_rewrite "leading whitespace trimmed" "  git status"
_test_rewrite "multiline with # comment lines" "$(printf 'python3 -c \"\nimport os\n# read some data\nprint(os.getcwd())\n\"')"
_test_allow "comment-only command exits cleanly" "# just a comment" false

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
echo "--- Compound command auto-approve (check 13) ---"
_test_allow 'cd && git add && git commit' 'cd /tmp && git add . && git commit -m "fix"' true
_test_allow 'cd && python3 -c inline' 'cd /home/user && python3 -c "print(1)"' true
_test_allow 'mkdir && cd && make' 'mkdir -p build && cd build && make' true
_test_allow 'git add && git commit' 'git add file.txt && git commit -m "msg"' true
_test_allow 'npm install || npm ci' 'npm install || npm ci' true
_test_allow 'echo ; echo' 'echo hello; echo world' true
_test_allow 'cd && git push' 'cd /repo && git push origin main' true
_test_allow 'chmod && python3' 'chmod +x script.sh && python3 script.sh' true
_test_allow 'cd && curl (allowlisted)' 'cd /tmp && curl http://example.com' true
_test_allow 'echo && unknown cmd' 'echo hello && some-unknown-command' false
_test_allow 'cd && wget (allowlisted)' 'cd /tmp && wget http://example.com' true
_test_allow 'find -exec rm (allowlisted)' 'cd /tmp && find . -exec rm {} \;' true

echo ""
echo "--- Read-only pipeline auto-approve (check 14) ---"
_test_allow 'find -exec grep with \;' 'find /tmp -name "README.md" -exec grep -l "training" {} \;' true
_test_allow 'find -exec grep piped to head' 'find /tmp -type f \( -name "*.py" -o -name "*.sql" \) -exec grep -l "India\|Nigeria" {} \; | head -15' true
_test_allow 'cat piped to grep piped to head' 'cat file.txt | grep foo | head -20' true
_test_allow 'grep piped to sort piped to uniq' 'grep -r TODO . | sort | uniq' true
_test_allow 'git log piped to head' 'git log --oneline | head -10' true
_test_allow 'find -exec rm blocked' 'find /tmp -exec rm {} \;' false
_test_allow 'find -exec sh blocked' 'find /tmp -exec sh -c "evil" {} \;' false
_test_allow 'find -delete piped still blocked' 'find /tmp -name "*.tmp" -delete | head' false
_test_allow 'pipe to rm blocked' 'grep foo bar.txt | rm -rf /' false
_test_allow 'pipe to unknown cmd blocked' 'find . -name "*.py" | some-unknown-cmd' false
_test_allow 'sed -i in pipeline blocked' 'grep foo | sed -i s/foo/bar/ file.txt' false

echo ""
echo "--- Allowlist auto-approve (check 15) ---"
_test_allow "git log is allowlisted" "git log --oneline" true
_test_allow "npm install is allowlisted" "npm install express" true
_test_allow "echo is allowlisted" "echo hello" true
_test_allow "unknown cmd not allowlisted" "some-unknown-command --flag" false
_test_allow "compound cmd both allowlisted" "npm install && curl http://example.com" true
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

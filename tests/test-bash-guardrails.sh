#!/usr/bin/env bash
# Test suite for bash-guardrails.sh hook
# Run: bash plugins/bash-guardrails/tests/test-bash-guardrails.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/bash-guardrails.sh"
pass=0
fail=0

run_test() {
  local expect="$1" label="$2" cmd="$3"
  result=$(printf '{"tool_input":{"command":"%s"}}' "$cmd" | bash "$HOOK" 2>&1)
  exit_code=$?

  if [ "$expect" = "pass" ] && [ $exit_code -ne 2 ]; then
    pass=$((pass+1))
  elif [ "$expect" = "block" ] && [ $exit_code -eq 2 ]; then
    pass=$((pass+1))
  elif [ "$expect" = "hint" ]; then
    if echo "$result" | grep -q "HINT"; then
      pass=$((pass+1))
    else
      echo "  FAIL: $label (expected HINT, got none)"
      fail=$((fail+1))
      return
    fi
  elif [ "$expect" = "no-hint" ]; then
    if echo "$result" | grep -q "HINT"; then
      echo "  FAIL: $label (unexpected HINT)"
      fail=$((fail+1))
      return
    else
      pass=$((pass+1))
    fi
  else
    echo "  FAIL: $label (expected $expect, got exit $exit_code)"
    echo "        $result"
    fail=$((fail+1))
    return
  fi
  echo "  ok: $label"
}

# Helper for commands with embedded double quotes or multiline content
_test_json() {
  local expect="$1" label="$2" cmd="$3"
  result=$(jq -n --arg c "$cmd" '{"tool_input":{"command":$c}}' | bash "$HOOK" 2>&1)
  exit_code=$?
  if [ "$expect" = "pass" ] && [ $exit_code -ne 2 ]; then
    pass=$((pass+1)); echo "  ok: $label"
  elif [ "$expect" = "block" ] && [ $exit_code -eq 2 ]; then
    pass=$((pass+1)); echo "  ok: $label"
  else
    echo "  FAIL: $label (expected $expect, got exit $exit_code)"
    echo "        $result"
    fail=$((fail+1))
  fi
}

# Helper for testing permissionDecision output
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

run_test_allowlist() {
  local label="$1" cmd="$2" expect_allow="$3"
  result=$(printf '{"tool_input":{"command":"%s"}}' "$cmd" | bash "$HOOK" 2>/dev/null)
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
echo "--- Safe single commands ---"
run_test pass "simple git command" "git log --oneline"
run_test pass "git with flags" "git diff --stat HEAD~3"
run_test pass "mkdir" "mkdir -p /tmp/test"
run_test pass "echo" "echo hello world"

echo ""
echo "--- git -C (allowed) ---"
run_test pass "git -C log" "git -C /some/path log --oneline"
run_test pass "git -C status" "git -C /some/path status"

echo ""
echo "--- cd && single command (allowed) ---"
run_test pass "cd && ls" "cd /tmp && ls -la"
run_test pass "cd && git stash" "cd /tmp && git stash"
run_test pass "cd && git pull" "cd /tmp && git pull origin main"
run_test pass "cd quoted path && cmd" 'cd \\"my folder\\" && git status'

echo ""
echo "--- Shell control structures (allowed) ---"
run_test pass "for loop" 'for f in *.txt; do echo \$f; done'
run_test pass "while loop" 'while true; do sleep 1; done'
run_test pass "if/then/fi" 'if [ -f x ]; then cat x; fi'
run_test pass "case/esac" 'case \$x in a) echo a;; b) echo b;; esac'

echo ""
echo "--- Heredoc body not treated as commands (section 4b) ---"
_test_json pass "heredoc with backticks in body" "$(printf 'gh pr create --body-file /dev/stdin <<'"'"'BODY'"'"'\nThis has `backticks` and `code`\nBODY')"
_test_json pass "heredoc with && in body" "$(printf 'cat > /tmp/notes.md <<'"'"'EOF'"'"'\ncd && cmd and foo && bar\nEOF')"
_test_json pass "heredoc with || in body" "$(printf 'cmd --body-file /dev/stdin <<'"'"'END'"'"'\nnpm install || npm ci\nEND')"

echo ""
echo "--- Error suppression: || true / || : (allowed) ---"
run_test pass "cmd || true" "some-cmd 2>/dev/null || true"
run_test pass "cmd || :" "some-cmd 2>/dev/null || :"
run_test pass "git || true" "git branch --show-current || true"
run_test pass "\$(cmd || true)" '_UPD=\$(cmd 2>/dev/null || true)'

echo ""
echo "--- Default value: || echo (allowed at EOL) ---"
run_test pass "cmd || echo default" "cmd 2>/dev/null || echo true"

echo ""
echo "--- Read-only compounds (allowed) ---"
run_test pass "echo ; echo" "echo hello; echo world"
run_test pass "echo && find && grep" 'echo "=== header ===" && find . -type f && grep foo bar.txt'
run_test pass "git log && git status" "git log --oneline && git status"
run_test pass "ls && wc" "ls -la && wc -l file.txt"
run_test pass "cat | sort | uniq && echo" "cat foo | sort | uniq && echo done"
run_test pass "find | sort && echo" "find ~/project -type f | sort && echo done"
run_test pass "git diff && echo" 'git diff --stat && echo "=== end ==="'

echo ""
echo "--- Dangerous compounds (blocked) ---"
run_test block "rm && mkdir" "rm -rf /tmp/foo && mkdir /tmp/bar"
run_test block "git pull && push" "git pull && git push"
run_test block "npm || exit" "npm install || exit 1"
run_test block "cd && two cmds" "cd /path && git pull && git push"
run_test block "cmd1 || cmd2 (non-trivial)" "npm install || npm ci"
run_test block "cmd || rm" "test -f x || rm -rf y"
run_test block "source ; echo" "source <(cmd); echo REPO_MODE"
run_test block "double fallback" '_UPD=$(cmd1 || cmd2 || true)'
run_test block "echo && npm install" "echo starting && npm install express"
run_test block "git log && git push" "git log --oneline && git push origin main"

echo ""
echo "--- git commit --amend (blocked) ---"
run_test block "git amend" "git commit --amend -m fix"
run_test block "git amend no-edit" "git commit --amend --no-edit"

echo ""
echo "--- Pipe hints (targeted) ---"
run_test hint "cat pipe warns" "cat file.txt | wc -l"
run_test hint "grep pipe warns" "grep foo bar.txt | head"
run_test hint "find pipe warns" "find . -name x | xargs rm"
run_test no-hint "jq pipe no warn" "npm list --json | jq .deps"
run_test no-hint "sort pipe no warn" "git log --oneline | sort"
run_test no-hint "cmd | wc no warn" "docker ps | wc -l"

echo ""
echo "--- cd && single command emits allow (section 10c) ---"
run_test_allowlist "cd && git status emits allow" "cd /some/repo && git status" true
run_test_allowlist "cd && git log emits allow" "cd /some/repo && git log --oneline" true
run_test_allowlist "cd && git checkout emits allow" "cd /some/repo && git checkout main" true
run_test_allowlist "cd && npm install emits allow" "cd /some/project && npm install" true
run_test_allowlist "cd && python emits allow" "cd /some/project && python main.py" true

echo ""
echo "--- Here-string <<< with quoted literal (section 11b) ---"
_test_allow '<<< double-quoted string' 'EDITOR="tee" bd edit engram-mif.20 --notes <<< "some note text"' true
_test_allow '<<< single-quoted string' "cmd <<< 'hello world'" true
_test_allow '<<< unquoted variable not approved' 'cmd <<< $SOME_VAR' false

echo ""
echo "--- Allowlist auto-approve (section 12) ---"
run_test_allowlist "git log is allowlisted" "git log --oneline" true
run_test_allowlist "npm install is allowlisted" "npm install express" true
run_test_allowlist "echo is allowlisted" "echo hello" true
run_test_allowlist "unknown cmd not allowlisted" "some-unknown-command --flag" false
run_test block "amend still blocked despite allowlist" "git commit --amend -m fix"

echo ""
echo "========================="
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED: $pass tests"
else
  echo "RESULTS: $pass passed, $fail FAILED"
  exit 1
fi

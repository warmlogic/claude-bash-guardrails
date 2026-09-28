#!/usr/bin/env bash
# Test suite for bash-guardrails.sh hook
# Run: bash plugins/bash-guardrails/tests/test-bash-guardrails.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/bash-guardrails.sh"
pass=0
fail=0

# Hermetic HOME: the hook reads $HOME/.claude/settings.json(+.local) and
# $CLAUDE_PROJECT_DIR/.claude/settings.json(+.local) for permissions.allow /
# permissions.deny rules. Point every hook invocation at a throwaway HOME
# with no project dir, so a developer's real permissions (e.g. an explicit
# `Bash(rm -rf *)` deny, or the *absence* of an allow rule this suite
# assumes) can't leak into the suite and flip an expected result. The
# mktemp dir is left in place on purpose (no `rm` cleanup here).
#
# A fixed baseline settings.json ships the allow rules many "passes
# through" tests below assume for ordinary dev commands (git, python3,
# npm, curl, wget, cat, echo, find, ...) — mirroring what a real Claude
# Code user's permissions.allow typically looks like, per this plugin's
# own README ("if you have a broad permissions.allow list ... this plugin
# adds minimal value"). Broad rules like `Bash(find *)` can't weaken the
# carveout tests: the allow-rule fallback never fires for a hardcoded first
# token (see allow_rule_fallback in the hook, and the "Broad allow rules"
# fixture section below, which pins this with `Bash(rm *)` et al.).
TEST_HOME="$(mktemp -d)"
mkdir -p "$TEST_HOME/.claude"
cat > "$TEST_HOME/.claude/settings.json" <<'BASELINE_SETTINGS'
{
  "permissions": {
    "allow": [
      "Bash(cat *)",
      "Bash(echo *)",
      "Bash(git *)",
      "Bash(gh *)",
      "Bash(python *)",
      "Bash(python3 *)",
      "Bash(PYTHONPATH=*)",
      "Bash(node *)",
      "Bash(npm *)",
      "Bash(pip *)",
      "Bash(pip3 *)",
      "Bash(cargo *)",
      "Bash(make *)",
      "Bash(curl *)",
      "Bash(wget *)",
      "Bash(jq *)",
      "Bash(bd *)",
      "Bash(chmod *)",
      "Bash(tar *)",
      "Bash(find *)"
    ]
  }
}
BASELINE_SETTINGS

# Run the hook hermetically: fixed HOME, no project dir, unless the caller
# passes its own HOME (see _test_allow_with_settings below).
run_hook() {
  HOME="${HOOK_TEST_HOME:-$TEST_HOME}" CLAUDE_PROJECT_DIR= bash "$HOOK"
}

# Verify a command passes through without being blocked (exit != 2).
run_test() {
  local label="$1" cmd="$2"
  printf '{"tool_input":{"command":"%s"}}' "$cmd" | run_hook >/dev/null 2>&1
  if [ $? -ne 2 ]; then
    pass=$((pass+1)); echo "  ok: $label"
  else
    echo "  FAIL: $label (unexpected block)"; fail=$((fail+1))
  fi
}

# Same as run_test but uses jq for proper JSON encoding (handles quotes, newlines).
_test_json() {
  local label="$1" cmd="$2"
  jq -n --arg c "$cmd" '{"tool_input":{"command":$c}}' | run_hook >/dev/null 2>&1
  if [ $? -ne 2 ]; then
    pass=$((pass+1)); echo "  ok: $label"
  else
    echo "  FAIL: $label (unexpected block)"; fail=$((fail+1))
  fi
}

# Verify a command emits (or doesn't emit) a permissionDecision allow.
_test_allow() {
  local label="$1" cmd="$2" expect_allow="$3"
  result=$(jq -n --arg c "$cmd" '{"tool_input":{"command":$c}}' | run_hook 2>/dev/null)
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

# Verify a command gets denied with a reason (permissionDecision: deny).
_test_deny() {
  local label="$1" cmd="$2"
  result=$(jq -n --arg c "$cmd" '{"tool_input":{"command":$c}}' | run_hook 2>/dev/null)
  if echo "$result" | grep -q '"permissionDecision": "deny"'; then
    pass=$((pass+1)); echo "  ok: $label"
  else
    echo "  FAIL: $label (expected deny, got: $result)"; fail=$((fail+1))
  fi
}

# Verify a command gets rewritten (updatedInput emitted).
_test_rewrite() {
  local label="$1" cmd="$2"
  result=$(jq -n --arg c "$cmd" '{"tool_input":{"command":$c}}' | run_hook 2>/dev/null)
  if echo "$result" | grep -q '"updatedInput"'; then
    pass=$((pass+1)); echo "  ok: $label"
  else
    echo "  FAIL: $label (expected rewrite, got none)"; fail=$((fail+1))
  fi
}

# Verify a command's allow/no-decision behavior under a *specific* fixture
# permissions.allow/deny settings.json, written into its own throwaway HOME
# (never the operator's real $HOME). Pins the settings-driven behavior
# (checks 15 / deny-defers-to-CC) deliberately, instead of leaving it to
# whatever real settings happen to be on the machine running the suite.
_test_allow_with_settings() {
  local label="$1" cmd="$2" expect_allow="$3" settings_json="$4"
  local fixture_home
  fixture_home="$(mktemp -d)"
  mkdir -p "$fixture_home/.claude"
  printf '%s' "$settings_json" > "$fixture_home/.claude/settings.json"
  local result
  result=$(jq -n --arg c "$cmd" '{"tool_input":{"command":$c}}' \
    | HOME="$fixture_home" CLAUDE_PROJECT_DIR= bash "$HOOK" 2>/dev/null)
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
echo "--- Heredoc-in-command-substitution denial (check 0) ---"
_test_deny "git commit with \$(cat <<EOF)" "$(printf 'git commit -m "$(cat <<EOF\nhello\nEOF\n)"')"
_test_deny "git commit with \$(cat <<'EOF')" "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nhello\nEOF\n)"')"
_test_deny "chained \$(cat <<EOF) with &&" "$(printf 'git add foo && git commit -m "$(cat <<EOF\nbody\nEOF\n)"')"
_test_deny "gh pr create with \$(cat <<EOF)" "$(printf 'gh pr create --body "$(cat <<EOF\nbody\nEOF\n)"')"
_test_allow "plain cat << heredoc (no \$(...)) passes through" "$(printf 'cat > /tmp/note.md <<EOF\nbody\nEOF')" true
_test_allow "git commit -F file passes through" "git commit -F /tmp/msg.txt" true
_test_allow "git commit -m simple message passes" "git commit -m \"simple message\"" true

echo ""
echo "--- Interpreter heredoc denial (check 4) ---"
_test_deny "python3 heredoc with indented body" "$(printf 'python3 <<'"'"'EOF'"'"'\nfor i in range(3):\n    print(i)\nEOF')"
_test_deny "node heredoc" "$(printf 'node <<'"'"'EOF'"'"'\nconst x = 1;\nconsole.log(x);\nEOF')"
_test_deny "python3 heredoc unquoted delimiter" "$(printf 'python3 <<EOF\nprint(1)\nEOF')"
# Regression: bitshift << must NOT trigger check 4
_test_allow "python3 bitshift operator not a heredoc" "python3 -c 'print(1 << 4)'" true
# Regression: here-string <<< must NOT trigger check 4
_test_allow "python3 here-string not a heredoc" "python3 <<< 'print(42)'" true

echo ""
echo "--- Multi-line python3 -c indentation denial (check 4b) ---"
_test_deny "multi-line python3 -c with indented body" "$(printf 'python3 -c "\nfor i in range(3):\n    print(i)\n"')"
_test_allow "single-line python3 -c no body (no indent)" "python3 -c \"print('hi')\"" true
_test_allow "python3 script-path + grep -c on different lines" "$(printf 'echo step1\ngrep -c "pattern" file.txt\npython3 ~/script.py')" true
_test_allow "python3 script-path + bd close -c reason multi-line" "$(printf 'grep -c foo bar.txt\npython3 ~/check.py')" true
_test_allow "multi-line python3 -c no indented body" "$(printf 'python3 -c "\nimport os\nprint(os.getcwd())\n"')" true
# Intentional recall loss after v0.10.2: regex requires python3 + -c on the
# same logical command segment ([^|;&] between). Compound-prefix forms below
# previously denied; now allowed. If a future tightening re-introduces the
# deny here, this test forces an explicit decision rather than silent change.
_test_allow "cd && python3 -c multi-line indent (compound prefix — recall loss)" "$(printf 'cd /tmp && python3 -c "\nfor i in range(3):\n    print(i)\n"')" true
_test_allow "VAR= python3 -c multi-line indent (env prefix — recall loss)" "$(printf 'PYTHONPATH=. python3 -c "\nfor i in range(3):\n    print(i)\n"')" true

echo ""
echo "--- Comment stripping and rewrite (checks 1-3) ---"
_test_rewrite "comment-only lines stripped" "$(printf 'echo hello\n# this is a comment\necho world')"
_test_allow "inline trailing comment passes through unchanged" "echo hello # trailing comment" true
# Regression: old check 2 truncated this to "echo" (lost the quoted arg) due to
# position-mapping bug between quote-stripped and original cmd. Check 2 removed.
_test_allow "inline comment after quoted arg not truncated" "echo 'foo' # trailing" true
_test_rewrite "leading whitespace trimmed" "  git status"
_test_rewrite "multiline with # comment lines" "$(printf 'python3 -c \"\nimport os\n# read some data\nprint(os.getcwd())\n\"')"
_test_rewrite "piped cmd with # in python -c string" "$(printf 'bd list --json 2>/dev/null | python3 -c \"\nimport json, sys\n# parse data\nprint(json.load(sys.stdin))\n\"')"
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
run_test "for loop" 'for f in *.txt; do echo $f; done'
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
_test_allow 'find -exec rm blocked in compound despite Bash(find *)' 'cd /tmp && find . -exec rm {} \;' false
_test_allow 'touch && echo' 'touch /tmp/marker && echo done' true
_test_allow 'cp && echo' 'cp /tmp/a.txt /tmp/b.txt && echo copied' true
_test_allow 'mv && echo' 'mv /tmp/old.txt /tmp/new.txt && echo moved' true
_test_allow 'tar && echo' 'tar czf /tmp/archive.tar.gz /tmp/src && echo archived' true
_test_allow 'gh pr list' 'cd /repo && gh pr list' true
_test_allow 'git stash && git checkout' 'git stash && git checkout main' true
_test_allow 'git stash pop' 'git checkout feature && git stash pop' true
_test_allow 'git clone && cd' 'git clone https://github.com/user/repo.git && cd repo' true
_test_allow 'tee in compound' 'echo hello && echo world | tee /tmp/out.txt' true
_test_allow 'rm file && echo' 'rm /tmp/old.txt && echo done' true
_test_allow 'rm -rf dir && mkdir' 'rm -rf /tmp/build && mkdir /tmp/build' true
_test_allow 'rm -f with path' 'rm -f /tmp/cache.json && echo cleared' true
_test_allow 'rm bare slash blocked' 'rm -rf / && echo oops' false
_test_allow 'rm home blocked' 'rm -rf ~ && echo oops' false
_test_allow 'rm home slash blocked' 'rm -rf ~/ && echo oops' false
_test_allow 'rm dotdot blocked' 'rm -rf .. && echo oops' false
_test_allow 'rm .git blocked' 'rm -rf .git && echo oops' false
_test_allow 'rm bare flags blocked' 'rm -rf && echo oops' false

echo ""
echo "--- Shell loop/conditional auto-approve (check 13 — flow control) ---"
_test_allow 'for loop with glob' 'for f in *.txt; do echo $f; done' true
_test_allow 'for loop with find cmd sub' 'for f in $(find /tmp/plugins -name "SKILL.md"); do echo "=== $f ==="; head -20 "$f"; echo; done' true
_test_allow 'for loop with safe backtick cmd sub' 'for f in `find /tmp -name "*.md"`; do head -5 "$f"; done' true
_test_allow 'for loop with allowlisted iterator cmd sub' 'for f in $(curl http://example.com); do echo $f; done' true
_test_allow 'for loop with non-allowlisted iterator cmd sub' 'for f in $(some-unknown-command); do echo $f; done' false
_test_allow 'for loop with non-allowlisted backtick cmd sub' 'for f in `some-unknown-command`; do echo $f; done' false
_test_allow 'for loop with allowlisted body (cp)' 'for f in *.txt; do cp "$f" /tmp/; done' true
_test_allow 'for loop with non-allowlisted body' 'for f in *.txt; do some-unknown-command "$f"; done' false
_test_allow 'while read loop' 'while read -r line; do echo "$line"; done' true
_test_allow 'if/then/fi with safe cmds' 'if [ -f x ]; then cat x; fi' true
_test_allow 'if/then/else/fi' 'if test -d /tmp; then ls /tmp; else echo missing; fi' true
_test_allow 'if with unsafe then branch' 'if [ -f x ]; then rm -rf /; fi' false
_test_allow 'for loop with variable assignment' 'for f in *.md; do name=$(basename "$f" .md); echo "$name"; done' true
_test_allow 'for loop with basename and head' 'for f in /tmp/agents/*.md; do name=$(basename "$f" .md); first=$(head -1 "$f" | sed "s/^# //"); echo "$name: $first"; done | sort' true
_test_allow 'for loop with dirname' 'for f in /tmp/skills/*/SKILL.md; do dir=$(dirname "$f"); name=$(basename "$dir"); echo "$name"; done' true
_test_allow 'for loop body with allowlisted cmd' 'for id in a b c; do curl http://example.com; done' true
_test_allow 'for loop body with allowlisted cmd and args' 'for id in a b c; do wget -q http://example.com; done' true
_test_allow 'if/then with allowlisted cmd in then' 'if [ -f x ]; then curl http://example.com; fi' true
_test_allow 'variable assignment with allowlisted cmd sub' 'for f in *.txt; do data=$(curl http://example.com); echo "$data"; done' true
_test_allow 'variable assignment with non-allowlisted cmd sub' 'for f in *.txt; do data=$(some-unknown-command); echo "$data"; done' false
_test_allow 'simple variable assignment' 'x=hello; echo $x' true
_test_allow 'variable assignment with safe cmd sub' 'ts=$(date +%s); echo "timestamp: $ts"' true

echo ""
echo "--- Multi-line quoted strings (regression: sed's [^\"]* can't cross newlines) ---"
_test_allow 'multi-line dq description with ; inside' "$(printf 'cd /tmp && T=$(bd create "title" --description "line one.\nhas semis; escalate; do not force." --acceptance "ok") && echo done')" true
_test_allow 'multi-line sq description with && inside' "$(printf 'cd /tmp && T=$(bd create --description '"'"'line one\ncontains && operator\nline three'"'"') && echo done')" true
_test_allow 'multi-line dq with embedded newline but no compound leak' "$(printf 'echo "line1\nline2" && echo done')" true
_test_allow 'multi-line sq awk script with ;' "$(printf 'cd /tmp && awk '"'"'\nBEGIN { x=1; y=2 }\n{ print x; print y }\n'"'"' file && echo done')" true
_test_allow 'multi-line python -c with ; inside' "$(printf 'cd /tmp && python3 -c "\nx = 1; y = 2\nprint(x); print(y)\n" && echo done')" true
_test_allow 'dangerous compound not masked by multi-line quote' "$(printf 'echo "harmless\nmulti-line" && some-unknown-tool')" false
_test_allow 'rm -rf not masked by multi-line quote' "$(printf 'echo "harmless\nmulti-line" && rm -rf /')" false

echo ""
echo "--- Safe pipeline auto-approve (check 14) ---"
_test_allow 'find -exec grep with \;' 'find /tmp -name "README.md" -exec grep -l "training" {} \;' true
_test_allow 'find -exec grep piped to head' 'find /tmp -type f \( -name "*.py" -o -name "*.sql" \) -exec grep -l "India\|Nigeria" {} \; | head -15' true
_test_allow 'cat piped to grep piped to head' 'cat file.txt | grep foo | head -20' true
_test_allow 'grep piped to sort piped to uniq' 'grep -r TODO . | sort | uniq' true
_test_allow 'git log piped to head' 'git log --oneline | head -10' true
_test_allow 'head piped to python3 piped to head' 'head -c 2000 /tmp/data.txt | python3 -c "import sys; print(sys.stdin.read())" | head -20' true
_test_allow 'python3 piped to jq' 'python3 -c "import json; print(json.dumps({}))" | jq .' true
_test_allow 'cat piped to node' 'cat data.json | node -e "process.stdin.pipe(process.stdout)"' true
_test_allow 'git diff piped to npm exec' 'git diff --name-only | npm exec prettier -- --check' true
_test_allow 'sha256sum piped to cut' 'sha256sum /tmp/file.bin | cut -d" " -f1' true
_test_allow 'git for-each-ref piped to grep' 'git for-each-ref --format="%(refname)" | grep main' true
_test_allow 'cmd piped to tee piped to grep' 'cat /tmp/log.txt | tee /tmp/copy.txt | grep ERROR' true
_test_allow 'nproc in pipeline' 'nproc | head -1' true
_test_allow 'gh piped to jq' 'gh api repos/owner/repo | jq .name' true
_test_allow 'find -exec rm blocked' 'find /tmp -exec rm {} \;' false
_test_allow 'find -exec sh blocked' 'find /tmp -exec sh -c "evil" {} \;' false
_test_allow 'find -delete piped still blocked' 'find /tmp -name "*.tmp" -delete | head' false
_test_allow 'pipe to rm blocked' 'grep foo bar.txt | rm -rf /' false
_test_allow 'pipe to unknown cmd blocked' 'find . -name "*.py" | some-unknown-cmd' false
_test_allow 'sed -i in pipeline blocked' 'grep foo | sed -i s/foo/bar/ file.txt' false
_test_allow 'curl (allowlisted) piped to jq' 'curl https://api.example.com/foo | jq .' true
_test_allow 'wget (allowlisted) piped to head' 'wget -qO- http://example.com | head -5' true
_test_allow 'allowlisted cmd with redirect piped to head' 'curl https://example.com 2>&1 | head -20' true

echo ""
echo "--- Allowlist auto-approve (check 15) ---"
_test_allow "git log is allowlisted" "git log --oneline" true
_test_allow "npm install is allowlisted" "npm install express" true
_test_allow "echo is allowlisted" "echo hello" true
_test_allow "unknown cmd not allowlisted" "some-unknown-command --flag" false
_test_allow "compound cmd both allowlisted" "npm install && curl http://example.com" true
_test_allow "piped cmd not allowlisted" "git log | rm -rf /" false
_test_allow "semicolon cmd not allowlisted" "echo hello; rm -rf /" false
_test_allow "env-prefixed rm -rf / in compound blocked" "FOO=1 rm -rf / && echo hi" false
_test_allow "env-prefixed unknown cmd in compound blocked" "FOO=1 some-unknown-command && echo hi" false
_test_allow "env-prefixed unknown cmd in pipeline blocked" "FOO=1 some-unknown-command | head" false
_test_allow "env-prefixed safe cmd in compound approved" "A=1 B=2 make && echo ok" true
_test_allow "pipe stage after && is vetted (xargs rm)" "cd x && find . -name a | xargs rm -rf" false
_test_allow "pipe stage after && is vetted (rm -rf /)" "true && echo y | rm -rf /" false
_test_allow "pipe stage after && is vetted (git reset --hard)" "ls && git status | git reset --hard" false
_test_allow "backgrounded cmd after && is vetted" "cd x && npm run dev & git reset --hard" false
_test_allow "backgrounded cmd after a pipeline is vetted" "cat x | grep y & rm -rf ~" false
_test_allow "env cmd after && is vetted" "cd x && env FOO=1 rm -rf /" false
_test_allow "sed -Ei in compound blocked" "cd x && sed -Ei s/a/b/ f" false
_test_allow "sed --in-place in compound blocked" "cd x && sed --in-place s/a/b/ f" false
_test_allow "cmd sub in a safe cmd's args is vetted" "cd x && echo \$(rm -rf ~)" false
_test_allow "pipeline inside a cmd sub is vetted" "cd x && echo \$(ls | rm -rf ~)" false
_test_allow "redirections are not separators" "cd x && make 2>&1 | tail -5" true
_test_allow "arithmetic expansion is not a cmd sub" "cd x && echo \$((1+2))" true
_test_allow "env with a safe cmd approved" "cd x && env FOO=1 make" true
_test_allow "pipe inside a cmd sub in a loop approved" 'for f in *.md; do n=$(head -1 "$f" | sed "s/^# //"); echo "$n"; done' true
_test_allow "multi-line: every line safe approved" "$(printf 'cd /tmp\necho ok\ngrep -c x f')" true
_test_allow "multi-line: an unsafe line blocks" "$(printf 'cd /tmp\nrm -rf /')" false
_test_allow "heredoc body lines are data, not commands" "$(printf 'cat > /tmp/n.md <<EOF\ndon'"'"'t rm -rf /\nEOF')" true
_test_allow "quoted << is not a heredoc (double quotes)" "$(printf 'echo "<<EOF"\nrm -rf ~')" false
_test_allow "quoted << is not a heredoc (single quotes)" "$(printf "echo 'x <<EOF'\nrm -rf ~")" false
_test_allow "quoted << in grep pattern hides no line" "$(printf "grep -n '<<EOF' f.sh && ls\ngit reset --hard")" false
_test_allow "quoted << mid-string hides no line" "$(printf 'echo "use <<EOF here" && ls\nrm -rf ~')" false
_test_allow "arithmetic << hides no line" "$(printf 'echo $((1 << FOO)) && ls\nrm -rf ~')" false
_test_allow "hyphenated heredoc delimiter terminates" "$(printf 'cd x && cat > f <<END-MSG\nbody\nEND-MSG\nrm -rf ~')" false
_test_allow "quoted << with a matching EOF line hides nothing" "$(printf "ls && echo '<<EOF'\nrm -rf ~\nEOF")" false
_test_allow "process substitution is vetted" "cd x && cat <(rm -rf ~)" false
_test_allow "safe process substitution approved" "cd x && diff <(ls a) <(ls b)" true
_test_allow "quoted heredoc delimiter body is data" "$(printf "cat > /tmp/n.md <<'EOF'\ndon't\nEOF")" true
_test_allow "cmd after a heredoc is vetted" "$(printf 'cat > /tmp/n.md <<EOF\nbody\nEOF\nrm -rf ~')" false
_test_allow_with_settings "one allowlisted line doesn't carry a second line" "$(printf 'git status\nrm -rf ~')" false \
  '{"permissions":{"allow":["Bash(npm test*)","Bash(git status*)"]}}'
_test_allow_with_settings "allowlisted cmd doesn't carry a backgrounded one" "npm test & git reset --hard" false \
  '{"permissions":{"allow":["Bash(npm test*)","Bash(git status*)"]}}'
_test_allow_with_settings "allowlisted cmd with 2>&1 still approved" "npm test 2>&1" true \
  '{"permissions":{"allow":["Bash(npm test*)","Bash(git status*)"]}}'

echo ""
echo "--- Settings-driven allow/deny fixtures (pins checks 15 + deny-defers) ---"
_test_allow_with_settings \
  'explicit deny rule defers (no allow) even for an otherwise-safe rm -rf' \
  'rm -rf /tmp/build && mkdir /tmp/build' \
  false \
  '{"permissions":{"deny":["Bash(rm -rf *)"]}}'
_test_allow_with_settings \
  'explicit allow rule approves an otherwise-unknown command' \
  'some-fixture-only-command --flag' \
  true \
  '{"permissions":{"allow":["Bash(some-fixture-only-command *)"]}}'
_test_allow_with_settings \
  'allowlisted unknown command in a compound is approved' \
  'cd /tmp && some-fixture-only-command --flag' \
  true \
  '{"permissions":{"allow":["Bash(some-fixture-only-command *)"]}}'

echo ""
echo "--- Broad allow rules never override hardcoded carveouts (checks 13/14) ---"
_test_allow_with_settings \
  'Bash(rm *) does not unlock rm -rf / in a compound' \
  'rm -rf / && echo oops' \
  false \
  '{"permissions":{"allow":["Bash(rm *)"]}}'
_test_allow_with_settings \
  'Bash(rm *) does not unlock rm -rf ~ in a then-branch' \
  'if [ -f x ]; then rm -rf ~; fi' \
  false \
  '{"permissions":{"allow":["Bash(rm *)"]}}'
_test_allow_with_settings \
  'Bash(rm *) does not unlock rm -rf .git in a while condition' \
  'while rm -rf .git; do echo x; done' \
  false \
  '{"permissions":{"allow":["Bash(rm *)"]}}'
_test_allow_with_settings \
  'Bash(find *) does not unlock find -exec rm in a compound' \
  'cd /tmp && find . -exec rm {} \;' \
  false \
  '{"permissions":{"allow":["Bash(find *)"]}}'
_test_allow_with_settings \
  'Bash(sed *) does not unlock sed -i in a compound' \
  'cd /tmp && sed -i s/a/b/ f.txt' \
  false \
  '{"permissions":{"allow":["Bash(sed *)"]}}'
_test_allow_with_settings \
  'Bash(find *) does not unlock find -delete in a pipeline' \
  'find /tmp -delete | head' \
  false \
  '{"permissions":{"allow":["Bash(find *)"]}}'

echo ""
echo "--- ANSI-C string auto-approve (check 16) ---"
_test_allow "echo with \$'...' is approved" "echo \$'line1\\nline2'" true
_test_allow "printf with \$'...' is approved" "printf \$'%s\\n' hi" true
_test_allow "git with \$'...' is approved" "git commit -m \$'subject\\n\\nbody'" true
_test_allow "bd with \$'...' is approved" "bd create --title \$'foo\\nbar'" true
_test_allow "compound VAR= && bd with \$'...' is approved" "BAM=/tmp && bd create --description \$'multi\\nline'" true
_test_allow "multi-line backslash-continuation bd with \$'...' is approved" "bd create \\
--type bug \\
--description \$'multi\\nline'" true
_test_allow "unknown outer cmd with \$'...' not approved" "evil \$'arg'" false
_test_allow "rm with \$'...' not approved" "rm \$'/tmp/foo'" false
_test_allow "safe \$'...' piece doesn't carry rm -rf / after &&" "echo \$'x' && rm -rf /" false
_test_allow "safe \$'...' piece doesn't carry an unknown cmd after &&" "echo \$'x' && some-unknown-command" false
_test_allow "safe \$'...' piece doesn't carry a pipe to sh" "echo \$'x' | sh" false
_test_allow "unapproved cmd sub in assignment blocks \$'...' approval" "X=\$(some-unknown-command) && echo \$'x'" false
_test_allow_with_settings "git carveout holds with \$'...' (git reset --hard, no allow rules)" "git reset --hard \$'x'" false '{}'
_test_allow "every \$'...' piece safe is approved" "echo \$'x'; git commit -m \$'y'" true
_test_allow "\$'...' piped to jq is approved" "echo \$'a' | jq ." true

echo ""
echo "========================="
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED: $pass tests"
else
  echo "RESULTS: $pass passed, $fail FAILED"
  exit 1
fi

#!/usr/bin/env bash
# bash-guardrails: a trap-only PreToolUse hook for Claude Code's Bash tool.
#
# It denies a command only when zsh (default options) will reject it, and says in one
# line what to write instead. Otherwise it exits 0 with no output, so Claude
# Code's own permission handling decides. It never emits "allow", never
# rewrites the command (no updatedInput), and reads no settings.
#
# Traps, checked on unquoted text only (quoted strings, heredoc bodies,
# comments, ${...} and $[...] expansions, case ... esac blocks, [[ ]] tests, and
# arithmetic are skipped):
#   eq    a word starting with "==": `[ a == b ]`, `echo ===`
#         (zsh: "= not found" / "== not found")
#   glob  a glob zsh cannot match (zsh: "no matches found"):
#         `--flag=*pattern`, `find -name *pattern`, `path?key=value`
set -uo pipefail

# Both traps are zsh defaults (the EQUALS and NOMATCH options). The Bash tool
# runs the user's login shell, so under any other shell there is nothing to catch.
[ "${SHELL##*/}" = zsh ] || exit 0

MAX_SCAN_CHARS=32768
cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null) || exit 0

# Fast path: every trap needs one of these characters.
case "$cmd" in
  *'='* | *'*'* | *'?'* | *'['*) ;;
  *) exit 0 ;;
esac
# The scan below is quadratic in word length; fail open on huge commands.
[ "${#cmd}" -le "$MAX_SCAN_CHARS" ] || exit 0

hit=$(CMD="$cmd" awk '
function reset() { prev = w; w = ""; m = "" }
# w is the word as the shell sees it; m marks each char "u" (unquoted) or "q".
function check_word() {
  if (w == "") return
  if (skip_until != "") { if (w == skip_until) skip_until = ""; reset(); return }
  if (w == "[[") { skip_until = "]]"; reset(); return }
  # Inside case ... esac, patterns like --file=*|-f=*) are matched, never
  # globbed, so check nothing there (a missed trap is cheap, a false deny is not).
  if (m ~ /^u+$/ && (prev == "" || prev ~ /^(do|then|else|elif|[{!])$/)) {
    if (w == "case") in_case++
    else if (w == "esac" && in_case > 0) in_case--
  }
  if (in_case > 0) { reset(); return }
  if (substr(w, 1, 2) == "==" && substr(m, 1, 2) == "uu") hit("eq")
  if (w ~ /^--?[A-Za-z][A-Za-z0-9_-]*=/ && has_glob(index(w, "=") + 1)) hit("glob")
  if (prev ~ /^-i?(name|path|wholename)$/ && has_glob(1)) hit("glob")
  # zsh does not glob assignments (FOO=a?b=1, export FOO=...).
  if (w !~ /^[A-Za-z_][A-Za-z0-9_]*=/ && match(w, /\?[A-Za-z_][A-Za-z0-9_]*=/) && substr(m, RSTART, 1) == "u") hit("glob")
  reset()
}
function hit(kind) { print kind "\t" w; exit }
function has_glob(from,   j, c) {
  for (j = from; j <= length(w); j++) {
    if (substr(m, j, 1) != "u") continue
    c = substr(w, j, 1)
    if (c == "*" || c == "?") return 1
    if (c == "[" && index(substr(w, j + 1), "]")) return 1
  }
  return 0
}
function add(c, q) { w = w c; m = m q }
# At "<<" (i on the first "<"): record the heredoc delimiter, advance past it.
function read_heredoc(   d, ch, strip) {
  i += 2; strip = 0
  if (substr(s, i, 1) == "-") { strip = 1; i++ }
  while (substr(s, i, 1) ~ /[ \t]/) i++
  d = ""
  while (i <= n && substr(s, i, 1) !~ /[ \t\n;&|<>()]/) {
    ch = substr(s, i, 1)
    if (ch != "\"" && ch != SQ && ch != "\\") d = d ch
    i++
  }
  nh++; hdelim[nh] = d; hstrip[nh] = strip
}
# At the start of a line: skip every pending heredoc body.
function skip_bodies(   h, e, line) {
  for (h = 1; h <= nh; h++) {
    while (i <= n) {
      e = index(substr(s, i), "\n")
      line = e ? substr(s, i, e - 1) : substr(s, i)
      i = e ? i + e : n + 1
      if (hstrip[h]) sub(/^\t+/, "", line)
      if (line == hdelim[h]) break
    }
  }
  nh = 0
}
function is_heredoc() { return substr(s, i, 2) == "<<" && substr(s, i, 3) != "<<<" }
BEGIN {
  SQ = sprintf("%c", 39)
  s = ENVIRON["CMD"]; n = length(s); i = 1; nh = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\n") { check_word(); prev = ""; i++; skip_bodies(); continue }
    if (c == " " || c == "\t") { check_word(); i++; continue }
    if (c == "$" && substr(s, i, 3) == "$((" || c == "(" && substr(s, i, 2) == "((") {
      check_word()
      e = index(substr(s, i), "))")
      i = e ? i + e + 1 : n + 1
      continue
    }
    if (c == "$" && substr(s, i + 1, 1) ~ /[{[]/) {
      # ${...} and $[...] hold patterns and subscripts zsh never globs.
      close_ch = substr(s, i + 1, 1) == "{" ? "}" : "]"
      open_ch = substr(s, i + 1, 1); depth = 0
      for (; i <= n; i++) {
        ch = substr(s, i, 1)
        if (ch == "\"" || ch == SQ || ch == "\\") exit   # too tangled to track: fail open
        add(ch, "q")
        if (ch == open_ch) depth++
        else if (ch == close_ch && --depth == 0) { i++; break }
      }
      continue
    }
    if (c == "$" && substr(s, i + 1, 1) == "(") { check_word(); prev = ""; i += 2; continue }
    if (c ~ /[;&|<>()]/) {
      check_word(); prev = ""
      if (substr(s, i, 3) == "<<<") i += 3; else if (is_heredoc()) read_heredoc(); else i++
      continue
    }
    if (c == "#" && w == "") {
      e = index(substr(s, i), "\n")
      i = e ? i + e - 1 : n + 1
      continue
    }
    if (c == "\\") { add(substr(s, i + 1, 1), "q"); i += 2; continue }
    if (c == SQ) {
      e = index(substr(s, i + 1), SQ)
      if (!e) exit
      for (j = i + 1; j < i + e; j++) add(substr(s, j, 1), "q")
      i += e + 1
      continue
    }
    if (c == "\"") {
      i++
      while (i <= n && substr(s, i, 1) != "\"") {
        if (is_heredoc()) {
          # "$(cat <<EOF ... EOF)": skip the body, which may hold quotes.
          read_heredoc()
          e = index(substr(s, i), "\n")
          if (!e) exit
          i += e
          skip_bodies()
          continue
        }
        if (substr(s, i, 1) == "\\") i++
        add(substr(s, i, 1), "q")
        i++
      }
      i++
      continue
    }
    add(c, "u"); i++
  }
  check_word()
}')

[ -n "$hit" ] || exit 0
kind=${hit%%$'\t'*}
word=${hit#*$'\t'}

if [ "$kind" = eq ]; then
  reason="zsh reads the unquoted word \`$word\` as a command path and fails (\"= not found\"): quote it (\`echo '==='\`), or compare with \`[[ a == b ]]\` or \`[ a = b ]\`."
else
  reason="zsh expands the unquoted glob \`$word\` against local files, and fails (\"no matches found\") when nothing matches: quote it, e.g. \`--include='*.md'\`, \`-name '*.md'\`, or \`'repos/x?ref=main'\`."
fi

jq -n --arg r "$reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'

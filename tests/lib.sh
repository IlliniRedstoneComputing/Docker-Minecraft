#!/usr/bin/env bash
# Shared assertion helpers. Source this from every test script.
#
# Sourcing sets `set -uo pipefail` in the caller. It deliberately does NOT
# set -e: a suite must record a failure and keep going.
#
# Results are recorded in temp files rather than shell variables so that an
# assertion inside a pipeline or a $(...) subshell is still counted. Plain
# counters are lost with the subshell, which lets a suite print FAIL and
# still exit 0 -- a test that passes when it should fail is worse than no
# test at all.
set -uo pipefail

: "${_ASSERT_RUN_LOG:=$(mktemp)}"
: "${_ASSERT_FAIL_LOG:=$(mktemp)}"

# Deliberately NOT exported. Subshells inherit ordinary shell variables, which
# is all the counting needs. Exporting would also hand the paths to CHILD
# PROCESSES, so a child suite that sources this file would delete the parent's
# logs in its own finish -- erasing already-recorded failures and letting the
# parent exit 0. That is the same false-pass class this design exists to close.
trap 'rm -f "$_ASSERT_RUN_LOG" "$_ASSERT_FAIL_LOG"' EXIT

pass() {
  printf 'x\n' >>"$_ASSERT_RUN_LOG"
  printf '  ok   %s\n' "$1"
}

fail() {
  printf 'x\n' >>"$_ASSERT_RUN_LOG"
  printf 'x\n' >>"$_ASSERT_FAIL_LOG"
  printf '  FAIL %s\n' "$1"
  if [ $# -gt 1 ]; then printf '       %s\n' "$2"; fi
  return 0
}

# bail <description> -- unrecoverable setup failure; stop the suite non-zero.
# The EXIT trap cleans up the logs.
bail() {
  printf '  FAIL %s\n' "$1"
  printf '\nsuite aborted\n'
  exit 1
}

# assert_contains <haystack> <needle> <description>
assert_contains() {
  case "$1" in
    *"$2"*)
      pass "$3"
      ;;
    *)
      # Name the likely cause: an empty haystack almost always means a
      # broken extraction, not a genuinely missing needle.
      if [ -z "$1" ]; then
        fail "$3" "expected to find: $2 (haystack was empty; the extraction probably failed)"
      else
        fail "$3" "expected to find: $2"
      fi
      ;;
  esac
}

# assert_not_contains <haystack> <needle> <description>
#
# An empty haystack is a FAILURE, not a pass. Without this guard a broken
# extraction -- a renamed service, a changed indent, a compose render change
# -- silently converts this assertion into a permanent pass.
assert_not_contains() {
  if [ -z "$1" ]; then
    fail "$3" "haystack was empty; the extraction probably failed"
    return 0
  fi
  case "$1" in
    *"$2"*) fail "$3" "did not expect to find: $2" ;;
    *) pass "$3" ;;
  esac
}

# assert_eq <actual> <expected> <description>
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected '$2', got '$1'"; fi
}

# assert_in <value> <space-separated-allowed> <description>
assert_in() {
  case " $2 " in
    *" $1 "*) pass "$3" ;;
    *) fail "$3" "got '$1', expected one of: $2" ;;
  esac
}

# flatten <text> -- collapse newlines and runs of spaces to single spaces.
#
# For matching against `docker compose config` output. The renderer re-emits a
# long command scalar as WRAPPED yaml and breaks it mid-command: a
# `chown -R 1000:1000 /mnt/data` comes back with the line ending after `-R`.
# A literal needle spanning that break cannot match however correct the compose
# file is -- measured, after an assertion failed against a config that was
# already right.
#
# Fold before matching, and fold for EVERY needle against that haystack rather
# than only the ones observed to wrap, since where the renderer chooses to break
# is not a property any test should depend on.
#
# The cost: folding joins adjacent yaml keys, so a needle could in principle
# match across a key boundary that does not exist in the source. Keep needles
# specific enough that this cannot bite -- a bare word like `777` is fine
# because the renderer only ever folds at whitespace, so a short token cannot
# straddle a break.
flatten() {
  printf '%s' "$1" | tr '\n' ' ' | tr -s ' '
}

# service_block <name> <yaml> -- print one top-level service's block.
#
# Works on both the rendered config and the raw compose.yml. The block ends
# at the next sibling key (two-space indent) or the next top-level key (zero
# indent), whatever its first character. Two traps this avoids:
#   - matching /^  [a-z]/ would let the LAST service swallow the networks
#     and volumes sections as soon as any name began with a capital or digit
#   - without the zero-indent rule the last service trails a bare
#     "networks:" line, since that key is not indented at all
# `index($0, svc) == 1` is a literal column-1 match, so service names
# containing '-' need no escaping, and the trailing colon keeps
# "luckperms-db" from matching the "luckperms-db-data" volume.
service_block() {
  printf '%s\n' "$2" | awk -v svc="  $1:" '
    index($0, svc) == 1 { f = 1; next }
    f && /^[^ ]/ { exit }
    f && /^  [^ ]/ { exit }
    f { print }
  '
}

finish() {
  local run=0 failed=0
  [ -s "$_ASSERT_RUN_LOG" ] && run=$(wc -l <"$_ASSERT_RUN_LOG" | tr -d ' ')
  [ -s "$_ASSERT_FAIL_LOG" ] && failed=$(wc -l <"$_ASSERT_FAIL_LOG" | tr -d ' ')
  printf '\n%d run, %d failed\n' "$run" "$failed"
  [ "$failed" -eq 0 ] || exit 1
  exit 0
}

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
export _ASSERT_RUN_LOG _ASSERT_FAIL_LOG

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
bail() {
  printf '  FAIL %s\n' "$1"
  printf '\nsuite aborted\n'
  rm -f "$_ASSERT_RUN_LOG" "$_ASSERT_FAIL_LOG"
  exit 1
}

# assert_contains <haystack> <needle> <description>
assert_contains() {
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3" "expected to find: $2" ;;
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

# service_block <name> <yaml> -- print one top-level service's block.
#
# Works on both the rendered config and the raw compose.yml. The block ends
# at the next key indented two spaces, whatever its first character:
# matching /^  [a-z]/ instead would let the LAST service swallow the
# networks and volumes sections as soon as any name began with a capital
# or a digit.
service_block() {
  printf '%s\n' "$2" | awk -v svc="  $1:" '
    index($0, svc) == 1 { f = 1; next }
    f && /^  [^ ]/ { exit }
    f { print }
  '
}

finish() {
  run=0
  failed=0
  [ -s "$_ASSERT_RUN_LOG" ] && run=$(wc -l <"$_ASSERT_RUN_LOG" | tr -d ' ')
  [ -s "$_ASSERT_FAIL_LOG" ] && failed=$(wc -l <"$_ASSERT_FAIL_LOG" | tr -d ' ')
  rm -f "$_ASSERT_RUN_LOG" "$_ASSERT_FAIL_LOG"
  printf '\n%d run, %d failed\n' "$run" "$failed"
  [ "$failed" -eq 0 ] || exit 1
  exit 0
}

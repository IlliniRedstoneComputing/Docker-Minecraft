#!/usr/bin/env bash
# Shared assertion helpers. Source this from every test script.
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  ok   %s\n' "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL %s\n' "$1"
  [ $# -gt 1 ] && printf '       %s\n' "$2"
  return 0
}

# assert_contains <haystack> <needle> <description>
assert_contains() {
  case "$1" in
    *"$2"*) _pass "$3" ;;
    *) _fail "$3" "expected to find: $2" ;;
  esac
}

# assert_not_contains <haystack> <needle> <description>
assert_not_contains() {
  case "$1" in
    *"$2"*) _fail "$3" "did not expect to find: $2" ;;
    *) _pass "$3" ;;
  esac
}

# assert_eq <actual> <expected> <description>
assert_eq() {
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3" "expected '$2', got '$1'"; fi
}

# assert_in <value> <space-separated-allowed> <description>
assert_in() {
  local value="$1" allowed="$2" desc="$3" candidate
  for candidate in $allowed; do
    if [ "$value" = "$candidate" ]; then _pass "$desc"; return 0; fi
  done
  _fail "$desc" "got '$value', expected one of: $allowed"
}

finish() {
  printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ] || exit 1
  exit 0
}

#!/usr/bin/env bash
# Run every test suite. Requires the stack to be running.
cd "$(dirname "$0")/.." || exit 1

FAILED=""
RAN=0
for suite in tests/test-*.sh; do
  # An unmatched glob stays literal in bash, so with no suites present this
  # loop would run once with suite='tests/test-*.sh' and report a confusing
  # "No such file or directory" instead of the obvious thing. Say it plainly.
  [ -r "$suite" ] || { echo "no test suites found in tests/"; exit 1; }
  echo
  echo "=============================================================="
  echo "$suite"
  echo "=============================================================="
  RAN=$((RAN + 1))
  bash "$suite" || FAILED="$FAILED $suite"
done

echo
if [ -z "$FAILED" ]; then
  echo "ALL $RAN SUITES PASSED"
  exit 0
fi
# Name them. Each suite already prints its own failures, but four suites emit
# several hundred lines between them, and "SOME SUITES FAILED" on its own
# makes you scroll back through all of it to learn which one to look at.
echo "FAILED SUITES:$FAILED"
exit 1

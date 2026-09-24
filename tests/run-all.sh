#!/usr/bin/env bash
# Run every test suite. Requires the stack to be running.
cd "$(dirname "$0")/.." || exit 1

# Collect the suites up front. An unmatched glob stays literal in bash, so
# testing the first element for existence is what separates "no suites at all"
# from "a suite that happens to be named tests/test-*.sh". Checking here rather
# than inside the loop is deliberate: a per-iteration guard abandons every
# suite after the first unreadable one AND reports "no test suites found",
# which is both a false message and silent loss of coverage.
suites=(tests/test-*.sh)
[ -e "${suites[0]}" ] || { echo "no test suites found in tests/"; exit 1; }

FAILED=""
RAN=0
for suite in "${suites[@]}"; do
  echo
  echo "=============================================================="
  echo "$suite"
  echo "=============================================================="
  RAN=$((RAN + 1))

  out=$(mktemp)
  bash "$suite" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}

  # Exit status alone is not enough to judge a suite. In tests/lib.sh, fail()
  # returns 0 and only appends to a log; finish() is the one thing that turns
  # recorded failures into a non-zero exit. So a suite that prints FAIL lines
  # and then dies -- or is simply written without a trailing finish -- exits 0
  # and would be counted here as a pass. lib.sh's own header says a test that
  # passes when it should fail is worse than no test at all; this keeps that
  # true across the process boundary. bail() exits 1 and is unaffected.
  if [ "$rc" -eq 0 ] && ! grep -qE '^[0-9]+ run, [0-9]+ failed$' "$out"; then
    echo "  (exited 0 without reaching finish -- treating as a failure)"
    rc=1
  fi
  rm -f "$out"

  # Record the exit code, not just the name. rc=1 is an ordinary assertion
  # failure (or the missing-finish case above); anything else is not, and
  # collapsing them all to "this suite failed" sends you hunting in the wrong
  # file. 130 means the suite was interrupted. Note that a bad shebang does
  # NOT show up as 126/127 here -- `bash "$suite"` reads the file itself, so
  # the shebang line is just a comment, and such a suite exits 0 and is caught
  # by the finish check instead. Measured both ways.
  [ "$rc" -eq 0 ] || FAILED="$FAILED $suite(rc=$rc)"
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

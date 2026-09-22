#!/usr/bin/env bash
# Static checks against the rendered compose configuration.
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib.sh
. tests/lib.sh

echo "compose configuration"

if ! CONFIG=$(docker compose config 2>&1); then
  echo "  FAIL docker compose config did not render"
  echo "$CONFIG"
  exit 1
fi
_pass "docker compose config renders"

# The raw file, for checks about things the renderer erases. `docker compose
# config` strips comments and substitutes ${VAR:-default} away, so defaults
# and commented-out blocks are only visible here.
RAW=$(cat compose.yml)

# A missing backup.config must not abort the stack.
assert_contains "$RAW" "required: false" "backup.config is optional"

# Exactly one published port in the whole stack.
PUBLISHED=$(printf '%s\n' "$CONFIG" | grep -cE '^\s+published:' || true)
assert_eq "$PUBLISHED" "1" "exactly one published port"
assert_contains "$CONFIG" "target: 25565" "the published port targets 25565"

# Credential defaults must agree between the database and its clients. This
# must be checked against the raw file: interpolation hides the defaults.
assert_not_contains "$RAW" "user_luckperms" "no stale user_luckperms default"

# Velocity must have a restart policy like every other long-lived service.
VELOCITY=$(printf '%s\n' "$CONFIG" | awk '/^  velocity:/{f=1;next} /^  [a-z]/{f=0} f')
assert_contains "$VELOCITY" "restart: unless-stopped" "velocity has a restart policy"

# The base image healthcheck must not be shadowed by a weaker override.
LPSA=$(printf '%s\n' "$CONFIG" | awk '/^  luckperms-standalone:/{f=1;next} /^  [a-z]/{f=0} f')
assert_not_contains "$LPSA" "healthcheck" "no redundant luckperms healthcheck override"

finish

#!/usr/bin/env bash
# Static checks against the rendered compose configuration.
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib.sh
. tests/lib.sh

echo "compose configuration"

# Keep stderr out of the searched text. `docker compose config` writes
# warnings about unset variables and obsolete attributes to stderr, and
# merging them into CONFIG would let them satisfy the assertions below.
STDERR=$(mktemp)
if ! CONFIG=$(docker compose config 2>"$STDERR"); then
  cat "$STDERR" >&2
  rm -f "$STDERR"
  bail "docker compose config did not render"
fi
rm -f "$STDERR"
pass "docker compose config renders"

# The raw file, for checks about things the renderer erases. `docker compose
# config` strips comments and substitutes ${VAR:-default} away, so defaults
# and commented-out blocks are only visible here.
RAW=$(cat compose.yml)

# A missing backup.config must not abort the stack. Scoped to the backup
# service so it cannot be satisfied by the string appearing elsewhere.
BACKUP=$(service_block backup "$RAW")
assert_contains "$BACKUP" "required: false" "backup.config is optional"

# Exactly one published port in the whole stack.
PUBLISHED=$(printf '%s\n' "$CONFIG" | grep -cE '^[[:space:]]+published:' || true)
assert_eq "$PUBLISHED" "1" "exactly one published port"
assert_contains "$CONFIG" "target: 25565" "the published port targets 25565"

# Credential defaults must agree between the database and its clients. Checked
# against the raw file, since interpolation hides the defaults. Both the
# absence of the old value and the presence of the new one are asserted:
# absence alone would still pass if the setting were deleted outright.
assert_not_contains "$RAW" "user_luckperms" "no stale user_luckperms default"
DBUSER_ALL=$(printf '%s\n' "$RAW" | grep -cF '${LUCKPERMS_DB_USER:-' || true)
DBUSER_OK=$(printf '%s\n' "$RAW" | grep -cF '${LUCKPERMS_DB_USER:-luckperms_user}' || true)
if [ "$DBUSER_ALL" -gt 0 ]; then
  pass "LUCKPERMS_DB_USER defaults are present"
else
  fail "LUCKPERMS_DB_USER defaults are present" "found none at all"
fi
# Self-relative, not a hardcoded count: later tasks add more consumers.
assert_eq "$DBUSER_OK" "$DBUSER_ALL" "every LUCKPERMS_DB_USER default agrees"

# Velocity must have a restart policy like every other long-lived service.
VELOCITY=$(service_block velocity "$CONFIG")
assert_contains "$VELOCITY" "restart: unless-stopped" "velocity has a restart policy"

# The base image healthcheck must not be shadowed by a weaker override.
LPSA=$(service_block luckperms-standalone "$CONFIG")
assert_not_contains "$LPSA" "healthcheck" "no redundant luckperms healthcheck override"

# Dead volumes and services must be gone. Both are checked against the raw
# file: the commented-out sftpgo block is invisible to the renderer, and
# `docker compose config` silently prunes any top-level volume that no
# service mounts, so an unreferenced wireguard volume would never show up
# in $CONFIG regardless of whether it is still declared in compose.yml.
assert_not_contains "$RAW" "sftpgo" "no sftpgo remnants in compose.yml"
assert_not_contains "$RAW" "wireguard-module-data" "no wireguard volume"

finish

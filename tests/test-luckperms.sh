#!/usr/bin/env bash
# LuckPerms storage, messaging and API reachability.
# Requires the stack to be running.
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib.sh
. tests/lib.sh

# tr -d '\r' on every one of these: .env is a mixed-ending file -- CRLF
# throughout except the JAVA_OPTS line appended in Step 2 (CR=28, LF=30). Git
# Bash's grep opens in text mode and strips the CR by accident, so this looks
# unnecessary here and is not -- the same script on Linux keeps the CR, and a
# trailing CR inside a bearer token produces a 401 that reads like a wrong
# password rather than a line-ending bug. tests/test-webdav.sh omits this and
# survives only because of that Git Bash accident; worth backporting.
SECRET=$(grep -E '^LUCKPERMS_SECRET=' .env | cut -d= -f2- | tr -d '\r')
DB_USER=$(grep -E '^LUCKPERMS_DB_USER=' .env | cut -d= -f2- | tr -d '\r')
DB_PASS=$(grep -E '^LUCKPERMS_DB_PASSWORD=' .env | cut -d= -f2- | tr -d '\r')
DB_NAME=$(grep -E '^LUCKPERMS_DB=' .env | cut -d= -f2- | tr -d '\r')

BASE="http://caddy:80"

# Keep the bearer token off the docker run argv, where `docker inspect` and
# host `ps` would expose it for the container's lifetime. curl reads it from a
# config file on stdin instead -- the same trick tests/test-webdav.sh uses for
# the WebDAV password.
CURLRC=$(printf 'header = "Authorization: Bearer %s"\n' "$SECRET")

# api <curl-args...> -- curl inside the frontend network, against Caddy.
api() {
  printf '%s' "$CURLRC" | docker run --rm -i --network irc-frontend-network \
    curlimages/curl:latest -s -K - "$@"
}

# lp <path> -- GET the LuckPerms API through Caddy, exactly as an external
# client would, prefix and all.
lp() { api "$BASE/luckperms$1"; }

# The suite writes a real group into the shared database. Delete it both before
# and after, so an interrupted run cannot poison the next one. The trap covers
# the ordinary interrupted run; the explicit call below covers what a trap
# cannot -- a previous run killed by SIGKILL, where no handler fired at all.
# $$ is unique among live processes but PIDs recycle, and against a leftover
# group of the same name the POST becomes an update rather than a create.
#
# GROUP is named here, above the trap, so the handler is never installed with
# nothing to delete. A 404 from the pre-run delete is expected and ignored.
#
# tests/lib.sh installs its own EXIT trap to remove its temp result logs, so
# chain onto it rather than replacing it -- a plain `trap lp_cleanup EXIT`
# silently discards lib.sh's cleanup, leaking two temp files per run. Verified
# by capture-and-chain in a subshell: both _ASSERT_* logs are removed. Same
# pattern, and the same reasoning, as tests/test-webdav.sh.
GROUP="msgtest$$"

lp_cleanup() {
  api -o /dev/null -X DELETE "$BASE/luckperms/group/$GROUP" >/dev/null 2>&1 || true
}
_prior_exit_trap=$(trap -p EXIT)
_prior_exit_trap=${_prior_exit_trap#trap -- \'}
_prior_exit_trap=${_prior_exit_trap%\' EXIT}
trap "lp_cleanup; ${_prior_exit_trap}" EXIT
lp_cleanup

echo "luckperms"

# The API must be reachable through the Caddy /luckperms route, which proves
# the prefix is being stripped correctly.
# The needle is '"healthy":true'. NOT '"up":true' -- that is the needle the
# LuckPerms base image's own healthcheck greps for, which can never match this
# version. AGENTS.md item 1 documents it for the container healthcheck, and
# test-compose-config.sh already asserts the compose override does not use it.
# Measured through Caddy on a running stack:
#   {"healthy":true,"details":{"storageConnected":true,"storagePing":2}}
# The REST API on 8080 and the heartbeat server on 3001 both return this same
# schema, so the distinction between those two ports does not rescue "up".
HEALTH=$(lp /health)
assert_contains "$HEALTH" '"healthy":true' "API is healthy through the /luckperms route"

# Storage must be the shared MariaDB, not a local H2 file.
TABLES=$(docker compose exec -T luckperms-db \
  mariadb -u"$DB_USER" -p"$DB_PASS" -N -B -e "SHOW TABLES;" "$DB_NAME" 2>/dev/null)
assert_contains "$TABLES" "luckperms_group_permissions" "group permissions table exists"
assert_contains "$TABLES" "luckperms_user_permissions" "user permissions table exists"

# Every server must have resolved its configuration from the environment.
for svc in velocity survival lobby onboarding project-0 project-1; do
  LOGS=$(docker compose logs "$svc" 2>/dev/null)
  assert_contains "$LOGS" "LUCKPERMS_STORAGE_METHOD = mariadb" \
    "$svc resolved storage method from the environment"
done

# No server may have fallen back to a local H2 database.
for svc in survival lobby onboarding project-0 project-1; do
  H2=$(docker compose exec -T "$svc" sh -c 'ls /data/config/luckperms/ 2>/dev/null | grep -i "\.mv\.db" || echo NONE')
  assert_eq "$H2" "NONE" "$svc created no H2 database"
done

VH2=$(docker compose exec -T velocity sh -c 'ls /server/plugins/luckperms/ 2>/dev/null | grep -i "\.mv\.db" || echo NONE')
assert_eq "$VH2" "NONE" "velocity created no H2 database"

# Messaging: a group created through the API must reach a running server
# without restarting it.
#
# Do NOT probe this with `rcon-cli lp listgroups`. RCON itself works on
# survival -- `rcon-cli list` returns "There are 0 of a max of 20 players
# online" -- but `lp listgroups` returns an EMPTY string over RCON, and the
# output does not go to the server log either. Measured both ways. A test
# built on it fails permanently while reporting the failure as "messaging is
# broken", which is the worst possible way to be wrong here.
#
# Assert on the messenger's own log line instead. When another node writes an
# update, LuckPerms logs:
#   [Messaging] Received update ping with id: 74141066-09c3-4574-a9b9-264d36627c2b
# That is the SQL messenger delivering a cross-server notification, which is
# the property under test -- more direct than any command output.
#
# Creating a group is NOT enough to trigger one. Measured on the running stack
# under a controlled probe -- 20s quiet beforehand to establish that nothing
# pings spontaneously, then one call at a time:
#
#   quiet 20s                           6 -> 6
#   POST /group          (201)          6 -> 6   after a full 60 seconds
#   PUT  /group/<g>/nodes (200)         6 -> 7   within 5 seconds
#   DELETE /group/<g>    (200)          ping, ~1 second
#
# So the group create alone produces no bus message, and a test that waits for
# one fails on a perfectly healthy stack -- while reporting the failure as
# "messaging is broken", which is the worst available way to be wrong. This is
# not a defect to fix: an empty group changes nothing a backend caches, and the
# write immediately after it does push. Do not "correct" this back to asserting
# on the create.
#
# Note for anyone re-measuring: a DELETE also pings, so a probe that creates a
# group, deletes it, and then creates another will see a ping arrive shortly
# after the second create that was actually caused by the first delete. That
# false attribution is how the create was originally believed to ping at all.
# Leave a quiet gap, and change one thing at a time.
#
# Count BEFORE and require the count to rise. A bare grep would pass on a ping
# from earlier in the container's life and never fail.
PINGS_BEFORE=$(docker compose logs survival 2>/dev/null | grep -c 'Received update ping')

api -o /dev/null -H 'Content-Type: application/json' \
  -X POST -d "{\"name\":\"$GROUP\"}" "$BASE/luckperms/group"

# The write that actually exercises the messenger.
api -o /dev/null -H 'Content-Type: application/json' \
  -X PUT -d '[{"key":"test.probe","value":true}]' "$BASE/luckperms/group/$GROUP/nodes"

FOUND=NO
for _ in $(seq 1 30); do
  PINGS_NOW=$(docker compose logs survival 2>/dev/null | grep -c 'Received update ping')
  if [ "$PINGS_NOW" -gt "$PINGS_BEFORE" ]; then FOUND=YES; break; fi
  sleep 2
done
assert_eq "$FOUND" "YES" "a group written via the API pings survival without a restart"

# And the write itself must have landed in the shared database.
GROUPS_SQL=$(docker compose exec -T luckperms-db \
  mariadb -u"$DB_USER" -p"$DB_PASS" -N -B -e "SELECT name FROM luckperms_groups;" "$DB_NAME" 2>/dev/null)
assert_contains "$GROUPS_SQL" "$GROUP" "the new group is present in the shared database"

lp_cleanup

finish

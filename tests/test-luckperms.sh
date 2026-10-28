#!/usr/bin/env bash
# LuckPerms storage, messaging and API reachability.
# Requires the stack to be running.
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib.sh
. tests/lib.sh

# Name a missing prerequisite once, rather than letting it surface as a 401 and
# a cascade of unrelated-looking failures. Same precedent as the
# `[ -r compose.yml ] || bail` in tests/test-compose-config.sh.
[ -r .env ] || bail ".env is not readable from $(pwd)"

# tr -d '\r' on every one of these: .env is a mixed-ending file. Measured
# CR=28, LF=30 -- two lines carry no CR, CLOUDFLARE_TUNNEL_TOKEN and JAVA_OPTS,
# and every other line is CRLF. LUCKPERMS_SECRET is one of the CRLF lines,
# which is what makes this load-bearing. Git Bash's grep opens in text mode and
# strips the CR by accident, so the guard looks unnecessary here and is not:
# the same script on Linux keeps the CR, and a trailing CR inside a bearer
# token produces a 401 that reads like a wrong password rather than a
# line-ending bug. tests/test-webdav.sh omits this and survives only because of
# that Git Bash accident -- recorded as deferral 5 under Task 19 Step 2b.
SECRET=$(grep -E '^LUCKPERMS_SECRET=' .env | cut -d= -f2- | tr -d '\r')
DB_USER=$(grep -E '^LUCKPERMS_DB_USER=' .env | cut -d= -f2- | tr -d '\r')
DB_PASS=$(grep -E '^LUCKPERMS_DB_PASSWORD=' .env | cut -d= -f2- | tr -d '\r')
DB_NAME=$(grep -E '^LUCKPERMS_DB=' .env | cut -d= -f2- | tr -d '\r')

[ -n "$SECRET" ] || bail "LUCKPERMS_SECRET is empty or missing from .env"
[ -n "$DB_NAME" ] || bail "LUCKPERMS_DB is empty or missing from .env"

BASE="http://caddy:80"

# Keep the bearer token off the docker run argv, where `docker inspect` and
# host `ps` would expose it for the container's lifetime. curl reads it from a
# config file on stdin instead -- the same trick tests/test-webdav.sh uses for
# the WebDAV password.
CURLRC=$(printf 'header = "Authorization: Bearer %s"\n' "$SECRET")

# api <curl-args...> -- curl inside the frontend network, against Caddy.
api() {
  printf '%s' "$CURLRC" | docker run --rm -i --network irc-frontend-network \
    curlimages/curl:8.22.0 -s -K - "$@"
}

# lp <path> -- GET the LuckPerms API through Caddy, exactly as an external
# client would, prefix and all.
lp() { api "$BASE/luckperms$1"; }

# The suite writes a real group into the shared database. Delete it both before
# and after, so an interrupted run cannot poison the next one.
#
# Be precise about what the pre-run delete buys, because the obvious reading is
# too generous. It removes `msgtest$$` and nothing else, so against a run
# killed by SIGKILL -- where no EXIT handler fires at all -- it reclaims the
# leaked group ONLY if this run happens to draw the same PID. A SIGKILLed run
# therefore leaks one `msgtest<pid>` group carrying a `test.probe` node into
# the shared database, and nothing here sweeps it up. That is accepted rather
# than solved: sweeping everything matching `^msgtest[0-9]+$` would delete a
# concurrently running copy's group out from under it, trading a rare harmless
# leak for a confusing failure.
#
# The trap covers the ordinary interrupted run, which is the common case, and
# the pre-run call also covers the PID-reuse collision, where the POST would
# otherwise become an update rather than a create.
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
#
# Assert on the RAW directory listing and let assert_not_contains fail on an
# empty haystack. The obvious form is a false-pass generator:
#
#   H2=$(... 'ls /data/config/luckperms/ 2>/dev/null | grep -i "\.mv\.db" || echo NONE')
#   assert_eq "$H2" "NONE" ...
#
# because it manufactures the PASS sentinel out of a FAILED listing. Measured
# on the running stack: a nonexistent directory returns `NONE` byte for byte
# identically to a clean one, so a LuckPerms version that relocates its data
# folder, a renamed service, or a plugin that never loaded would silently turn
# all six of these into permanent passes. lib.sh documents a guard for exactly
# this class on assert_not_contains, and the `|| echo NONE` form routes around
# it. The raw listing separates the cases: a non-empty listing versus none.
#
# tr provides the case-insensitivity grep -i was doing, the same way
# test-compose-config.sh lowercases before its own checks.
for svc in survival lobby onboarding project-0 project-1; do
  LS=$(docker compose exec -T "$svc" sh -c 'ls -A /data/config/luckperms/ 2>/dev/null' | tr 'A-Z' 'a-z')
  assert_not_contains "$LS" ".mv.db" "$svc created no H2 database"
done

VLS=$(docker compose exec -T velocity sh -c 'ls -A /server/plugins/luckperms/ 2>/dev/null' | tr 'A-Z' 'a-z')
assert_not_contains "$VLS" ".mv.db" "velocity created no H2 database"

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
# Correlate by ping ID rather than by counting. A count that merely RISES is
# satisfied by anyone else's ping: a concurrent copy of this suite, an admin
# running an `lp` command on another node, or this script's own pre-run
# lp_cleanup DELETE landing late. Given that the comment directly above records
# a false attribution as the reason the create was ever believed to ping, a
# design open to the same confusion does not belong here.
#
# The id appears on both sides and matches exactly. Verified on the stack:
#   luckperms-standalone | [Messaging] Sending ping with id: 820d2c85-0dfe-...
#   survival-server      | [Messaging] Received update ping with id: 820d2c85-0dfe-...
#
# This also splits two failures that the count conflates: no new `Sending` line
# means the write never pushed, while `Sending` without `Received` means the
# messenger itself is broken.
#
# What this proves is bounded, and worth stating exactly: SENT_BEFORE is read a
# few seconds before the PUT, so a foreign ping landing in that window would be
# adopted as PING_ID. The delivery half stays exact either way, CODE_PUT and the
# row count independently prove our write happened, and the window is the
# POST+PUT interval rather than the whole run -- but it is not zero.
#
# The baseline read below is deliberately NOT bounded by --since, unlike the
# poll loops. It runs once rather than up to 45 times, so the cost that --since
# exists to avoid does not apply, and a window that excluded an older last ping
# would hand back an empty baseline that any new ping then appears to differ
# from. Do not "harmonize" it with the loops.
SENT_BEFORE=$(docker compose logs luckperms-standalone 2>/dev/null \
  | grep -o 'Sending ping with id: [0-9a-f-]*' | tail -1)

# Assert the writes SUCCEEDED before concluding anything about messaging. With
# -o /dev/null and no status check, a 401 from a rotated secret or a 5xx from a
# Caddy route change produces no ping, and the suite then reports "messaging is
# broken" -- the exact misdiagnosis this block twice warns against.
CODE_POST=$(api -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -X POST -d "{\"name\":\"$GROUP\"}" "$BASE/luckperms/group")
assert_eq "$CODE_POST" "201" "the API created the test group"

# The write that actually exercises the messenger. test.probe is deliberately
# OUTSIDE the mchprs.* namespace: MCHPRS reads this same database directly, and
# per AGENTS.md a stored node that is a strict prefix of a queried node panics
# it with an index-out-of-bounds. Do not rename this to mchprs.test.
CODE_PUT=$(api -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -X PUT -d '[{"key":"test.probe","value":true}]' "$BASE/luckperms/group/$GROUP/nodes")
assert_eq "$CODE_PUT" "200" "the API wrote a node to the test group"

# --since bounds each rescan: container logs here have no max-size, so an
# unbounded `docker compose logs` is re-read in full on every one of up to 45
# polls, and grows without limit on a busy server.
PING_ID=""
for _ in $(seq 1 15); do
  LATEST=$(docker compose logs --since 10m luckperms-standalone 2>/dev/null \
    | grep -o 'Sending ping with id: [0-9a-f-]*' | tail -1)
  if [ -n "$LATEST" ] && [ "$LATEST" != "$SENT_BEFORE" ]; then
    PING_ID=${LATEST##* }
    break
  fi
  sleep 2
done
assert_contains "$PING_ID" "-" "the standalone dispatched a new ping for that write"

# The [ -n "$PING_ID" ] guard is load-bearing, not defensive noise: with an
# empty PING_ID the grep pattern degrades to "Received update ping with id: ",
# which matches EVERY ping ever logged and passes unconditionally. Confirmed by
# running that exact unguarded grep.
RECEIVED=NO
if [ -n "$PING_ID" ]; then
  for _ in $(seq 1 30); do
    if docker compose logs --since 10m survival 2>/dev/null \
       | grep -q "Received update ping with id: $PING_ID"; then
      RECEIVED=YES; break
    fi
    sleep 2
  done
fi
assert_eq "$RECEIVED" "YES" "survival received that exact ping without a restart"

# And the write itself must have landed in the shared database. COUNT with an
# exact match rather than assert_contains on a name list: a substring test
# passes on a leftover msgtest12345 when GROUP is msgtest1234. Same reasoning
# as the trailing colon in lib.sh's service_block, which keeps luckperms-db
# from matching the luckperms-db-data volume.
GROUP_COUNT=$(docker compose exec -T luckperms-db \
  mariadb -u"$DB_USER" -p"$DB_PASS" -N -B \
  -e "SELECT COUNT(*) FROM luckperms_groups WHERE name = '$GROUP';" "$DB_NAME" 2>/dev/null | tr -d '\r')
assert_eq "$GROUP_COUNT" "1" "the new group is present in the shared database"

# Cleanup also runs from the EXIT trap; this is belt and braces.
lp_cleanup

finish

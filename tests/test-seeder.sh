#!/usr/bin/env bash
# Probes whether the LuckPerms REST API accepts a context value containing a
# hyphen. Requires the stack to be running.
#
# This gates permissions.yml. The OpenAPI schema declares context keys and
# values as ^[a-z0-9]+$, which would reject project-0; the implementation
# follows LuckPerms instead and allows it. So nodes MAY be scoped with
# `server: project-0` and `server: project-1`. If that ever stops being true,
# permissions.yml must drop those contexts, use the `global` context, and scope
# those servers by permission key instead.
#
# Which failure means what:
#   "returned 200/201" failing        -> the API began enforcing the schema.
#   "persisted" or "reads back"       -> worse. The write is being accepted and
#     failing while the status ones       silently discarded, so a permission
#     pass                                model built on these contexts would
#                                         look correct and apply EVERYWHERE.
#
# The header matters because this file is named for what Task 14 adds to it,
# not for what it currently contains.
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib.sh
. tests/lib.sh

[ -r .env ] || bail ".env is not readable from $(pwd)"

# tr -d '\r': .env is mixed-ending and LUCKPERMS_SECRET is one of the CRLF
# lines. See the longer note in tests/test-luckperms.sh.
SECRET=$(grep -E '^LUCKPERMS_SECRET=' .env | cut -d= -f2- | tr -d '\r')
DB_USER=$(grep -E '^LUCKPERMS_DB_USER=' .env | cut -d= -f2- | tr -d '\r')
DB_PASS=$(grep -E '^LUCKPERMS_DB_PASSWORD=' .env | cut -d= -f2- | tr -d '\r')
DB_NAME=$(grep -E '^LUCKPERMS_DB=' .env | cut -d= -f2- | tr -d '\r')

[ -n "$SECRET" ] || bail "LUCKPERMS_SECRET is empty or missing from .env"
[ -n "$DB_NAME" ] || bail "LUCKPERMS_DB is empty or missing from .env"
[ -n "$DB_USER" ] || bail "LUCKPERMS_DB_USER is empty or missing from .env"
[ -n "$DB_PASS" ] || bail "LUCKPERMS_DB_PASSWORD is empty or missing from .env"

BASE="http://caddy:80"

# Bearer token off the argv, where docker inspect and host ps would expose it.
# Note the DB password below is a deliberate exception, not an oversight: it
# goes on the `docker compose exec` argv, visible in that container's process
# list for the call's duration. Inherited from tests/test-luckperms.sh and
# accepted, since reading it there already requires access to the database
# container. Do not read the rule above as one this file enforces throughout.
CURLRC=$(printf 'header = "Authorization: Bearer %s"\n' "$SECRET")
api() {
  printf '%s' "$CURLRC" | docker run --rm -i --network irc-frontend-network \
    curlimages/curl:8.22.0 -s -K - "$@"
}

# GROUP is named above the trap so the handler is never installed with nothing
# to delete -- load-bearing, since sourcing lib.sh sets -u. lib.sh also installs
# its OWN EXIT trap for its temp result logs, so this CHAINS onto it: a plain
# `trap seeder_cleanup EXIT` silently discards lib.sh's cleanup and leaks two
# temp files per run, verified empirically in tests/test-webdav.sh.
#
# The pre-run delete reclaims a leaked group only on a PID collision, so a run
# killed by SIGKILL leaks one inert ctxprobe<pid> group into the shared
# database. That is accepted rather than swept: deleting everything matching
# ^ctxprobe[0-9]+$ would remove a concurrently running copy's group out from
# under it. Full reasoning in tests/test-luckperms.sh.
GROUP="ctxprobe$$"

# Part A's scratch artifacts are named here for exactly the reason given above:
# seeder_cleanup runs once before the suite starts, when none of them exist.
# PROBE_MODEL starts empty because mktemp has not run yet at that point.
#
# This widens what a SIGKILL leaks, which the comment above predates. A killed
# run now strands four API objects rather than one -- ctxprobe, seedprobe-base,
# seedprobe-child and seedprobe-track -- plus a mktemp file and, the expensive
# one, a tagged local image luckperms-init-test-<pid> carrying a whole
# python:3.12-alpine and PyYAML layer stack. The reasoning above still applies:
# a blind sweep of the seedprobe* names would delete a concurrently running
# copy's scratch state, so the pre-run pass reclaims only this PID's.
P_BASE="seedprobe-base$$"
P_CHILD="seedprobe-child$$"
P_TRACK="seedprobe-track$$"
SEED_IMAGE="luckperms-init-test-$$"
PROBE_MODEL=""

seeder_cleanup() {
  api -o /dev/null -X DELETE "$BASE/luckperms/group/$GROUP" >/dev/null 2>&1 || true
  api -o /dev/null -X DELETE "$BASE/luckperms/group/$P_BASE" >/dev/null 2>&1 || true
  api -o /dev/null -X DELETE "$BASE/luckperms/group/$P_CHILD" >/dev/null 2>&1 || true
  api -o /dev/null -X DELETE "$BASE/luckperms/track/$P_TRACK" >/dev/null 2>&1 || true
  docker image rm "$SEED_IMAGE" >/dev/null 2>&1 || true
  [ -n "$PROBE_MODEL" ] && rm -f "$PROBE_MODEL"
  return 0
}
_prior_exit_trap=$(trap -p EXIT)
_prior_exit_trap=${_prior_exit_trap#trap -- \'}
_prior_exit_trap=${_prior_exit_trap%\' EXIT}
trap "seeder_cleanup; ${_prior_exit_trap}" EXIT
seeder_cleanup

echo "context constraint probe"

CODE=$(api -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -X POST -d "{\"name\":\"$GROUP\"}" "$BASE/luckperms/group")
assert_eq "$CODE" "201" "the API created the probe group (201)"

# Does the API accept a context value containing a hyphen? The OpenAPI schema
# says ^[a-z0-9]+$, which would reject project-0. LuckPerms itself allows it,
# and the implementation follows LuckPerms rather than the schema.
#
# This assertion pins the STATUS CODE, which is not the same claim as the gate.
# 200 is what this version returns; a future 204 would also be a success, and
# this line would then fail while the context was still perfectly acceptable.
# If it ever fails with 204, the gate has NOT moved -- widen this to
# `assert_in "$CODE" "200 204"` rather than rewriting permissions.yml. The gate
# is answered by the two assertions below, which check the stored value.
#
# test.node, NOT mchprs.*: MCHPRS reads this same database directly, and per
# AGENTS.md MCHPRS constraint 1 a stored node that is a strict prefix of a
# queried node panics it with an index-out-of-bounds. Task 14 adds seeder
# assertions to this file that do use mchprs.* keys -- keep that constraint in
# mind there. (This node is doubly safe: constraint 2 says MCHPRS sees only the
# global and mchprs server contexts, so a project-0 context is invisible to it.)
CODE=$(api -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -X PUT -d '[{"key":"test.node","value":true,"context":[{"key":"server","value":"project-0"}]}]' \
  "$BASE/luckperms/group/$GROUP/nodes")
assert_eq "$CODE" "200" "the node write with a hyphenated context returned 200"

# Acceptance is not enough. An API that took the write and silently dropped or
# normalized the context would satisfy the status check above while leaving a
# permission model that does not scope to those servers at all -- a failure
# that would surface much later as "permissions apply everywhere". Confirm the
# value actually persisted, straight from the storage LuckPerms reads.
SERVERS=$(docker compose exec -T luckperms-db \
  mariadb -u"$DB_USER" -p"$DB_PASS" -N -B \
  -e "SELECT server FROM luckperms_group_permissions WHERE name = '$GROUP';" "$DB_NAME" 2>/dev/null | tr -d '\r')
assert_eq "$SERVERS" "project-0" "the hyphenated context persisted to storage intact"

# And it must survive the round trip back out through the API.
#
# The needle pins the KEY/VALUE PAIR, not the value alone. LuckPerms stores
# server and world contexts in dedicated columns plus a generic contexts
# column, and the GET merges all of them into one context array. A version that
# stopped treating `server` as first-class -- storing the node with
# server='global' and project-0 in the generic blob -- would make the SQL
# assertion above correctly fail with got 'global' while a bare
# '"value":"project-0"' needle still passed. That is precisely the
# accepted-but-silently-normalized case this section exists to catch, so the
# round trip must not be the half that gives the wrong answer.
READBACK=$(api "$BASE/luckperms/group/$GROUP")
assert_contains "$READBACK" '"key":"server","value":"project-0"' \
  "the server context reads back through the API"

echo "seeder"

# ===========================================================================
# Part A: idempotency across three starting states
# ===========================================================================
# Part A runs the seeder against a SCRATCH model with its own group names
# rather than against src/luckperms-init/permissions.yml. Two reasons:
#
#   - One state we have to manufacture is "these groups do not exist".
#     Manufacturing that for the real model means deleting `default` from a
#     live server: a destructive act on shared state, for no test benefit.
#   - A scratch model tears down completely, so this section leaves no trace
#     and can be re-run in any order against a stack that is already seeded.
#
# Why THREE states and not the obvious two: the middle one is where the most
# common seeder bug hides. A seeder whose "already applied?" check asks
# whether the GROUP exists short-circuits on a half-seeded database, reports
# changed=0, and writes no nodes at all -- looking perfectly idempotent while
# having done nothing. Only a state that separates "group exists" from "nodes
# applied" can tell the two apart. That is not hypothetical on this host: the
# live database sat in precisely that state -- four groups, zero rows in
# luckperms_group_permissions -- before the seeder first ran.
#
# States are built through the API, never with SQL. Measured: the standalone
# serves the API from an in-memory cache and does not see direct database
# writes, so a SQL-built state would be invisible to the thing under test.

docker build -q -t "$SEED_IMAGE" ./src/luckperms-init >/dev/null 2>&1 \
  || bail "could not build src/luckperms-init"

PROBE_MODEL=$(mktemp)
printf '%s\n' \
  "groups:" \
  "  $P_BASE:" \
  "    weight: 5" \
  "    permissions:" \
  '      - "seedprobe.base"' \
  "  $P_CHILD:" \
  "    weight: 50" \
  '    prefix: "&e[Probe] "' \
  "    inherits:" \
  "      - $P_BASE" \
  "    permissions:" \
  '      - key: "seedprobe.child"' \
  "        value: true" \
  '      - key: "seedprobe.denied"' \
  "        value: false" \
  "tracks:" \
  "  $P_TRACK:" \
  "    groups:" \
  "      - $P_BASE" \
  "      - $P_CHILD" \
  >"$PROBE_MODEL"

# The model arrives on stdin rather than as a bind mount because it lives in a
# mktemp file that nothing outside this process knows about: there is no stable
# path to mount, and a temp path is exactly what a -v would mangle.
#
# MSYS_NO_PATHCONV is defensive here rather than load-bearing. Measured on this
# host: without it, Git Bash rewrites -e PERMISSIONS_FILE=/dev/stdin into
# /proc/self/fd/0, which is a valid path to the very same descriptor, so the
# seeder works either way. Keep it anyway -- the rewrite is real, and the two
# spellings staying interchangeable is not something to depend on.
seed_probe() {
  MSYS_NO_PATHCONV=1 docker run --rm -i --network irc-frontend-network \
    -e LUCKPERMS_SECRET="$SECRET" \
    -e LUCKPERMS_API_URL=http://luckperms-standalone:8080 \
    -e PERMISSIONS_FILE=/dev/stdin \
    "$SEED_IMAGE" <"$PROBE_MODEL" 2>&1
}

# --- State 1: empty. Neither scratch group exists. ---
RUN_EMPTY=$(seed_probe)
assert_contains "$RUN_EMPTY" "created group $P_BASE" \
  "state 1 (empty): creates the missing group"
assert_contains "$RUN_EMPTY" "changed=6" \
  "state 1 (empty): 6 changes (2 groups + 2 node sets + track created + track set)"

NODES_EMPTY=$(api "$BASE/luckperms/group/$P_CHILD/nodes")
assert_contains "$NODES_EMPTY" "group.$P_BASE" \
  "state 1 (empty): inheritance is stored as a group.<name> node"

# --- State 3: fully seeded. Taken here because state 1 just produced it. ---
RUN_SEEDED=$(seed_probe)
assert_contains "$RUN_SEEDED" "changed=0" "state 3 (fully seeded): reports no changes"
assert_not_contains "$RUN_SEEDED" "created group" "state 3 (fully seeded): creates nothing"
# Both halves. seed.py prints "pushed update to connected servers" on success
# and "warning: messaging update returned HTTP ..." on failure, so checking
# only the success string would let an attempted-and-failed push pass as "no
# push happened".
assert_not_contains "$RUN_SEEDED" "pushed update" \
  "state 3 (fully seeded): logs no successful messaging push"
assert_not_contains "$RUN_SEEDED" "messaging update returned" \
  "state 3 (fully seeded): does not even attempt a messaging push"

# --- State 2: half-seeded. Groups present, nodes gone. ---
for g in "$P_BASE" "$P_CHILD"; do
  CODE=$(api -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -X PUT -d '[]' "$BASE/luckperms/group/$g/nodes")
  assert_eq "$CODE" "200" "state 2 setup: emptied $g's node set"
done

RUN_HALF=$(seed_probe)
assert_not_contains "$RUN_HALF" "created group" \
  "state 2 (half-seeded): the groups already exist, so nothing is created"
assert_contains "$RUN_HALF" "changed=2" \
  "state 2 (half-seeded): rewrites both node sets"
assert_contains "$RUN_HALF" "track $P_TRACK: already correct" \
  "state 2 (half-seeded): leaves the intact track alone"

# The point of the entire section. A seeder that short-circuits on group
# existence reports changed=0 above and leaves this empty.
NODES_HALF=$(api "$BASE/luckperms/group/$P_CHILD/nodes")
assert_eq "$NODES_HALF" "$NODES_EMPTY" \
  "state 2 converges to the same node set as state 1"

# ===========================================================================
# Part B: the real model, through compose, against the live stack
# ===========================================================================
# Part A proved the seeder's LOGIC. Part B proves the WIRING: that the compose
# service builds, reaches the API, and applies permissions.yml.
#
# --no-deps is deliberate. luckperms-init depends_on luckperms-standalone,
# which is already running and healthy. Measured on compose v5.5.1, a
# --force-recreate of one service reports its dependencies as "Running" rather
# than recreating them, so this is belt and braces rather than a fix for an
# observed bug -- but it makes the guarantee explicit instead of leaving it to
# a compose version's behaviour.
#
# This section asserts the END STATE rather than a change count, so it passes
# whether or not the stack was already seeded, and the suite stays re-runnable.
# Bind the log to the container THIS command creates. `docker compose logs`
# reads whichever container currently carries the service, and for a
# restart: "no" one-shot that container sits in `exited 0` with its full log
# intact. So if the `up` failed or quietly no-opped, these assertions would
# read the PREVIOUS run's log and pass -- and on an already-seeded stack that
# log says changed=0, which is exactly what the last assertion in this section
# looks for. A silent pass, in the one section that proves the compose wiring.
#
# Measured: --force-recreate always yields a new container id, so comparing
# ids either side of the call is a reliable "did it really run". Reading
# `docker logs <id>` also closes the related hazard of logs accumulating
# across runs if anyone later drops --force-recreate.
DEPLOY_WAS=$(docker compose ps -aq luckperms-init)
docker compose up --build --no-deps --force-recreate luckperms-init >/dev/null 2>&1
DEPLOY_ID=$(docker compose ps -aq luckperms-init)
if [ -n "$DEPLOY_ID" ] && [ "$DEPLOY_ID" != "$DEPLOY_WAS" ]; then
  pass "the compose service was recreated and ran"
else
  fail "the compose service was recreated and ran" \
    "container id was '$DEPLOY_WAS', now '$DEPLOY_ID'"
fi
DEPLOY=$(docker logs "$DEPLOY_ID" 2>&1)
assert_contains "$DEPLOY" "changed=" "the compose service ran to completion"
assert_not_contains "$DEPLOY" "INCOMPLETE" "the compose service did not fail partway"

# GROUP_LIST, not GROUPS. Bash keeps GROUPS as a special array holding the
# current user's group IDs and silently IGNORES assignments to it, so
# `GROUPS=$(api ...)` leaves $GROUPS expanding to a numeric gid -- measured
# here as 197609. The assertions then fail against a haystack that is wrong
# but NOT empty, which is the one shape assert_contains' empty-haystack guard
# cannot catch. Do not rename this back.
GROUP_LIST=$(api "$BASE/luckperms/group")
for g in default onboarder member admin; do
  assert_contains "$GROUP_LIST" "\"$g\"" "group $g exists"
done

# A track is ORDERED; a set-equal check would pass on a scrambled ladder.
TRACK=$(api "$BASE/luckperms/track/onboarding")
assert_contains "$TRACK" '"groups":["onboarder","member","admin"]' \
  "the onboarding track is in model order"

# Needle the key, type and value TOGETHER rather than the key alone. A node
# stored with "value":false -- a negated inheritance, a negated wildcard --
# satisfies a bare key match while meaning the opposite of the description.
# This file already holds itself to that standard further up, where the
# context probe pins "key":"server","value":"project-0" as a pair for exactly
# this reason.
MEMBER_NODES=$(api "$BASE/luckperms/group/member/nodes")
assert_contains "$MEMBER_NODES" '"key":"group.onboarder","type":"inheritance","value":true' \
  "member inherits onboarder as a positive group.<name> node"
assert_contains "$MEMBER_NODES" '"key":"weight.100","type":"weight","value":true' \
  "member carries its weight node"
assert_contains "$MEMBER_NODES" '"key":"mchprs.command.*","type":"permission","value":true' \
  "member carries the mchprs wildcard as a positive permission"

# MCHPRS reads the database directly rather than through the API, and Part A
# established that the two can disagree, so confirm the node reached storage
# and not merely the cache. This is the assertion that would catch a write the
# API acknowledged and never persisted.
MEMBER_ROWS=$(docker compose exec -T luckperms-db \
  mariadb -u"$DB_USER" -p"$DB_PASS" -N -B \
  -e "SELECT permission FROM luckperms_group_permissions WHERE name = 'member';" \
  "$DB_NAME" 2>/dev/null | tr -d '\r')
assert_contains "$MEMBER_ROWS" "group.onboarder" \
  "member's inheritance node is in storage, where MCHPRS reads it"

# And the deployment path itself must settle.
SECOND_WAS=$(docker compose ps -aq luckperms-init)
docker compose up --no-deps --force-recreate luckperms-init >/dev/null 2>&1
SECOND_ID=$(docker compose ps -aq luckperms-init)
if [ -n "$SECOND_ID" ] && [ "$SECOND_ID" != "$SECOND_WAS" ]; then
  pass "the second compose run recreated the container"
else
  fail "the second compose run recreated the container" \
    "container id was '$SECOND_WAS', now '$SECOND_ID'"
fi
SECOND=$(docker logs "$SECOND_ID" 2>&1)
assert_contains "$SECOND" "changed=0" "a second compose run is a no-op"

# Cleanup also runs from the EXIT trap; this is belt and braces.
seeder_cleanup

finish

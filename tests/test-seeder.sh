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
    curlimages/curl:latest -s -K - "$@"
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
seeder_cleanup() {
  api -o /dev/null -X DELETE "$BASE/luckperms/group/$GROUP" >/dev/null 2>&1 || true
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

# Cleanup also runs from the EXIT trap; this is belt and braces.
seeder_cleanup

finish

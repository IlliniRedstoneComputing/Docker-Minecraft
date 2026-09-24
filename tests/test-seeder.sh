#!/usr/bin/env bash
# luckperms-init correctness. Requires the stack to be running.
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

BASE="http://caddy:80"

# Bearer token off the argv, where docker inspect and host ps would expose it.
CURLRC=$(printf 'header = "Authorization: Bearer %s"\n' "$SECRET")
api() {
  printf '%s' "$CURLRC" | docker run --rm -i --network irc-frontend-network \
    curlimages/curl:latest -s -K - "$@"
}

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
assert_eq "$CODE" "201" "the API created the probe group"

# Does the API accept a context value containing a hyphen? The OpenAPI schema
# says ^[a-z0-9]+$, which would reject project-0. LuckPerms itself allows it,
# and the implementation follows LuckPerms rather than the schema.
CODE=$(api -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -X PUT -d '[{"key":"test.node","value":true,"context":[{"key":"server","value":"project-0"}]}]' \
  "$BASE/luckperms/group/$GROUP/nodes")
assert_eq "$CODE" "200" "hyphenated context values are accepted (project-0 usable)"

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
READBACK=$(api "$BASE/luckperms/group/$GROUP")
assert_contains "$READBACK" '"value":"project-0"' "the context reads back through the API"

seeder_cleanup

finish

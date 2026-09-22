#!/usr/bin/env bash
# Static checks against the rendered compose configuration.
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib.sh
. tests/lib.sh

echo "compose configuration"

# Fail loudly and once if the file under test is not here, rather than as a
# scatter of confusing assertion failures.
[ -r compose.yml ] || bail "compose.yml is not readable from $(pwd)"

# Keep stderr out of the searched text. `docker compose config` writes
# warnings about unset variables and obsolete attributes to stderr, and
# merging them into CONFIG would let them satisfy the assertions below.
#
# `-f compose.yml` is REQUIRED, not decorative. Without it `docker compose`
# walks UP the directory tree looking for a compose file. This plan executes
# in a worktree nested inside the main checkout, so the walk finds the main
# checkout's compose.yml and renders THAT -- every $CONFIG assertion then
# passes or fails against the wrong repository. Verified: with compose.yml
# renamed, the render resolved build contexts to the parent checkout's src/.
STDERR=$(mktemp)
if ! CONFIG=$(docker compose -f compose.yml config 2>"$STDERR"); then
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

# Exactly one published port in the whole stack. This is the invariant the
# entire tunnel architecture rests on, so it is guarded two ways.
#
# Counting `published:` alone is NOT sufficient: the short form
# `ports: - "6065"` publishes an ephemeral host port but renders only
# `mode/target/protocol`, with no `published:` key at all. Verified. So the
# number of services declaring a `ports:` block is counted as well.
PUBLISHED=$(printf '%s\n' "$CONFIG" | grep -cE '^[[:space:]]+published:' || true)
assert_eq "$PUBLISHED" "1" "exactly one published port"
PORTBLOCKS=$(printf '%s\n' "$CONFIG" | grep -cE '^[[:space:]]+ports:' || true)
assert_eq "$PORTBLOCKS" "1" "exactly one service declares ports at all"
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

# The healthcheck override must be PRESENT and must match the real response
# schema. The base image's inherited check greps '"up":true' while the endpoint
# reports {"healthy":true,...}, so inheriting it leaves the container forever
# unhealthy and luckperms-init never starts.
LPSA=$(service_block luckperms-standalone "$CONFIG")
assert_contains "$LPSA" "healthy" "luckperms healthcheck matches the real schema"
assert_not_contains "$LPSA" '"up":true' "luckperms healthcheck does not use the broken needle"

# Dead services and volumes must be gone. BOTH are checked against the raw
# file, not the rendered config, and asserting either against $CONFIG would
# be TAUTOLOGICAL:
#   - the sftpgo block is commented out, and the renderer strips comments
#   - `docker compose config` PRUNES any top-level volume no service mounts,
#     so an unmounted wireguard-module-data never appears in the render
#     whether or not it is declared
#
# The haystack is lowercased because the residue is not all lowercase:
# SFTPGO_AUTH_HOOK and friends are exactly the text someone would paste back
# into an environment: block, and a case-sensitive match sails past them.
# Both needles are kept broad for the same reason -- "wireguard" rather than
# the one exact volume name, so a wireguard service or a differently-named
# volume is caught too.
RAW_LOWER=$(printf '%s' "$RAW" | tr 'A-Z' 'a-z')
assert_not_contains "$RAW_LOWER" "sftpgo" "no sftpgo remnants in compose.yml"
assert_not_contains "$RAW_LOWER" "wireguard" "no wireguard remnants in compose.yml"

WEBDAV=$(service_block webdav "$CONFIG")
assert_contains "$WEBDAV" "hacdias/webdav" "webdav uses the hacdias image"
assert_contains "$WEBDAV" "frontend-network" "webdav is on frontend-network"
assert_contains "$WEBDAV" "target: /data" "managed-files is mounted at /data"
assert_not_contains "$WEBDAV" "/path/to/your/files" "no placeholder mount"

# Assert on the `ports:` KEY, not on `published:`. The short form
# `ports: - "6065"` publishes an ephemeral host port while rendering no
# `published:` key, so a `published` needle would pass on a service that is
# in fact reachable from the host.
assert_not_contains "$WEBDAV" "ports:" "webdav declares no ports at all"

# Network isolation is the containment boundary for an internet-reachable
# service holding full write access to every world. Presence of
# frontend-network above does not preclude ALSO being on minecraft-network.
assert_not_contains "$WEBDAV" "minecraft-network" "webdav is not on the minecraft network"

# The config mount must stay read-only, and the process must not run as root:
# files it creates as root cannot be rewritten in place by the Minecraft
# servers, which run as uid 1000.
assert_contains "$WEBDAV" "read_only: true" "the config mount is read-only"
assert_contains "$WEBDAV" "user: 1000:1000" "webdav does not run as root"

finish

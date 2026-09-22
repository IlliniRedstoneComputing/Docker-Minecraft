# Compose Orchestration Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the `compose.yml` deployment — a working WebDAV interface over the shared data volume, a Cloudflare tunnel replacing published admin ports, and a LuckPerms installation that is correct on every server and defined in code.

**Architecture:** One Cloudflare tunnel terminates at an internal Caddy router which path-routes `/files` to a single-account WebDAV server and `/luckperms` to the LuckPerms REST API; `25565` on Velocity stays the only published port. All LuckPerms connection settings move out of config files and into `LUCKPERMS_*` environment variables, which LuckPerms resolves ahead of its config file on every platform. A one-shot `luckperms-init` container applies a declarative `permissions.yml` through the REST API on every `up`.

**Tech Stack:** Docker Compose, Caddy 2, `ghcr.io/hacdias/webdav`, `cloudflare/cloudflared`, `ghcr.io/luckperms/rest-api`, MariaDB 11.4, Python 3 (seeder), Bash (entrypoints and tests).

**Design spec:** [`../specs/2026-09-22-compose-orchestration-completion-design.md`](../specs/2026-09-22-compose-orchestration-completion-design.md)

> **Before touching anything, read [`AGENTS.md`](../../../AGENTS.md).** Five behaviors in this repository look like bugs and are correct. Do not "fix" the `:3001/healthz` healthcheck, do not add a healthcheck to `velocity`, do not add `:3306` to the mchprs address, do not stop `lobby`/`onboarding` overwriting `world/`, and do not extend backup coverage.

---

## File Structure

**Created**

| Path | Responsibility |
| --- | --- |
| `tests/lib.sh` | Shared assertion helpers for every test script |
| `tests/test-compose-config.sh` | Static validation of `compose.yml` |
| `tests/test-webdav.sh` | WebDAV behavior through Caddy |
| `tests/test-luckperms.sh` | LuckPerms storage, messaging, and API reachability |
| `tests/test-seeder.sh` | `luckperms-init` correctness and idempotency |
| `tests/run-all.sh` | Runs every suite in order |
| `src/webdav/config.yml` | WebDAV server configuration |
| `src/luckperms-init/Dockerfile` | Seeder image |
| `src/luckperms-init/seed.py` | Applies `permissions.yml` through the REST API |
| `src/luckperms-init/permissions.yml` | The declarative permission model |
| `scripts/normalize-luckperms-conf.sh` | One-shot editor for the five `luckperms.conf` files |

**Modified**

| Path | Change |
| --- | --- |
| `compose.yml` | Blocking fixes, `webdav` rewrite, new `caddy`/`cloudflared`/`luckperms-init`, velocity LuckPerms env |
| `src/caddy/Caddyfile` | Internal path router |
| `.env.example` | Complete and accurate |
| `src/luckperms-standalone/Dockerfile` | Drop the extension jar |
| `src/velocity/entrypoint.sh` | Seeding policy |
| `src/velocity/server/plugins/luckperms/config.yml` | Stock values, no placeholders |
| `src/survival/entrypoint.sh` | Seeding policy |
| `src/{survival,lobby,onboarding,project-0,project-1}/server/config/luckperms/luckperms.conf` | Normalized |
| `src/mchprs/Config.toml` | Fallback credentials aligned; keeps its `${...}` placeholders |
| `src/{lobby,onboarding}/entrypoint.sh` | Robust secret injection, seeding policy, keep world re-sync |
| `src/{project-0,project-1}/entrypoint.sh` | Robust secret injection, seeding policy |

**Deleted**

| Path | Reason |
| --- | --- |
| `src/luckperms-standalone/Initialization-1.0-SNAPSHOT.jar` | Unsourced binary, replaced by the seeder |
| `wg0.conf.example` | Dead — no WireGuard service exists |

**Submodule note:** `src/lobby`, `src/onboarding`, `src/project-0`, and `src/project-1` are separate repositories. Changes there are committed and pushed on a branch in each repository, then the parent repository's submodule pointers are bumped in Task 12.

---

## Task 1: Test harness and compose validation

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/test-compose-config.sh`

- [ ] **Step 1: Write the shared helper library**

Create `tests/lib.sh`:

```bash
#!/usr/bin/env bash
# Shared assertion helpers. Source this from every test script.
#
# Sourcing sets `set -uo pipefail` in the caller. It deliberately does NOT
# set -e: a suite must record a failure and keep going.
#
# Results are recorded in temp files rather than shell variables so that an
# assertion inside a pipeline or a $(...) subshell is still counted. Plain
# counters are lost with the subshell, which lets a suite print FAIL and
# still exit 0 -- a test that passes when it should fail is worse than no
# test at all.
#
# ASSERTION OUTPUT MUST NEVER ECHO A HAYSTACK. The rendered compose config
# contains live secrets (WEBDAV_PASSWORD, the LuckPerms credentials, the
# tunnel token), and these suites run in CI-visible output. Every helper here
# prints only the needle and the description on failure. Note that assert_eq
# prints BOTH of its arguments, so never pass a service block or a rendered
# config to it.
set -uo pipefail

: "${_ASSERT_RUN_LOG:=$(mktemp)}"
: "${_ASSERT_FAIL_LOG:=$(mktemp)}"

# Deliberately NOT exported. Subshells inherit ordinary shell variables, which
# is all the counting needs. Exporting would also hand the paths to CHILD
# PROCESSES, so a child suite that sources this file would delete the parent's
# logs in its own finish -- erasing already-recorded failures and letting the
# parent exit 0. That is the same false-pass class this design exists to close.
trap 'rm -f "$_ASSERT_RUN_LOG" "$_ASSERT_FAIL_LOG"' EXIT

pass() {
  printf 'x\n' >>"$_ASSERT_RUN_LOG"
  printf '  ok   %s\n' "$1"
}

fail() {
  printf 'x\n' >>"$_ASSERT_RUN_LOG"
  printf 'x\n' >>"$_ASSERT_FAIL_LOG"
  printf '  FAIL %s\n' "$1"
  if [ $# -gt 1 ]; then printf '       %s\n' "$2"; fi
  return 0
}

# bail <description> -- unrecoverable setup failure; stop the suite non-zero.
# The EXIT trap cleans up the logs.
bail() {
  printf '  FAIL %s\n' "$1"
  printf '\nsuite aborted\n'
  exit 1
}

# assert_contains <haystack> <needle> <description>
assert_contains() {
  case "$1" in
    *"$2"*)
      pass "$3"
      ;;
    *)
      # Name the likely cause: an empty haystack almost always means a
      # broken extraction, not a genuinely missing needle.
      if [ -z "$1" ]; then
        fail "$3" "expected to find: $2 (haystack was empty; the extraction probably failed)"
      else
        fail "$3" "expected to find: $2"
      fi
      ;;
  esac
}

# assert_not_contains <haystack> <needle> <description>
#
# An empty haystack is a FAILURE, not a pass. Without this guard a broken
# extraction -- a renamed service, a changed indent, a compose render change
# -- silently converts this assertion into a permanent pass.
assert_not_contains() {
  if [ -z "$1" ]; then
    fail "$3" "haystack was empty; the extraction probably failed"
    return 0
  fi
  case "$1" in
    *"$2"*) fail "$3" "did not expect to find: $2" ;;
    *) pass "$3" ;;
  esac
}

# assert_eq <actual> <expected> <description>
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected '$2', got '$1'"; fi
}

# assert_in <value> <space-separated-allowed> <description>
assert_in() {
  case " $2 " in
    *" $1 "*) pass "$3" ;;
    *) fail "$3" "got '$1', expected one of: $2" ;;
  esac
}

# service_block <name> <yaml> -- print one top-level service's block.
#
# Works on both the rendered config and the raw compose.yml. The block ends
# at the next sibling key (two-space indent) or the next top-level key (zero
# indent), whatever its first character. Two traps this avoids:
#   - matching /^  [a-z]/ would let the LAST service swallow the networks
#     and volumes sections as soon as any name began with a capital or digit
#   - without the zero-indent rule the last service trails a bare
#     "networks:" line, since that key is not indented at all
# `index($0, svc) == 1` is a literal column-1 match, so service names
# containing '-' need no escaping, and the trailing colon keeps
# "luckperms-db" from matching the "luckperms-db-data" volume.
service_block() {
  printf '%s\n' "$2" | awk -v svc="  $1:" '
    index($0, svc) == 1 { f = 1; next }
    f && /^[^ ]/ { exit }
    f && /^  [^ ]/ { exit }
    f { print }
  '
}

finish() {
  local run=0 failed=0
  [ -s "$_ASSERT_RUN_LOG" ] && run=$(wc -l <"$_ASSERT_RUN_LOG" | tr -d ' ')
  [ -s "$_ASSERT_FAIL_LOG" ] && failed=$(wc -l <"$_ASSERT_FAIL_LOG" | tr -d ' ')
  printf '\n%d run, %d failed\n' "$run" "$failed"
  [ "$failed" -eq 0 ] || exit 1
  exit 0
}
```

- [ ] **Step 2: Write the failing compose-validation test**

Create `tests/test-compose-config.sh`:

```bash
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
# The needle is the full '"healthy":true' string, not a bare "healthy". The
# service block also contains `condition: service_healthy` from its depends_on
# clause, so a bare needle matches that instead and passes no matter what the
# healthcheck command actually greps for.
assert_contains "$LPSA" '"healthy":true' "luckperms healthcheck matches the real schema"
assert_not_contains "$LPSA" '"up":true' "luckperms healthcheck does not use the broken needle"

finish
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bash tests/test-compose-config.sh
```

Expected: fails immediately — `docker compose config` errors with `env file .../backup.config not found`.

- [ ] **Step 4: Make `backup.config` optional**

In `compose.yml`, in the `backup` service, replace:

```yaml
    env_file:
      - backup.config
```

with:

```yaml
    env_file:
      - path: backup.config
        required: false
```

- [ ] **Step 5: Align the database credential defaults**

In `compose.yml`, in the `luckperms-db` service, the default is `luckperms_user` while every client uses `user_luckperms`. Standardize on `luckperms_user`. Replace every occurrence of:

```
${LUCKPERMS_DB_USER:-user_luckperms}
```

with:

```
${LUCKPERMS_DB_USER:-luckperms_user}
```

There are five occurrences: `luckperms-standalone`, `lobby`, `survival`, `onboarding`, `mchprs`, `project-0`, `project-1`. Verify none remain:

```bash
grep -c 'user_luckperms' compose.yml
```

Expected: `0`.

- [ ] **Step 6: Add velocity's restart policy**

In `compose.yml`, in the `velocity` service, immediately after the `container_name: velocity` line, add:

```yaml
    restart: unless-stopped
```

- [ ] **Step 7: Fix the LuckPerms healthcheck — do NOT delete it**

> **This step was reversed during execution.** It originally said to delete the override
> and inherit the base image's check. That was wrong, it was acted on, and it introduced
> a regression that would have blocked Task 16. Recorded rather than silently rewritten,
> because the reasoning matters.

The base image declares
`wget http://localhost:3001/health -q -O - | grep -c '"up":true'`, but this version's
endpoint actually returns:

```json
{"healthy":true,"details":{"storageConnected":true,"storagePing":1}}
```

The field is `healthy`, not `up`, so **the inherited check can never pass** and the
container sits permanently `unhealthy`. Verified by running all three candidate commands
inside the running container. This blocks `luckperms-init` (Task 16), which declares
`depends_on: luckperms-standalone: {condition: service_healthy}`.

Replace the existing `healthcheck:` block in the `luckperms-standalone` service with:

```yaml
    healthcheck:
      # The base image's inherited check greps for '"up":true', but this version
      # reports {"healthy":true,...}. The inherited check can NEVER pass, so this
      # must be overridden rather than removed. Matching the body rather than just
      # the status code also proves storage connectivity, not merely liveness.
      test:
        [
          "CMD-SHELL",
          "wget -q -O - http://localhost:3001/health | grep -q '\"healthy\":true'",
        ]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
```

Port 3001 is the standalone heartbeat server, separate from the REST API's 8080. That
part of the original configuration was always correct — see `AGENTS.md`.

- [ ] **Step 8: Remove the placeholder webdav mount and port**

In `compose.yml`, in the `webdav` service, delete both of these:

```yaml
    ports:
      - "8080:80"
```

```yaml
      - /path/to/your/files:/media/data
```

The port must go now, not in Task 3, or the "exactly one published port"
assertion fails. The service is fully rewritten in Task 3.

- [ ] **Step 9: Run the test to verify it passes**

```bash
bash tests/test-compose-config.sh
```

Expected: `0 failed`.

- [ ] **Step 10: Commit**

```bash
git add tests/lib.sh tests/test-compose-config.sh compose.yml
git commit -m "test: add compose validation harness and fix blocking compose errors"
```

---

## Task 2: Remove dead configuration

**Files:**
- Modify: `compose.yml`
- Delete: `wg0.conf.example`
- Modify: `.gitignore`
- Modify: `tests/test-compose-config.sh`

- [ ] **Step 1: Add failing assertions for the cleanup**

In `tests/test-compose-config.sh`, insert immediately before the `finish` line:

```bash
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
```

> **General rule for this plan's test suites.** Absence assertions against the
> *rendered* config fail in two distinct ways, and both have bitten already:
>
> 1. **The thing is erased by rendering.** Comments, unused volumes, and
>    `${VAR:-default}` fallbacks never appear in `$CONFIG` whether or not they
>    are declared, so asserting their absence there is tautological. Assert
>    against `$RAW` instead.
> 2. **The thing has more than one rendered form.** `ports: - "6065"` publishes
>    a host port but renders no `published:` key, so a `published` needle
>    passes on a service that is genuinely exposed. Assert on the parent key
>    (`ports:`) rather than on one of its children.
>
> Before writing any absence assertion, confirm by experiment that the thing
> you are forbidding would actually appear, in every form it can take, when
> present.

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test-compose-config.sh
```

Expected: FAIL on `no sftpgo remnants in compose.yml` and `no wireguard volume`.

- [ ] **Step 3: Delete the dead configuration**

In `compose.yml`:

1. Delete the entire commented-out `# sftpgo:` service block (every line from `  # # SFTPGO/HTTP server for file transfers` through `  #       condition: service_completed_successfully`).
2. In the `volumes:` section, delete these two entries:

```yaml
  sftpgo-data:
    driver: local
  wireguard-module-data:
    driver: local
```

Then delete the dead example file:

```bash
git rm wg0.conf.example
```

And remove its now-orphaned ignore rule. In `.gitignore`, delete:

```
# Wireguard configuration
wg0.conf
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash tests/test-compose-config.sh
```

Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add compose.yml tests/test-compose-config.sh
git commit -m "chore: remove dead sftpgo and wireguard configuration"
```

---

## Task 3: WebDAV service

**Files:**
- Create: `src/webdav/config.yml`
- Modify: `compose.yml`
- Modify: `tests/test-compose-config.sh`

- [ ] **Step 1: Add failing assertions for the new service shape**

In `tests/test-compose-config.sh`, insert immediately before the `finish` line:

```bash
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
# Unquoted needle on purpose: compose.yml writes user: "1000:1000", but the
# renderer's YAML dumper drops quotes from unambiguous scalars and emits
# user: 1000:1000. A quoted needle can never match.
assert_contains "$WEBDAV" "user: 1000:1000" "webdav does not run as root"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test-compose-config.sh
```

Expected: FAIL on `webdav uses the hacdias image`.

- [ ] **Step 3: Write the WebDAV configuration**

Create `src/webdav/config.yml`:

```yaml
# WebDAV server configuration.
#
# This service is deliberately a SINGLE service account with full CRUD over the
# entire managed-files volume. User management, per-directory scoping and audit
# are the responsibility of the separate administration service that connects
# here over one WebDAV connection. Do not add multi-user support.
#
# The `prefix` below must match the path Caddy routes here, and Caddy must use
# `handle` rather than `handle_path` so the prefix actually reaches this server.

address: 0.0.0.0
port: 6065

# Serve under /files. The server strips this itself and adds it back to
# PROPFIND responses, which is why the reverse proxy must NOT strip it.
prefix: /files

# Log the real client address forwarded by Caddy.
behindProxy: true

# The whole managed-files volume.
directory: /data

# Full create/read/update/delete for the single service account.
permissions: CRUD

users:
  - username: "{env}WEBDAV_USERNAME"
    password: "{env}WEBDAV_PASSWORD"
```

- [ ] **Step 4: Replace the webdav service**

In `compose.yml`, replace the entire `webdav:` service block with:

```yaml
  # WebDAV interface over the shared server-data volume.
  # Single service account by design -- see src/webdav/config.yml.
  webdav:
    # Pinned, not :latest -- this is the one service reachable from the
    # internet through the tunnel, so an unreviewed image must not land here
    # on the next pull.
    image: ghcr.io/hacdias/webdav:v5.16.0
    container_name: webdav
    restart: unless-stopped
    command: ["-c", "/config.yml"]
    # Both Minecraft base images run as uid 1000. Matching it means files
    # created through WebDAV stay rewritable by the servers, and vice versa.
    # The image is FROM scratch and binds an unprivileged port, so it needs
    # no root. volume_init's chmod 777 covers directory traversal.
    user: "1000:1000"
    environment:
      - WEBDAV_USERNAME=${WEBDAV_USERNAME:?WEBDAV_USERNAME must be set in .env}
      - WEBDAV_PASSWORD=${WEBDAV_PASSWORD:?WEBDAV_PASSWORD must be set in .env}
    volumes:
      - ./src/webdav/config.yml:/config.yml:ro
      - type: volume
        source: managed-files
        target: /data
    networks:
      - frontend-network
    depends_on:
      volume_init:
        condition: service_completed_successfully
```

There is intentionally no `healthcheck`: the image is built `FROM scratch` and contains no shell or HTTP client.

- [ ] **Step 5: Provide the required variables for validation**

`docker compose config` now fails without the WebDAV variables, which is the intended behavior. Create a local `.env` if one does not exist:

```bash
[ -f .env ] || cp .env.example .env
# .env.example does not end with a newline -- its last byte is a space. A bare
# append would land on that last line, producing
# "VELOCITY_SECRET=... WEBDAV_USERNAME=testuser" and silently losing the
# variable. Terminate the file first if it is not already terminated.
[ -s .env ] && [ -n "$(tail -c1 .env)" ] && printf '\n' >> .env
grep -q '^WEBDAV_USERNAME=' .env || printf 'WEBDAV_USERNAME=testuser\n' >> .env
grep -q '^WEBDAV_PASSWORD=' .env || printf 'WEBDAV_PASSWORD=testpassword123\n' >> .env
```

Guarded rather than a bare append, so re-running the step does not accumulate
duplicate entries. `.env` is gitignored and must never be committed.

Verify the result parsed as intended before moving on — this is the failure
mode the newline guard exists for:

```bash
grep -c '^WEBDAV_USERNAME=testuser$' .env
```

Expected: `1`. A `0` means the append merged onto a previous line.

- [ ] **Step 6: Run the test to verify it passes**

```bash
bash tests/test-compose-config.sh
```

Expected: `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add src/webdav/config.yml compose.yml tests/test-compose-config.sh
git commit -m "feat: replace webdav with hacdias/webdav behind a /files prefix"
```

---

## Task 4: Caddy router

**Files:**
- Modify: `src/caddy/Caddyfile`
- Modify: `compose.yml`
- Create: `tests/test-webdav.sh`

- [ ] **Step 1: Write the Caddyfile**

Replace the entire contents of `src/caddy/Caddyfile` with:

```caddyfile
# Internal router. Not exposed directly -- cloudflared is the only client.
# TLS is terminated by Cloudflare, so this listens on plain HTTP.
:80 {
	# WebDAV COPY and MOVE send an absolute URL in Destination. Rewrite it to a
	# path-only form, or any client whose Destination host does not match the
	# request Host gets a 502 from the WebDAV server.
	#
	# `request_header`, NOT `header`. In Caddy, `header` manipulates the
	# RESPONSE; only `request_header` rewrites what reaches the upstream.
	# Verified: with `header`, a foreign-host Destination still returned 502
	# because the rewrite never applied to the proxied request.
	@hasDest header_regexp dest Destination ^https?://[^/]+(.*)$
	request_header @hasDest Destination {re.dest.1}

	# handle, NOT handle_path: the /files prefix must reach the WebDAV server,
	# which strips it itself and adds it back to PROPFIND responses.
	#
	# A named matcher with two path patterns, not the glob /files*, so
	# matching is segment-bounded. /files* also matches /filesystem, which
	# would be proxied to webdav instead of falling through to the catch-all
	# redirect. `handle /files /files/* { ... }` (two bare path args) is not
	# valid Caddyfile syntax -- handle takes exactly one matcher token, and
	# caddy refuses to start with "wrong argument count ... after '/files/*'"
	# -- so the two patterns are given to a `path` matcher instead.
	@filesPath path /files /files/*
	handle @filesPath {
		reverse_proxy webdav:6065 {
			header_up X-Real-IP {remote_host}
			header_up REMOTE-HOST {remote_host}

			# webdav has no container healthcheck -- its image is FROM
			# scratch, with no shell or HTTP client to run one. Caddy is
			# therefore its only liveness signal, so make that signal real.
			# `restart: unless-stopped` catches a process that exits, but
			# not one that is wedged and still listening; passive health
			# checking turns that case into a logged, observable upstream
			# failure instead of silence. Passive rather than active because
			# every webdav endpoint requires auth, so there is no
			# unauthenticated URI to probe.
			fail_duration 30s
			max_fails 3
		}
	}

	# The LuckPerms REST API has no base-path setting and serves /user,
	# /group and /track at the root, so the /luckperms prefix must be
	# stripped before proxying -- same reasoning as the original handle_path.
	#
	# Segment-bounded for the same reason as /files above, via a named `path`
	# matcher with two patterns. handle_path itself cannot be used here:
	# `handle_path /luckperms /luckperms/* { ... }` is not valid Caddyfile
	# syntax for the same reason as the files block, and handle_path also
	# refuses a named matcher argument ("path matcher must begin with '/'"),
	# because it needs a literal path token to derive the prefix to strip.
	# So `handle` matches the named matcher and `uri strip_prefix` does what
	# handle_path did implicitly. Verified equivalent: /luckperms/health ->
	# upstream sees /health; bare /luckperms -> upstream sees "".
	@luckpermsPath path /luckperms /luckperms/*
	handle @luckpermsPath {
		uri strip_prefix /luckperms
		reverse_proxy luckperms-standalone:8080
	}

	handle {
		redir https://illiniredstone.org
	}
}
```

- [ ] **Step 2: Add the caddy service**

In `compose.yml`, add this service immediately after the `webdav` service:

```yaml
  # Internal path router between the tunnel and the admin services.
  caddy:
    # Pinned for the same reason webdav is: this sits directly in the
    # request path from the internet.
    image: caddy:2.11.4-alpine
    container_name: caddy
    restart: unless-stopped
    volumes:
      - ./src/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
    networks:
      - frontend-network
    depends_on:
      # webdav has no healthcheck by design (FROM scratch: no shell, no HTTP
      # client), so it can only be waited on for start. luckperms-standalone
      # does have one, so gate on it -- consistent with how the rest of this
      # file treats health-gated dependencies.
      webdav:
        condition: service_started
      luckperms-standalone:
        condition: service_healthy
```

- [ ] **Step 3: Write the failing WebDAV behavior test**

Create `tests/test-webdav.sh`:

```bash
#!/usr/bin/env bash
# WebDAV behavior through Caddy. Requires the stack to be running.
#
# Caddy publishes no port in normal operation, so this test talks to it through
# a temporary container attached to the frontend network. That keeps the test
# honest -- it exercises the real Caddy -> webdav path, prefix and all.
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib.sh
. tests/lib.sh

USER_NAME=$(grep -E '^WEBDAV_USERNAME=' .env | cut -d= -f2-)
PASS=$(grep -E '^WEBDAV_PASSWORD=' .env | cut -d= -f2-)
BASE="http://caddy:80"

# Keep the password off the docker run argv, where it would be visible in
# `docker inspect` and host `ps` output for the container's lifetime. curl
# reads it from a config file on stdin instead.
CURLRC=$(printf 'user = "%s:%s"\n' "$USER_NAME" "$PASS")

# dav <curl-args...> -- runs curl inside the frontend network against Caddy.
dav() {
  printf '%s' "$CURLRC" | docker run --rm -i --network irc-frontend-network \
    curlimages/curl:latest -s -K - "$@"
}

# The suite writes real files into the shared volume. Clear the known paths
# both before and after, so an interrupted run cannot poison the next one.
# Proven necessary: a leftover webdav-moved.txt makes MOVE return 412 instead
# of overwriting, and a leftover davtest/ makes MKCOL return 405 -- both
# false failures with a confusing cause.
dav_cleanup() {
  for p in \
    "$BASE/files/survival/webdav-test.txt" \
    "$BASE/files/survival/webdav-moved.txt" \
    "$BASE/files/survival/davtest/nested.txt" \
    "$BASE/files/survival/davtest/"; do
    dav -o /dev/null -X DELETE "$p" >/dev/null 2>&1 || true
  done
}
# tests/lib.sh installs its own EXIT trap to remove its temp result logs.
# A plain `trap dav_cleanup EXIT` here would replace that handler outright
# instead of adding to it -- verified empirically: with only the plain form,
# lib.sh's two temp files were left behind after every run. Capture the
# existing handler and chain it after this script's own cleanup instead.
_prior_exit_trap=$(trap -p EXIT)
_prior_exit_trap=${_prior_exit_trap#trap -- \'}
_prior_exit_trap=${_prior_exit_trap%\' EXIT}
trap "dav_cleanup; ${_prior_exit_trap}" EXIT
dav_cleanup

echo "webdav through caddy"

# A request without the /files prefix must be refused by the WebDAV server.
CODE=$(dav -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' "$BASE/files/")
assert_eq "$CODE" "207" "PROPFIND /files/ returns multi-status"

# A path outside both admin routes falls through to the catch-all redirect.
# (The 207 above is what proves the /files prefix actually reaches webdav: if
# Caddy stripped it, webdav would see "/" and answer 400. A path like
# /survival/ never reaches webdav at all, so it cannot test that.)
CODE=$(dav -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' "$BASE/survival/")
assert_in "$CODE" "301 302 307 308" "an unrouted path hits the catch-all redirect"

# Unauthenticated access must be rejected.
CODE=$(docker run --rm --network irc-frontend-network curlimages/curl:latest \
  -s -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' "$BASE/files/")
assert_eq "$CODE" "401" "unauthenticated PROPFIND is rejected"

# Write, read back, move, and delete.
CODE=$(dav -o /dev/null -w '%{http_code}' -X PUT --data 'hello' "$BASE/files/survival/webdav-test.txt")
assert_in "$CODE" "201 204" "PUT creates a file"

BODY=$(dav "$BASE/files/survival/webdav-test.txt")
assert_eq "$BODY" "hello" "GET returns the written content"

CODE=$(dav -o /dev/null -w '%{http_code}' -X MOVE \
  -H 'Destination: /files/survival/webdav-moved.txt' \
  "$BASE/files/survival/webdav-test.txt")
assert_in "$CODE" "201 204" "MOVE with a path-only Destination succeeds"

# The same MOVE with an absolute Destination whose host does NOT match the
# request Host. This is the real regression guard for the @hasDest rule.
#
# A matching host would prove nothing: golang.org/x/net/webdav, which this
# server is built on, already accepts an absolute Destination whenever its
# host equals the request's Host, so "http://caddy/..." succeeds with or
# without the rewrite. Only a foreign host exercises it -- verified: 502
# without the rewrite, 201 with it.
CODE=$(dav -o /dev/null -w '%{http_code}' -X MOVE \
  -H "Destination: http://other-host.example:9999/files/survival/webdav-test.txt" \
  "$BASE/files/survival/webdav-moved.txt")
assert_in "$CODE" "201 204" "MOVE with a foreign-host absolute Destination succeeds"

CODE=$(dav -o /dev/null -w '%{http_code}' -X DELETE "$BASE/files/survival/webdav-test.txt")
assert_in "$CODE" "200 204" "DELETE removes the file"

# Directory creation and nested writes -- what the administration service
# will actually do. Self-contained: no Minecraft server has run at this
# point, so /files/survival/ is empty and nothing deeper exists yet. WebDAV
# PUT does not create parent collections, so the MKCOL is required, not
# decorative. (The harder case -- writing into a directory a Minecraft
# server created as uid 1000 -- needs a server to have run, so it lives in
# the full-stack task.)
CODE=$(dav -o /dev/null -w '%{http_code}' -X MKCOL "$BASE/files/survival/davtest/")
assert_in "$CODE" "201" "MKCOL creates a collection"

CODE=$(dav -o /dev/null -w '%{http_code}' -X PUT --data 'nested' \
  "$BASE/files/survival/davtest/nested.txt")
assert_in "$CODE" "201 204" "PUT into a newly created collection succeeds"

# Route matching must be segment-bounded. A glob prefix like /files* also
# matches /filesystem, proxying it to webdav instead of letting it fall
# through to the catch-all redirect. Verified before the fix: /filesystem/
# reached webdav (404 from webdav, not a redirect).
CODE=$(dav -o /dev/null -w '%{http_code}' "$BASE/filesystem/")
assert_in "$CODE" "301 302 307 308" "/filesystem does not leak into the webdav route"

CODE=$(dav -o /dev/null -w '%{http_code}' "$BASE/luckpermsx/")
assert_in "$CODE" "301 302 307 308" "/luckpermsx does not leak into the luckperms route"

# Cleanup also runs from the EXIT trap; this is belt and braces.
dav_cleanup

finish
```

- [ ] **Step 4: Run the test to verify it fails**

```bash
bash tests/test-webdav.sh
```

Expected: every assertion fails — the stack is not running yet.

- [ ] **Step 5: Start the stack and run the test**

```bash
docker compose up -d volume_init luckperms-db luckperms-standalone webdav caddy
docker compose ps
bash tests/test-webdav.sh
```

Expected: `0 failed`. If `PROPFIND /files/` returns `400`, the `prefix` in `src/webdav/config.yml` does not match the Caddy route. If the absolute-`Destination` MOVE fails, the `@hasDest` rule is wrong.

- [ ] **Step 6: Commit**

```bash
git add src/caddy/Caddyfile compose.yml tests/test-webdav.sh
git commit -m "feat: add caddy path router and webdav behavior tests"
```

---

## Task 5: Cloudflare tunnel and environment template

**Files:**
- Modify: `compose.yml`
- Modify: `.env.example`
- Modify: `tests/test-compose-config.sh`

- [ ] **Step 1: Add a failing assertion**

In `tests/test-compose-config.sh`, insert immediately before the `finish` line:

```bash
CFD=$(service_block cloudflared "$CONFIG")
# Assert the pinned image rather than the bare word "cloudflared", which
# would also match the container name and prove nothing about the image.
assert_contains "$CFD" "cloudflare/cloudflared:2026.9.1" "cloudflared uses a pinned image"
assert_not_contains "$CFD" "ports:" "cloudflared declares no ports"

# The token wiring is asserted against $RAW, not $CONFIG. Rendering
# substitutes the value and erases BOTH the source variable name and the
# `:?` required guard -- the rendered line is just
# `TUNNEL_TOKEN: <value>`. A $CONFIG needle therefore proves only that the
# destination key is spelled TUNNEL_TOKEN. Verified: rewiring the source to
# ${WEBDAV_PASSWORD:-fallback}, dropping the guard entirely, still passed.
#
# This single needle covers all three properties at once: the destination
# key cloudflared requires, the correct source variable, and the `:?` guard
# that makes a missing token fail loudly instead of silently running empty.
CFD_RAW=$(service_block cloudflared "$RAW")
assert_contains "$CFD_RAW" 'TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN:?' \
  "the tunnel token is sourced from CLOUDFLARE_TUNNEL_TOKEN and required"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash tests/test-compose-config.sh
```

Expected: FAIL on `cloudflared service exists`.

- [ ] **Step 3: Add the cloudflared service**

In `compose.yml`, add immediately after the `caddy` service:

```yaml
  # Cloudflare tunnel. Token auth means the tunnel is REMOTELY managed: a local
  # config.yml with ingress rules would be silently ignored. That is fine here
  # because Caddy does all routing, so the dashboard needs exactly one public
  # hostname: mc-admin.illiniredstone.org -> http://caddy:80
  cloudflared:
    # Pinned like caddy and webdav: this terminates the public entrypoint.
    image: cloudflare/cloudflared:2026.9.1
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN:?CLOUDFLARE_TUNNEL_TOKEN must be set in .env}
    networks:
      - frontend-network
    depends_on:
      - caddy
```

**Do not start this service locally.** With the placeholder token in `.env` it cannot
authenticate and will restart-loop. That is expected and harmless, but it is noise in
`docker compose ps` and logs. It is configured here and verified for the first time
against a real tunnel by whoever deploys it.

- [ ] **Step 4: Rewrite the environment template**

Replace the entire contents of `.env.example` with:

```dotenv
# Environment variables for Docker Compose.
# Copy this file to .env and replace every placeholder with a real secret:
#   cp .env.example .env
#
# Docker Compose reads `.env` automatically. Do not name it `.env.local`.

# --- Java -------------------------------------------------------------------
# Heap for each Minecraft server. Six servers at 2G plus Velocity is ~14G, so
# lower this on a smaller host.
JAVA_OPTS=-Xmx2G -Xms1G

# --- LuckPerms database -----------------------------------------------------
LUCKPERMS_DB_ROOT_PASSWORD=change_me_root_password
LUCKPERMS_DB_USER=luckperms_user
LUCKPERMS_DB_PASSWORD=change_me_db_password
LUCKPERMS_DB=luckperms

# --- LuckPerms REST API -----------------------------------------------------
# Bearer token for the REST API. The remote administration service uses this.
LUCKPERMS_SECRET=change_me_api_secret

# --- Velocity ---------------------------------------------------------------
# Shared forwarding secret between the proxy and every backend server.
VELOCITY_SECRET=change_me_velocity_secret

# --- WebDAV -----------------------------------------------------------------
# A single service account with full read/write over all server data. The
# separate administration service holds these and enforces its own user model.
WEBDAV_USERNAME=change_me_webdav_user
WEBDAV_PASSWORD=change_me_webdav_password

# --- Cloudflare tunnel ------------------------------------------------------
# Create the tunnel in the Zero Trust dashboard, then paste its token here.
# Add one public hostname: mc-admin.illiniredstone.org -> http://caddy:80
CLOUDFLARE_TUNNEL_TOKEN=change_me_tunnel_token
```

This drops the dead `SFTPGO_*`, `LUCKPERMS_MESSENGER_PASSWORD`, and
`MINECRAFT_HOSTNAME` variables, and fixes the "copy to `.env.local`" instruction, which
was wrong — Compose reads `.env`.

The file must end with a trailing newline. Its previous version did not, which silently
corrupted an append in an earlier task.

Keep **CRLF** line endings. Every other tracked text file here is CRLF (`compose.yml`,
`.gitignore`), `.gitattributes` sets only `text=auto` with an `eol=lf` override for
`*.sh`, and `core.autocrlf` is `false` — so rewriting this one as LF introduces an
inconsistency nothing asked for.

- [ ] **Step 5: Add the tunnel token to the local `.env`**

```bash
[ -s .env ] && [ -n "$(tail -c1 .env)" ] && printf '\n' >> .env
grep -q '^CLOUDFLARE_TUNNEL_TOKEN=' .env \
  || printf 'CLOUDFLARE_TUNNEL_TOKEN=placeholder-not-used-in-local-tests\n' >> .env
grep -c '^CLOUDFLARE_TUNNEL_TOKEN=' .env
```

Expected: `1`. Guarded so a re-run does not duplicate the entry, and newline-terminated
first so the append cannot merge onto a previous line.

- [ ] **Step 6: Run the test to verify it passes**

```bash
bash tests/test-compose-config.sh
```

Expected: `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add compose.yml .env.example tests/test-compose-config.sh
git commit -m "feat: add cloudflared tunnel and rewrite the env template"
```

---

## Task 6: Normalize the LuckPerms config files

**Files:**
- Create: `scripts/normalize-luckperms-conf.sh`
- Modify: `src/survival/server/config/luckperms/luckperms.conf`
- Modify: `src/lobby/server/config/luckperms/luckperms.conf`
- Modify: `src/onboarding/server/config/luckperms/luckperms.conf`
- Modify: `src/project-0/server/config/luckperms/luckperms.conf`
- Modify: `src/project-1/server/config/luckperms/luckperms.conf`

All five files are byte-identical apart from their `server = "<name>"` line, so one script edits them all.

- [ ] **Step 1: Write the normalization script**

Create `scripts/normalize-luckperms-conf.sh`:

```bash
#!/usr/bin/env bash
# Normalize every server's luckperms.conf.
#
# Connection and messaging settings now come from LUCKPERMS_* environment
# variables in compose.yml, which LuckPerms resolves ahead of this file on
# every platform. This script strips the ${...} placeholders that used to
# carry them, leaving stock values behind, and disables the Redis messenger
# that pointed at a service which does not exist.
#
# The `server = "<name>"` line is deliberately left alone: that is the
# server's identity and belongs with the server.
#
# WHY PERL AND NOT SED. These files are CRLF (684 CR / 684 LF each). On Git
# Bash for Windows, `sed`, `awk` and `grep` are PE binaries that open files
# in TEXT mode: they silently translate CRLF to LF on read and never restore
# it, so `sed -i` strips the carriage return from EVERY line, not just the
# ones it rewrites, and `grep -q $'\r'` cannot detect a carriage return at
# all. Measured on this toolchain: sed -i, sed with redirection and awk with
# redirection all reduce CR from 3 to 0 on a three-line CRLF fixture, while
# `perl -i -pe` preserves all 3. Hence perl.
#
# The patterns use [^\r\n]* rather than .* for the same reason: `.` matches
# a carriage return, so `.*` would swallow it and the replacement would emit
# an LF-only line into an otherwise CRLF file, leaving mixed endings.
set -euo pipefail

cd "$(dirname "$0")/.."

for conf in src/*/server/config/luckperms/luckperms.conf; do
  echo "normalizing $conf"

  perl -i -pe '
    s|^storage-method = [^\r\n]*|storage-method = "h2"|;
    s|^  address = "\$\{LUCKPERMS_DATA_ADDRESS[^\r\n]*|  address = "localhost:3306"|;
    s|^  database = "\$\{LUCKPERMS_DATA_DATABASE[^\r\n]*|  database = "minecraft"|;
    s|^  username = "\$\{LUCKPERMS_DATA_USERNAME[^\r\n]*|  username = "root"|;
    s|^  password = "\$\{LUCKPERMS_DATA_PASSWORD[^\r\n]*|  password = ""|;
    s|^messaging-service = [^\r\n]*|messaging-service = "sql"|;
    s|^  address = "\$\{LUCKPERMS_REDIS_ADDRESS[^\r\n]*|  address = "localhost"|;
    s|^  username = "\$\{LUCKPERMS_REDIS_USERNAME[^\r\n]*|  username = ""|;
    s|^  password = "\$\{LUCKPERMS_REDIS_PASSWORD[^\r\n]*|  password = ""|;

    # Disable the Redis messenger, and ONLY the redis block: the nats and
    # rabbitmq blocks have an identically-spelled `enabled` line.
    $inredis = 1 if /^redis \{/;
    if ($inredis && s|^  enabled = true|  enabled = false|) { $inredis = 0; }
    $inredis = 0 if /^\}/;
  ' "$conf"
done

echo "done"
```

- [ ] **Step 2: Verify the current broken state**

```bash
grep -h 'messaging-service\|storage-method' src/*/server/config/luckperms/luckperms.conf
```

Expected: five `messaging-service = "redis"` lines and five `storage-method = "${LUCKPERMS_STORAGE_METHOD:-postgresql}"` lines.

- [ ] **Step 3: Run the script**

```bash
chmod +x scripts/normalize-luckperms-conf.sh
bash scripts/normalize-luckperms-conf.sh
```

- [ ] **Step 4: Verify no placeholders remain**

```bash
grep -c '\${LUCKPERMS' src/*/server/config/luckperms/luckperms.conf
```

Expected: `0` for all five files.

```bash
grep -h 'messaging-service' src/*/server/config/luckperms/luckperms.conf
```

Expected: five `messaging-service = "sql"` lines.

```bash
grep -A2 '^redis {' src/survival/server/config/luckperms/luckperms.conf
```

Expected: `enabled = false`.

```bash
grep -h '^server = ' src/*/server/config/luckperms/luckperms.conf
```

Expected: five distinct names — `lobby`, `onboarding`, `project-0`, `project-1`, `survival`. Each server keeps its own identity.

Then confirm CRLF survived and the diff is small, not a whole-file rewrite:

```bash
for f in src/*/server/config/luckperms/luckperms.conf; do
  printf '%-52s CR=%s LF=%s\n' "$f" \
    "$(tr -cd '\r' < "$f" | wc -c)" "$(tr -cd '\n' < "$f" | wc -c)"
done
git diff --stat src/survival/server/config/luckperms/luckperms.conf
```

Expected: CR equals LF for every file (684 each), and the survival diff shows roughly
a dozen changed lines, not 680.

- [ ] **Step 5: Align the mchprs credential defaults**

`src/mchprs/Config.toml` is not a LuckPerms config file — MCHPRS reads the database
directly and has no environment-variable override — so it **must keep its `${...}`
placeholders**. But its fallback defaults disagree with what `compose.yml` uses, so a
missing environment variable would silently produce wrong credentials.

In `src/mchprs/Config.toml`, replace:

```toml
username = "${LUCKPERMS_DATA_USERNAME:-user_luckperms}"
password = "${LUCKPERMS_DATA_PASSWORD:-password_luckperms}"
```

with:

```toml
username = "${LUCKPERMS_DATA_USERNAME:-luckperms_user}"
password = "${LUCKPERMS_DATA_PASSWORD:-luckperms_password}"
```

**Do not touch the `host` line.** `host = "${LUCKPERMS_DATA_ADDRESS}"` receives a bare
hostname with no port, which is correct: MCHPRS passes it to
`OptsBuilder::ip_or_hostname()`, which defaults the port itself. Adding `:3306` breaks it.

Verify:

```bash
grep -c 'user_luckperms\|password_luckperms' src/mchprs/Config.toml
```

Expected: `0`.

- [ ] **Step 6: Commit the parent-repo files**

The four submodule files are committed in their own repositories in Tasks 9–10.

```bash
git add scripts/normalize-luckperms-conf.sh \
  src/survival/server/config/luckperms/luckperms.conf \
  src/mchprs/Config.toml
git commit -m "refactor: drive luckperms connection settings from the environment"
```

---

## Task 7: Velocity LuckPerms wiring and seeding policy

**Files:**
- Modify: `compose.yml`
- Modify: `src/velocity/server/plugins/luckperms/config.yml`
- Modify: `src/velocity/entrypoint.sh`

Velocity currently receives no `LUCKPERMS_*` variables, so its entrypoint renders `storage-method: ${LUCKPERMS_STORAGE_METHOD:-h2}` to the literal `h2` and the proxy runs on a private H2 file, disconnected from the shared database.

- [ ] **Step 1: Add the LuckPerms environment block**

In `compose.yml`, in the `velocity` service, replace:

```yaml
    environment:
      - JAVA_OPTS=${JAVA_OPTS:--Xmx2G -Xms1G}
      - VELOCITY_SECRET=${VELOCITY_SECRET:-velocitysecret}
```

with:

```yaml
    environment:
      - JAVA_OPTS=${JAVA_OPTS:--Xmx2G -Xms1G}
      - VELOCITY_SECRET=${VELOCITY_SECRET:-velocitysecret}

      # Luckperms database configuration
      - LUCKPERMS_STORAGE_METHOD=mariadb
      - LUCKPERMS_DATA_ADDRESS=luckperms-db:3306
      - LUCKPERMS_DATA_DATABASE=${LUCKPERMS_DB:-luckperms}
      - LUCKPERMS_DATA_USERNAME=${LUCKPERMS_DB_USER:-luckperms_user}
      - LUCKPERMS_DATA_PASSWORD=${LUCKPERMS_DB_PASSWORD:-luckperms_password}

      # Luckperms messaging service configuration
      - LUCKPERMS_MESSAGING_SERVICE=sql
```

- [ ] **Step 2: Normalize the Velocity LuckPerms config**

In `src/velocity/server/plugins/luckperms/config.yml`, replace these lines:

```yaml
storage-method: ${LUCKPERMS_STORAGE_METHOD:-h2}
data:
  address: ${LUCKPERMS_DB_ADDRESS:-localhost:3306}
  database: ${LUCKPERMS_DB_NAME:-luckperms}
  username: ${LUCKPERMS_DB_USERNAME:-root}
  password: ${LUCKPERMS_DB_PASSWORD:-}
```

with:

```yaml
# Connection settings come from LUCKPERMS_* environment variables in
# compose.yml, which LuckPerms resolves ahead of this file. Do not add
# connection settings here.
storage-method: h2
data:
  address: localhost:3306
  database: minecraft
  username: root
  password: ""
```

Then replace:

```yaml
messaging-service: ${LUCKPERMS_MESSAGING_SERVICE:-auto}
```

with:

```yaml
messaging-service: sql
```

Then replace every remaining `${LUCKPERMS_...}` placeholder in the `redis:`, `nats:`, and `rabbitmq:` blocks with stock values:

```yaml
redis:
  enabled: false
  address: localhost
  username: ""
  password: ""
  sentinel:
    enabled: false
    master: mymaster
    addresses:
      - localhost:26379
    username: ""
    password: ""
nats:
  enabled: false
  address: localhost:4222
  username: ""
  password: ""
  token: ""
rabbitmq:
  enabled: false
  address: localhost:5672
  vhost: "/"
  username: guest
  password: guest
```

Verify none remain:

```bash
grep -c '\${LUCKPERMS' src/velocity/server/plugins/luckperms/config.yml
```

Expected: `0`.

- [ ] **Step 3: Apply the seeding policy to the Velocity entrypoint**

In `src/velocity/entrypoint.sh`, replace everything from the line `echo "Injecting secrets..."` to the end of the file with:

```bash
echo "Injecting secrets..."

# velocity.toml references forwarding-secret-file and holds no secret itself,
# but render it anyway so future placeholders work.
render_env_placeholders "$CONFIG_DIR/velocity.toml"
render_env_placeholders "$CONFIG_DIR/forwarding.secret"

echo "Secrets injected successfully."

# Image-controlled: always re-synced so plugin upgrades actually land.
mkdir -p /server/plugins
cp -a "$CONFIG_DIR/plugins/." /server/plugins/

# Always rewritten so secret rotation propagates.
cp -a "$CONFIG_DIR/forwarding.secret" /server/forwarding.secret

# Admin-editable over WebDAV: seeded only when absent, so operators can add
# backend servers to velocity.toml without losing the change on restart.
[ -f /server/velocity.toml ] || cp -a "$CONFIG_DIR/velocity.toml" /server/velocity.toml
[ -f /server/server-icon.png ] || cp -a "$CONFIG_DIR/server-icon.png" /server/server-icon.png

echo "Copying complete. Starting Velocity..."

# This executes the CMD from your Dockerfile
exec "/usr/bin/run-bungeecord.sh"
```

Note the removal of `render_env_placeholders "$CONFIG_DIR/plugins/luckperms/config.yml"` — that file no longer contains placeholders.

- [ ] **Step 4: Rebuild and verify Velocity joins shared storage**

```bash
docker compose up -d --build velocity
sleep 45
docker compose logs velocity | grep -i "Resolved configuration value from environment variable"
```

Expected: lines including `LUCKPERMS_STORAGE_METHOD = mariadb` and `LUCKPERMS_DATA_ADDRESS = luckperms-db:3306`.

- [ ] **Step 5: Verify no H2 database was created**

```bash
docker compose exec velocity sh -c 'ls /server/plugins/luckperms/ 2>/dev/null | grep -i h2 || echo NO_H2'
```

Expected: `NO_H2`. An H2 file here means the environment variables did not take effect.

- [ ] **Step 6: Commit**

```bash
git add compose.yml src/velocity/server/plugins/luckperms/config.yml src/velocity/entrypoint.sh
git commit -m "fix: connect velocity luckperms to shared storage and seed config safely"
```

---

## Task 8: Survival entrypoint seeding policy

**Files:**
- Modify: `src/survival/entrypoint.sh`

- [ ] **Step 1: Apply the seeding policy**

In `src/survival/entrypoint.sh`, replace everything from the line `echo "Injecting secrets..."` to the end of the file with:

```bash
echo "Injecting secrets..."

# FabricProxy-Lite has no environment-variable support, so it is templated.
# luckperms.conf is NOT templated: its connection settings come from
# LUCKPERMS_* variables, which LuckPerms resolves ahead of the file.
render_env_placeholders "$CONFIG_DIR/FabricProxy-Lite.toml"

echo "Secrets injected successfully."

echo "Seeding /data..."

# Image-controlled: always re-synced so mod upgrades actually land.
mkdir -p /data/mods
cp -a /usr/src/init_data/mods/. /data/mods/

# Admin-editable over WebDAV: seeded only when absent so edits survive restarts.
mkdir -p /data/config
cp -a -n /usr/src/init_data/config/. /data/config/
[ -f /data/server.properties ] || cp -a /usr/src/init_data/server.properties /data/server.properties

# world/ is deliberately never touched here. This server's world is
# player-owned state. Contrast with lobby and onboarding, whose worlds are
# code artifacts re-synced from the image on every start.

echo "Initialization complete. Starting server..."

# This executes the CMD from your Dockerfile
exec "/image/scripts/start"
```

- [ ] **Step 2: Verify config edits now survive a restart**

```bash
docker compose up -d --build survival
sleep 60
docker compose exec survival sh -c 'echo "# edited" >> /data/config/FabricProxy-Lite.toml'
docker compose restart survival
sleep 60
docker compose exec survival grep -c '# edited' /data/config/FabricProxy-Lite.toml
```

Expected: `1`. Before this change the edit would have been reverted to `0`.

- [ ] **Step 3: Verify mods are still re-synced**

```bash
docker compose exec survival sh -c 'rm -f /data/mods/spark-1.10.142-fabric.jar'
docker compose restart survival
sleep 60
docker compose exec survival sh -c 'ls /data/mods/spark-1.10.142-fabric.jar'
```

Expected: the path is listed — the image restored it.

- [ ] **Step 4: Commit**

```bash
git add src/survival/entrypoint.sh
git commit -m "fix: seed survival config without clobbering admin edits"
```

---

## Task 9: Lobby and onboarding entrypoints

**Files:**
- Modify: `src/lobby/entrypoint.sh`
- Modify: `src/onboarding/entrypoint.sh`

These two repositories currently share a byte-identical entrypoint that injects the Velocity secret with `sed`, which silently corrupts any secret containing `/`, `&`, or `\`. They also copy `world/` unconditionally — **which is correct and must be preserved**, because those worlds are code artifacts.

- [ ] **Step 1: Branch both submodules**

```bash
cd src/lobby && git checkout -b claude/luckperms-seeding-fixes && cd ../..
cd src/onboarding && git checkout -b claude/luckperms-seeding-fixes && cd ../..
```

- [ ] **Step 2: Write the shared entrypoint**

Write this identical content to **both** `src/lobby/entrypoint.sh` and `src/onboarding/entrypoint.sh`:

```bash
#!/bin/bash
set -euo pipefail

CONFIG_DIR="/usr/src/init_data/config"

# ---------------------------------------------------------------------------
# render_env_placeholders <file>
#
# Replaces ${VAR} and ${VAR:-default} tokens in <file> with values from the
# process environment, writing the result back to the same file in place.
#
# Why not sed/envsubst?
#   - sed has no concept of ":-default" fallback syntax; it's pure literal
#     find/replace, so you'd need one hand-written sed line per variable
#     with no way to express "use this default if unset."
#   - envsubst only expands bare ${VAR} -- it doesn't understand the
#     ":-default" suffix either, and chokes on/passes through anything
#     that isn't a plain variable reference.
#   - Both approaches are also fragile: if a secret value happens to
#     contain '/', '&', or '\', a sed replacement string silently breaks
#     (sed treats '&' as "the whole match" and '/' as its delimiter).
#
# This function avoids all of that by using bash's own regex engine to
# find each ${...} token and indirect parameter expansion (${!varname})
# to look up its value, then splicing the result together with plain
# string operations -- never treating the replacement value as a pattern,
# and never eval-ing file content.
# ---------------------------------------------------------------------------
render_env_placeholders() {
  local file="$1" content result pattern full varname default value

  content=$(cat "$file")
  result=""
  # Matches ${NAME} or ${NAME:-default}. The default text may be empty
  # (${NAME:-}) but cannot itself contain a literal '}'.
  pattern='\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}'

  while [[ "$content" =~ $pattern ]]; do
    full="${BASH_REMATCH[0]}"
    varname="${BASH_REMATCH[1]}"
    default="${BASH_REMATCH[3]}"
    value="${!varname-}"

    if [[ -z "$value" ]]; then
      value="$default"
    fi

    result+="${content%%"$full"*}${value}"
    content="${content#*"$full"}"
  done
  result+="$content"

  printf '%s' "$result" > "$file"
}

echo "Injecting secrets..."

# FabricProxy-Lite has no environment-variable support, so it is templated.
# luckperms.conf is NOT templated: its connection settings come from
# LUCKPERMS_* variables, which LuckPerms resolves ahead of the file.
render_env_placeholders "$CONFIG_DIR/FabricProxy-Lite.toml"

echo "Secrets injected successfully."

echo "Seeding /data..."

# Image-controlled: always re-synced so mod upgrades actually land.
mkdir -p /data/mods
cp -a /usr/src/init_data/mods/. /data/mods/

# Image-controlled BY DESIGN. This server's world is a code artifact: builders
# publish a new design by rebuilding the image, and players are in adventure
# mode and cannot modify blocks. Do not convert this to seed-if-absent.
mkdir -p /data/world
cp -a /usr/src/init_data/world/. /data/world/

# Admin-editable over WebDAV: seeded only when absent so edits survive restarts.
mkdir -p /data/config
cp -a -n /usr/src/init_data/config/. /data/config/
[ -f /data/server.properties ] || cp -a /usr/src/init_data/server.properties /data/server.properties

echo "Initialization complete. Starting server..."

# This executes the CMD from your Dockerfile
exec "/image/scripts/start"
```

- [ ] **Step 3: Normalize both luckperms.conf files**

Already done by the script in Task 6, which globbed `src/*/server/config/luckperms/luckperms.conf`. Confirm:

```bash
grep -c '\${LUCKPERMS' src/lobby/server/config/luckperms/luckperms.conf src/onboarding/server/config/luckperms/luckperms.conf
```

Expected: `0` for both.

- [ ] **Step 4: Verify a secret containing a slash now survives**

```bash
cd src/lobby
VELOCITY_SECRET='a/b&c\d' bash -c '
  CONFIG_DIR=$(mktemp -d)
  mkdir -p "$CONFIG_DIR"
  printf "secret = \"\${VELOCITY_SECRET}\"\n" > "$CONFIG_DIR/FabricProxy-Lite.toml"
  # shellcheck disable=SC1091
  source <(sed -n "/^render_env_placeholders()/,/^}/p" entrypoint.sh)
  render_env_placeholders "$CONFIG_DIR/FabricProxy-Lite.toml"
  cat "$CONFIG_DIR/FabricProxy-Lite.toml"
'
cd ../..
```

Expected: `secret = "a/b&c\d"` exactly. The old `sed` implementation mangled this.

- [ ] **Step 5: Commit in both submodules**

```bash
cd src/lobby
git add entrypoint.sh server/config/luckperms/luckperms.conf
git commit -m "fix: robust secret injection and seed config without clobbering edits"
cd ../..

cd src/onboarding
git add entrypoint.sh server/config/luckperms/luckperms.conf
git commit -m "fix: robust secret injection and seed config without clobbering edits"
cd ../..
```

---

## Task 10: Project server entrypoints

**Files:**
- Modify: `src/project-0/entrypoint.sh`
- Modify: `src/project-1/entrypoint.sh`

These two repositories share a byte-identical entrypoint. Unlike lobby and onboarding they ship no `world/` directory, and their worlds are player-owned and must never be overwritten.

- [ ] **Step 1: Branch both submodules**

```bash
cd src/project-0 && git checkout -b claude/luckperms-seeding-fixes && cd ../..
cd src/project-1 && git checkout -b claude/luckperms-seeding-fixes && cd ../..
```

- [ ] **Step 2: Write the shared entrypoint**

Write this identical content to **both** `src/project-0/entrypoint.sh` and `src/project-1/entrypoint.sh`:

```bash
#!/bin/bash
set -euo pipefail

CONFIG_DIR="/usr/src/init_data/config"

# ---------------------------------------------------------------------------
# render_env_placeholders <file>
#
# Replaces ${VAR} and ${VAR:-default} tokens in <file> with values from the
# process environment, writing the result back to the same file in place.
#
# Why not sed/envsubst?
#   - sed has no concept of ":-default" fallback syntax; it's pure literal
#     find/replace, so you'd need one hand-written sed line per variable
#     with no way to express "use this default if unset."
#   - envsubst only expands bare ${VAR} -- it doesn't understand the
#     ":-default" suffix either, and chokes on/passes through anything
#     that isn't a plain variable reference.
#   - Both approaches are also fragile: if a secret value happens to
#     contain '/', '&', or '\', a sed replacement string silently breaks
#     (sed treats '&' as "the whole match" and '/' as its delimiter).
#
# This function avoids all of that by using bash's own regex engine to
# find each ${...} token and indirect parameter expansion (${!varname})
# to look up its value, then splicing the result together with plain
# string operations -- never treating the replacement value as a pattern,
# and never eval-ing file content.
# ---------------------------------------------------------------------------
render_env_placeholders() {
  local file="$1" content result pattern full varname default value

  content=$(cat "$file")
  result=""
  # Matches ${NAME} or ${NAME:-default}. The default text may be empty
  # (${NAME:-}) but cannot itself contain a literal '}'.
  pattern='\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}'

  while [[ "$content" =~ $pattern ]]; do
    full="${BASH_REMATCH[0]}"
    varname="${BASH_REMATCH[1]}"
    default="${BASH_REMATCH[3]}"
    value="${!varname-}"

    if [[ -z "$value" ]]; then
      value="$default"
    fi

    result+="${content%%"$full"*}${value}"
    content="${content#*"$full"}"
  done
  result+="$content"

  printf '%s' "$result" > "$file"
}

echo "Injecting secrets..."

# FabricProxy-Lite has no environment-variable support, so it is templated.
# luckperms.conf is NOT templated: its connection settings come from
# LUCKPERMS_* variables, which LuckPerms resolves ahead of the file.
render_env_placeholders "$CONFIG_DIR/FabricProxy-Lite.toml"

echo "Secrets injected successfully."

echo "Seeding /data..."

# Image-controlled: always re-synced so mod upgrades actually land.
mkdir -p /data/mods
cp -a /usr/src/init_data/mods/. /data/mods/

# Admin-editable over WebDAV: seeded only when absent so edits survive restarts.
mkdir -p /data/config
cp -a -n /usr/src/init_data/config/. /data/config/
[ -f /data/server.properties ] || cp -a /usr/src/init_data/server.properties /data/server.properties

# world/ is deliberately never touched here. This server's world is
# player-owned state.

echo "Initialization complete. Starting server..."

# This executes the CMD from your Dockerfile
exec "/image/scripts/start"
```

- [ ] **Step 3: Confirm the luckperms.conf normalization reached both**

```bash
grep -c '\${LUCKPERMS' src/project-0/server/config/luckperms/luckperms.conf src/project-1/server/config/luckperms/luckperms.conf
```

Expected: `0` for both.

- [ ] **Step 4: Commit in both submodules**

```bash
cd src/project-0
git add entrypoint.sh server/config/luckperms/luckperms.conf
git commit -m "fix: robust secret injection and seed config without clobbering edits"
cd ../..

cd src/project-1
git add entrypoint.sh server/config/luckperms/luckperms.conf
git commit -m "fix: robust secret injection and seed config without clobbering edits"
cd ../..
```

---

## Task 11: Push submodules and bump pointers

**Files:**
- Modify: `.gitmodules` (no change expected — verify only)
- Modify: parent repository submodule pointers

- [ ] **Step 1: Push all four submodule branches**

```bash
for repo in lobby onboarding project-0 project-1; do
  echo "=== $repo ==="
  (cd "src/$repo" && git push -u origin claude/luckperms-seeding-fixes)
done
```

If push is rejected for lack of permission, stop and report which repositories failed. Do not proceed to Step 2 with unpushed commits — the parent pointer would reference a commit nobody else can fetch.

- [ ] **Step 2: Verify each submodule is on the pushed commit**

```bash
git submodule status
```

Expected: four lines with a `+` prefix, indicating the checked-out commit differs from the one recorded in the parent.

- [ ] **Step 3: Bump the pointers in the parent repository**

```bash
git add src/lobby src/onboarding src/project-0 src/project-1
git commit -m "chore: bump submodules for luckperms and seeding fixes"
```

- [ ] **Step 4: Verify the pointers are clean**

```bash
git submodule status
```

Expected: four lines with no `+` prefix.

---

## Task 12: Verify LuckPerms storage and messaging

**Files:**
- Create: `tests/test-luckperms.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test-luckperms.sh`:

```bash
#!/usr/bin/env bash
# LuckPerms storage, messaging and API reachability.
# Requires the stack to be running.
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib.sh
. tests/lib.sh

SECRET=$(grep -E '^LUCKPERMS_SECRET=' .env | cut -d= -f2-)
DB_USER=$(grep -E '^LUCKPERMS_DB_USER=' .env | cut -d= -f2-)
DB_PASS=$(grep -E '^LUCKPERMS_DB_PASSWORD=' .env | cut -d= -f2-)
DB_NAME=$(grep -E '^LUCKPERMS_DB=' .env | cut -d= -f2-)

# lp <path> -- GET the LuckPerms API through Caddy, exactly as an external
# client would, prefix and all.
lp() {
  docker run --rm --network irc-frontend-network curlimages/curl:latest \
    -s -H "Authorization: Bearer $SECRET" "http://caddy:80/luckperms$1"
}

echo "luckperms"

# The API must be reachable through the Caddy /luckperms route, which proves
# the prefix is being stripped correctly.
HEALTH=$(lp /health)
assert_contains "$HEALTH" '"up":true' "API is healthy through the /luckperms route"

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

# Messaging: a group created through the API must become visible to a server
# without restarting it. Poll briefly, since the SQL messenger is not instant.
GROUP="msgtest$$"
docker run --rm --network irc-frontend-network curlimages/curl:latest \
  -s -o /dev/null -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' \
  -X POST -d "{\"name\":\"$GROUP\"}" "http://caddy:80/luckperms/group"

FOUND=NO
for _ in $(seq 1 30); do
  if docker compose exec -T survival rcon-cli lp listgroups 2>/dev/null | grep -q "$GROUP"; then
    FOUND=YES; break
  fi
  sleep 2
done
assert_eq "$FOUND" "YES" "a new group propagates to survival without a restart"

docker run --rm --network irc-frontend-network curlimages/curl:latest \
  -s -o /dev/null -H "Authorization: Bearer $SECRET" \
  -X DELETE "http://caddy:80/luckperms/group/$GROUP"

finish
```

- [ ] **Step 2: Bring the stack up in stages**

Six servers at `-Xmx2G` plus Velocity exceeds a 16 GB host. Lower the heap for testing first:

```bash
sed -i 's|^JAVA_OPTS=.*|JAVA_OPTS=-Xmx1G -Xms512M|' .env
docker compose up -d --build volume_init luckperms-db luckperms-standalone webdav caddy velocity survival mchprs
sleep 90
docker compose up -d --build lobby onboarding project-0 project-1
sleep 120
docker compose ps
```

Expected: every service `running`, and `luckperms-db`, `luckperms-standalone`, and `velocity` additionally `healthy`.

- [ ] **Step 3: Run the test**

```bash
bash tests/test-luckperms.sh
```

Expected: `0 failed`.

If `rcon-cli` is unavailable on `survival`, substitute the equivalent check by querying the database directly:

```bash
docker compose exec -T luckperms-db mariadb -u"$DB_USER" -p"$DB_PASS" -N -B \
  -e "SELECT name FROM luckperms_groups;" "$DB_NAME"
```

- [ ] **Step 4: Commit**

```bash
git add tests/test-luckperms.sh
git commit -m "test: verify luckperms shared storage and cross-server messaging"
```

---

## Task 13: Probe the context-value constraint

**Files:**
- Create: `tests/test-seeder.sh` (first assertions only)

The REST API's OpenAPI schema declares context keys and values as `^[a-z0-9]+$`, which would reject `project-0` and `project-1`. LuckPerms itself permits hyphens. This must be settled **before** `permissions.yml` is written, because it decides whether per-server contexts are usable for the project servers.

- [ ] **Step 1: Write the probe**

Create `tests/test-seeder.sh`:

```bash
#!/usr/bin/env bash
# luckperms-init correctness. Requires the stack to be running.
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib.sh
. tests/lib.sh

SECRET=$(grep -E '^LUCKPERMS_SECRET=' .env | cut -d= -f2-)

api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    docker run --rm --network irc-frontend-network curlimages/curl:latest \
      -s -w '\n%{http_code}' -H "Authorization: Bearer $SECRET" \
      -H 'Content-Type: application/json' -X "$method" -d "$body" \
      "http://caddy:80/luckperms$path"
  else
    docker run --rm --network irc-frontend-network curlimages/curl:latest \
      -s -w '\n%{http_code}' -H "Authorization: Bearer $SECRET" \
      -X "$method" "http://caddy:80/luckperms$path"
  fi
}

echo "context constraint probe"

# Does the API accept a context value containing a hyphen? The OpenAPI schema
# says ^[a-z0-9]+$, which would reject project-0. LuckPerms itself allows it.
api POST /group '{"name":"ctxprobe"}' >/dev/null
RESP=$(api PUT /group/ctxprobe/nodes \
  '[{"key":"test.node","value":true,"context":[{"key":"server","value":"project-0"}]}]')
CODE=$(printf '%s' "$RESP" | tail -n1)

if [ "$CODE" = "200" ] || [ "$CODE" = "201" ] || [ "$CODE" = "204" ]; then
  pass "hyphenated context values are accepted (project-0 usable)"
  echo "       -> permissions.yml MAY use per-server contexts for project servers"
else
  fail "hyphenated context values rejected with HTTP $CODE" \
       "permissions.yml MUST NOT use server=project-0 contexts; see the fallback in the spec"
fi

api DELETE /group/ctxprobe >/dev/null

finish
```

- [ ] **Step 2: Run the probe and record the result**

```bash
bash tests/test-seeder.sh
```

Record the outcome. **If it fails**, `permissions.yml` in Task 15 must not use `server: project-0` or `server: project-1` contexts; use `global` context instead and scope those servers by permission key. **If it passes**, per-server contexts are safe everywhere.

- [ ] **Step 3: Commit**

```bash
git add tests/test-seeder.sh
git commit -m "test: probe whether the luckperms api accepts hyphenated contexts"
```

---

## Task 14: The seeder

**Files:**
- Create: `src/luckperms-init/Dockerfile`
- Create: `src/luckperms-init/seed.py`
- Delete: `src/luckperms-standalone/Initialization-1.0-SNAPSHOT.jar`
- Modify: `src/luckperms-standalone/Dockerfile`

- [ ] **Step 1: Remove the unsourced extension jar**

```bash
git rm src/luckperms-standalone/Initialization-1.0-SNAPSHOT.jar
```

Replace the entire contents of `src/luckperms-standalone/Dockerfile` with:

```dockerfile
FROM ghcr.io/luckperms/rest-api:latest

# The permission model is applied by the luckperms-init service from
# src/luckperms-init/permissions.yml, not by a compiled extension.
```

- [ ] **Step 2: Write the seeder image**

Create `src/luckperms-init/Dockerfile`:

```dockerfile
FROM python:3.12-alpine

RUN pip install --no-cache-dir "PyYAML==6.0.2"

COPY seed.py /seed.py

ENTRYPOINT ["python3", "/seed.py"]
```

- [ ] **Step 3: Write the seeder**

Create `src/luckperms-init/seed.py`:

```python
#!/usr/bin/env python3
"""Apply the declarative LuckPerms model in permissions.yml via the REST API.

The model is authoritative for the groups it names: each managed group's node
set is replaced wholesale, so the file always describes reality. Groups absent
from the file are never touched, which leaves ad-hoc groups as an escape hatch.

The script is idempotent. It compares desired state against actual state and
only writes when they differ, then reports how many changes it made, so a
second run reports zero.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

import yaml

API = os.environ.get("LUCKPERMS_API_URL", "http://luckperms-standalone:8080").rstrip("/")
KEY = os.environ["LUCKPERMS_SECRET"]
MODEL_PATH = os.environ.get("PERMISSIONS_FILE", "/permissions.yml")

changes = 0


def request(method, path, body=None):
    """Return (status_code, parsed_body_or_text)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{API}{path}", data=data, method=method)
    req.add_header("Authorization", f"Bearer {KEY}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            if not raw:
                return resp.status, None
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw.decode(errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode(errors="replace")


def wait_for_api(attempts=60, delay=2):
    for _ in range(attempts):
        try:
            status, body = request("GET", "/health")
            if status == 200:
                print(f"api ready: {body}")
                return
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(delay)
    sys.exit("luckperms api never became reachable")


def build_context(raw):
    """Turn {'server': 'survival'} into [{'key': ..., 'value': ...}]."""
    if not raw:
        return []
    return [{"key": str(k), "value": str(v)} for k, v in sorted(raw.items())]


def build_nodes(group_name, spec):
    """Expand a group spec into the flat node list LuckPerms stores.

    Node type is encoded in the key, so no separate type field is sent:
      weight.100          -> group weight
      group.member        -> inheritance
      prefix.100.&c[A]    -> prefix at priority 100
    """
    nodes = []

    weight = spec.get("weight")
    if weight is not None:
        nodes.append({"key": f"weight.{int(weight)}", "value": True, "context": []})

    prefix = spec.get("prefix")
    if prefix is not None:
        priority = int(spec.get("prefix_priority", weight or 0))
        nodes.append({"key": f"prefix.{priority}.{prefix}", "value": True, "context": []})

    for parent in spec.get("inherits", []) or []:
        nodes.append({"key": f"group.{parent}", "value": True, "context": []})

    for entry in spec.get("permissions", []) or []:
        if isinstance(entry, str):
            nodes.append({"key": entry, "value": True, "context": []})
            continue
        if "key" not in entry:
            sys.exit(f"group '{group_name}': permission entry is missing 'key': {entry}")
        node = {
            "key": entry["key"],
            "value": bool(entry.get("value", True)),
            "context": build_context(entry.get("context")),
        }
        if "expiry" in entry:
            node["expiry"] = int(entry["expiry"])
        nodes.append(node)

    return nodes


def node_identity(node):
    """A comparable form, so ordering and absent optional fields do not matter."""
    return (
        node["key"],
        bool(node.get("value", True)),
        tuple(sorted((c["key"], c["value"]) for c in node.get("context") or [])),
        node.get("expiry"),
    )


def ensure_group(name, existing_names):
    global changes
    if name in existing_names:
        return
    status, body = request("POST", "/group", {"name": name})
    if status in (200, 201, 204):
        print(f"created group {name}")
        changes += 1
    elif status == 409:
        pass  # raced with something else; harmless
    else:
        sys.exit(f"failed to create group '{name}': HTTP {status} {body}")


def apply_group_nodes(name, desired):
    global changes
    status, actual = request("GET", f"/group/{name}/nodes")
    if status != 200:
        sys.exit(f"failed to read nodes for group '{name}': HTTP {status} {actual}")

    have = {node_identity(n) for n in (actual or [])}
    want = {node_identity(n) for n in desired}
    if have == want:
        print(f"group {name}: already correct ({len(want)} nodes)")
        return

    status, body = request("PUT", f"/group/{name}/nodes", desired)
    if status not in (200, 201, 204):
        sys.exit(f"failed to set nodes for group '{name}': HTTP {status} {body}")
    print(f"group {name}: set {len(desired)} nodes (was {len(have)})")
    changes += 1


def apply_track(name, groups):
    global changes
    status, actual = request("GET", f"/track/{name}")
    if status == 404:
        status, body = request("POST", "/track", {"name": name})
        if status not in (200, 201, 204):
            sys.exit(f"failed to create track '{name}': HTTP {status} {body}")
        print(f"created track {name}")
        changes += 1
        actual = {"groups": []}
    elif status != 200:
        sys.exit(f"failed to read track '{name}': HTTP {status} {actual}")

    if (actual or {}).get("groups") == groups:
        print(f"track {name}: already correct")
        return

    status, body = request("PATCH", f"/track/{name}", {"groups": groups})
    if status not in (200, 201, 204):
        sys.exit(f"failed to update track '{name}': HTTP {status} {body}")
    print(f"track {name}: set to {groups}")
    changes += 1


def main():
    with open(MODEL_PATH, encoding="utf-8") as handle:
        model = yaml.safe_load(handle) or {}

    wait_for_api()

    status, existing = request("GET", "/group")
    if status != 200:
        sys.exit(f"failed to list groups: HTTP {status} {existing}")
    existing_names = set(existing or [])

    for name, spec in (model.get("groups") or {}).items():
        ensure_group(name, existing_names)
        apply_group_nodes(name, build_nodes(name, spec or {}))

    for name, spec in (model.get("tracks") or {}).items():
        apply_track(name, list((spec or {}).get("groups") or []))

    if changes:
        status, body = request("POST", "/messaging/update")
        if status not in (200, 201, 202, 204):
            print(f"warning: messaging update returned HTTP {status} {body}", file=sys.stderr)
        else:
            print("pushed update to connected servers")

    print(f"changed={changes}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Commit**

```bash
git add src/luckperms-init/Dockerfile src/luckperms-init/seed.py src/luckperms-standalone/Dockerfile
git commit -m "feat: add declarative luckperms seeder and retire the unsourced jar"
```

---

## Task 15: The permission model

**Files:**
- Create: `src/luckperms-init/permissions.yml`

> **Depends on Task 13.** If the context probe failed, remove every `context:` block referencing `project-0` or `project-1` from the file below and leave those nodes global.

- [ ] **Step 1: Write the model**

Create `src/luckperms-init/permissions.yml`:

```yaml
# ============================================================================
# LuckPerms permission model -- applied on every `docker compose up`.
# ============================================================================
#
# THIS FILE IS AUTHORITATIVE for the groups it names. Each managed group's
# node set is REPLACED wholesale on every deployment, so changes made to
# these groups through the LuckPerms web editor WILL BE OVERWRITTEN.
#
# Groups NOT listed here are never touched. Create an unlisted group if you
# need somewhere to make ad-hoc runtime grants.
#
# ---------------------------------------------------------------------------
# MCHPRS constraints -- read before adding permissions
# ---------------------------------------------------------------------------
# MCHPRS reads this data straight out of the database rather than running the
# LuckPerms plugin, and its implementation is limited in three ways:
#
#   1. NEVER write a node that is a strict prefix of another node MCHPRS will
#      query. Its matcher indexes the stored path while iterating the queried
#      string's segments, so a stored `mchprs.command` checked against a
#      queried `mchprs.command.foo` panics with an index-out-of-bounds.
#      Use exact keys or an explicit `*` wildcard -- never a partial path.
#   2. Only `global` and `mchprs` server contexts are visible to it.
#   3. Group membership must be an explicit `group.<name>` node on the user.
#      MCHPRS never consults the primary-group table.
#
# ---------------------------------------------------------------------------
# Syntax
# ---------------------------------------------------------------------------
#   weight:       integer, higher wins for prefix and meta resolution
#   prefix:       chat prefix; priority defaults to the group's weight
#   inherits:     list of parent group names
#   permissions:  either a bare string (granted globally), or a mapping with
#                 key, optional value (false negates), optional context,
#                 and optional expiry (epoch seconds)
# ============================================================================

groups:
  # Everyone starts here. LuckPerms assigns `default` automatically.
  default:
    weight: 0
    inherits:
      - onboarder

  # A new player who has not yet been vouched for. Confined to the
  # onboarding server.
  onboarder:
    weight: 10
    prefix: "&7[New] "
    permissions:
      - key: "irc.server.onboarding"
        value: true
      # Explicitly denied elsewhere so the deny is visible in the model
      # rather than implied by absence.
      - key: "irc.server.survival"
        value: false
      - key: "irc.server.project"
        value: false

  # A vouched member with normal play access.
  member:
    weight: 100
    prefix: "&a[Member] "
    inherits:
      - onboarder
    permissions:
      - key: "irc.server.survival"
        value: true
      - key: "irc.server.project"
        value: true
      # Wildcard, not a partial path -- see the MCHPRS constraints above.
      - key: "mchprs.command.*"
        value: true
        context:
          server: mchprs

  # Staff. Full administrative control.
  admin:
    weight: 1000
    prefix: "&c[Admin] "
    inherits:
      - member
    permissions:
      - "luckperms.*"
      - "minecraft.command.*"
      - key: "mchprs.admin.*"
        value: true
        context:
          server: mchprs

tracks:
  # Promotion path: lp user <name> promote onboarding
  onboarding:
    groups:
      - onboarder
      - member
      - admin
```

- [ ] **Step 2: Validate the YAML parses**

```bash
docker run --rm -v "$PWD/src/luckperms-init:/w" -w /w python:3.12-alpine sh -c \
  'pip install --no-cache-dir PyYAML==6.0.2 >/dev/null && python3 -c "import yaml,sys; yaml.safe_load(open(\"permissions.yml\")); print(\"ok\")"'
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add src/luckperms-init/permissions.yml
git commit -m "feat: define the luckperms permission model in code"
```

---

## Task 16: Wire in the seeder and prove idempotency

**Files:**
- Modify: `compose.yml`
- Modify: `tests/test-seeder.sh`

- [ ] **Step 1: Add the service**

In `compose.yml`, add immediately after the `luckperms-standalone` service:

```yaml
  # One-shot: applies src/luckperms-init/permissions.yml through the REST API.
  # Runs on every `up`; idempotent, and reports changed=0 when already correct.
  luckperms-init:
    build:
      context: ./src/luckperms-init
    container_name: luckperms-init
    restart: "no"
    environment:
      - LUCKPERMS_API_URL=http://luckperms-standalone:8080
      - LUCKPERMS_SECRET=${LUCKPERMS_SECRET:-luckpermssecret}
      - PERMISSIONS_FILE=/permissions.yml
    volumes:
      - ./src/luckperms-init/permissions.yml:/permissions.yml:ro
    networks:
      - frontend-network
    depends_on:
      luckperms-standalone:
        condition: service_healthy
```

- [ ] **Step 2: Add failing idempotency assertions**

In `tests/test-seeder.sh`, insert immediately before the `finish` line:

```bash
echo "seeder"

# First run: applies the model.
docker compose up --build --force-recreate luckperms-init >/tmp/seed1.log 2>&1
FIRST=$(docker compose logs --no-log-prefix luckperms-init 2>/dev/null | tail -n 40)
assert_contains "$FIRST" "changed=" "seeder reported a change count"

# Every modelled group must now exist.
GROUPS=$(api GET /group | head -n1)
for g in default onboarder member admin; do
  assert_contains "$GROUPS" "\"$g\"" "group $g exists"
done

# The track must exist with the right order.
TRACK=$(api GET /track/onboarding | head -n1)
assert_contains "$TRACK" "onboarder" "track contains onboarder"
assert_contains "$TRACK" "member" "track contains member"
assert_contains "$TRACK" "admin" "track contains admin"

# Inheritance is stored as a group.<name> node, which is what MCHPRS reads.
MEMBER_NODES=$(api GET /group/member/nodes | head -n1)
assert_contains "$MEMBER_NODES" "group.onboarder" "member inherits onboarder as a node"
assert_contains "$MEMBER_NODES" "weight.100" "member has its weight node"

# Second run against unchanged input must be a no-op.
docker compose up --force-recreate luckperms-init >/tmp/seed2.log 2>&1
SECOND=$(docker compose logs --no-log-prefix luckperms-init 2>/dev/null | tail -n 40)
assert_contains "$SECOND" "changed=0" "second run is a no-op"
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bash tests/test-seeder.sh
```

Expected: FAIL — the `luckperms-init` service does not build yet if Step 1 was skipped, or groups are missing on a fresh database.

- [ ] **Step 4: Build and run the seeder**

```bash
docker compose up -d --build luckperms-init
docker compose logs luckperms-init
```

Expected: `created group onboarder`, `group member: set N nodes`, `pushed update to connected servers`, `changed=N` with N greater than zero.

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash tests/test-seeder.sh
```

Expected: all assertions pass, including `second run is a no-op`.

- [ ] **Step 6: Commit**

```bash
git add compose.yml tests/test-seeder.sh
git commit -m "feat: run the luckperms seeder on every up, verified idempotent"
```

---

## Task 17: Full-stack verification

**Files:**
- Create: `tests/run-all.sh`

- [ ] **Step 1: Write the runner**

Create `tests/run-all.sh`:

```bash
#!/usr/bin/env bash
# Run every test suite. Requires the stack to be running.
cd "$(dirname "$0")/.." || exit 1

FAILED=0
for suite in tests/test-*.sh; do
  echo
  echo "=============================================================="
  echo "$suite"
  echo "=============================================================="
  bash "$suite" || FAILED=1
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "ALL SUITES PASSED"
else
  echo "SOME SUITES FAILED"
fi
exit "$FAILED"
```

- [ ] **Step 2: Recreate the stack from scratch**

This proves a clean deployment works, not just an incrementally-patched one.

```bash
docker compose -f compose.yml down -v
docker compose -f compose.yml up -d --build volume_init luckperms-db luckperms-standalone luckperms-init webdav caddy velocity survival mchprs
sleep 120
docker compose -f compose.yml up -d --build lobby onboarding project-0 project-1
sleep 150
docker compose -f compose.yml ps
```

Expected: all services `running`; `luckperms-db`, `luckperms-standalone`, and `velocity` also `healthy`; `volume_init` and `luckperms-init` `exited (0)`.

**`cloudflared` is deliberately excluded from both `up` commands.** With the placeholder
token in `.env` it cannot authenticate and would restart-loop, which is noise rather
than a failure. It is verified against a real tunnel at deploy time, not here.

- [ ] **Step 3: Run every suite**

```bash
bash tests/run-all.sh
```

Expected: `ALL SUITES PASSED`.

- [ ] **Step 4: Verify the uid trap is actually closed**

This is the check that could not run earlier: it needs a Minecraft server to have
actually started and created directories as uid 1000. Writing into one of those over
WebDAV is the original failure mode that motivated replacing the nginx image.

```bash
WU=$(grep -E '^WEBDAV_USERNAME=' .env | cut -d= -f2-)
WP=$(grep -E '^WEBDAV_PASSWORD=' .env | cut -d= -f2-)

# The survival server creates /data/config as uid 1000 on first boot.
docker compose exec -T survival sh -c 'ls -ldn /data/config'

docker run --rm --network irc-frontend-network curlimages/curl:latest \
  -s -o /dev/null -w 'PUT=%{http_code}\n' -u "$WU:$WP" \
  -X PUT --data 'x' http://caddy:80/files/survival/config/uidtest.txt
```

Expected: the directory is owned by `1000 1000`, and `PUT=201`.

Then confirm the reverse direction — that a Minecraft server can rewrite a file WebDAV
created, which is what running webdav as uid 1000 rather than root buys:

```bash
docker compose exec -T survival sh -c 'echo rewritten > /data/config/uidtest.txt && cat /data/config/uidtest.txt'
docker compose exec -T survival sh -c 'rm -f /data/config/uidtest.txt'
```

Expected: `rewritten`, with no permission error. A failure here means the ownership
alignment regressed.

- [ ] **Step 5: Verify MCHPRS reads the seeded model**

```bash
docker compose logs mchprs | grep -iE "permission|luckperms|error" | head -n 20
```

Expected: no connection errors. MCHPRS connects to `luckperms-db` on the default MySQL port using the bare hostname — **do not add `:3306`**.

Confirm the data MCHPRS reads is actually present:

```bash
DB_USER=$(grep -E '^LUCKPERMS_DB_USER=' .env | cut -d= -f2-)
DB_PASS=$(grep -E '^LUCKPERMS_DB_PASSWORD=' .env | cut -d= -f2-)
DB_NAME=$(grep -E '^LUCKPERMS_DB=' .env | cut -d= -f2-)
docker compose exec -T luckperms-db mariadb -u"$DB_USER" -p"$DB_PASS" -N -B \
  -e "SELECT name, permission, server FROM luckperms_group_permissions ORDER BY name;" "$DB_NAME"
```

Expected: rows for `onboarder`, `member`, and `admin`, with `mchprs.command.*` carrying server `mchprs`, and no permission that is a strict prefix of another.

- [ ] **Step 6: Verify the only published port**

```bash
docker compose ps --format '{{.Service}} {{.Ports}}' | grep -E '0\.0\.0\.0|:::'
```

Expected: exactly one line, for `velocity`, showing `25565`.

- [ ] **Step 7: Restore the production heap setting**

```bash
sed -i 's|^JAVA_OPTS=.*|JAVA_OPTS=-Xmx2G -Xms1G|' .env
```

- [ ] **Step 8: Commit**

```bash
git add tests/run-all.sh
git commit -m "test: add a runner for the full suite"
```

---

: Reconcile the documentation

**Files:**
- Modify: `docs/api.md`
- Modify: `README.md`

- [ ] **Step 1: Resolve the unverified context note**

In `docs/api.md`, find the blockquote beginning `> **Unverified:** the OpenAPI schema declares context keys and values as`.

If the Task 13 probe **passed**, replace the whole blockquote with:

```markdown
> **Verified:** hyphenated context values such as `project-0` are accepted, even
> though the OpenAPI schema declares context keys and values as `^[a-z0-9]+$`.
> The schema is stricter than the implementation. `context` is sent as an array
> of `{key, value}` pairs.
```

If the probe **failed**, replace it with:

```markdown
> **Verified:** the API rejects context values containing hyphens, so `project-0`
> and `project-1` cannot be used as `server` context values. Scope permissions for
> those servers with global-context permission keys instead. `context` is sent as
> an array of `{key, value}` pairs.
```

- [ ] **Step 2: Remove the status caveat**

In `docs/api.md`, replace the opening blockquote:

```markdown
> **Status:** describes the deployment as specified in
> [`superpowers/specs/2026-09-22-compose-orchestration-completion-design.md`](superpowers/specs/2026-09-22-compose-orchestration-completion-design.md).
> Items marked **unverified** have not yet been exercised against a running stack.
```

with:

```markdown
> **Status:** implemented and verified against a running stack. The cloudflared
> hop is configured but not exercised end-to-end; everything from Caddy inward
> is covered by `tests/`.
```

- [ ] **Step 3: Document the test suite in the README**

In `README.md`, insert this section immediately before the `## Documentation` heading:

```markdown
## Tests

The suites under `tests/` exercise a running stack. Bring it up first, then:

```bash
bash tests/run-all.sh
```

| Suite | Covers |
| --- | --- |
| `test-compose-config.sh` | Static validation: one published port, optional backup config, consistent credential defaults |
| `test-webdav.sh` | WebDAV through Caddy: prefix handling, `Destination` rewriting, writes into server-created directories |
| `test-luckperms.sh` | Shared MariaDB storage on every server, no H2 fallback, cross-server messaging |
| `test-seeder.sh` | The permission model applies correctly and re-running is a no-op |

On a host with less than about 20 GB of RAM, lower `JAVA_OPTS` in `.env` before
running the full stack.
```

- [ ] **Step 4: Commit**

```bash
git add docs/api.md README.md
git commit -m "docs: reconcile documentation with the verified implementation"
```

---

## Task 19: Final review

- [ ] **Step 1: Confirm no placeholders survive anywhere**

```bash
grep -rn 'path/to/your\|${LUCKPERMS_DATA_\|${LUCKPERMS_REDIS_\|user_luckperms' \
  compose.yml src/ --include='*.yml' --include='*.conf' --include='*.sh' --include='*.toml' \
  | grep -v '^src/[^/]*/\.git' || echo "CLEAN"
```

Expected: `CLEAN`.

- [ ] **Step 2: Confirm the retracted findings were not "fixed"**

```bash
grep -c 'healthcheck' compose.yml
```

Expected: `2` — `luckperms-db` and nothing else that shadows a base-image check. Then:

```bash
grep -n 'LUCKPERMS_DATA_ADDRESS=luckperms-db$' compose.yml
```

Expected: one line, inside the `mchprs` service. The bare hostname is correct.

```bash
grep -n 'cp -a /usr/src/init_data/world' src/lobby/entrypoint.sh src/onboarding/entrypoint.sh
```

Expected: one line in each — the intentional world re-sync is intact.

- [ ] **Step 3: Confirm the working tree and submodules are clean**

```bash
git status --short
git submodule status
```

Expected: no output from the first; no `+` prefixes from the second.

- [ ] **Step 4: Review the full diff**

```bash
git log --oneline main..HEAD
git diff main...HEAD --stat
```

- [ ] **Step 5: Request code review**

Use the superpowers:requesting-code-review skill against the design spec.

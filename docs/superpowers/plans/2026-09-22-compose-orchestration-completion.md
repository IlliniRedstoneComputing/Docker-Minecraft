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
| `src/survival/Dockerfile` | Drop the unrendered /config copy that would clobber the rendered secret |
| `src/{survival,lobby,onboarding,project-0,project-1}/server/config/luckperms/luckperms.conf` | Normalized |
| `src/mchprs/Config.toml` | Fallback credentials aligned; keeps its `${...}` placeholders |
| `src/{lobby,onboarding}/entrypoint.sh` | Robust secret injection, seeding policy, keep world re-sync |
| `src/{project-0,project-1}/entrypoint.sh` | Robust secret injection, seeding policy |

**Deleted**

| Path | Reason |
| --- | --- |
| `src/luckperms-standalone/Initialization-1.0-SNAPSHOT.jar` | Unsourced binary, replaced by the seeder |
| `wg0.conf.example` | Dead — no WireGuard service exists |

**Submodule note:** `src/lobby`, `src/onboarding`, `src/project-0`, and `src/project-1` are separate repositories. Changes there are committed and pushed on a branch in each repository, then the parent repository's submodule pointers are bumped in Task 11.

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
# src/mchprs/Config.toml is NOT handled here, even though it carries the same
# placeholders. MCHPRS reads the database directly and has no environment
# variable override, so its placeholders must survive; it is rendered at
# container start instead. There is nothing for this script to do to it.
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

cd "$(dirname "$0")/.." || exit 1

# Assert the full set is present before touching anything. Four of these five
# live in git submodules, and an uninitialized checkout is the DEFAULT state of
# a fresh clone. Without this guard the glob quietly matches one file, the
# script normalizes it, prints "done" and exits 0 -- leaving four servers still
# pointing at a Redis messenger that does not exist, with nothing in the output
# to say so. `set -e` does not help: `perl -i` on a missing file warns to
# stderr and still exits 0.
shopt -s nullglob
confs=(src/*/server/config/luckperms/luckperms.conf)
if [ "${#confs[@]}" -ne 5 ]; then
  printf 'expected 5 luckperms.conf files, found %d:\n' "${#confs[@]}" >&2
  printf '  %s\n' "${confs[@]}" >&2
  if [ "${#confs[@]}" -lt 5 ]; then
    printf 'run: git submodule update --init --recursive\n' >&2
  else
    printf 'a server was added -- update the expected count in this script\n' >&2
  fi
  exit 1
fi

for conf in "${confs[@]}"; do
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
    # rabbitmq blocks have an identically-spelled `enabled` line. Top-level
    # blocks close at column 0 while nested ones close at "  }", so /^\}/ is
    # a safe reset.
    #
    # Matching the line and flipping it are deliberately separate steps. On a
    # second run the line already reads `enabled = false`, so keying the
    # assertion below on a successful substitution would make a correct
    # re-run fail.
    our ($in_redis, $seen_redis);
    $in_redis = 1 if /^redis \{/;
    if ($in_redis && /^  enabled = (?:true|false)/) {
      s|^  enabled = true|  enabled = false|;
      $in_redis = 0;
      $seen_redis = 1;
    }
    $in_redis = 0 if /^\}/;

    # The match is coupled to exact indentation and spacing. If upstream ever
    # reformats the file it would silently miss, leaving LuckPerms dialling a
    # Redis host that does not exist -- the precise failure this script exists
    # to remove. Refuse to exit 0 on that.
    END {
      our $seen_redis;
      die "redis `enabled` line never matched -- file reformatted?\n"
        unless $seen_redis;
    }
  ' "$conf"
done

# Prove the result rather than assuming it. The CRLF check is the one that
# matters most: it catches the next person who reaches for `sed -i` here.
for conf in "${confs[@]}"; do
  cr=$(tr -cd '\r' < "$conf" | wc -c)
  lf=$(tr -cd '\n' < "$conf" | wc -c)
  if [ "$cr" -ne "$lf" ]; then
    printf 'CRLF damaged in %s: CR=%s LF=%s\n' "$conf" "$cr" "$lf" >&2
    exit 1
  fi
  if grep -qF '${LUCKPERMS' "$conf"; then
    printf 'placeholders remain in %s\n' "$conf" >&2
    exit 1
  fi
  # messaging-service needs its own check. Every other rewritten setting either
  # carried a ${LUCKPERMS...} placeholder, caught by the test above, or is the
  # redis `enabled` line, caught by the END assertion. This one went from
  # "redis" to "sql" with no placeholder either side, so a reformat that made
  # the pattern miss would leave the file still selecting the Redis messenger
  # while the redis block is disabled -- and nothing would say so. Asserting
  # the post-state rather than the substitution keeps it idempotent.
  if ! grep -q '^messaging-service = "sql"' "$conf"; then
    printf 'messaging-service not normalized in %s\n' "$conf" >&2
    exit 1
  fi
done

printf 'done: normalized and verified %d files\n' "${#confs[@]}"
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

- [ ] **Step 5b: Align the database password default across `compose.yml`**

The username half of this was standardized in Task 2; the password half was missed.
`compose.yml` gives `MARIADB_PASSWORD` the default `luckperms_password` while all seven
clients default `LUCKPERMS_DATA_PASSWORD` to `password_luckperms`. With no `.env`, the
database creates the user with one spelling and every LuckPerms client authenticates
with the other, so all seven fail to connect. Aligning the mchprs fallback in Step 5 does
not help: `compose.yml` always sets the variable, so that fallback is unreachable.

`compose.yml` is CRLF — use perl, never `sed -i`:

```bash
perl -i -pe 's|\$\{LUCKPERMS_DB_PASSWORD:-password_luckperms\}|\${LUCKPERMS_DB_PASSWORD:-luckperms_password}|g' compose.yml
```

Verify — expect `0` stale and `8` aligned (one database plus seven clients), with CRLF
intact at 448/448:

```bash
grep -cF 'password_luckperms' compose.yml
grep -cF 'luckperms_password' compose.yml
printf 'CR=%s LF=%s\n' "$(tr -cd '\r' < compose.yml | wc -c)" "$(tr -cd '\n' < compose.yml | wc -c)"
```

Then add the mirror of the existing username assertion to `tests/test-compose-config.sh`,
immediately after the `every LUCKPERMS_DB_USER default agrees` line:

```bash
# The same check for the password. This half was missed when the username was
# standardized: the database created the user with one spelling while all seven
# clients connected with the other, so a deployment with no .env came up with
# every LuckPerms client unable to authenticate.
assert_not_contains "$RAW" "password_luckperms" "no stale password_luckperms default"
DBPASS_ALL=$(printf '%s\n' "$RAW" | grep -cF '${LUCKPERMS_DB_PASSWORD:-' || true)
DBPASS_OK=$(printf '%s\n' "$RAW" | grep -cF '${LUCKPERMS_DB_PASSWORD:-luckperms_password}' || true)
if [ "$DBPASS_ALL" -gt 0 ]; then
  pass "LUCKPERMS_DB_PASSWORD defaults are present"
else
  fail "LUCKPERMS_DB_PASSWORD defaults are present" "found none at all"
fi
assert_eq "$DBPASS_OK" "$DBPASS_ALL" "every LUCKPERMS_DB_PASSWORD default agrees"
```

Run `bash tests/test-compose-config.sh`. Expected: `27 run, 0 failed`.

Then prove the assertions can fail — reintroduce the mismatch on a single client line,
re-run, and confirm two failures and a non-zero exit before restoring.

- [ ] **Step 6: Commit the parent-repo files**

The four submodule files are committed in their own repositories in Tasks 9–10.

```bash
git add scripts/normalize-luckperms-conf.sh \
  src/survival/server/config/luckperms/luckperms.conf \
  src/mchprs/Config.toml \
  compose.yml \
  tests/test-compose-config.sh
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

`src/velocity/server/plugins/luckperms/config.yml` is **CRLF (623 CR / 623 LF)**. Use
`perl -i -pe`, never `sed -i` — see the platform section in `AGENTS.md`. Patterns use
`[^\r\n]*` rather than `.*` so the carriage return is not swallowed.

This file is upstream LuckPerms' own annotated config: every setting sits between
explanatory comment lines. **Replace the placeholder lines individually, in place.** Do
not paste a contiguous YAML block over the region — that silently deletes the upstream
comments between `address:`, `database:`, and `username:`, and between the `redis:`,
`sentinel:`, `nats:`, and `rabbitmq:` blocks.

There are 19 placeholders across 5 regions. Run:

```bash
perl -i -pe '
  s|^storage-method: [^\r\n]*|storage-method: h2|;
  s|^  address: \$\{LUCKPERMS_DB_ADDRESS[^\r\n]*|  address: localhost:3306|;
  s|^  database: \$\{LUCKPERMS_DB_NAME[^\r\n]*|  database: minecraft|;
  s|^  username: \$\{LUCKPERMS_DB_USERNAME[^\r\n]*|  username: root|;
  s|^  password: \$\{LUCKPERMS_DB_PASSWORD[^\r\n]*|  password: ""|;
  s|^messaging-service: [^\r\n]*|messaging-service: sql|;

  s|^  enabled: \$\{LUCKPERMS_REDIS_ENABLED[^\r\n]*|  enabled: false|;
  s|^  address: \$\{LUCKPERMS_REDIS_ADDRESS[^\r\n]*|  address: localhost|;
  s|^  username: \$\{LUCKPERMS_REDIS_USERNAME[^\r\n]*|  username: ""|;
  s|^  password: \$\{LUCKPERMS_REDIS_PASSWORD[^\r\n]*|  password: ""|;

  s|^  enabled: \$\{LUCKPERMS_NATS_ENABLED[^\r\n]*|  enabled: false|;
  s|^  address: \$\{LUCKPERMS_NATS_ADDRESS[^\r\n]*|  address: localhost|;
  s|^  username: \$\{LUCKPERMS_NATS_USERNAME[^\r\n]*|  username: ""|;
  s|^  password: \$\{LUCKPERMS_NATS_PASSWORD[^\r\n]*|  password: ""|;

  s|^  enabled: \$\{LUCKPERMS_RABBITMQ_ENABLED[^\r\n]*|  enabled: false|;
  s|^  address: \$\{LUCKPERMS_RABBITMQ_ADDRESS[^\r\n]*|  address: localhost|;
  s|^  vhost: \$\{LUCKPERMS_RABBITMQ_VHOST[^\r\n]*|  vhost: "/"|;
  s|^  username: \$\{LUCKPERMS_RABBITMQ_USERNAME[^\r\n]*|  username: guest|;
  s|^  password: \$\{LUCKPERMS_RABBITMQ_PASSWORD[^\r\n]*|  password: guest|;
' src/velocity/server/plugins/luckperms/config.yml
```

The `redis:` and `nats:` `username`/`password` patterns are disambiguated by variable
name, not by position, so they cannot cross-match the `data:` block above them.

Add a header note above `storage-method:` recording where the real values come from. It
must be inserted, not pasted over the neighbouring comment lines:

```bash
perl -i -pe '
  if (s|^storage-method: h2|#\r\n# Connection settings come from LUCKPERMS_* environment variables in\r\n# compose.yml, which LuckPerms resolves ahead of this file. Do not add\r\n# connection settings here.\r\nstorage-method: h2|) { }
' src/velocity/server/plugins/luckperms/config.yml
```

Verify — no placeholders left, CRLF intact, and the upstream comments still present:

```bash
grep -c '\${LUCKPERMS' src/velocity/server/plugins/luckperms/config.yml
printf 'CR=%s LF=%s\n' \
  "$(tr -cd '\r' < src/velocity/server/plugins/luckperms/config.yml | wc -c)" \
  "$(tr -cd '\n' < src/velocity/server/plugins/luckperms/config.yml | wc -c)"
grep -c '^#' src/velocity/server/plugins/luckperms/config.yml
git diff --stat src/velocity/server/plugins/luckperms/config.yml
```

Expected: `0` placeholders; CR and LF equal and **4 higher than 623** (627/627) because
the inserted note adds four lines (a bare `#` separator plus three of prose); the `^#`
comment count goes **387 → 391**, increasing by exactly those four, so no upstream
comment is lost; and the diff shows roughly 24 changed lines, not 600. A diff of several hundred lines means the whole file was
rewritten with the wrong line endings — revert and use perl.

Also confirm the `sentinel:` sub-block is untouched, since it never held placeholders:

```bash
grep -A6 '  sentinel:' src/velocity/server/plugins/luckperms/config.yml
```

Expected: `enabled: false`, `master: mymaster`, `addresses:`, `- localhost:26379`,
`username: ""`, `password: ""` — exactly as before.

- [ ] **Step 3: Fix the trailing-newline loss in `render_env_placeholders`**

`src/velocity/entrypoint.sh` is LF-only (0 CR / 78 LF) — keep it that way.

The function reads the file with `content=$(cat "$file")` and writes it back with
`printf '%s'`. Command substitution strips **every** trailing newline and `printf '%s'`
does not put one back, so rendering a file silently drops its final line terminator.
Measured **inside the image** on a two-line CRLF fixture: 14 bytes in, 13 out, LF 2→1,
**CR unchanged at 2** — the file comes back ending in a dangling bare CR with mixed
endings.

Measure this in the container, not in Git Bash. Git Bash's `$(cat)` also eats the CR
because of its text-mode reads, which yields 12 bytes and CR 2→1 — plausible-looking
numbers for a script that does not run there. An earlier draft of this plan carried
exactly those figures.

Note this is narrower than what `AGENTS.md` describes for `sed`, which strips the CR
from *every* line. Here one final LF is lost.

Replace:

```bash
  content=$(cat "$file")
```

with:

```bash
  # Preserve the file's trailing newline. A bare $(cat "$file") strips it and
  # `printf '%s'` does not put it back. Measured inside the image on a 14-byte
  # CRLF fixture: 14 bytes in, 13 out, LF 2->1, CR unchanged -- so the file
  # comes back ending in a dangling bare CR with mixed endings. The sentinel
  # byte restores it exactly.
  #
  # `&&`, not `;`. With `;` the substitution takes printf's exit status, which
  # is always 0, so a missing or unreadable file would NOT trip `set -e`: the
  # function would fall through with content="", truncate the file to zero
  # bytes, and let the server start on it.
  content=$(cat "$file" && printf x); content="${content%x}"
```

- [ ] **Step 4: Apply the seeding policy to the Velocity entrypoint**

In `src/velocity/entrypoint.sh`, replace everything from the line `echo "Injecting secrets..."` to the end of the file with:

```bash
echo "Injecting secrets..."

# velocity.toml points at forwarding-secret-file and holds no secret itself.
# Rendered anyway so a placeholder added later works on a FRESH volume -- note
# it will not reach an existing one, because velocity.toml is seed-if-absent
# below.
render_env_placeholders "$CONFIG_DIR/velocity.toml"
render_env_placeholders "$CONFIG_DIR/forwarding.secret"

echo "Secrets injected successfully."

# Image-controlled: the image owns the plugin jars and the configs it ships
# beside them -- plugins/bStats/config.txt, plugins/luckperms/config.yml and
# plugins/viaversion/config.yml -- so edits to THOSE do not survive a restart.
# Anything the image does not ship, such as plugins/viabackwards/config.yml,
# is left alone. Any other top-level jar is removed, not merely shadowed.
#
# Clearing the jars first is what makes an UPGRADE work. Jar filenames carry
# the version, so a bump is a rename, and copying without deleting would leave
# both versions in the folder for Velocity to load as duplicate plugin ids.
# The glob is top-level only, so runtime state like plugins/viabackwards/ and
# plugins/luckperms/libs/ survives.
mkdir -p /server/plugins
rm -f /server/plugins/*.jar
cp -a "$CONFIG_DIR/plugins/." /server/plugins/

# Always rewritten so secret rotation propagates. This lands on container
# recreate -- which a changed .env forces -- rather than on a bare
# `docker restart`, where the rendered copy holds no token left to re-render.
cp -a "$CONFIG_DIR/forwarding.secret" /server/forwarding.secret

# Admin-editable over WebDAV: seeded only when absent, so operators can add
# backend servers to velocity.toml without losing the change on restart.
[ -f /server/velocity.toml ] || cp -a "$CONFIG_DIR/velocity.toml" /server/velocity.toml
[ -f /server/server-icon.png ] || cp -a "$CONFIG_DIR/server-icon.png" /server/server-icon.png

echo "Copying complete. Starting Velocity..."

# Hand off to the base image's CMD. itzg/mc-proxy declares
# ENTRYPOINT ["/__cacert_entrypoint.sh"] and CMD ["/usr/bin/run-bungeecord.sh"],
# and src/velocity/Dockerfile overrides ONLY the CMD, with this script. So the
# cacert entrypoint has already run and exec'd us, and this line resumes the
# chain where that override interrupted it.
#
# The base image's HEALTHCHECK is inherited because this Dockerfile declares
# none of its own. That holds however CMD or ENTRYPOINT are overridden -- it is
# NOT a consequence of overriding CMD rather than ENTRYPOINT. Verified:
# irc-minecraft-lobby, irc-minecraft-onboarding and irc-minecraft-survival all
# REPLACE the entrypoint and still report the base mc-health check. AGENTS.md
# item 2 spells this out.
#
# "$@" forwards anything appended at `docker run`, and expands to nothing when
# there is nothing to forward.
exec /usr/bin/run-bungeecord.sh "$@"
```

Three things to note about this rewrite:

- `render_env_placeholders "$CONFIG_DIR/plugins/luckperms/config.yml"` is REMOVED, because after Step 2 that file no longer contains placeholders. Confirm nothing else regressed: `velocity.toml` has no `${...}` tokens and `forwarding.secret` is exactly `${VELOCITY_SECRET}` and is still rendered.
- The old `cp -a /usr/src/init_data/plugins /server/plugins` is replaced by `mkdir -p` plus `cp -a "$CONFIG_DIR/plugins/." /server/plugins/`. The old form copies the directory INTO an existing `/server/plugins`, producing `/server/plugins/plugins`. The live volume already carries ~9 MB of that damage from before this fix; the fix stops it recurring but does not clean it up.
- `rm -f /server/plugins/*.jar` is what makes a plugin **upgrade** work. Verified on a fixture: renaming `Plugin-1.0.jar` to `Plugin-1.1.jar` in the image and re-running the copy alone leaves BOTH jars in the volume, which Velocity would load as duplicate plugin ids. With the `rm -f`, only the new jar remains, while `plugins/viabackwards/` and the nested `plugins/luckperms/libs/*.jar` survive — the glob is top-level only.

Everything above `echo "Injecting secrets..."` — the shebang, `set -e`, `CONFIG_DIR`, and the whole `render_env_placeholders` function — must otherwise be preserved byte for byte.

- [ ] **Step 5: Assert the wiring in the test suite**

Nothing currently fails if velocity's whole `LUCKPERMS_*` block is deleted — the suite
only checks velocity for `restart: unless-stopped`. Add the substance.

First, the database NAME. `LUCKPERMS_DB` is the third member of the credential family
alongside `LUCKPERMS_DB_USER` and `LUCKPERMS_DB_PASSWORD`, and it is the only one with
no guard. Insert after the `every LUCKPERMS_DB_PASSWORD default agrees` line in
`tests/test-compose-config.sh`:

```bash
# The database NAME, the third member of the credential family. luckperms-db
# creates MARIADB_DATABASE from ${LUCKPERMS_DB:-...} and eight clients connect
# to ${LUCKPERMS_DB:-...}; a drift between them fails only when .env is absent,
# which is exactly how the username and password mismatches went unnoticed.
DBNAME_ALL=$(printf '%s\n' "$RAW" | grep -cF '${LUCKPERMS_DB:-' || true)
DBNAME_OK=$(printf '%s\n' "$RAW" | grep -cF '${LUCKPERMS_DB:-luckperms}' || true)
if [ "$DBNAME_ALL" -gt 0 ]; then
  pass "LUCKPERMS_DB defaults are present"
else
  fail "LUCKPERMS_DB defaults are present" "found none at all"
fi
assert_eq "$DBNAME_OK" "$DBNAME_ALL" "every LUCKPERMS_DB default agrees"
```

Then, after the `velocity has a restart policy` line:

```bash
# Velocity must reach the SHARED database like every backend. Without these
# variables LuckPerms falls back to the config file's inert `h2`, and the proxy
# silently runs on a private H2 file whose permissions diverge from everyone
# else's -- with no error anywhere to say so.
assert_contains "$VELOCITY" "LUCKPERMS_STORAGE_METHOD: mariadb" "velocity uses shared storage"
assert_contains "$VELOCITY" "LUCKPERMS_DATA_ADDRESS: luckperms-db:3306" "velocity points at the shared database"
assert_contains "$VELOCITY" "LUCKPERMS_MESSAGING_SERVICE: sql" "velocity uses sql messaging"

# The credentials are the quiet half. With the three above but these missing,
# LuckPerms reaches the right HOST and then falls back to the config file for
# the rest -- database "minecraft", user "root", empty password -- which is the
# same silent divergence, just one layer down. `every LUCKPERMS_DB default
# agrees` does not backstop this: it is self-relative, so deleting a consumer
# lowers both counts equally and stays green.
assert_contains "$VELOCITY" "LUCKPERMS_DATA_DATABASE: luckperms" "velocity uses the shared database name"
assert_contains "$VELOCITY" "LUCKPERMS_DATA_USERNAME: luckperms_user" "velocity uses the shared database user"
assert_contains "$VELOCITY" "LUCKPERMS_DATA_PASSWORD: luckperms_password" "velocity uses the shared database password"
```

Run `bash tests/test-compose-config.sh`. Expected: `35 run, 0 failed`.

Prove the assertions can fail before trusting them. Three separate controls, because
each catches a different failure:

- deleting velocity's whole `LUCKPERMS_*` block → `35 run, 6 failed`
- deleting **only** the three credential lines, leaving storage method, address and
  messaging in place → `35 run, 3 failed`. This is the case that was silently green
  before the credential assertions existed: LuckPerms reaches the right host and then
  quietly uses the config file's `minecraft` / `root` / empty password.
- changing one client's `${LUCKPERMS_DB:-luckperms}` to a different default →
  `every LUCKPERMS_DB default agrees / expected '9', got '8'`

Note the needles are not unique stack-wide — `LUCKPERMS_DATA_ADDRESS: luckperms-db:3306`
appears seven times in the rendered config. The assertions are scoped by
`service_block velocity "$CONFIG"`, which returns only velocity's block, so removing the
line from velocity alone still fails. Restore `compose.yml` after each control and
confirm CR=458 LF=458.

- [ ] **Step 6: Rebuild and verify Velocity joins shared storage**

```bash
docker compose up -d --build velocity
sleep 45
docker compose logs velocity | grep -i "Resolved configuration value from environment variable"
```

Expected: lines including `LUCKPERMS_STORAGE_METHOD = mariadb` and `LUCKPERMS_DATA_ADDRESS = luckperms-db:3306`.

- [ ] **Step 7: Verify no H2 database was created**

```bash
docker compose exec velocity sh -c 'ls /server/plugins/luckperms/ 2>/dev/null | grep -i h2 || echo NO_H2'
```

Expected: `NO_H2` on a fresh volume.

**On a volume that has booted before this fix, expect to see `luckperms-h2-v2.mv.db`
instead, and that is not a failure.** The `/server` volume is persistent and carries the
H2 file created back when `storage-method` rendered to the literal `h2` — the very bug
this task fixes. Distinguish a stale artifact from a live one by its timestamp and by
what the boot actually loaded, not by its presence:

```bash
docker inspect velocity --format '{{.State.StartedAt}}'
docker compose exec velocity sh -c 'ls -la --time-style=full-iso /server/plugins/luckperms/'
docker compose logs velocity | grep -E 'Loading storage provider|Loading messaging service'
docker compose logs velocity | grep -ci 'h2'
```

The file is stale if its mtime predates `StartedAt`, the log says
`Loading storage provider... [MARIADB]` and `Loading messaging service... [SQL]`, and the
h2 grep count is `0`. Leave it alone — it is inert data on a live volume, and deleting it
is an operator decision, not part of this task.

- [ ] **Step 8: Commit**

```bash
git add compose.yml src/velocity/server/plugins/luckperms/config.yml \
  src/velocity/entrypoint.sh tests/test-compose-config.sh
git commit -m "fix: connect velocity luckperms to shared storage and seed config safely"
```

---

## Task 8: Survival entrypoint seeding policy

**Files:**
- Modify: `src/survival/Dockerfile`
- Modify: `src/survival/entrypoint.sh`

- [ ] **Step 1: Remove the unrendered config copy from the Dockerfile**

`src/survival/Dockerfile` stages a **second, unrendered** copy of
`FabricProxy-Lite.toml` into `/config/`:

```dockerfile
FROM alpine:latest AS builder

COPY --chmod=644 ./server/config/FabricProxy-Lite.toml /FabricProxy-Lite.toml
...
COPY --from=builder --chmod=644 ./FabricProxy-Lite.toml /config/FabricProxy-Lite.toml
```

The itzg image treats `/config` as a directory to sync into `/data/config` on every
start — its log says so explicitly: `[init] Copying any configs from /config to
/data/config`. That copy holds the literal `secret = "${VELOCITY_SECRET}"`, so if it
lands it overwrites the file the entrypoint just rendered and **every backend server
fails Velocity forwarding authentication**.

Today it does not land, because the copy fails:

```
WARN : Failed to visit file /config/FabricProxy-Lite.toml due to AccessDeniedException
```

**The forwarding secret is therefore working by accident.** The failure appears to be a
Docker Desktop on Windows quirk — the container runs as uid 0 and still cannot read a
644 root-owned file — and on the Linux deployment host that copy would most likely
succeed, breaking proxy auth with an opaque error. `survival` is also the only one of
the five Fabric servers that does this; `lobby`, `onboarding`, `project-0` and
`project-1` have no `/config` copy at all, which is a further sign it was unintentional.

Delete the `builder` stage and the `COPY --from=builder` line. The stage exists solely
to stage that one file. The result should read:

```dockerfile
FROM itzg/minecraft-server:latest

ENV TYPE=FABRIC
ENV EULA=TRUE
ENV ONLINE_MODE=FALSE
ENV VERSION=1.21.8

# Copy server files (they will take on default permissions)
WORKDIR /usr/src/init_data
COPY ./server .
RUN chown -R minecraft:minecraft . && \ 
    find . -type d -exec chmod 755 {} + && \
    find . -type f -exec chmod 644 {} +

WORKDIR /

# Copy the entrypoint script and make it executable
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 25565

ENTRYPOINT ["/entrypoint.sh"]
```

This matches the other four servers' Dockerfiles. The entrypoint already renders
`FabricProxy-Lite.toml` and seeds it into `/data/config`, which is the only copy the
server needs.

Verify afterwards that the warning is gone and the secret still renders:

```bash
docker compose -f compose.yml up -d --build volume_init luckperms-db survival
sleep 90
docker compose -f compose.yml logs survival | grep -ci 'accessdenied'
docker compose -f compose.yml exec -T survival grep '^secret' /data/config/FabricProxy-Lite.toml
```

Expected: `0` AccessDenied warnings, and `secret = "velocity_secret"` — matching
`VELOCITY_SECRET` in `.env`, not the literal `${VELOCITY_SECRET}`.

- [ ] **Step 2: Fix the trailing-newline loss in `render_env_placeholders`**

`src/survival/entrypoint.sh` carries its own copy of the same function fixed in Task 7,
with the same defect. It reads the file with `content=$(cat "$file")` and writes it back
with `printf '%s'`. Command substitution strips **every** trailing newline and
`printf '%s'` does not restore one, so rendering a file silently drops its final line
terminator — measured **inside the image** on a two-line CRLF fixture: 14 bytes in, 13
out, LF 2→1, **CR unchanged at 2**, leaving a dangling bare CR. (Git Bash reports 12
bytes and CR 2→1 because its `$(cat)` eats the CR too; measure in the container.)

This function renders `FabricProxy-Lite.toml`, which carries the Velocity forwarding
secret. That file happens to end without a trailing newline today (CR=4 LF=4 across five
lines), so nothing is being lost right now — but a stray byte difference in the secret
file between the proxy and a backend breaks forwarding authentication in a way that is
very hard to diagnose, so the latent bug is not one to leave in place.

In `src/survival/entrypoint.sh` (LF-only — keep it LF), replace:

```bash
  content=$(cat "$file")
```

with:

```bash
  # Preserve the file's trailing newline. A bare $(cat "$file") strips it and
  # `printf '%s'` does not put it back. Measured inside the image on a 14-byte
  # CRLF fixture: 14 bytes in, 13 out, LF 2->1, CR unchanged -- so the file
  # comes back ending in a dangling bare CR with mixed endings. The sentinel
  # byte restores it exactly.
  #
  # `&&`, not `;`. With `;` the substitution takes printf's exit status, which
  # is always 0, so a missing or unreadable file would NOT trip `set -e`: the
  # function would fall through with content="", truncate the file to zero
  # bytes, and let the server start on it.
  content=$(cat "$file" && printf x); content="${content%x}"
```

- [ ] **Step 3: Apply the seeding policy**

In `src/survival/entrypoint.sh`, replace everything from the line `echo "Injecting secrets..."` to the end of the file with:

```bash
echo "Injecting secrets..."

# FabricProxy-Lite has no environment-variable support, so it is templated.
# luckperms.conf is NOT templated: its connection settings come from
# LUCKPERMS_* variables, which LuckPerms resolves ahead of the file.
#
# ROTATION CAVEAT. This renders the IMAGE's copy. FabricProxy-Lite.toml is both
# secret-bearing and admin-editable, and the seeding below resolves that
# conflict in favour of admin-editable -- so on a volume that has already
# booted, a rotated VELOCITY_SECRET never reaches /data/config. velocity's own
# forwarding.secret IS re-copied unconditionally, so after a rotation the proxy
# moves to the new secret while every Fabric backend keeps the old one, and the
# only symptom is backends refusing connections.
#
# To rotate: change VELOCITY_SECRET, delete /data/config/FabricProxy-Lite.toml
# on every backend, then RECREATE the containers. `docker compose restart` is
# NOT enough. This renders the image's own copy in place, in the container's
# writable layer, so after a first boot that copy holds an already-rendered
# secret with no ${VELOCITY_SECRET} token left in it. A bare restart therefore
# re-seeds the OLD secret from it, silently.
render_env_placeholders "$CONFIG_DIR/FabricProxy-Lite.toml"

echo "Secrets injected successfully."

echo "Seeding /data..."

# Image-controlled: the image owns the mod set, so a mod dropped into
# /data/mods by hand is removed rather than merely shadowed.
#
# Clearing the jars first is what makes an UPGRADE work. Mod filenames carry
# the version, so a bump is a rename, and copying without deleting leaves BOTH
# jars in /data/mods -- which Fabric refuses to start on, as duplicate mod ids.
# Verified on a fixture: renaming fabric-api-0.136.1+1.21.8.jar to
# fabric-api-0.137.0+1.21.8.jar in the image and re-running the copy alone
# yields both. The glob is top-level only, so any per-mod state directory
# under /data/mods survives.
mkdir -p /data/mods
rm -f /data/mods/*.jar
cp -a /usr/src/init_data/mods/. /data/mods/

# Admin-editable over WebDAV: seeded only when absent so edits survive restarts.
#
# --update=none rather than -n: coreutils 9.x warns that "behavior of -n is
# non-portable and may change in future", and this flag is the entire
# load-bearing mechanism of the seed-if-absent policy -- not somewhere to rely
# on a spelling upstream has reserved the right to redefine. Verified
# equivalent in this image (coreutils 9.4): an edited file is preserved, a
# missing one is copied, and no warning is emitted.
mkdir -p /data/config
cp -a --update=none /usr/src/init_data/config/. /data/config/
[ -f /data/server.properties ] || cp -a /usr/src/init_data/server.properties /data/server.properties

# world/ is deliberately never touched here. This server's world is
# player-owned state. Contrast with lobby, whose world is a code artifact
# re-synced from the image on every start -- and see AGENTS.md item 4 for why
# onboarding follows that same policy without yet being in that state.

echo "Initialization complete. Starting server..."

# Hand off to the base image's own entrypoint. itzg/minecraft-server declares
# ENTRYPOINT ["/image/scripts/start"] and NO CMD (verified with docker image
# inspect: Cmd=[]), and this server's Dockerfile replaces that ENTRYPOINT with
# this script -- so nothing starts the server unless this line does.
#
# "$@" matters: /image/scripts/start ends in `exec ... start-configuration "$@"`,
# so it forwards arguments onward. Dropping them here severs a path the base
# image supports, and a CMD added to the Dockerfile, or arguments appended to
# `docker run`, would be discarded in silence. Safe when empty -- bash does not
# treat an unset "$@" as an unbound variable under `set -u`.
exec /image/scripts/start "$@"
```

- [ ] **Step 4: Verify config edits now survive a restart**

```bash
docker compose up -d --build survival
sleep 60
docker compose exec survival sh -c 'sed -i "s|^disconnectMessage = .*|disconnectMessage = \"ADMIN_EDIT_PROBE\"|" /data/config/FabricProxy-Lite.toml'
docker compose exec survival sh -c 'echo "adminonly = true" > /data/config/zz-admin-probe.toml'
docker compose restart survival
sleep 75
docker compose exec survival sh -c 'grep "^disconnectMessage" /data/config/FabricProxy-Lite.toml'
docker compose exec survival sh -c 'cat /data/config/zz-admin-probe.toml 2>/dev/null || echo GONE'
```

Expected: `disconnectMessage = "ADMIN_EDIT_PROBE"` and `adminonly = true`. Before this
change the unconditional `cp -a` would have reverted both.

**Probe with a value edit and a new file, never an appended comment.**
`FabricProxy-Lite` owns this TOML and rewrites it through night-config on load and again
at JVM shutdown, which discards comments. An appended `# edited` line therefore vanishes
within about ten seconds of boot no matter what the entrypoint does, and tells you
nothing about the seeding policy. An earlier draft of this step used exactly that probe
and read its failure as a policy failure.

If the result ever looks ambiguous, compare byte shapes. The image's rendered copy is
CRLF with no trailing newline (172 bytes, CR=4 LF=4); the live file after the mod has
loaded is LF-only with one (169 bytes, CR=0 LF=5). `cp -a` copies bytes verbatim and
cannot perform that conversion, so an LF-only live file proves the mod wrote it and the
entrypoint did not.

Restore the probe state so the volume is left clean:

```bash
docker compose exec survival sh -c 'sed -i "s|^disconnectMessage = .*|disconnectMessage = \"This server requires you to connect with Velocity.\"|" /data/config/FabricProxy-Lite.toml; rm -f /data/config/zz-admin-probe.toml'
```

- [ ] **Step 5: Verify mods are still re-synced**

```bash
docker compose exec survival sh -c 'rm -f /data/mods/spark-1.10.142-fabric.jar'
docker compose restart survival
sleep 60
docker compose exec survival sh -c 'ls /data/mods/spark-1.10.142-fabric.jar'
```

Expected: the path is listed — the image restored it.

Then verify the other half, that a jar the image does **not** ship is removed rather than
left to accumulate. This is what makes an upgrade work, since a version bump is a rename:

```bash
docker compose exec survival sh -c 'touch /data/mods/stale-mod-0.0.1.jar'
docker compose restart survival
sleep 60
docker compose exec survival sh -c 'ls /data/mods/stale-mod-0.0.1.jar 2>/dev/null || echo REMOVED'
docker compose exec survival sh -c 'ls -1 /data/mods/*.jar | wc -l'
```

Expected: `REMOVED`, and a jar count of `8` — matching `src/survival/server/mods/`
exactly. If the stale jar survives, the `rm -f` line is missing and a future mod upgrade
will leave two versions of the same mod in place, which Fabric refuses to start on.

- [ ] **Step 6: Commit**

```bash
git add src/survival/Dockerfile src/survival/entrypoint.sh
git commit -m "fix: seed survival config without clobbering admin edits"
```

Note the `Dockerfile` — Step 1 modifies it, and an earlier draft of this step omitted it,
which would have left the unrendered-config-copy fix uncommitted.

---

> **Deliberately out of scope: `src/mchprs/entrypoint.sh`.** It carries a third copy of
> `render_env_placeholders` still using the bare `content=$(cat "$file")`. This is a
> considered decline, not an oversight. That form is a plain assignment, so the
> substitution's exit status *is* the assignment's and `set -e` fires normally — only
> the `;`-sentinel variant broke that. And `src/mchprs/Config.toml` is LF-only
> (CR=0 LF=31) ending without a trailing newline, so the missing sentinel costs nothing.
> The divergence is cosmetic. Revisit only if that file gains a trailing newline or
> becomes CRLF.

## Task 9: Lobby and onboarding entrypoints

**Files:**
- Modify: `src/lobby/entrypoint.sh`
- Modify: `src/onboarding/entrypoint.sh`

These two repositories currently share a byte-identical entrypoint that injects the Velocity secret with `sed`, which silently corrupts any secret containing `/`, `&`, or `\`. They also copy `world/` unconditionally — **which is correct and must be preserved**, because those worlds are code artifacts.

**Line endings:** both `entrypoint.sh` files are LF-only today (`CR=0 LF=19`), and
writing them as LF keeps them that way — but **not** because of `.gitattributes`. These
are separate repositories: the parent's `*.sh text eol=lf` rule does not reach inside a
submodule, and neither `src/lobby` nor `src/onboarding` carries a `.gitattributes` of
its own. Verified — `git -C src/lobby check-attr text eol -- entrypoint.sh` reports both
attributes as `unspecified`. What actually holds the line is `core.autocrlf=false`
(parent, submodule and global alike) plus the files already being LF in the index.
Verify after writing with `tr -cd '\r' < file | wc -c` returning `0`. Do not generalize
that to other files: the Dockerfiles are genuinely mixed (`lobby` 24/24 and `onboarding`
29/29 are CRLF, while `survival`, `project-0` and `project-1` are LF-only), and the
`luckperms.conf` files are CRLF at 684/684. This task touches neither.

**`set -euo pipefail` here, `set -e` in the siblings.** The divergence is deliberate
rather than an oversight: `survival`, `velocity` and `mchprs` were written and reviewed
with `set -e` and are not in scope for this task. `-u` is safe in this function — bash
leaves an unmatched optional group in `BASH_REMATCH` as an empty string, not unset, so
`${BASH_REMATCH[3]}` does not abort on `${VELOCITY_SECRET}`, which carries no
`:-default` clause. Verified inside `irc-minecraft-lobby:latest` (bash 5.2.21, coreutils
9.4): the match reports `n=4 g1=[VELOCITY_SECRET] g3=[]`. Harmonizing the other three is
left to Task 19.

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

  # Preserve the file's trailing newline. A bare $(cat "$file") strips it and
  # `printf '%s'` does not put it back. Measured inside the image on a 14-byte
  # CRLF fixture: 14 bytes in, 13 out, LF 2->1, CR unchanged -- so the file
  # comes back ending in a dangling bare CR with mixed endings. The sentinel
  # byte restores it exactly.
  #
  # This is defensive here: the only file this script renders,
  # FabricProxy-Lite.toml, ends WITHOUT a trailing newline (175 bytes, CR=4 LF=4
  # across five lines), so nothing is lost today. It is kept because that file
  # carries the forwarding secret, and a stray byte in a secret breaks auth
  # invisibly. velocity's copy of this function renders velocity.toml, which is
  # CRLF-terminated and genuinely hit this.
  #
  # `&&`, not `;`. With `;` the substitution takes printf's exit status, which
  # is always 0, so a missing or unreadable file would NOT trip `set -e`: the
  # function would fall through with content="", truncate the file to zero
  # bytes, and let the server start on it.
  content=$(cat "$file" && printf x); content="${content%x}"
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
#
# ROTATION CAVEAT. This renders the IMAGE's copy. FabricProxy-Lite.toml is both
# secret-bearing and admin-editable, and the seeding below resolves that
# conflict in favour of admin-editable -- so on a volume that has already
# booted, a rotated VELOCITY_SECRET never reaches /data/config. velocity's own
# forwarding.secret IS re-copied unconditionally, so after a rotation the proxy
# moves to the new secret while every Fabric backend keeps the old one, and the
# only symptom is backends refusing connections.
#
# To rotate: change VELOCITY_SECRET, delete /data/config/FabricProxy-Lite.toml
# on every backend, then RECREATE the containers. `docker compose restart` is
# NOT enough. This renders the image's own copy in place, in the container's
# writable layer, so after a first boot that copy holds an already-rendered
# secret with no ${VELOCITY_SECRET} token left in it. A bare restart therefore
# re-seeds the OLD secret from it, silently.
render_env_placeholders "$CONFIG_DIR/FabricProxy-Lite.toml"

echo "Secrets injected successfully."

echo "Seeding /data..."

# Image-controlled: the image owns the mod set, so a mod dropped into
# /data/mods by hand is removed rather than merely shadowed.
#
# Clearing the jars first is what makes an UPGRADE work. Mod filenames carry
# the version, so a bump is a rename, and copying without deleting leaves BOTH
# jars in /data/mods -- which Fabric refuses to start on, as duplicate mod ids.
# Verified on a fixture: renaming fabric-api-0.136.1+1.21.8.jar to
# fabric-api-0.137.0+1.21.8.jar in the image and re-running the copy alone
# yields both. The glob is top-level only, so any per-mod state directory
# under /data/mods survives.
mkdir -p /data/mods
rm -f /data/mods/*.jar
cp -a /usr/src/init_data/mods/. /data/mods/

# Image-controlled BY DESIGN, per AGENTS.md item 4: this world is a code
# artifact, republished by rebuilding the image rather than allowed to drift.
# Do not convert this to seed-if-absent.
#
# The two servers that share this file are NOT in the same state, and the
# difference matters before anyone commits a world here:
#   - lobby ships a published build (21 tracked files under server/world) and
#     runs gamemode=adventure with force-gamemode=true, so players cannot
#     modify blocks and overwriting costs nothing.
#   - onboarding ships an EMPTY server/world holding only .gitkeep, and runs
#     gamemode=survival. Nothing re-syncs its world, so the volume holds the
#     only copy -- a disposable placeholder, by maintainer decision recorded in
#     AGENTS.md item 5, which is why it is not backed up. Publishing a real
#     world into src/onboarding/server/world is the intended end state, and it
#     makes this server the same case as lobby, including the part where the
#     image overwrites whatever players changed.
#
# This is a MERGE, not a replace: cp overwrites what the image ships and leaves
# everything else alone, so a region file the image no longer carries survives
# in the volume. Delete-first would fix that and is deliberately NOT done here:
# it is only safe on a server whose image ships the world that server owns.
# lobby qualifies. onboarding does not, and will not until a real world is
# published into src/onboarding/server/world -- until then delete-first means
# rm -rf /data/world followed by restoring a lone .gitkeep, so the server would
# regenerate its world from scratch on every restart, which presents as a
# corruption bug rather than as a policy. Revisit when that world is published,
# or sooner if orphaned region files start to matter.
#
# mkdir -p runs as root, and it is the cp -a below that resets this directory's
# owner to minecraft from the image copy. Dropping that cp -- it looks like a
# no-op on onboarding, which copies only .gitkeep -- would leave /data/world
# root-owned and unwritable by the server on any boot AFTER THE FIRST, because
# itzg's start script chowns /data only when /data's own owner differs from
# $UID. On a fresh volume that chown still fires and masks the problem, which
# is what would make it a nasty one to diagnose.
mkdir -p /data/world
cp -a /usr/src/init_data/world/. /data/world/

# Admin-editable over WebDAV: seeded only when absent so edits survive restarts.
#
# --update=none rather than -n: coreutils 9.x warns that "behavior of -n is
# non-portable and may change in future", and this flag is the entire
# load-bearing mechanism of the seed-if-absent policy -- not somewhere to rely
# on a spelling upstream has reserved the right to redefine. Verified
# equivalent in this image (coreutils 9.4): an edited file is preserved, a
# missing one is copied, and no warning is emitted.
#
# The policy has no removal story, and that is inherent rather than a bug:
# seed-if-absent only ever adds, so a config file the image stops shipping stays
# in /data/config forever. Retiring one means deleting it on each volume.
mkdir -p /data/config
cp -a --update=none /usr/src/init_data/config/. /data/config/
[ -f /data/server.properties ] || cp -a /usr/src/init_data/server.properties /data/server.properties

echo "Initialization complete. Starting server..."

# Hand off to the base image's own entrypoint. itzg/minecraft-server declares
# ENTRYPOINT ["/image/scripts/start"] and NO CMD (verified with docker image
# inspect: Cmd=[]), and this server's Dockerfile replaces that ENTRYPOINT with
# this script -- so nothing starts the server unless this line does.
#
# "$@" matters: /image/scripts/start ends in `exec ... start-configuration "$@"`,
# so it forwards arguments onward. Dropping them here severs a path the base
# image supports, and a CMD added to the Dockerfile, or arguments appended to
# `docker run`, would be discarded in silence. Safe when empty -- bash does not
# treat an unset "$@" as an unbound variable under `set -u`.
exec /image/scripts/start "$@"
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

These two repositories share a byte-identical entrypoint. Unlike lobby and onboarding they seed no `world/` at all, and their worlds are player-owned and must never be overwritten.

Audited before dispatch: both repos ship `server/config/FabricProxy-Lite.toml` (175 bytes,
CRLF 4/4, carrying `secret = "${VELOCITY_SECRET}"`), `server/config/luckperms/luckperms.conf`
already normalized to zero `${LUCKPERMS` placeholders, an identical 11-mod set, no
`server/world` directory at all, and `gamemode=creative` with `force-gamemode=true`. The two
entrypoints are byte-identical to each other and use `sed -i` for the secret, exactly as
lobby and onboarding did.

**Line endings:** both `entrypoint.sh` files are LF-only today (`CR=0 LF=18`), and writing
them as LF keeps them that way — but **not** because of `.gitattributes`. As with lobby and
onboarding, these are separate repositories: the parent's `*.sh text eol=lf` rule does not
reach inside a submodule, and neither `src/project-0` nor `src/project-1` carries a
`.gitattributes` of its own. Verified — `git -C src/project-0 check-attr text eol --
entrypoint.sh` reports both attributes as `unspecified`. What holds the line is
`core.autocrlf=false` plus the files already being LF in the index. Verify after writing with
`tr -cd '\r' < file | wc -c` returning `0`. Their Dockerfiles are also LF-only (24/24),
unlike lobby's and onboarding's, but this task does not touch them.

**`set -euo pipefail` here, `set -e` in the siblings.** Same deliberate divergence as Task 9:
`survival`, `velocity` and `mchprs` were written and reviewed with `set -e` and are not in
scope. `-u` is safe in this function — bash leaves an unmatched optional group in
`BASH_REMATCH` as an empty string, not unset, so `${BASH_REMATCH[3]}` does not abort on
`${VELOCITY_SECRET}`, which carries no `:-default` clause. Verified in-image (bash 5.2.21,
coreutils 9.4): the match reports `n=4 g1=[VELOCITY_SECRET] g3=[]`.

**No world block, and that is the point.** Do not copy Task 9's `world/` handling into this
file. These servers' worlds are player-owned state that must never be overwritten, and the
images ship nothing to overwrite them with. `/data/world` is created by the server itself
after itzg's start script has chowned `/data`, so the root-owned-directory trap documented in
Task 9 does not arise here.

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

  # Preserve the file's trailing newline. A bare $(cat "$file") strips it and
  # `printf '%s'` does not put it back. Measured inside the image on a 14-byte
  # CRLF fixture: 14 bytes in, 13 out, LF 2->1, CR unchanged -- so the file
  # comes back ending in a dangling bare CR with mixed endings. The sentinel
  # byte restores it exactly.
  #
  # This is defensive here: the only file this script renders,
  # FabricProxy-Lite.toml, ends WITHOUT a trailing newline (175 bytes, CR=4 LF=4
  # across five lines), so nothing is lost today. It is kept because that file
  # carries the forwarding secret, and a stray byte in a secret breaks auth
  # invisibly. velocity's copy of this function renders velocity.toml, which is
  # CRLF-terminated and genuinely hit this.
  #
  # `&&`, not `;`. With `;` the substitution takes printf's exit status, which
  # is always 0, so a missing or unreadable file would NOT trip `set -e`: the
  # function would fall through with content="", truncate the file to zero
  # bytes, and let the server start on it.
  content=$(cat "$file" && printf x); content="${content%x}"
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
#
# ROTATION CAVEAT. This renders the IMAGE's copy. FabricProxy-Lite.toml is both
# secret-bearing and admin-editable, and the seeding below resolves that
# conflict in favour of admin-editable -- so on a volume that has already
# booted, a rotated VELOCITY_SECRET never reaches /data/config. velocity's own
# forwarding.secret IS re-copied unconditionally, so after a rotation the proxy
# moves to the new secret while every Fabric backend keeps the old one, and the
# only symptom is backends refusing connections.
#
# To rotate: change VELOCITY_SECRET, delete /data/config/FabricProxy-Lite.toml
# on every backend, then RECREATE the containers. `docker compose restart` is
# NOT enough. This renders the image's own copy in place, in the container's
# writable layer, so after a first boot that copy holds an already-rendered
# secret with no ${VELOCITY_SECRET} token left in it. A bare restart therefore
# re-seeds the OLD secret from it, silently.
render_env_placeholders "$CONFIG_DIR/FabricProxy-Lite.toml"

echo "Secrets injected successfully."

echo "Seeding /data..."

# Image-controlled: the image owns the mod set, so a mod dropped into
# /data/mods by hand is removed rather than merely shadowed.
#
# Clearing the jars first is what makes an UPGRADE work. Mod filenames carry
# the version, so a bump is a rename, and copying without deleting leaves BOTH
# jars in /data/mods -- which Fabric refuses to start on, as duplicate mod ids.
# Verified on a fixture: renaming fabric-api-0.136.1+1.21.8.jar to
# fabric-api-0.137.0+1.21.8.jar in the image and re-running the copy alone
# yields both. The glob is top-level only, so any per-mod state directory
# under /data/mods survives.
mkdir -p /data/mods
rm -f /data/mods/*.jar
cp -a /usr/src/init_data/mods/. /data/mods/

# Admin-editable over WebDAV: seeded only when absent so edits survive restarts.
#
# --update=none rather than -n: coreutils 9.x warns that "behavior of -n is
# non-portable and may change in future", and this flag is the entire
# load-bearing mechanism of the seed-if-absent policy -- not somewhere to rely
# on a spelling upstream has reserved the right to redefine. Verified
# equivalent in this image (coreutils 9.4): an edited file is preserved, a
# missing one is copied, and no warning is emitted.
#
# The policy has no removal story, and that is inherent rather than a bug:
# seed-if-absent only ever adds, so a config file the image stops shipping stays
# in /data/config forever. Retiring one means deleting it on each volume.
mkdir -p /data/config
cp -a --update=none /usr/src/init_data/config/. /data/config/
[ -f /data/server.properties ] || cp -a /usr/src/init_data/server.properties /data/server.properties

# world/ is deliberately never touched here. This server's world is
# player-owned state, and the image ships no world/ to seed it from. Contrast
# with lobby, whose world IS a code artifact re-synced from the image on every
# start -- see AGENTS.md item 4.
#
# Note what follows from that: because this script never copies world/, a world
# committed into src/project-N/server/ would be baked into the image by the
# Dockerfile's `COPY ./server .` and then silently ignored -- dead weight in the
# image, no effect, no error. Publishing a world here would need a seeding line
# added as well, and would change this server's world from player-owned to
# image-owned, which is a policy decision, not a mechanical one.

echo "Initialization complete. Starting server..."

# Hand off to the base image's own entrypoint. itzg/minecraft-server declares
# ENTRYPOINT ["/image/scripts/start"] and NO CMD (verified with docker image
# inspect: Cmd=[]), and this server's Dockerfile replaces that ENTRYPOINT with
# this script -- so nothing starts the server unless this line does.
#
# "$@" matters: /image/scripts/start ends in `exec ... start-configuration "$@"`,
# so it forwards arguments onward. Dropping them here severs a path the base
# image supports, and a CMD added to the Dockerfile, or arguments appended to
# `docker run`, would be discarded in silence. Safe when empty -- bash does not
# treat an unset "$@" as an unbound variable under `set -u`.
exec /image/scripts/start "$@"
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
    curlimages/curl:latest -s -K - "$@"
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
```

- [ ] **Step 2: Bring the stack up in stages**

Six servers at `-Xmx2G` plus Velocity exceeds the host. Measured on this machine:
`docker info` reports **15.3 GiB** total, and `compose.yml` defaults each of the seven
JVMs to `${JAVA_OPTS:--Xmx2G -Xms1G}` — 14 GiB of heap before anything else. Lower it
first.

**`JAVA_OPTS` is absent from `.env` entirely.** It is in `.env.example` (line 10) but not
in the working `.env`, so the obvious `sed -i 's|^JAVA_OPTS=.*|...|' .env` matches **zero
lines and silently changes nothing** — every server then boots at the 2 GiB default and
the host thrashes or the OOM killer fires, with nothing in the output to say why. Append
when the key is missing, substitute when it is present:

```bash
if grep -q '^JAVA_OPTS=' .env; then
  perl -i -pe 's|^JAVA_OPTS=[^\r\n]*|JAVA_OPTS=-Xmx1G -Xms512M|' .env
else
  printf 'JAVA_OPTS=-Xmx1G -Xms512M\n' >> .env
fi
docker compose config | grep -m1 JAVA_OPTS
```

Expected: `JAVA_OPTS: -Xmx1G -Xms512M`. Verify this before bringing anything up — it is
the whole point of the step, and it is the one part that fails quietly.

**Use `perl -i -pe`, never `sed -i`, on `.env`.** It is a CRLF file (measured before
this step: CR=28, LF=29 — every line but the last; the `printf` above appends an
LF-only line, making it CR=28, LF=30), and on Git Bash `sed -i` strips the CR from *every*
line of the file, not just the one it rewrites. See the platform section of `AGENTS.md`.
`[^\r\n]*` rather than `.*` for the same reason: `.` matches a CR, so `.*` swallows it and
leaves that one line LF-only inside an otherwise CRLF file.

```bash
docker compose up -d --build volume_init luckperms-db luckperms-standalone webdav caddy velocity survival mchprs
sleep 90
docker compose up -d --build lobby onboarding project-0 project-1
sleep 120
docker compose ps
```

Expected: every service `running`, and `luckperms-db`, `luckperms-standalone`, and
`velocity` additionally `healthy`.

**Name the services explicitly on every `up`.** A bare `docker compose up -d` also starts
`cloudflared`, which holds a placeholder token and restart-loops. It must never be started
locally.

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

**The answer is already known: hyphenated context values ARE accepted.** Measured on
the running stack before this task was dispatched, so the probe below is written to
confirm a known result rather than to discover an unknown one. Evidence:

```
PUT /group/<g>/nodes  [{"key":"test.node","value":true,
                        "context":[{"key":"server","value":"project-0"}]}]   HTTP 200

SELECT name, permission, value, server, world FROM luckperms_group_permissions:
  ctxprobe1585   test.node   1   project-0   global

GET /group/<g>:
  {"nodes":[{"key":"test.node","type":"permission","value":true,
             "context":[{"key":"server","value":"project-0"}]}], ...}
```

So the OpenAPI schema's `^[a-z0-9]+$` is not enforced by the implementation, and
**Task 15 MAY use `server: project-0` and `server: project-1` contexts.** Write the
probe anyway: it pins the behavior, so a LuckPerms upgrade that starts enforcing the
schema fails here loudly instead of silently producing a permission model that no
longer scopes to those servers.

Match the conventions already established in `tests/test-luckperms.sh`: `tr -d '\r'`
on the `.env` extraction, and the bearer token passed through a curl config on stdin
rather than on the `docker run` argv.

```bash
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
```

- [ ] **Step 2: Run the probe and record the result**

```bash
bash tests/test-seeder.sh
```

Expected: `4 run, 0 failed`.

The outcome is already settled by the measurement recorded above — per-server contexts
ARE usable, so `permissions.yml` in Task 15 may scope nodes with `server: project-0`
and `server: project-1`.

Keep the fallback documented, because this suite exists to catch the day it changes:
**if the probe ever fails**, `permissions.yml` must not use those contexts; use the
`global` context instead and scope those servers by permission key.

Note which failure means what. The `accepted` assertion failing means the API started
enforcing the OpenAPI schema. The `persisted` or `reads back` assertion failing while
`accepted` passes is worse — it means the write is being taken and silently discarded,
so a permission model built on these contexts would look correct and apply everywhere.

Separately, remember that MCHPRS sees only the `global` and `mchprs` server contexts
(AGENTS.md, MCHPRS constraint 2). A `project-0` context is invisible to it by design;
that is not a bug and is not what this probe is about.

- [ ] **Step 3: Commit**

```bash
git add tests/test-seeder.sh
git commit -m "test: probe whether the luckperms api accepts hyphenated contexts"
```

---

## Task 14: The seeder

**The REST API contract this task depends on is measured, not assumed.** Probed against
the running stack before the task was dispatched, on `http://luckperms-standalone:8080`:

```
GET    /health                  200  {"healthy":true,"details":{"storageConnected":true,...}}
GET    /group                   200  ["onboarder","default","member","admin"]
POST   /group {"name":X}        201  {"name":X,"weight":0,"nodes":[],...}
POST   /group {"name":X} again  409  Group already exists!
GET    /group/X/nodes           200  []
PUT    /group/X/nodes [...]     200  returns the resulting node list
GET    /track/nosuchtrack       404  Track doesn't exist
POST   /track {"name":T}        201  {"name":T,"groups":[]}
GET    /track/T                 200  {"name":T,"groups":[...]}
PATCH  /track/T {"groups":[..]} 200  ok
POST   /messaging/update        202  ok
```

Four of those results are load-bearing for the code below. Do not "simplify" them away.

- **`PUT /group/X/nodes` replaces the node set wholesale.** Verified by writing four
  nodes, then writing one, and reading back exactly one. That is what makes the model
  authoritative for the groups it names, and what makes `apply_group_nodes` safe to skip
  when the two sets already match.
- **Node type is derived from the key and is never sent.** `weight.100`,
  `prefix.100.&c[A] `, `group.default` and `test.alpha` read back as types `weight`,
  `prefix`, `inheritance` and `permission`. A `type` field in the request is unnecessary.
- **`GET` omits `expiry` entirely on a non-expiring node**, which is why `node_identity`
  compares `node.get("expiry")` instead of requiring the key on both sides.
- **`PATCH /track/T` and `POST /messaging/update` return the bare string `ok`, not
  JSON.** `request()` must tolerate a non-JSON body; that is what its
  `json.JSONDecodeError` fallback is for.

`POST /group` answering 409 on a duplicate is what `ensure_group` swallows, and
`GET /track/T` answering 404 rather than 200-with-null is what `apply_track` branches on.

**A second round of probing, run during this task's quality review, found three more
normalizations that the code has to account for.** Each was measured against the same
running stack:

| Sent | Stored / returned |
| --- | --- |
| `POST /group {"name":"Admin77"}` | `{"name":"admin77"}` -- names are lowercased |
| `context: [{"key":"Server","value":"Project-0"}]` | `[{"key":"server","value":"project-0"}]` |
| `context: [{"key":"World","value":"Nether"}]` | `[{"key":"world","value":"nether"}]` |

Permission **keys** are NOT touched: `Essentials.Home` and `MCHPRS.Command` both read
back verbatim. It is names and contexts that get folded to lower case.

That matters more than it looks. The seeder decides "already correct?" by comparing what
it wants against what it reads back, so a context written as `Server: Survival` can never
equal the stored `server: survival` -- the seeder would rewrite that group on every
single deploy, push a messaging update every time, and report success forever. Hence
`build_context` lowercases before sending, and `apply_group_nodes` checks the PUT's
returned list actually converged rather than assuming it did.

Two further measurements shaped the validation:

- `POST /group {"name":"bad name77"}` -> **400 `Invalid name entry`**. The API does police
  names, so a malformed one fails loudly at creation.
- `POST /group {"name":"has#hash77"}` -> **201**, and then `DELETE /group/has#hash77` ->
  **404 with the group still present**. Everything from `#` on is a URL fragment, so that
  request actually targeted `/group/has`. `DELETE /group/has%23hash77` removed it. So the
  API's own name check is not sufficient, `NAME_RE` is deliberately stricter than it, and
  path segments are percent-encoded.

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

**Keep that file CRLF.** It is CRLF today (`git ls-files --eol` reports `i/crlf w/crlf`),
as are `src/mchprs/Dockerfile` and `src/velocity/Dockerfile`. There is no repo-wide
convention to appeal to here -- `src/survival/Dockerfile` is LF -- so preserving what the
file already has is the choice that adds no unrelated change to the diff. The hazard is
that a bash heredoc writes LF silently, which is exactly the accident the CRLF section of
`AGENTS.md` exists to warn about. Use `perl -i -pe`, or write the file and then check it.
The replacement is four CRLF-terminated lines, so both counts are 4 -- not the 2/2
the current three-line, newline-less file reports:

```bash
tr -cd '\r' < src/luckperms-standalone/Dockerfile | wc -c   # expect 4
tr -cd '\n' < src/luckperms-standalone/Dockerfile | wc -c   # expect 4
```

Both new files in this task (`src/luckperms-init/Dockerfile` and `seed.py`) are LF, which
matches everything else added on this branch.

- [ ] **Step 2: Write the seeder image**

Create `src/luckperms-init/Dockerfile`:

```dockerfile
FROM python:3.12-alpine

# Unbuffered on purpose: this runs as a compose one-shot, and with the default
# block buffering `docker compose logs luckperms-init` shows nothing at all for
# the up-to-two-minute wait_for_api poll, so an operator cannot tell waiting
# from hung. It also keeps progress output if the container is killed mid-run,
# which is the only record of how far a partial application got.
ENV PYTHONUNBUFFERED=1

# PyYAML is pinned exactly; the base image deliberately is not, so rebuilds keep
# picking up CPython 3.12 patch releases and Alpine security updates. The only
# dependency is a pure-data parser, so the exposure of a floating base is small
# and the exposure of a stale one is not.
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
set is REPLACED WHOLESALE, so the file always describes reality. Groups absent
from the file are never touched, which leaves ad-hoc groups as an escape hatch.

Operationally that means any change an admin makes in-game to a managed group
-- `/lp group admin permission set ...` -- is DESTROYED on the next
`docker compose up`. That is the intended design, not a bug. Edit
permissions.yml, not the live server, for anything that should survive a deploy.

The same rule applies within the file: a group listed with an empty spec means
"this group has no nodes", not "leave this group alone". Commenting out a
group's `permissions:` block while debugging therefore deletes those nodes on
the next run. Delete the whole group entry to stop managing it instead.

The script is idempotent. It compares desired state against actual state and
only writes when they differ, then reports how many changes it made, so a
second run reports changed=0.
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import yaml

API = os.environ.get("LUCKPERMS_API_URL", "http://luckperms-standalone:8080").rstrip("/")
KEY = os.environ.get("LUCKPERMS_SECRET")
MODEL_PATH = os.environ.get("PERMISSIONS_FILE", "/permissions.yml")

if not KEY:
    sys.exit("LUCKPERMS_SECRET is not set")

# Deliberately stricter than the API. Measured: the API rejects a space with
# 400 "Invalid name entry" and lowercases what it accepts (POST {"name":"Admin"}
# stores "admin"), but it happily accepts `#` -- and a group named `has#hash` is
# then unreachable, because everything from `#` on is a URL fragment, so
# DELETE /group/has#hash answers 404 and leaves the group sitting there.
# Requiring lowercase also keeps the `existing_names` comparison below honest.
NAME_RE = re.compile(r"^[a-z0-9._-]+$")

MODEL_KEYS = {"groups", "tracks"}
GROUP_KEYS = {"weight", "prefix", "prefix_priority", "inherits", "permissions"}
PERMISSION_KEYS = {"key", "value", "context", "expiry"}
TRACK_KEYS = {"groups"}

changes = 0


def check_keys(where, mapping, allowed):
    """Reject unrecognized keys instead of ignoring them.

    Ignoring an unknown key is unsafe here specifically because a write
    REPLACES a group's whole node set: a typo of `permisions:` for
    `permissions:` would otherwise mean "delete every permission this group
    has", push that deletion to every running server, and exit 0.
    """
    unknown = sorted(set(mapping) - allowed)
    if unknown:
        sys.exit(f"{where}: unknown key(s) {unknown}; allowed are {sorted(allowed)}")


def as_int(value, where):
    """int() with a message instead of a traceback."""
    try:
        return int(value)
    except (TypeError, ValueError):
        sys.exit(f"{where}: expected a whole number, got {value!r}")


def as_list(value, where):
    """Require a real list. A bare scalar is NOT an acceptable one-item list.

    Python strings are iterable, so `permissions: essentials.home` -- the
    brackets and dashes left off, which is an ordinary thing to type -- reads
    as ['e','s','s','e','n',...]. Measured before this guard existed: that
    wrote fifteen single-character permission nodes, one of them named `.`,
    destroyed the group's real permissions in the same breath because a write
    replaces wholesale, pushed the lot to every running server, and exited 0.
    It was then stably idempotent, so nothing would ever have flagged it.
    """
    if value is None:
        return []
    if not isinstance(value, list):
        sys.exit(
            f"{where}: must be a list, got {type(value).__name__} -- write "
            f"`[value]` or a `- value` block, never a bare scalar"
        )
    return value


def request(method, path, body=None):
    """Return (status_code, parsed_body_or_text).

    PATCH /track/X and POST /messaging/update answer with the bare string `ok`
    rather than JSON, so a non-JSON body is normal here, not exceptional.
    """
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


def seg(name):
    """Percent-encode one path segment.

    See NAME_RE: a `#` in a name silently retargets the request at a different
    path. NAME_RE rejects such names up front; this is the second line of
    defence, and it costs nothing.
    """
    return urllib.parse.quote(name, safe="")


def wait_for_api(attempts=60, delay=2):
    """Poll until the REST API answers 200, or give up.

    A 4xx is fatal immediately rather than retried. Retrying one burns the full
    two minutes and then reports "never became reachable", which points a
    misconfigured LUCKPERMS_SECRET -- a 401, and a very likely first-deploy
    failure -- squarely at the network instead.
    """
    for _ in range(attempts):
        try:
            status, body = request("GET", "/health")
            if status == 200:
                print(f"api ready: {body}")
                return
            if 400 <= status < 500:
                sys.exit(f"luckperms api rejected the health check: HTTP {status} {body}")
        except OSError:
            # urllib.error.URLError subclasses OSError, so this covers both the
            # connection-refused case during startup and a DNS failure.
            pass
        time.sleep(delay)
    sys.exit("luckperms api never became reachable")


def build_context(raw, where):
    """Turn {'server': 'survival'} into [{'key': ..., 'value': ...}].

    Lowercased to match what storage will hold. Measured: the API normalizes
    context keys AND values, so {"key":"Server","value":"Project-0"} reads back
    as {"key":"server","value":"project-0"}. Sending mixed case unchanged would
    make desired != actual on every single run, and this script would rewrite
    the same group forever while reporting success.
    """
    if not raw:
        return []
    if not isinstance(raw, dict):
        sys.exit(f"{where}: context must be a mapping, got {type(raw).__name__}")
    out = []
    for key, value in sorted(raw.items()):
        if isinstance(value, (list, dict, tuple)):
            # str() would cheerfully store "['nether', 'the_end']" -- a node
            # that matches no real context, applies to nobody, and is then
            # stably and silently wrong on every subsequent run.
            sys.exit(
                f"{where}: context '{key}' must be a single scalar value, "
                f"got {type(value).__name__}"
            )
        out.append({"key": str(key).lower(), "value": str(value).lower()})
    return out


def check_mchprs_prefixes(where, keys):
    """Reject a stored mchprs node that is a strict prefix of another.

    MCHPRS reads this database directly, and per AGENTS.md its
    PermissionNode::matches indexes the stored node's path while walking the
    queried string, so a stored `mchprs.command` checked against a queried
    `mchprs.command.tp` panics the server with an index-out-of-bounds. Two
    adjacent lines of YAML can crash a Minecraft server, and this is the one
    mechanical chokepoint where that is catchable.

    Deliberately scoped to the mchprs namespace. The same shape is ordinary
    elsewhere -- `essentials.home` alongside `essentials.home.other` is fine --
    and only MCHPRS crashes on it.

    This catches the mistake that is visible from the model, both keys present
    somewhere in one player's effective set. It CANNOT catch a lone stored
    `mchprs.command` whose queried form `mchprs.command.tp` exists only in
    MCHPRS's source, so AGENTS.md's rule -- exact keys or explicit `*`
    wildcards -- still governs when writing a model.
    """
    # A key of exactly `mchprs` is in scope too: it is a strict prefix of every
    # mchprs.* key there is, and `startswith("mchprs.")` alone would miss it.
    scoped = sorted(k for k in keys if k == "mchprs" or k.startswith("mchprs."))
    for shorter in scoped:
        if shorter.endswith("*"):
            continue
        for longer in scoped:
            if longer != shorter and longer.startswith(shorter + "."):
                sys.exit(
                    f"{where}: '{shorter}' is a strict prefix of '{longer}', "
                    f"which panics MCHPRS. Use '{shorter}.*' or drop one."
                )


def check_mchprs_closure(desired, inherits_of):
    """Run the prefix check over each group's inheritance closure.

    Per group is not enough, because MCHPRS resolves inheritance and the nodes
    from several groups land in one effective set. A `default` holding
    `mchprs.command` and an `admin` holding `group.default` plus
    `mchprs.command.tp` is a panic waiting to happen, with neither group
    tripping a per-group check on its own. The model this repository ships is
    one long inheritance chain, so that is the shape the mistake will take.

    The closure covers groups the model defines. A parent inherited from
    outside the model -- the ad-hoc escape hatch -- is invisible here. That is
    a limit worth knowing, not a reason to skip the check.

    Node contexts are deliberately ignored. Per AGENTS.md constraint 2 MCHPRS
    only sees the `global` and `mchprs` server contexts, so a prefix pair
    scoped to `server: survival` could not actually panic it and is rejected
    anyway. That over-rejection is the intended trade: the cost of filtering by
    context wrongly is a crashed Minecraft server, and the cost of rejecting
    too much is one edit to a YAML file.
    """
    for name in desired:
        keys = set()
        seen = set()
        stack = [name]
        while stack:
            current = stack.pop()
            if current in seen or current not in desired:
                continue
            seen.add(current)
            keys.update(node["key"] for node in desired[current])
            stack.extend(inherits_of.get(current, ()))
        label = f"group '{name}'"
        if len(seen) > 1:
            label += f" (with what it inherits: {', '.join(sorted(seen - {name}))})"
        check_mchprs_prefixes(label, keys)


def build_nodes(group_name, spec):
    """Expand a group spec into the flat node list LuckPerms stores.

    Node type is encoded in the key, so no separate type field is sent:
      weight.100          -> group weight
      group.member        -> inheritance
      prefix.100.&c[A]    -> prefix at priority 100
    """
    if not isinstance(spec, dict):
        sys.exit(f"group '{group_name}': spec must be a mapping, got {type(spec).__name__}")
    check_keys(f"group '{group_name}'", spec, GROUP_KEYS)

    nodes = []

    weight = spec.get("weight")
    if weight is not None:
        weight = as_int(weight, f"group '{group_name}' weight")
        nodes.append({"key": f"weight.{weight}", "value": True, "context": []})

    prefix = spec.get("prefix")
    if prefix is not None:
        # Priority defaults to the group's own weight, so a heavier group's
        # prefix wins without having to say so twice; `weight or 0` also maps
        # an absent weight onto priority 0.
        priority = as_int(
            spec.get("prefix_priority", weight or 0), f"group '{group_name}' prefix_priority"
        )
        nodes.append({"key": f"prefix.{priority}.{prefix}", "value": True, "context": []})

    for parent in as_list(spec.get("inherits"), f"group '{group_name}' inherits"):
        nodes.append({"key": f"group.{parent}", "value": True, "context": []})

    for entry in as_list(spec.get("permissions"), f"group '{group_name}' permissions"):
        if isinstance(entry, str):
            nodes.append({"key": entry, "value": True, "context": []})
            continue
        if not isinstance(entry, dict):
            sys.exit(
                f"group '{group_name}': permission entry must be a string or a "
                f"mapping, got {type(entry).__name__}"
            )
        check_keys(f"group '{group_name}' permission entry", entry, PERMISSION_KEYS)
        if "key" not in entry:
            sys.exit(f"group '{group_name}': permission entry is missing 'key': {entry}")
        node = {
            "key": entry["key"],
            "value": bool(entry.get("value", True)),
            "context": build_context(
                entry.get("context"), f"group '{group_name}' permission '{entry['key']}'"
            ),
        }
        if "expiry" in entry:
            node["expiry"] = as_int(
                entry["expiry"], f"group '{group_name}' permission '{entry['key']}' expiry"
            )
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
    status, actual = request("GET", f"/group/{seg(name)}/nodes")
    if status != 200:
        sys.exit(f"failed to read nodes for group '{name}': HTTP {status} {actual}")

    have = {node_identity(n) for n in (actual or [])}
    want = {node_identity(n) for n in desired}
    if have == want:
        print(f"group {name}: already correct ({len(want)} nodes)")
        return

    status, body = request("PUT", f"/group/{seg(name)}/nodes", desired)
    if status not in (200, 201, 204):
        sys.exit(f"failed to set nodes for group '{name}': HTTP {status} {body}")
    changes += 1

    # Name what moved. Counts alone -- "set 1 nodes (was 1)" -- make a rewrite
    # loop impossible to diagnose from the log.
    for key in sorted({identity[0] for identity in want - have}):
        print(f"group {name}: + {key}")
    for key in sorted({identity[0] for identity in have - want}):
        print(f"group {name}: - {key}")
    print(f"group {name}: set {len(desired)} nodes (was {len(have)})")

    # The PUT answers with the resulting node list. Check it converged rather
    # than assuming it did. If the API normalizes anything we sent, desired
    # never equals actual, and this script rewrites the same group on every
    # deploy forever while exiting 0 -- exactly the failure mode that
    # build_context's lowercasing exists to prevent. Whatever that misses
    # should be loud rather than eternal.
    if isinstance(body, list):
        settled = {node_identity(n) for n in body}
        if settled != want:
            sys.exit(
                f"group '{name}' did not converge: the API stored something "
                f"other than what was sent. "
                f"missing={sorted(repr(i) for i in want - settled)} "
                f"unexpected={sorted(repr(i) for i in settled - want)}"
            )
    else:
        # Not fatal -- the write itself succeeded -- but say so, or the check
        # above disappears silently the day the response shape changes.
        print(
            f"warning: group '{name}' PUT returned {type(body).__name__} rather "
            f"than a list, so convergence was not verified",
            file=sys.stderr,
        )


def apply_track(name, groups):
    global changes
    status, actual = request("GET", f"/track/{seg(name)}")
    if status == 404:
        status, body = request("POST", "/track", {"name": name})
        if status not in (200, 201, 204):
            sys.exit(f"failed to create track '{name}': HTTP {status} {body}")
        print(f"created track {name}")
        changes += 1
        actual = {"groups": []}
    elif status != 200:
        sys.exit(f"failed to read track '{name}': HTTP {status} {actual}")

    if not isinstance(actual, dict):
        sys.exit(f"failed to read track '{name}': unexpected body {actual!r}")

    # A track is ORDERED, so this compares lists, not sets: a reordering is a
    # real change to the promotion ladder.
    if actual.get("groups") == groups:
        print(f"track {name}: already correct")
        return

    status, body = request("PATCH", f"/track/{seg(name)}", {"groups": groups})
    if status not in (200, 201, 204):
        sys.exit(f"failed to update track '{name}': HTTP {status} {body}")
    print(f"track {name}: set to {groups}")
    changes += 1

    # PATCH answers with the bare string `ok`, so convergence needs a re-read
    # rather than a look at the response. Worth the extra GET: a track's payload
    # is a list of group NAMES, and names are exactly what gets normalized.
    # Measured -- PATCH ["Admin","Member"] reads back ["admin","member"] -- so
    # without this, a mixed-case member would rewrite the same track on every
    # deploy while exiting 0. NAME_RE rejects that case before we get here;
    # this catches whatever normalization comes next.
    status, settled = request("GET", f"/track/{seg(name)}")
    if status == 200 and isinstance(settled, dict) and settled.get("groups") != groups:
        sys.exit(
            f"track '{name}' did not converge: sent {groups}, stored "
            f"{settled.get('groups')}"
        )


def push_messaging():
    """Tell connected servers to reload.

    Best effort on purpose: a failure here leaves stale caches until the next
    restart, not a wrong database, so it must not fail the deploy.
    """
    status, body = request("POST", "/messaging/update")
    if status not in (200, 201, 202, 204):
        print(f"warning: messaging update returned HTTP {status} {body}", file=sys.stderr)
    else:
        print("pushed update to connected servers")


def check_reference_names(groups, tracks):
    """Validate the names a group or track REFERS to, not just the ones it defines.

    Measured: an inheritance node is lowercased in transit -- PUT `group.Member`
    reads back `group.member` -- and so is a track member. So a mixed-case
    reference can never match what was sent, and without this the run would die
    in the convergence backstop with a message about identity tuples instead of
    pointing at the line that is wrong.
    """
    for name, spec in groups.items():
        for parent in as_list((spec or {}).get("inherits"), f"group '{name}' inherits"):
            if not NAME_RE.match(str(parent)):
                sys.exit(
                    f"group '{name}' inherits '{parent}', which must match "
                    f"{NAME_RE.pattern} -- inheritance nodes are lowercased in "
                    f"transit, so this could never converge"
                )
    for name, spec in tracks.items():
        for member in as_list(spec.get("groups"), f"track '{name}' groups"):
            if not NAME_RE.match(str(member)):
                sys.exit(
                    f"track '{name}' lists '{member}', which must match "
                    f"{NAME_RE.pattern} -- track members are lowercased in transit"
                )


def check_references_exist(desired, wanted_tracks, inherits_of, existing_names):
    """Every inherited parent and track member must name a group that exists.

    Checked against the model's own groups PLUS what the server already has,
    because inheriting a group this file does not manage is the documented
    escape hatch rather than an error.

    This is the half NAME_RE cannot see: `inherits: [membr]` is lowercase and
    well formed, so it sails through, stores a dangling `group.membr`, and is
    then perfectly idempotent -- changed=0 forever, while the player inherits
    nothing at all.

    Consulting the server means the SAME permissions.yml can be valid here and
    invalid against a fresh database, which is disaster recovery -- the worst
    possible moment to find out. That is still the right trade, because the
    alternative refuses to run against a perfectly good live configuration, but
    it is why the message below names the ad-hoc case explicitly rather than
    leaving someone to read it as a typo and go hunting in the wrong file.
    """
    known = set(desired) | set(existing_names)
    hint = (
        f"neither defined in {MODEL_PATH} nor present on the server. If it is "
        f"an ad-hoc group this file does not manage, it has to exist before "
        f"this runs -- which it will not on a freshly created database."
    )
    for name in sorted(inherits_of):
        for parent in inherits_of[name]:
            if parent not in known:
                sys.exit(f"group '{name}' inherits '{parent}', which is {hint}")
    for name in sorted(wanted_tracks):
        for member in wanted_tracks[name]:
            if member not in known:
                sys.exit(f"track '{name}' lists '{member}', which is {hint}")


def load_model():
    """Read and validate permissions.yml before anything touches the API."""
    try:
        with open(MODEL_PATH, encoding="utf-8") as handle:
            model = yaml.safe_load(handle)
    except OSError as exc:
        sys.exit(f"cannot read {MODEL_PATH}: {exc}")
    except yaml.YAMLError as exc:
        sys.exit(f"{MODEL_PATH} is not valid YAML: {exc}")

    # An empty or mis-keyed file must NOT read as "nothing to do". `changed=0`
    # is the exact string the idempotency test greps for, so a model that was
    # never really read would sail through that gate while applying nothing at
    # all -- silently, forever, on a bind mount that resolved to the wrong file
    # or a file truncated by a bad merge.
    if not isinstance(model, dict):
        sys.exit(f"{MODEL_PATH} must contain a mapping, got {type(model).__name__}")
    check_keys(MODEL_PATH, model, MODEL_KEYS)

    groups = model.get("groups")
    if not isinstance(groups, dict) or not groups:
        sys.exit(f"{MODEL_PATH} must define a non-empty 'groups' mapping")
    for name, spec in groups.items():
        if spec is not None and not isinstance(spec, dict):
            sys.exit(f"group '{name}': spec must be a mapping, got {type(spec).__name__}")

    tracks = model.get("tracks") or {}
    if not isinstance(tracks, dict):
        sys.exit(f"{MODEL_PATH}: 'tracks' must be a mapping, got {type(tracks).__name__}")
    for name, spec in tracks.items():
        if not isinstance(spec, dict):
            sys.exit(f"track '{name}': spec must be a mapping, got {type(spec).__name__}")
        check_keys(f"track '{name}'", spec, TRACK_KEYS)

    for kind, names in (("group", groups), ("track", tracks)):
        for name in names:
            if not NAME_RE.match(str(name)):
                sys.exit(
                    f"{kind} name '{name}' must match {NAME_RE.pattern} -- the "
                    f"API lowercases names, and other characters are either "
                    f"rejected outright or break the request URL"
                )

    check_reference_names(groups, tracks)
    return groups, tracks


def main():
    groups, tracks = load_model()

    # Expand everything BEFORE the first write, so a model error cannot leave
    # the database half-applied.
    desired = {name: build_nodes(name, spec or {}) for name, spec in groups.items()}
    wanted_tracks = {
        name: list(as_list(spec.get("groups"), f"track '{name}' groups"))
        for name, spec in tracks.items()
    }
    inherits_of = {
        name: [str(p) for p in as_list((spec or {}).get("inherits"), f"group '{name}' inherits")]
        for name, spec in groups.items()
    }
    check_mchprs_closure(desired, inherits_of)

    wait_for_api()

    status, existing = request("GET", "/group")
    if status != 200:
        sys.exit(f"failed to list groups: HTTP {status} {existing}")
    existing_names = set(existing or [])
    check_references_exist(desired, wanted_tracks, inherits_of, existing_names)

    complete = False
    failed = False
    failure = None
    try:
        for name, nodes in desired.items():
            ensure_group(name, existing_names)
            apply_group_nodes(name, nodes)
        for name, order in wanted_tracks.items():
            apply_track(name, order)
        complete = True
    except SystemExit as exc:
        # Flag the failure separately from its message. A bare sys.exit() sets
        # `code` to None, so keying off `failure is not None` would swallow the
        # exception, print INCOMPLETE, and then return from main() with status
        # 0 -- a failure made invisible, which is the one thing this file is
        # built to prevent. No call site does that today; this keeps it from
        # mattering the day one does.
        failed = True
        failure = exc.code
    finally:
        # Print the cause before the summary. The finally would otherwise run
        # ahead of SystemExit's own message, leaving the log reading
        # "INCOMPLETE" first and the reason for it afterwards -- and the tail of
        # the log is what gets pasted into a bug report.
        if isinstance(failure, str):
            print(failure, file=sys.stderr)
        # Push whatever DID land, even when a later group failed. Otherwise a
        # persistent failure on one group strands every earlier group's writes
        # in the database, invisible to running servers, and it never
        # self-heals: the next run finds those groups already correct, leaves
        # `changes` at 0, and dies in the same place again.
        if changes:
            push_messaging()
        if complete:
            print(f"changed={changes}")
        else:
            # Deliberately NOT a `changed=` line. A failed run must not be able
            # to satisfy a log check looking for changed=0.
            print(f"INCOMPLETE -- failed after {changes} change(s)", file=sys.stderr)

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Verify the image builds and the seeder compiles**

Nothing wires the seeder into the stack until Task 16, so without this step the only
thing this task checks is that it committed. Two failures would otherwise surface two
tasks later, attached to the wrong change: a syntax error in `seed.py`, and `PyYAML`
turning out to need a compiler on Alpine.

```bash
docker build -t luckperms-init-check ./src/luckperms-init
docker run --rm --entrypoint python3 luckperms-init-check -m py_compile /seed.py
docker run --rm --entrypoint python3 luckperms-init-check -c "import yaml; print(yaml.__version__)"
```

Expected: the build succeeds, `py_compile` prints nothing and exits 0, and the last
command prints `6.0.2`. `PyYAML==6.0.2` publishes musllinux wheels for CPython 3.12, so
no compiler is needed -- confirmed by running that `pip install` on `python:3.12-alpine`.

This is a build check, not a run: the seeder needs a `permissions.yml` that Task 15 has
not written yet, so do not try to execute it.

Then drop the throwaway tag:

```bash
docker image rm luckperms-init-check
```

- [ ] **Step 5: Commit**

```bash
git add src/luckperms-init/Dockerfile src/luckperms-init/seed.py src/luckperms-standalone/Dockerfile
git commit -m "feat: add declarative luckperms seeder and retire the unsourced jar"
```

---

## Task 15: The permission model

**Files:**
- Create: `src/luckperms-init/permissions.yml`

> **Task 13's gate is answered: per-server contexts ARE usable.** Hyphenated context
> values such as `project-0` are accepted, persist to storage intact, and read back
> unchanged, so nothing in this file is constrained by that question.
>
> Note that the model below does not actually use them. Its only context is
> `server: mchprs`, which MCHPRS constraint 2 requires. Per-server access to the
> project servers is gated by permission KEYS instead (`irc.server.project`), which
> the proxy reads -- a different mechanism from LuckPerms contexts, and not something
> Task 13's fallback would ever have applied to. The earlier instruction to strip
> `context:` blocks referencing `project-0` was describing a file that does not exist.

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
#      MCHPRS never consults the primary-group table. In practice that means
#      a player whose only membership is the `default` group LuckPerms
#      assigns automatically belongs to NO group as far as MCHPRS is
#      concerned. Grant membership with `lp user <name> parent add <group>`,
#      which writes the `group.<name>` node MCHPRS looks for.
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

- [ ] **Step 2: Validate the model against the seeder that will apply it**

Checking that the YAML merely parses is far too weak now. `seed.py` rejects unknown
keys, non-list `permissions`/`inherits`/`groups`, mixed-case or malformed names and
references, non-scalar context values, and any `mchprs.*` node that is a strict
prefix of another across a group's inheritance closure. Every one of those is a
mistake you can make while writing this file, so validate with the real thing:

```bash
docker build -t luckperms-init-check ./src/luckperms-init
docker run --rm -i -e LUCKPERMS_SECRET=validate-only -e PERMISSIONS_FILE=/dev/stdin \
  --entrypoint python3 luckperms-init-check -c "
import sys
sys.path.insert(0, '/')
import seed
groups, tracks = seed.load_model()
desired = {n: seed.build_nodes(n, s or {}) for n, s in groups.items()}
inherits = {n: list((s or {}).get('inherits') or []) for n, s in groups.items()}
seed.check_mchprs_closure(desired, inherits)
for name, nodes in desired.items():
    print(f'{name}: ' + ', '.join(n['key'] for n in nodes))
for name, spec in tracks.items():
    print(f'track {name}: ' + ' -> '.join(spec.get('groups') or []))
print('MODEL OK')
" < src/luckperms-init/permissions.yml
docker image rm luckperms-init-check
```

The model is fed on **stdin** rather than bind-mounted on purpose: this worktree's
path contains spaces, and `-v "$PWD/..."` is awkward to get right on Windows.
`MSYS_NO_PATHCONV=1` may be needed in front of `docker run` on Git Bash, which
otherwise rewrites the leading `/` in `/dev/stdin` into a Windows path.

Expected, exactly (this was run against the model above before the task was
dispatched, so a difference means the file was mistyped rather than that the
expectation is stale):

```
default: weight.0, group.onboarder
onboarder: weight.10, prefix.10.&7[New] , irc.server.onboarding, irc.server.survival, irc.server.project
member: weight.100, prefix.100.&a[Member] , group.onboarder, irc.server.survival, irc.server.project, mchprs.command.*
admin: weight.1000, prefix.1000.&c[Admin] , group.member, luckperms.*, minecraft.command.*, mchprs.admin.*
track onboarding: onboarder -> member -> admin
MODEL OK
```

Note what that output confirms beyond "it parses": every node key is the form
LuckPerms derives a node TYPE from, so `weight.0` becomes a weight and
`group.onboarder` becomes an inheritance edge rather than a literal permission
called "group.onboarder". If a key you expected to be structural shows up here
looking like an ordinary permission string, the spec key above it is misspelled.

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

**This snippet is stale and must be adapted, not transcribed.** It calls
`api GET /group`, the method-and-path helper from the ORIGINAL Task 13 block. The
`tests/test-seeder.sh` that now exists defines `api()` as a passthrough for curl
arguments -- `api "$BASE/luckperms/group"`, with `$BASE` already set and the bearer token
supplied from a curl config on stdin. Read the helper in the file before writing any of
this, and match it. The `| head -n1` calls below exist only to strip the old helper's
appended status-code line and should go away with it.

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

**The live database is NOT in either of the two states this step imagines.** Measured
during Task 12, on the running stack:

```
name        nodes
admin       0
default     0
member      0
onboarder   0
```

All four groups already exist, and `luckperms_group_permissions` is **empty**. So the
database is neither fresh nor seeded — it is half-seeded, and that is the state the
seeder will actually meet on this host.

This matters for the idempotency assertions in Step 2, because it is the exact shape
that hides the most common seeder bug: a seeder whose "already applied?" check asks
whether the *group* exists short-circuits here, reports `changed=0`, and writes none of
the nodes. The run looks perfectly idempotent while having done nothing at all.

So test three starting states, not two:

1. **empty** — no groups (drop them, or use a scratch database)
2. **half-seeded** — groups present, nodes absent (today's live state; recreate it with
   `DELETE FROM luckperms_group_permissions;`)
3. **fully seeded** — the state left by a successful run, where `changed=0` is correct

Only state 3 may report `changed=0`. States 1 and 2 must both report a non-zero change
count and must both converge to the same node set. A seeder that passes 1 and 3 but not
2 will look correct on a fresh machine and silently do nothing on this one.

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

Same two traps as Task 12 Step 2: `.env` is CRLF, so `sed -i` strips the CR from every
line of it, and the key may be absent from `.env` entirely, in which case a substitution
matches nothing and silently leaves the test heap in place.

```bash
if grep -q '^JAVA_OPTS=' .env; then
  perl -i -pe 's|^JAVA_OPTS=[^\r\n]*|JAVA_OPTS=-Xmx2G -Xms1G|' .env
else
  printf 'JAVA_OPTS=-Xmx2G -Xms1G\n' >> .env
fi
docker compose config | grep -m1 JAVA_OPTS
```

Expected: `JAVA_OPTS: -Xmx2G -Xms1G`.

Note what this restores: 2 GiB x 7 JVMs is 14 GiB of heap, which does **not** fit the
15.3 GiB `docker info` reports on this host. It is the production value, put back after
testing — not a setting the full local stack can be brought up with. Anyone running the
stack locally after this step should expect to lower it again.

- [ ] **Step 8: Commit**

```bash
git add tests/run-all.sh
git commit -m "test: add a runner for the full suite"
```

---

## Task 18: Reconcile the documentation

**Files:**
- Modify: `docs/api.md`
- Modify: `README.md`

- [ ] **Step 0: Document that mod-owned configs discard WebDAV edits**

Found during Task 8. The durability table in `docs/api.md` treats everything under
`/data/config` as admin-editable and durable, but that is only true of files no running
mod owns.

`FabricProxy-Lite` parses its TOML through night-config and **writes the file back** —
on load, and again at JVM shutdown. Two consequences a remote administration service
must handle:

- **Comments do not survive.** An appended `# comment` is gone within about ten seconds
  of boot. Verified: the image's rendered copy is CRLF with no trailing newline (172
  bytes); the live file after the mod loads is LF-only with one (169 bytes) — a
  conversion `cp -a` cannot perform, so the mod is provably the writer.
- **Edits made while the server is running are silently discarded at shutdown**, because
  the mod serializes its in-memory state over whatever is on disk. Only edits made while
  the server is stopped, or applied through the game, are safe.

Value edits made while stopped *do* persist — verified with `disconnectMessage` across a
restart, alongside a brand-new `zz-admin-probe.toml`, which also survived.

Add a row or note to the durability table in `docs/api.md` distinguishing
**mod-owned configs** (`config/FabricProxy-Lite.toml`, and any other file a loaded mod
rewrites) from **inert configs** the server only reads. Recommend that the administration
service stop the target server before editing a mod-owned file, and never rely on
comments as a carrier for anything.

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

- [ ] **Step 3b: Document where the submodule pointers actually point**

Task 11 pushed the four server submodules on `claude/luckperms-seeding-fixes` and bumped
the parent's gitlinks to those commits. They are **not** on any submodule's `main`, and a
gitlink records a bare SHA with no ref name, so nothing in a checkout reveals which branch
a pointer came from. That fact currently lives only in the Task 11 commit message, which
is where nobody looks until after it breaks.

Add a note to the submodule step of `README.md` setup, next to
`git submodule update --init --recursive`:

```
The four server submodules are pinned to commits on the
`claude/luckperms-seeding-fixes` branch of their repositories, not to `main`. Until
those branches are merged, do not delete or force-push them -- a gitlink records a
bare SHA, and if no ref on the remote still reaches it, `git submodule update` fails
and the checkout cannot be completed.

Merging them needs care: a squash or rebase merge writes a new commit, so the pinned
SHA survives only on the branch, and "automatically delete head branches" then removes
the last ref holding it. Either merge with a real merge commit or fast-forward, or
re-bump the four pointers to the post-merge `main` SHAs in the same change.
```

Do not add a `branch =` key to `.gitmodules` to "fix" this. Submodules here are build
inputs -- Compose builds them into images -- so pinning by SHA is what makes "this parent
commit produces that image" true. `branch = main` would be worse than useless: the
recorded SHAs are not on `main`, so `git submodule update --remote` would roll all four
pointers backwards onto the pre-fix entrypoints, reinstating the `sed`-based secret
injection, and would present as a working checkout rather than an error.

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

- [ ] **Step 2b: Close the deferrals this plan accumulated**

Items 1-4 were declined during Tasks 8, 9 and 10 on the explicit grounds that they
should change across the whole entrypoint family at once, rather than splitting it.
This is that moment. None of them is a bug today. Item 5 came later, from Task 12.

1. **`CONFIG_DIR` is used once while the same prefix is hardcoded three more times.**
   In all five Fabric entrypoints, `CONFIG_DIR="/usr/src/init_data/config"` is used
   only for the `render_env_placeholders` call, while the seeding lines spell out
   `/usr/src/init_data/mods/.`, `/usr/src/init_data/config/.` and
   `/usr/src/init_data/server.properties` literally. Change `CONFIG_DIR` and the
   script renders a template at the new path while seeding from the old — shipping an
   unrendered literal `${VELOCITY_SECRET}` into `/data/config` on a server running
   `ONLINE_MODE=FALSE`, which surfaces only as backends refusing proxy connections.
   `src/velocity/entrypoint.sh` already uses `$CONFIG_DIR` throughout and does not
   have the split. Either introduce `INIT_DIR=/usr/src/init_data` and use it
   everywhere, or drop the variable and hardcode the render call too.

2. **Six of the seven entrypoints end without a trailing newline; `velocity` ends
   with one.** Functionally irrelevant — bash executes an unterminated final line
   — but it puts a permanent `\ No newline at end of file` marker on any future diff
   touching the last line of six files. Normalize only if item 1 is being done
   anyway, since that already rewrites the same files.

3. **`set -euo pipefail` in four entrypoints, `set -e` in the other three.** `lobby`,
   `onboarding`, `project-0` and `project-1` use the strict form; `survival`,
   `velocity` and `mchprs` use bare `set -e`, because they were written and reviewed
   before the strict form was adopted and harmonizing them was out of scope at the
   time (recorded in this plan under Task 9). The strict form is safe in this code:
   bash leaves an unmatched optional group in `BASH_REMATCH` as an empty string
   rather than unset, so `${BASH_REMATCH[3]}` does not abort under `-u` on
   `${VELOCITY_SECRET}`, which has no `:-default` clause. Verified in-image, bash
   5.2.21: `n=4 g1=[VELOCITY_SECRET] g3=[]`. If the three are harmonized, re-check
   each for unguarded `$1`/`$@` expansions first — `mchprs` in particular has not
   been read with `-u` in mind.

4. **`src/mchprs/entrypoint.sh` keeps the bare `content=$(cat "$file")` form**, where
   the other six use the `&& printf x` sentinel. **Read the decline note under Task 8
   before touching it** — this is deliberate, and the reasoning is not obvious from the
   file. The bare form is a plain assignment, so the substitution's exit status *is*
   the assignment's and `set -e` fires normally; only the `;`-sentinel variant broke
   that. `src/mchprs/Config.toml` is LF-only (CR=0 LF=31) with no trailing newline, so
   the sentinel would buy nothing there.

   This matters because **item 3 above sends you into this exact file.** Someone
   harmonizing `set -e` will see a `render_env_placeholders` visibly different from the
   other six and be tempted to harmonize that too. If they reach for `;` rather than
   `&&`, they reintroduce the bug the other six were fixed for: `printf`'s always-zero
   status disarms `set -e`, and the function truncates a secret-bearing file to zero
   bytes. Harmonize it only with `&&`, or leave it alone.

5. **`tests/test-webdav.sh` reads `.env` without `tr -d '\r'`.** Found during Task 12,
   which added the guard to `tests/test-luckperms.sh` but deliberately did not widen
   its scope to rewrite a sibling suite. `test-webdav.sh` extracts
   `WEBDAV_USERNAME` and `WEBDAV_PASSWORD` from a file whose lines are CRLF, and
   survives only because Git Bash's `grep` opens in text mode and strips the CR by
   accident — the same platform quirk `AGENTS.md` documents. Run that suite under a
   Linux `grep` and both credentials carry a trailing CR, which presents as an
   authentication failure rather than as a line-ending bug. Add the same
   `| tr -d '\r'` to both extractions.

6. **`ghcr.io/luckperms/rest-api:latest` is unpinned, and code now depends on its
   contract.** Raised during Task 14's quality review. Until that task nothing here
   cared what the REST API returned; now `src/luckperms-init/seed.py` depends on
   measured behavior: that `PUT /group/X/nodes` replaces rather than appends, that a
   node's type is derived from its key, that contexts come back lowercased, that a
   duplicate group answers 409. `:latest` means any of that can change under the
   stack with no change in this repository, on whatever day someone next runs
   `docker compose build`. Declined during Task 14 on scope: pinning it changes what
   the running stack rebuilds to, which is a Task 17 judgement rather than a Task 14
   one, and the other image references deserve the same look at the same time. Note
   the asymmetry that makes it awkward to leave open: `seed.py`'s own dependency is
   pinned exactly, `PyYAML==6.0.2`, while the service it exists to talk to is not.

```bash
grep -n 'CONFIG_DIR\|/usr/src/init_data' src/*/entrypoint.sh
grep -H '^set ' src/*/entrypoint.sh
grep -n 'content=$(cat' src/*/entrypoint.sh
grep -c 'tr -d' tests/test-webdav.sh
grep -n ':latest' compose.yml src/*/Dockerfile
```

Expected, once all six items are closed: no single file both defines `CONFIG_DIR`
and spells out the literal `/usr/src/init_data` prefix, all seven `set` lines agree,
and `test-webdav.sh` reports 2 rather than 0. Before they are closed, this block is a
status report rather than a test — none of the six is a bug on this host
today. Item 5 is the only one that becomes a real failure off it, and item 6 the
only one that can start failing here without anyone touching this repository.
Item 6 is also the only one with no single right answer, so its grep is a prompt to
decide rather than a target to reach.

Decide each item explicitly. Leaving one open is a legitimate outcome, but record the
decision here rather than letting it lapse — every one of these was already declined
once, and an item that is silently dropped twice looks settled without anyone having
settled it.

- [ ] **Step 3: Confirm the working tree and submodules are clean**

```bash
git status --short
git submodule status
```

Expected: no output from the first; no `+` prefixes from the second.

- [ ] **Step 3b: Confirm every gitlink is still reachable on its remote**

`git submodule status` above is **not** sufficient and must not be treated as if it
were. It reads local objects, so it prints four clean lines whether or not those commits
still exist on origin -- it would pass unchanged the day after all four branches were
squash-merged and their heads deleted, which is exactly the failure that breaks a fresh
clone. Check the remote instead:

```bash
git submodule foreach --quiet '
  git fetch --quiet --prune origin 2>/dev/null
  sha=$(git rev-parse HEAD)
  refs=$(git branch -r --contains "$sha" 2>/dev/null | tr -d " " | tr "\n" "," | sed "s/,$//")
  if [ -n "$refs" ]; then
    echo "$name: $sha REACHABLE from $refs"
  else
    echo "$name: $sha NOT REACHABLE FROM ANY REMOTE REF -- clones will fail"
  fi
'
```

Expected: four `REACHABLE from ...` lines. Any `NOT REACHABLE` means the parent pointer
references a commit a fresh clone cannot obtain; `git submodule update` fails there with
no way to recover the tree. Fix it before merging by pushing a ref that reaches the
commit, or by re-bumping the pointer to one that is reachable.

Use `--contains` and not `ls-remote | grep "^$sha"`. The grep form only matches a SHA that
is itself a **ref tip**, so the moment these branches merge with a merge commit the pinned
SHA becomes an ordinary ancestor of `main` and the grep form reports it missing although it
is perfectly fetchable. That false alarm would land precisely in the post-merge situation
this step exists to check. Verified both ways: `--contains` finds an ancestor commit (it
reports `origin/main` for one) and still rejects a fabricated SHA. The `git fetch` on the
first line is load-bearing — `branch -r` reads remote-tracking refs, which are stale
otherwise, and a deleted upstream branch only disappears from them after `--prune`.

Note what this checks and what it does not: it proves some ref on origin reaches that SHA,
using these credentials. It cannot prove the commit will still be reachable after the four
branches merge. Carry that forward as a merge-order requirement rather than a test:

> Merge the four submodule branches with a real merge commit or a fast-forward, **or**
> re-bump the four gitlinks to the post-merge `main` SHAs in the same change that merges
> them. A squash or rebase merge plus GitHub's "automatically delete head branches" leaves
> the recorded SHA unreferenced.

Merging those four repositories is a maintainer decision and is deliberately **not** a
step in this plan. Surface the requirement at handoff; do not merge them unprompted.

- [ ] **Step 4: Review the full diff**

```bash
git log --oneline main..HEAD
git diff main...HEAD --stat
```

- [ ] **Step 5: Request code review**

Use the superpowers:requesting-code-review skill against the design spec.

# Agent guidance — IRC Minecraft orchestration

This repository orchestrates several Minecraft servers behind a Velocity proxy, with
LuckPerms for permissions, a WebDAV interface over the shared data volume, and a
Cloudflare tunnel for admin access.

`compose.yml` is the live definition. **`compose-old.yml` is historical — do not edit it
and do not use it as a reference for current intent.**

## Verified behaviors — do NOT "fix" these

Each item below looks like a bug, has been investigated against upstream sources or
confirmed with the maintainer, and is correct. Changing them will break something.
Verification evidence is in
[`docs/superpowers/specs/2026-09-22-compose-orchestration-completion-design.md`](docs/superpowers/specs/2026-09-22-compose-orchestration-completion-design.md),
Appendix B.

### 1. The `luckperms-standalone` healthcheck must be overridden, and port 3001 is correct

Port 3001 is the LuckPerms **standalone heartbeat server**, started when the app runs
with `--docker`. It is entirely separate from the REST API's port 8080.
`HeartbeatHttpServer` registers `createContext("/health", ...)`, and Java's `HttpServer`
matches contexts by **path prefix**, so `/healthz` also resolves to that handler. `wget`
is present in the image, and the handler returns 503 when unhealthy.

**Do not delete the compose-level `healthcheck:` override to "inherit the base image's".**
The base image declares
`wget http://localhost:3001/health -q -O - | grep -c '"up":true'`, but this version's
endpoint actually returns:

```json
{"healthy":true,"details":{"storageConnected":true,"storagePing":1}}
```

The field is `healthy`, not `up`. The inherited check can **never** pass, leaving the
container permanently `unhealthy` — which in turn stops `luckperms-init` from ever
starting, since it waits on `condition: service_healthy`. Verified by running all three
candidate commands inside the running container.

The override must therefore grep `"healthy":true`. Do not "correct" the port to 8080.

### 2. `velocity` does not need a healthcheck added

`itzg/mc-proxy` declares `HEALTHCHECK --start-period=10s CMD /usr/bin/health.sh`.
`HEALTHCHECK` is inherited unless the derived Dockerfile declares its own, and
`src/velocity/Dockerfile` declares none — which is the whole reason it is inherited.
It is **not** a consequence of that Dockerfile overriding only `CMD`. Those are two
independent facts, and welding them into a causal link is a mistake this repository
has already made twice. The disproof: `lobby`, `onboarding` and `survival` all
replace `ENTRYPOINT` outright and still report the base image's `mc-health` check.

`health.sh` reads `.bind` from `velocity.toml` in WORKDIR `/server` — exactly where
the entrypoint places it — and resolves port 25565.

`depends_on: velocity: {condition: service_healthy}` therefore works as written.

### 3. `mchprs` takes a bare hostname — never add `:3306`

MCHPRS passes its `host` config value to `OptsBuilder::ip_or_hostname()`, which accepts a
**hostname only** and defaults the port. `LUCKPERMS_DATA_ADDRESS=luckperms-db` is correct
for `mchprs`, even though every other service uses `luckperms-db:3306`. Adding the port
would make it try to resolve a host literally named `luckperms-db:3306`.

### 4. `lobby` and `onboarding` overwrite `world/` on every restart — intentionally

Those worlds are **code artifacts**, not player state. Builders publish a new design by
rebuilding the image, so the world is intentionally defined in code rather than allowed
to drift the way a normal Minecraft world does.

Do not convert these to seed-if-absent. Contrast with `survival`, `project-0`,
`project-1`, and `mchprs`, whose worlds are player-owned and must never be overwritten.

**Only `lobby` matches that description today.** The two servers are not in the same
state:

- `lobby` ships a published build — 21 tracked files under `server/world` — and runs
  `gamemode=adventure` with `force-gamemode=true`, so players cannot modify blocks and
  the overwrite costs nothing.
- `onboarding` ships an **empty** `server/world` holding only `.gitkeep`, and runs
  `gamemode=survival`. Its live world is whatever the server generated in the volume,
  that is the only copy, and the overwrite moves no world data today. It is not dead
  code, though: the `cp` is what leaves `/data/world` owned by `minecraft`, as the
  entrypoint comment explains. That volume world is a **disposable placeholder** — see
  item 5 — so nothing is at risk today; publishing a real world into
  `src/onboarding/server/world` is the intended end state, and it makes this server the
  same case as `lobby`, including the part where the image starts overwriting whatever
  players changed.

### 5. `backup` intentionally covers only `survival`, `project-0`, and `project-1`

Those are the only volumes holding state that accrues over time.

- `lobby`'s world is restored from the image on every start, so backing it up would only
  duplicate what git already holds.
- `velocity` and `mchprs` hold no durable state worth restoring.

Do not extend backup coverage to the other services.

**`onboarding` is excluded for a different reason, settled by the maintainer.** Its
exclusion was originally recorded on the same grounds as `lobby`'s, but `onboarding`
ships no world in its image (item 4), so nothing restores it: its world exists only in
the `managed-files` volume under the `onboarding` subpath, in neither git nor the backup
set. Raised as a possible data-loss risk and **resolved 2026-09-23 — the world currently
in that volume is a disposable placeholder.** A real onboarding world will be published
as a code artifact the way `lobby`'s is, at which point this becomes the same case as
`lobby`. Until then there is nothing to protect, and the backup set is correct as it
stands. Do not reopen this, and do not add `onboarding` to `backup`.

## Platform: CRLF files and the Git Bash toolchain

Most tracked text files here are **CRLF**: `compose.yml`, `.gitignore`,
`.env.example`, and all five `luckperms.conf` files (684 CR / 684 LF each).
`.gitattributes` sets `text=auto` with an `eol=lf` override only for `*.sh`, and
`core.autocrlf` is `false`.

On Git Bash for Windows, `sed`, `awk` and `grep` are PE binaries that open files in
**text mode**. They silently translate CRLF to LF on read and never restore it. Measured
on a three-line CRLF fixture:

| Command | CR preserved |
| --- | --- |
| `grep -q $'\r' file` | **cannot detect CR at all** |
| `sed -i 's/x/y/' file` | no — strips CR from *every* line, not just rewritten ones |
| `sed 's/x/y/' < in > out` | no |
| `awk '{...}' < in > out` | no |
| `perl -i -pe 's/x/y/' file` | **yes** |

So:

- **Use `perl -i -pe` to edit CRLF files in place.** Never `sed -i`.
- **Use `[^\r\n]*` rather than `.*`** in those patterns. `.` matches a carriage return,
  so `.*` swallows it and the replacement emits an LF-only line into an otherwise CRLF
  file, leaving mixed endings.
- **Detect line endings by counting bytes**, not with grep:
  `tr -cd '\r' < file | wc -c` versus `tr -cd '\n' < file | wc -c`. Redirection opens in
  binary mode, so `tr` reports correctly.
- `cat -A` through a pipe can also strip CR as an MSYS artifact. Byte counting is
  authoritative.

`scripts/normalize-luckperms-conf.sh` documents this inline and is the worked example.

## Project conventions

- **LuckPerms wiring comes from environment variables, not config files.** LuckPerms
  resolves config in the order: file secrets → system properties → **environment
  variables** → config file. The adapter lives in `AbstractLuckPermsPlugin`, so this
  applies identically on Fabric, Velocity, and standalone. Key mapping is
  `"LUCKPERMS_" + path.toUpperCase().replace('-','_').replace('.','_')`, so `data.address`
  becomes `LUCKPERMS_DATA_ADDRESS`. Config files should carry only `server = "<name>"`.
- **Never inject secrets with `sed`.** A secret containing `/`, `&`, or `\` silently
  corrupts a `sed` replacement. Use the `render_env_placeholders` bash function; its
  docstring explains why.
- **Files with no env-override support** still need templating: `FabricProxy-Lite.toml`,
  `velocity.toml`, `forwarding.secret`, and mchprs `Config.toml`.
- **`25565` is the only published port.** Everything else reaches the outside world
  through Caddy and the Cloudflare tunnel.
- **Submodules must be initialized**: `git submodule update --init --recursive`. Four
  server definitions (`lobby`, `onboarding`, `project-0`, `project-1`) live in separate
  repositories under the IlliniRedstoneComputing organization.

## MCHPRS permission constraints

MCHPRS reads the LuckPerms database directly rather than using the plugin, and its
implementation is limited in three ways that constrain how permissions are written:

1. **Never write a node that is a strict prefix of another queried node.**
   `PermissionNode::matches` iterates the queried string's segments while indexing the
   stored node's path, so a stored `mchprs.command` checked against a queried
   `mchprs.command.foo` panics with an index-out-of-bounds. Use exact keys or explicit
   `*` wildcards.
2. **Only `global` and `mchprs` server contexts are visible to it.**
3. **Group membership must be an explicit `group.<name>` node on the user.** MCHPRS
   resolves inheritance through `group.`-prefixed nodes and never consults the
   `luckperms_players` primary-group table.

MCHPRS also has no messaging support; it rebuilds its cache per player on join, so
permission changes take effect on relog rather than needing a restart.

## WebDAV constraints

- The WebDAV service is deliberately a **single service account with full CRUD** over the
  whole volume. User management and per-directory permissions belong to a separate
  administration service that talks to this one over a single connection. Do not add
  multi-user support here.
- Serving under `/files` requires all three of: `prefix: /files` in the WebDAV config,
  Caddy `handle` (**not** `handle_path` — the prefix must reach the server), and a
  `Destination` header rewrite. Without the rewrite every `COPY` and `MOVE` fails.

## References

Sources consulted when verifying the behaviors above.

- [hacdias/webdav — configuration and subpath serving](https://github.com/hacdias/webdav)
- [LuckPerms REST API](https://github.com/LuckPerms/rest-api)
- [LuckPerms `EnvironmentVariableConfigAdapter`](https://github.com/LuckPerms/LuckPerms/blob/master/common/src/main/java/me/lucko/luckperms/common/config/generic/adapter/EnvironmentVariableConfigAdapter.java)
- [LuckPerms `HeartbeatHttpServer`](https://github.com/LuckPerms/LuckPerms/blob/master/standalone/app/src/main/java/me/lucko/luckperms/standalone/app/utils/HeartbeatHttpServer.java)
- [LuckPerms standalone Dockerfile (declares the healthcheck)](https://github.com/LuckPerms/LuckPerms/blob/master/standalone/docker/Dockerfile)
- [MCHPRS permissions module](https://github.com/MCHPR/MCHPRS/blob/master/crates/core/src/permissions/mod.rs)
- [itzg/docker-mc-proxy — healthcheck and `health.sh`](https://github.com/itzg/docker-mc-proxy)
- [Cloudflare Tunnel configuration file](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/)
- [cloudflared#1029 — `--config` is ignored when `--token` is used](https://github.com/cloudflare/cloudflared/issues/1029)
- [cloudflared#563 — ingress cannot rewrite the origin path](https://github.com/cloudflare/cloudflared/issues/563)
- [Compose `env_file` `required` attribute](https://docs.docker.com/reference/compose-file/services/#env_file)

## Further reading

- [`README.md`](README.md) — setup, architecture, and operations
- [`docs/api.md`](docs/api.md) — the HTTP surface exposed to remote administration tools
- [`docs/superpowers/specs/`](docs/superpowers/specs/) — design specifications

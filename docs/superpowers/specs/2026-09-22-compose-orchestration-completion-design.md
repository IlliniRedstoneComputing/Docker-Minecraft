# Completing the `compose.yml` Orchestration

**Date:** 2026-09-22
**Status:** Approved, ready for implementation planning
**Scope:** `compose.yml` only. `compose-old.yml` is not touched.

## Goal

Finish the multi-container Minecraft deployment: a working WebDAV interface over the
`managed-files` volume, a Cloudflare tunnel replacing published admin ports, and a
LuckPerms installation that is correct across every server and definable in code.

## Investigation summary

The repository was audited end-to-end before design. Findings are recorded in
[Appendix A](#appendix-a--audit-findings) so implementation can verify each one is
addressed. Three initial findings were **wrong** and were retracted after checking
upstream sources; they are listed in [Appendix B](#appendix-b--retracted-findings) so
nobody re-introduces a "fix" for a non-problem.

## Architecture

### Networks

| Network | Services |
| --- | --- |
| `frontend-network` | `cloudflared`, `caddy`, `webdav`, `luckperms-standalone`, `luckperms-init` |
| `minecraft-network` | `velocity`, six Minecraft servers, `luckperms-db`, `luckperms-standalone`, `backup` |

`luckperms-standalone` is the only service on both: MariaDB behind it, HTTP in front.

### Published ports

`25565` on `velocity` is the **only** published port in the stack. WebDAV's current
`8080:80` mapping is removed. Minecraft cannot traverse a standard Cloudflare tunnel —
TCP requires `cloudflared access` on every client or paid Spectrum — so `25565` stays
direct, reached via a plain `mc.illiniredstone.org` DNS record. A dedicated proxy for
that is planned separately and is out of scope here.

### Request path

```
mc-admin.illiniredstone.org
  -> Cloudflare edge
    -> cloudflared
      -> caddy:80
        -> handle /files*       -> webdav:6065            (prefix passed through)
        -> handle_path /luckperms* -> luckperms-standalone:8080  (prefix stripped)
        -> handle               -> redir illiniredstone.org
```

The asymmetry is deliberate and required. See [WebDAV](#webdav).

## Components

### Blocking fixes

These land first; nothing else is testable until they do.

1. **`backup.config` is absent and gitignored**, so `env_file` aborts the entire stack.
   Change to the optional form, supported since Compose 2.20:
   ```yaml
   env_file:
     - path: backup.config
       required: false
   ```
2. **Submodule initialization.** `src/lobby`, `src/onboarding`, `src/project-0`, and
   `src/project-1` are empty without `git submodule update --init --recursive`.
   Document as a required clone step in the README.
3. **Self-inconsistent database credential defaults.** `luckperms-db` creates
   `${LUCKPERMS_DB_USER:-luckperms_user}` while every client connects as
   `${LUCKPERMS_DB_USER:-user_luckperms}`. Authentication fails whenever `.env` is
   absent. Use one default everywhere.
4. **`webdav` mounts the literal placeholder** `/path/to/your/files`. Resolved by the
   rewrite below.
5. **`velocity` has no `restart:` policy** — the only service missing one. Add
   `restart: unless-stopped`.
6. **Delete the `luckperms-standalone` healthcheck override.** It works, but it is a
   weaker any-2xx check that shadows the stricter one the base image already declares
   (`wget http://localhost:3001/health -q -O - | grep -c '"up":true'`). Removing the
   override inherits the better check. See [Appendix B](#appendix-b--retracted-findings).

### WebDAV

Replace `sfuhrm/docker-nginx-webdav` with `ghcr.io/hacdias/webdav:latest`.

Rationale: the current image serves at `/` on port 8080 (the compose mapping of
`8080:80` is wrong), supports only one user, and runs nginx as uid 100 — which cannot
write into directories created later by the Minecraft servers as uid 1000. It also has
no base-path support, and WebDAV behind a *stripped* prefix is broken by design:
`PROPFIND` returns root-relative `<D:href>` values that clients resolve against the
origin, losing the prefix.

`hacdias/webdav` has a native `prefix` option, is `FROM scratch` (runs as uid 0, so the
permission trap disappears entirely), and reads credentials from the environment.

Service: no published ports, `frontend-network`, `depends_on: volume_init`,
`managed-files` mounted at `/data`, `command: ["-c", "/config.yml"]`.

`src/webdav/config.yml`, mounted read-only:

```yaml
address: 0.0.0.0
port: 6065
prefix: /files
behindProxy: true
directory: /data
permissions: CRUD
users:
  - username: "{env}WEBDAV_USERNAME"
    password: "{env}WEBDAV_PASSWORD"
```

**Single service account by design.** User management, per-directory scoping, and file
permissions are the responsibility of a separate application that talks to this service
over one WebDAV connection. Do not add multi-user support here.

The image is `FROM scratch` and contains no shell or HTTP client, so this service gets
**no healthcheck**. Caddy is its liveness signal.

### Caddy

`caddy:2-alpine`, no published ports, no `caddy-data` volume — the tunnel terminates
TLS. `src/caddy/Caddyfile` becomes:

```caddyfile
:80 {
    @hasDest header_regexp dest ^https?://[^/]+(.*)$
    header @hasDest Destination {re.dest.1}

    handle /files* {
        reverse_proxy webdav:6065 {
            header_up X-Real-IP {remote_host}
            header_up REMOTE-HOST {remote_host}
        }
    }

    handle_path /luckperms* {
        reverse_proxy luckperms-standalone:8080
    }

    handle {
        redir https://illiniredstone.org
    }
}
```

Three requirements that are easy to get wrong:

- **`handle`, not `handle_path`, for WebDAV.** The prefix must reach the server, which
  strips it itself via `prefix:` and adds it back to responses.
- **`handle_path` for LuckPerms.** The REST API has no base-path setting and serves
  `/user`, `/group`, `/track` at root, so the prefix must be stripped.
- **The `@hasDest` rewrite is mandatory.** Without rewriting `Destination` to a
  path-only form, every `COPY` and `MOVE` fails. Both the request path and `Destination`
  must carry `/files`, or the server answers `400`.

### Cloudflare tunnel

`cloudflare/cloudflared:latest`, `command: tunnel --no-autoupdate run`,
`frontend-network`, `depends_on: caddy`, token supplied as `TUNNEL_TOKEN`.

Token auth means the tunnel is **remotely managed**; a local `config.yml` with ingress
rules would be silently ignored. This is fine because Caddy absorbs all routing: the
dashboard needs exactly one public hostname, `mc-admin.illiniredstone.org` →
`http://caddy:80`. Every other routing decision lives in the Caddyfile in git.

Document the one-time dashboard steps in the README: create the tunnel, copy the token
into `.env`, add the single public hostname, and add the `mc` A record for `25565`.

### LuckPerms correctness

**Single source of truth for wiring.** LuckPerms resolves config from, in precedence
order: file secrets, system properties, **environment variables**, then the config file.
The env adapter lives in `AbstractLuckPermsPlugin`, so it applies identically on Fabric,
Velocity, and standalone. Key mapping is
`"LUCKPERMS_" + path.toUpperCase().replace('-','_').replace('.','_')`.

Therefore:

- Remove **all** `${...}` tokens from LuckPerms configs in all six repositories. Ship
  near-stock files carrying only `server = "<name>"` — identity belongs with the server.
- Drive storage method, address, credentials, and messaging entirely from `LUCKPERMS_*`
  env vars in `compose.yml`.
- Keep `render_env_placeholders` only for files with no env-override support:
  `FabricProxy-Lite.toml`, `velocity.toml`, `forwarding.secret`, mchprs `Config.toml`.

This removes the hardcoded `messaging-service = "redis"`, the dead
`luckperms_messenger:6379` reference, and the unrendered literal `${...}` strings that
reach `/data` in four of the five Fabric servers.

**Velocity gains the LuckPerms env block it never had.** Today `velocity` receives no
`LUCKPERMS_*` variables at all, so its entrypoint renders
`storage-method: ${LUCKPERMS_STORAGE_METHOD:-h2}` to the literal `h2` and the proxy runs
on a local H2 file, disconnected from the shared database. Its `config.yml` also uses
`LUCKPERMS_DB_*` placeholder names that collide in meaning with the `.env` variable of
the same name; normalize to the project-wide `LUCKPERMS_DATA_*` scheme.

**Standardize secret injection.** The four submodules use
`sed -i "s/\${VELOCITY_SECRET}/$VELOCITY_SECRET/g"`, which silently corrupts any secret
containing `/`, `&`, or `\` — precisely the hazard documented in `survival`'s
`render_env_placeholders` docstring. All five Fabric repos adopt that robust
implementation.

**Messaging.** `LUCKPERMS_MESSAGING_SERVICE=sql` on all Fabric servers and Velocity,
which works because storage is MariaDB. MCHPRS has no messaging support; it reads the
database directly and rebuilds its cache per player on join, so changes there take
effect on relog rather than requiring a restart.

### Seeding: image content vs. volume content

Current entrypoints unconditionally `cp -a` `mods/`, `config/`, `server.properties` —
and for `lobby` and `onboarding`, `world/` — over `/data` on every start. Anything
written over WebDAV in those paths is reverted on the next restart, which defeats the
purpose of the WebDAV interface.

Hybrid policy:

| Path | Policy | Reason |
| --- | --- | --- |
| `mods/` | re-sync every start | mod upgrades must actually land |
| `config/` | seed if absent | admin-editable over WebDAV |
| `server.properties` | seed if absent | admin-editable over WebDAV |
| `world/` | **depends on server role — see below** | |

The `world/` policy is per-role, not global:

| Server | `world/` policy | Reason |
| --- | --- | --- |
| `lobby`, `onboarding` | re-sync every start | The world is a **code artifact**. Builders publish a new design by rebuilding the image; players are in adventure mode and cannot modify blocks. The image is authoritative by intent. |
| `survival`, `project-0`, `project-1`, `mchprs` | never touched after first boot | Player-owned state. |

This is why `lobby` and `onboarding` ship a `world/` directory in git and copy it
unconditionally: that is correct behavior, not the data-loss bug it resembles.

Velocity specifically:

| Path | Policy | Reason |
| --- | --- | --- |
| `plugins/` | re-sync every start | plugin upgrades must land |
| `forwarding.secret` | always re-render | secret rotation must propagate |
| `velocity.toml` | seed if absent | admins add backend servers here |

`velocity.toml` contains no secret — it references `forwarding-secret-file` — so
seed-if-absent is safe.

### LuckPerms as code

Delete `src/luckperms-standalone/Initialization-1.0-SNAPSHOT.jar` and its `COPY` line.
It is a committed binary with no source in the repository; decompilation shows it only
creates three empty groups (`member`, `onboarder`, `admin`) with no permissions,
weights, inheritance, or tracks.

Replace with `luckperms-init`: a one-shot service, `restart: "no"`,
`depends_on: luckperms-standalone: {condition: service_healthy}`, on `frontend-network`,
reading `src/luckperms-init/permissions.yml`.

Endpoint mapping:

| Step | Call |
| --- | --- |
| list existing groups | `GET /group` |
| create a group | `POST /group` (tolerate already-exists) |
| set a group's full node set | `PUT /group/{name}/nodes` |
| create the track | `POST /track` (tolerate already-exists) |
| define the track's groups | `PATCH /track/{trackName}` |
| push to live servers | `POST /messaging/update` |

Authentication is `Authorization: Bearer <LUCKPERMS_SECRET>`.

Weights, inheritance, prefixes, and suffixes are all nodes distinguished by `type`
(`weight`, `inheritance`, `prefix`, `suffix`, `meta`, `permission`), so the entire model
fits in one YAML file.

**Sync semantics: replace.** `PUT /group/{name}/nodes` replaces a group's entire node
set, which makes the seeder idempotent by construction and makes `permissions.yml`
authoritative. Consequences, to be documented prominently at the top of the file:

- Changes made to a **managed** group through the LuckPerms web editor are overwritten
  on the next `docker compose up`.
- Groups **absent** from `permissions.yml` are never touched, so ad-hoc groups remain a
  supported escape hatch.

**Starter content.** A documented baseline: the track `onboarder -> member -> admin`,
group weights, `default` inheriting `member`, and `admin` granted `luckperms.*` plus
operator-equivalent permissions via `vanilla-permissions`. Heavily commented so it can
be edited without consulting LuckPerms documentation.

The starter must respect three MCHPRS constraints ([Appendix A](#appendix-a--audit-findings), items 22–24):

- **Never write a node that is a strict prefix of another queried node.** MCHPRS's
  matcher iterates the queried string's segments while indexing the stored node's path,
  so a stored `mchprs.command` against a queried `mchprs.command.foo` panics with an
  index-out-of-bounds. Use exact keys or explicit `*` wildcards.
- **Use `global` or `mchprs` server context** for anything MCHPRS must see; other
  contexts are invisible to it.
- **Write group membership as explicit `group.<name>` nodes.** MCHPRS resolves
  inheritance through `group.`-prefixed nodes and never consults the
  `luckperms_players` primary-group table.

### Environment and cleanup

Rewrite `.env.example` to be complete and accurate: correct target filename (`.env`, not
`.env.local`), add `WEBDAV_USERNAME`, `WEBDAV_PASSWORD`, and `CLOUDFLARE_TUNNEL_TOKEN`,
and fix the credential default mismatch.

No hostname variable is added. Caddy listens on `:80` and routes purely by path, and
cloudflared is token-driven, so `mc-admin.illiniredstone.org` appears in no config file —
it is a dashboard setting, documented in the README. Adding an `ADMIN_HOSTNAME` variable
would only reintroduce the dead-variable problem being cleaned up here.

Remove dead configuration: the unused `sftpgo-data` and `wireguard-module-data` volumes,
the commented-out `sftpgo` service block, `wg0.conf.example`, and the dead `SFTPGO_*`,
`LUCKPERMS_MESSENGER_PASSWORD`, and `MINECRAFT_HOSTNAME` variables.

## Testing strategy

The host has 22 CPUs and 16.5 GB RAM. Six servers at `-Xmx2G` plus Velocity is roughly
14 GB of heap before MariaDB and overhead, so bring-up is staged and local testing uses
reduced heaps via `JAVA_OPTS` in `.env`.

Stage 1: `luckperms-db`, `luckperms-standalone`, `luckperms-init`, `velocity`,
`survival`, `mchprs`, `webdav`, `caddy`.
Stage 2: `lobby`, `onboarding`, `project-0`, `project-1`.

Verifications:

1. `docker compose config` validates.
2. All services reach healthy; no dependency stalls.
3. Each server logs `Resolved configuration value from environment variable:
   LUCKPERMS_STORAGE_METHOD`, and `luckperms_*` tables exist in MariaDB.
4. **No H2 database file exists in velocity's volume** — the specific regression that
   proves the proxy joined shared storage.
5. A permission set on one server propagates to another without a restart.
6. Running `luckperms-init` twice is a no-op the second time.
7. WebDAV through Caddy: `PROPFIND`, `PUT`, `GET`, and `MOVE` via `curl -u`, confirming
   the `/files` prefix and the `Destination` rewrite both work.
8. A WebDAV write into a directory **created by a Minecraft server** succeeds — the
   original uid trap.
9. MCHPRS resolves a seeded permission, including the prefix edge case from
   [Appendix A](#appendix-a--audit-findings) item 22.
10. **Context values containing hyphens are accepted.** The REST API's OpenAPI schema
    declares context keys and values as `^[a-z0-9]+$`, which would reject `project-0` and
    `project-1`, though LuckPerms itself permits hyphens. The schema is also inconsistent
    about whether `context` is an array of pairs or an object. Both must be confirmed
    against a running instance before `permissions.yml` relies on per-server contexts for
    the project servers. If the pattern is enforced, the fallback is to use `global`
    context with permission keys that encode the server instead.

The cloudflared hop is **not** verified end-to-end. Caddy is tested by temporarily
publishing a local port, which is removed afterward. cloudflared ships configured but
unverified, with exact dashboard steps documented.

## Out of scope

Explicitly deferred, by decision:

- **Rotating the committed secret** `management-server-secret=Pw4mZIYJ...` in
  `src/survival/server/server.properties`. It remains in git history regardless; full
  removal needs a history rewrite across repositories.
- **Extending backup coverage.** This is **intentional and correct**, not an oversight.
  `backup` archives only `survival`, `project-0`, and `project-1` because those are the
  only volumes holding state that accrues over time. `lobby` and `onboarding` worlds are
  defined in code and restored from the image on every start, so a backup would only
  duplicate what git already holds. `velocity` and `mchprs` hold no durable state worth
  restoring. Do not "fix" this.
- **Cloudflare Access** in front of the admin hostname. Protection is the WebDAV
  password and the LuckPerms bearer token; both must be strong.
- **A dedicated Minecraft proxy** for `mc.illiniredstone.org`; `25565` stays published.
- **Fixing the MCHPRS matcher panic upstream.** Worked around in `permissions.yml`.

## Appendix A — audit findings

Confirmed problems the implementation must address.

**Blockers**

1. Submodules empty without explicit initialization.
2. `backup.config` absent and gitignored; `env_file` aborts the stack.
3. `webdav` mounts the placeholder `/path/to/your/files`.

**WebDAV**

4. `sfuhrm/docker-nginx-webdav` listens on **8080**, not 80; the `8080:80` mapping is wrong.
5. Attached to no network, no `depends_on: volume_init`, mounts none of `managed-files`.
6. `WEBDAV_USERNAME` / `WEBDAV_PASSWORD` missing from `.env.example`.
7. Single user only, no scoping.
8. nginx runs as uid 100; `volume_init`'s one-time `chmod 777` does not cover
   directories the servers create later as uid 1000.
9. Entrypoints revert WebDAV edits on every restart.

**Cloudflare / edge**

10. `src/caddy/Caddyfile` exists but no `caddy` service does; it still references the
    removed `sftpgo`.
11. `luckperms-standalone` joins `frontend-network` but publishes nothing, so it is
    currently unreachable.
12. cloudflared cannot strip path prefixes; the LuckPerms REST API has no base-path
    option, so `/luckperms*` must be rewritten by a reverse proxy.
13. `--token` forces remote management; a local ingress `config.yml` is ignored.
14. `MINECRAFT_HOSTNAME` is unused.

**LuckPerms**

15. `velocity` receives no `LUCKPERMS_*` variables and silently runs on local H2.
16. `velocity`'s `config.yml` uses `LUCKPERMS_DB_*` names that collide in meaning with
    the `.env` variable of the same name.
17. All five Fabric `luckperms.conf` files hardcode `messaging-service = "redis"` with
    `redis.enabled = true` pointing at the nonexistent `luckperms_messenger:6379`.
18. The four submodule entrypoints never render `luckperms.conf`, so literal
    `${LUCKPERMS_DATA_ADDRESS:-localhost:5432}` text reaches `/data`.
19. Database credential defaults are self-inconsistent.
20. `Initialization-1.0-SNAPSHOT.jar` is a committed binary with no source, creating
    three empty groups.
21. Submodule secret injection via `sed` corrupts secrets containing `/`, `&`, or `\`.

**MCHPRS**

22. Its matcher panics when a stored node is a strict prefix of a queried node.
23. It ignores the `luckperms_players` primary-group table, resolving inheritance only
    through `group.`-prefixed nodes.
24. It honors only `global` and its own `mchprs` server context.

**Hygiene**

25. `sftpgo-data` and `wireguard-module-data` volumes unused; `wg0.conf.example` and the
    commented `sftpgo` block are dead.
26. `velocity` lacks a `restart:` policy.
27. `.env.example` names the wrong target file and carries dead variables.
28. *(Retracted — see [Appendix B](#appendix-b--retracted-findings). `lobby` and
    `onboarding` overwriting the world on every restart is intentional.)*

## Appendix B — retracted findings

Initially reported, then disproved against upstream sources. **Do not "fix" these.**

| Claim | Why it was wrong |
| --- | --- |
| The `luckperms-standalone` healthcheck targets the wrong port/path | Port 3001 is the standalone heartbeat server, started when the app runs with `--docker`, independent of the REST API's 8080. `HeartbeatHttpServer` registers `createContext("/health", ...)`, and Java's `HttpServer` matches contexts by path prefix, so `/healthz` resolves to it. `wget` is present. The check works. The only note: the base image already declares a stricter check (`grep -c '"up":true'`), so the compose override is redundant and may simply be deleted. |
| `velocity` has no healthcheck, so `service_healthy` dependencies fail | `itzg/mc-proxy` declares `HEALTHCHECK --start-period=10s CMD /usr/bin/health.sh`. `HEALTHCHECK` is inherited unless explicitly overridden, and `src/velocity/Dockerfile` overrides only `CMD`. `health.sh` reads `.bind` from `velocity.toml` in WORKDIR `/server` — where the entrypoint places it — resolving port 25565. |
| mchprs is missing `:3306` on `LUCKPERMS_DATA_ADDRESS` | MCHPRS passes `host` to `OptsBuilder::ip_or_hostname()`, which takes a hostname only and defaults the port. The bare `luckperms-db` is correct; adding `:3306` would break it. |
| `lobby` and `onboarding` clobber the live world on every restart | Intentional. Those worlds are code artifacts: builders publish a new design by rebuilding the image, and players are in adventure mode and cannot modify blocks. The image is authoritative by design. This is also why neither is backed up. |
| `backup` is missing `lobby`, `onboarding`, `mchprs`, and `velocity` | Intentional. Only `survival`, `project-0`, and `project-1` accrue state over time. The lobby and onboarding worlds live in git; `velocity` and `mchprs` hold no durable state. |

## References

- [hacdias/webdav — configuration and subpath serving](https://github.com/hacdias/webdav)
- [LuckPerms REST API](https://github.com/LuckPerms/rest-api)
- [LuckPerms `EnvironmentVariableConfigAdapter`](https://github.com/LuckPerms/LuckPerms/blob/master/common/src/main/java/me/lucko/luckperms/common/config/generic/adapter/EnvironmentVariableConfigAdapter.java)
- [LuckPerms `HeartbeatHttpServer`](https://github.com/LuckPerms/LuckPerms/blob/master/standalone/app/src/main/java/me/lucko/luckperms/standalone/app/utils/HeartbeatHttpServer.java)
- [MCHPRS permissions module](https://github.com/MCHPR/MCHPRS/blob/master/crates/core/src/permissions/mod.rs)
- [itzg/docker-mc-proxy healthcheck](https://github.com/itzg/docker-mc-proxy)
- [Cloudflare Tunnel configuration file](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/)
- [cloudflared#1029 — `--config` ignored with `--token`](https://github.com/cloudflare/cloudflared/issues/1029)
- [Compose `env_file` `required`](https://docs.docker.com/reference/compose-file/services/#env_file)

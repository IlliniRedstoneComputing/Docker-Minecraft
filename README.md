# IRC Minecraft

A Docker Compose deployment running several Minecraft servers behind a Velocity proxy,
with shared LuckPerms permissions, a WebDAV interface over the server data volume, and a
Cloudflare tunnel for administrative access.

`compose.yml` is the live definition. `compose-old.yml` is kept for history only.

## Architecture

```
                     mc.illiniredstone.org:25565
                                |
                                v
                          [ velocity ]  <-- the only published port
                                |
        +---------+---------+---+-----+-----------+-----------+
        |         |         |         |           |           |
     lobby    survival  onboarding  mchprs    project-0   project-1
        |         |         |         |           |           |
        +---------+---------+----+----+-----------+-----------+
                                |
                        [ luckperms-db ]  (MariaDB)
                                ^
                                |
                     [ luckperms-standalone ]  (REST API)


        mc-admin.illiniredstone.org
                    |
                    v
            [ cloudflared ] --> [ caddy ] --+--> /files*     --> [ webdav ]
                                            |
                                            +--> /luckperms* --> [ luckperms-standalone ]
```

All server data lives in subdirectories of a single `managed-files` volume, created and
permissioned by the `volume_init` one-shot service. WebDAV exposes that whole volume.

### Networks

| Network | Services |
| --- | --- |
| `frontend-network` | `cloudflared`, `caddy`, `webdav`, `luckperms-standalone`, `luckperms-init` |
| `minecraft-network` | `velocity`, the six servers, `luckperms-db`, `luckperms-standalone`, `backup` |

`25565` on `velocity` is the only published port. Minecraft cannot traverse a standard
Cloudflare tunnel — TCP requires `cloudflared access` on every client or paid Spectrum —
so it is reached directly via a plain DNS record.

## Setup

1. **Create `.env`** from the template and fill in real secrets:

   ```bash
   cp .env.example .env
   ```

   Set the LuckPerms database credentials *before* the first `docker compose up`.
   MariaDB honours `MARIADB_USER` and `MARIADB_PASSWORD` only while it initializes an
   empty data directory. Once the `luckperms-db-data` volume exists, editing them in
   `.env` changes nothing on the server and every client is denied access instead --
   including `root`, so it does not present as one service being misconfigured.
   Recovering means dropping that volume, which re-runs initialization against the
   current `.env`.

2. **Optionally set up backups.** The `backup` service is **opt-in**: it declares
   `profiles: [backup]`, so the command in step 4 does not start it. Create
   `backup.config` from `backup.config.example`, then:

   ```bash
   docker compose --profile backup up -d
   ```

   The profile exists because the service is not inert when unconfigured. Measured: with
   `backup.config` absent and no backend variables set, it logs `Successfully scheduled
   backup from environment with expression @daily` — `@daily` being
   `offen/docker-volume-backup`'s own default. With no storage backend there is nowhere
   for the archive to go, and the `docker-volume-backup.stop-during-backup=true` labels
   on all seven game servers and `velocity` mean a run stops the network to produce
   nothing. Do not enable the profile until a backend is configured.

3. **Set up the Cloudflare tunnel** (one time, in the Zero Trust dashboard):
   - Create a tunnel and copy its token into `CLOUDFLARE_TUNNEL_TOKEN` in `.env`.
   - Add one public hostname: `mc-admin.illiniredstone.org` → `http://caddy:80`.
   - Add an `A` record for `mc.illiniredstone.org` pointing at the host, for port 25565.

   The tunnel is token-authenticated, which means it is *remotely managed* — a local
   `config.yml` with ingress rules would be silently ignored. That is fine here, because
   Caddy handles all routing, so the dashboard needs only the single hostname above.

4. **Start it:**

   ```bash
   docker compose up -d
   ```

## Design decisions worth knowing

These exist to prevent well-intentioned changes that would break things.

### Which data is backed up, and why

`backup` archives **`survival`, `project-0`, `project-1` and `mchprs`**, and is opt-in.
This is deliberate.

- **`lobby` and `onboarding` are excluded**, though for different reasons than one
  sentence can carry. `lobby`'s world is defined in code rather than accumulated through
  play: its players are in adventure mode and cannot modify blocks, the lobby changes
  only when builders publish a new design by rebuilding the image, and the world is
  restored from that image on every start — so a backup would duplicate what git already
  holds. **`onboarding` does not match that description yet.** It ships an empty world
  and runs survival mode, so nothing restores its world and nothing backs it up. The
  world in that volume is a disposable placeholder, confirmed by the maintainer, so the
  exclusion stands — it is just true for a different reason. Item 5 of
  [`AGENTS.md`](AGENTS.md) records it.
- **`velocity` is excluded** because it holds no durable state worth restoring: a jar,
  config, logs and lang files, nothing that accrues.
- **`mchprs` is included**, as of 2026-10-28. It was previously excluded on the same
  "no durable state" grounds as `velocity`, which was false: `mchprs/world/plots.db`,
  `world/plots`, `world/players` and `schems` are player-built redstone and saved
  schematics, held only in the volume. Item 5 of [`AGENTS.md`](AGENTS.md) records the
  correction.

The service declares `profiles: [backup]`, so `docker compose up -d` does not start it.
Unconfigured it would schedule a daily run with nowhere to write while holding the power
to stop every server; start it with `docker compose --profile backup up -d` once a
storage backend is set.

The same reasoning drives the seeding policy below: backups and world-seeding follow the
same line between "state that accrues" and "state defined in code."

### What survives a restart

Server images seed the data volume on start. What gets overwritten depends on whether a
path is image-controlled or admin-controlled:

| Path | Policy |
| --- | --- |
| `mods/` (and velocity `plugins/`) | re-synced every start, so upgrades land |
| `config/`, `server.properties` | seeded only if absent, so edits persist |
| `velocity.toml` | seeded only if absent, so backend servers can be added |
| `forwarding.secret` | always rewritten, so rotation propagates **to the proxy only** -- every backend keeps its old copy until you delete it, see the rotation caveat in each `src/*/entrypoint.sh` |
| `world/` — `lobby` | re-synced every start; the world is a code artifact |
| `world/` — `onboarding` | re-synced every start **in policy only** — the image ships an empty world, so in practice nothing overwrites it and nothing backs it up |
| `world/` — `survival`, `project-*`, `mchprs` | never touched; player-owned state |

Anything in the "seeded only if absent" rows can be edited durably over WebDAV. Anything
re-synced every start cannot — change it in the image instead.

**`onboarding/world/` is the exception to that rule.** The policy says re-synced, but
nothing re-syncs it: the image ships an empty world, so the volume holds the only copy,
in neither git nor the backup set. That copy is a disposable placeholder by design, so
losing it costs nothing — but unlike the other re-synced rows, a write to it *does*
persist. Item 5 of [`AGENTS.md`](AGENTS.md) has the detail.

### Permissions are defined in code

LuckPerms groups, permissions, weights, inheritance, and tracks are declared in
`src/luckperms-init/permissions.yml` and applied by a one-shot `luckperms-init` service
on every `docker compose up`.

**That file is authoritative for the groups it manages.** Changes made to a managed group
through the LuckPerms web editor are overwritten on the next start. Groups absent from
the file are never touched, so ad-hoc groups remain available as an escape hatch —
provided the ad-hoc group outweighs any managed group that denies the same key, since the
highest-weight value wins. [`docs/api.md`](docs/api.md#some-groups-are-managed-in-code)
has the measured detail.

### LuckPerms configuration comes from the environment

LuckPerms resolves configuration in the order: file secrets → system properties →
**environment variables** → config file, on every platform. Storage, credentials, and
messaging are therefore set via `LUCKPERMS_*` variables in `compose.yml`, and the
per-server config files carry only their `server = "<name>"` identity. Do not reintroduce
connection settings into those files.

## Operations

Start, stop, and inspect:

```bash
docker compose up -d
docker compose ps
docker compose logs -f velocity
docker compose down
```

Rebuild one server after changing its image content:

```bash
docker compose up -d --build survival
```

Re-apply the permission model without a full restart:

```bash
docker compose up --force-recreate luckperms-init
```

### Resource note

Six servers at `-Xmx2G` plus Velocity is roughly 14 GB of heap before MariaDB and
overhead. On a smaller host, lower `JAVA_OPTS` in `.env` or start the servers in stages.

## Tests

Three of the four suites under `tests/` exercise a running stack, so bring it up first —
see the resource note above. The fourth, `test-compose-config.sh`, is static and needs
nothing running. Then:

```bash
bash tests/run-all.sh
```

| Suite | Covers |
| --- | --- |
| `test-compose-config.sh` | Static validation of the rendered config: one published port, shared-volume ownership, the WebDAV and cloudflared service shapes, the LuckPerms healthcheck needle, consistent credential defaults |
| `test-webdav.sh` | WebDAV through Caddy: prefix handling, `Destination` rewriting, writes into a collection the client creates with `MKCOL`, and that neither route's prefix leaks onto a longer path |
| `test-luckperms.sh` | Shared MariaDB storage on every Fabric server and the proxy, no H2 fallback, cross-server messaging |
| `test-seeder.sh` | That hyphenated permission contexts are accepted, and that the permission model applies correctly and re-running it changes nothing |

`run-all.sh` fails the run if any suite fails **or** exits 0 without reaching its summary
line — a suite that died early would otherwise pass silently.

## Documentation

- [`docs/api.md`](docs/api.md) — the HTTP surface for remote administration tools
- [`AGENTS.md`](AGENTS.md) — conventions and verified behaviors, for coding agents
- [`docs/superpowers/specs/`](docs/superpowers/specs/) — design specifications

## References

Upstream sources this deployment depends on, consulted when verifying its behavior.

- [hacdias/webdav — configuration and subpath serving](https://github.com/hacdias/webdav)
- [LuckPerms REST API](https://github.com/LuckPerms/rest-api)
- [LuckPerms configuration](https://luckperms.net/wiki/Configuration)
- [LuckPerms `EnvironmentVariableConfigAdapter`](https://github.com/LuckPerms/LuckPerms/blob/master/common/src/main/java/me/lucko/luckperms/common/config/generic/adapter/EnvironmentVariableConfigAdapter.java)
- [LuckPerms `HeartbeatHttpServer`](https://github.com/LuckPerms/LuckPerms/blob/master/standalone/app/src/main/java/me/lucko/luckperms/standalone/app/utils/HeartbeatHttpServer.java)
- [MCHPRS permissions module](https://github.com/MCHPR/MCHPRS/blob/master/crates/core/src/permissions/mod.rs)
- [itzg/docker-mc-proxy](https://github.com/itzg/docker-mc-proxy)
- [itzg/docker-minecraft-server](https://github.com/itzg/docker-minecraft-server)
- [offen/docker-volume-backup](https://github.com/offen/docker-volume-backup)
- [Cloudflare Tunnel configuration file](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/)
- [cloudflared#1029 — `--config` is ignored when `--token` is used](https://github.com/cloudflare/cloudflared/issues/1029)
- [cloudflared#563 — ingress cannot rewrite the origin path](https://github.com/cloudflare/cloudflared/issues/563)
- [Compose `env_file` `required` attribute](https://docs.docker.com/reference/compose-file/services/#env_file)

## License

See [LICENSE](LICENSE).

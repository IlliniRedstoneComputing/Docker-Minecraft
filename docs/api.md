# External API surface

What this deployment exposes to the outside world, and how a remote administration
service should talk to it.

> **Status:** implemented and verified against a running stack. The cloudflared
> hop is configured but not exercised end-to-end; everything from Caddy inward
> is covered by `tests/`.

## Overview

Two HTTP surfaces sit behind a single hostname, plus one raw TCP port that is not part
of the API.

| Surface | Path | Purpose | Auth |
| --- | --- | --- | --- |
| WebDAV | `https://mc-admin.illiniredstone.org/files` | Read/write server data files | HTTP Basic |
| LuckPerms REST | `https://mc-admin.illiniredstone.org/luckperms` | Players, groups, permissions | Bearer token |
| Minecraft | `mc.illiniredstone.org:25565` | Game traffic | Minecraft protocol |

Anything else — MariaDB, the Velocity admin surface, the internal Caddy and WebDAV ports
— is **not reachable from outside**. There is no published port for them and no tunnel
route. A remote administration service must work entirely through the two HTTP surfaces
above.

### Transport

Both surfaces are reached through a Cloudflare tunnel terminating at an internal Caddy
instance. Consequences worth designing around:

- **TLS is terminated by Cloudflare.** Clients always use `https://`.
- **Cloudflare's request timeouts and body-size limits apply.** Large world uploads over
  WebDAV should be chunked rather than sent as one enormous `PUT`.
- **There is no separate staging hostname.** Treat writes as production.

### Credentials

| Secret | `.env` variable | Used for |
| --- | --- | --- |
| WebDAV username | `WEBDAV_USERNAME` | HTTP Basic user |
| WebDAV password | `WEBDAV_PASSWORD` | HTTP Basic password |
| LuckPerms API key | `LUCKPERMS_SECRET` | `Authorization: Bearer <key>` |

Both are **shared service credentials**, not per-person accounts. There is deliberately
no user model at this layer — see [Authorization model](#authorization-model).

## Authorization model

This deployment provides **authentication, not authorization**. The WebDAV service is a
single account with full create/read/update/delete over the entire data volume, and the
LuckPerms API key is all-or-nothing.

Per-user identity, role checks, audit logging, and scoping of who may touch which server
are the **remote administration service's responsibility**. It holds these two
credentials, presents its own login to humans, and enforces its own policy before
proxying an action through.

Practical implications for that service:

- Never expose these credentials to a browser or hand them to an end user.
- Scope every request server-side. Nothing here will stop a request that targets the
  wrong directory or the wrong group.
- Keep your own audit trail. LuckPerms records its own actions (see
  [`GET /action`](#actions-and-audit)), but WebDAV writes are not attributed to a human.

## WebDAV surface

Base: `https://mc-admin.illiniredstone.org/files`

A standard WebDAV server ([hacdias/webdav](https://github.com/hacdias/webdav)) exposing
the `managed-files` volume. Supported methods: `GET`, `HEAD`, `PUT`, `DELETE`, `MKCOL`,
`COPY`, `MOVE`, `PROPFIND`, `PROPPATCH`, `LOCK`, `UNLOCK`, `OPTIONS`, `PATCH`.

### Directory layout

Each Minecraft server owns one top-level directory:

```
/files/
├── velocity/       proxy config, plugins
├── lobby/
├── survival/
├── onboarding/
├── mchprs/
├── project-0/
└── project-1/
```

Inside a Fabric server directory the paths that matter are `config/`, `mods/`,
`server.properties`, `world/`, and `logs/`.

### What is safe to write

Writes to some paths are silently reverted on the next container restart, because the
image re-seeds them. This is the single most important thing to get right.

| Path | Durable? | Notes |
| --- | --- | --- |
| `<server>/config/**` | **Yes** | Seeded only if absent |
| `<server>/server.properties` | **Yes** | Seeded only if absent |
| `velocity/velocity.toml` | **Yes** | Seeded only if absent |
| `survival/world/**`, `project-*/world/**`, `mchprs/world/**` | **Yes** | Player-owned state |
| `<server>/mods/**`, `velocity/plugins/**` | **No** | Re-synced from the image every start |
| `lobby/world/**` | **No** | The world is a code artifact, re-synced from the image every start |
| `onboarding/world/**` | **No, but not for the stated reason** | The image ships an empty world, so nothing re-syncs it — the volume copy is a disposable placeholder, see the caveat below |
| `velocity/forwarding.secret` | **No** | Always rewritten from the environment |

A remote administration service should refuse — or at minimum loudly warn on — writes to
the "No" rows, since they will appear to succeed and then vanish.

**Caveat on `onboarding/world/**`.** The seeding policy treats it as a code artifact, the
same as `lobby`'s, but `src/onboarding/server/world` currently holds only a `.gitkeep`.
The re-sync therefore copies nothing, and the live world is whatever the server
generated in the volume — present in neither git nor the backup set. The maintainer has
confirmed that world is a **disposable placeholder**, so discarding it loses nothing, but
note that it is the one "No" row where a write would in fact persist. Once a real
onboarding world is published into the image this becomes the same case as `lobby`. See
[`AGENTS.md`](../AGENTS.md) item 5.

**Caveat on `<server>/config/**`.** "Durable" in that row means the *seeding* policy will
not overwrite the file. It does not mean a running mod will leave it alone.
`FabricProxy-Lite` parses its TOML through night-config and **writes the file back** — on
load, and again at JVM shutdown. Two consequences a remote administration service has to
handle:

- **Comments do not survive.** An appended `# comment` is gone within about ten seconds
  of boot.
- **Edits made while the server is running are silently discarded at shutdown**, because
  the mod serializes its in-memory state over whatever is on disk. Only edits made while
  the server is stopped, or applied through the game, are safe. Value edits made while
  stopped do persist: verified with `disconnectMessage` across a restart, alongside a
  brand-new `zz-admin-probe.toml`, which also survived.

The proof that the mod, and not the entrypoint's `cp -a`, is the writer is a line-ending
conversion no copy can perform. Re-measured on the running stack on 2026-09-24, and
identical on all five Fabric servers:

| File | In the image | Live in the volume |
| --- | --- | --- |
| `config/FabricProxy-Lite.toml` | 172 bytes, 4 CR | **169 bytes, 0 CR** |
| `config/luckperms/luckperms.conf` | 33894 bytes, 684 CR | 33894 bytes, 684 CR |

So the rule is neither "config is durable" nor "config is volatile". It is a three-way
split, and the split is mechanical enough to state as a test:

1. **Inert, durable.** Shipped in the image and byte-identical after boot. Today that is
   `config/luckperms/luckperms.conf`, which LuckPerms reads and does not rewrite.
2. **Mod-owned, shipped.** Shipped in the image and rewritten by a loaded mod. Today that
   is `config/FabricProxy-Lite.toml` alone.
3. **Mod-owned, generated.** Not in the image at all; a mod created it on first boot. At
   the time of writing: `config/ferritecore.mixin.properties`, `config/lithium.properties`,
   and `config/spark/config.json`. These were **not** individually tested for
   rewrite-on-shutdown — they are treated as category 2 because their writer is a running
   mod.

Do not treat that category-3 list as exhaustive. It is whatever mods happen to be loaded,
so it changes with a mod bump. Derive it instead of hardcoding it: **anything in
`/data/config` with no counterpart in `/usr/src/init_data/config` was created by a mod,
and is therefore owned by one.**

**So:** stop the target server before editing anything in category 2 or 3, and never rely
on a comment as a carrier for anything — in a mod-owned file it will not survive the next
boot.

### Two required client behaviors

**1. The `/files` prefix must be present on both the request path and the `Destination`
header.** The server is configured with `prefix: /files` and strips it itself. A request
missing the prefix is answered `400 Bad Request`.

**2. `Destination` must be path-only for `COPY` and `MOVE`.** Caddy rewrites
`https://host/files/x` to `/files/x` on the way in, so a well-behaved client sending an
absolute URL works — but a client sending something Caddy's rewrite does not match will
fail. Sending a path-only `Destination` is the safe choice.

### Examples

List a directory:

```bash
curl -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" \
  -X PROPFIND -H 'Depth: 1' \
  https://mc-admin.illiniredstone.org/files/survival/config/
```

Upload a config file:

```bash
curl -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" \
  -T ./luckperms.conf \
  https://mc-admin.illiniredstone.org/files/survival/config/luckperms/luckperms.conf
```

Move a file (note the path-only `Destination`):

```bash
curl -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" \
  -X MOVE \
  -H 'Destination: /files/survival/config/old.conf' \
  https://mc-admin.illiniredstone.org/files/survival/config/new.conf
```

### Status codes

| Code | Meaning |
| --- | --- |
| `207` | Multi-status — normal `PROPFIND` response |
| `201` / `204` | Created / overwritten |
| `400` | Missing `/files` prefix on the path or `Destination` |
| `401` | Bad or missing Basic credentials |
| `409` | Parent collection does not exist — `MKCOL` it first |
| `423` | Locked |

## LuckPerms REST surface

Base: `https://mc-admin.illiniredstone.org/luckperms`

Caddy strips the `/luckperms` prefix, so the upstream paths below are what you append.
Authenticate every request with `Authorization: Bearer $LUCKPERMS_SECRET`.
Full upstream reference: [LuckPerms/rest-api](https://github.com/LuckPerms/rest-api).

### Endpoints

**Users**

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/user` | List all users |
| `POST` | `/user` | Create a user |
| `GET` | `/user/lookup` | Resolve a username to a UUID, or vice versa |
| `GET` | `/user/search` | Find users holding given nodes |
| `GET` | `/user/{uniqueId}` | Get a user |
| `PATCH` | `/user/{uniqueId}` | Update a user |
| `DELETE` | `/user/{uniqueId}` | Delete a user |
| `GET` | `/user/{uniqueId}/nodes` | Get a user's nodes |
| `POST` | `/user/{uniqueId}/nodes` | Add one node |
| `PATCH` | `/user/{uniqueId}/nodes` | Add several nodes |
| `PUT` | `/user/{uniqueId}/nodes` | **Replace** all nodes |
| `DELETE` | `/user/{uniqueId}/nodes` | Remove nodes |
| `GET` | `/user/{uniqueId}/meta` | Resolved prefix, suffix, meta, primary group |
| `GET`/`POST` | `/user/{uniqueId}/permission-check` | Test a permission |
| `POST` | `/user/{uniqueId}/promote` | Promote along a track |
| `POST` | `/user/{uniqueId}/demote` | Demote along a track |

**Groups**

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/group` | List all groups |
| `POST` | `/group` | Create a group |
| `GET` | `/group/search` | Find groups holding given nodes |
| `GET` | `/group/{groupName}` | Get a group |
| `DELETE` | `/group/{groupName}` | Delete a group |
| `GET` | `/group/{groupName}/nodes` | Get a group's nodes |
| `POST` | `/group/{groupName}/nodes` | Add one node |
| `PATCH` | `/group/{groupName}/nodes` | Add several nodes |
| `PUT` | `/group/{groupName}/nodes` | **Replace** all nodes |
| `DELETE` | `/group/{groupName}/nodes` | Remove nodes |
| `GET` | `/group/{groupName}/meta` | Resolved metadata |
| `GET`/`POST` | `/group/{groupName}/permission-check` | Test a permission |

**Tracks**

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/track` | List tracks |
| `POST` | `/track` | Create a track |
| `GET` | `/track/{trackName}` | Get a track |
| `PATCH` | `/track/{trackName}` | Set the track's ordered group list |
| `DELETE` | `/track/{trackName}` | Delete a track |

**Messaging, actions, events, health**

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/messaging/update` | Push a full update to all connected servers |
| `POST` | `/messaging/update/{uniqueId}` | Push one user's update |
| `POST` | `/messaging/custom` | Send a custom message |
| `GET` | `/action` | Query the action log |
| `POST` | `/action` | Submit an action log entry |
| `GET` | `/event/log-broadcast` | SSE stream of log broadcasts |
| `GET` | `/event/post-sync` | SSE stream, fired after a sync |
| `GET` | `/event/post-network-sync` | SSE stream, fired after a network sync |
| `GET` | `/event/pre-sync` | SSE stream, fired before a sync |
| `GET` | `/event/pre-network-sync` | SSE stream, fired before a network sync |
| `GET` | `/event/custom-message-receive` | SSE stream of custom messages |
| `GET` | `/health` | Application health |

### The node model

A node is the single unit of permission data. **Its type is encoded in its key**, so you
do not pass a separate type field when creating one:

| Key shape | Meaning |
| --- | --- |
| `minecraft.command.ban` | A plain permission |
| `group.member` | Inheritance — makes the holder a member of `member` |
| `weight.100` | Group weight |
| `prefix.100.&c[Admin] ` | Prefix at priority 100 |
| `suffix.50.&7[dev]` | Suffix at priority 50 |
| `meta.nametag-color.red` | A meta key/value pair |

Node fields:

```json
{
  "key": "minecraft.command.ban",
  "value": true,
  "context": [ { "key": "server", "value": "survival" } ],
  "expiry": 1758499200
}
```

`value: false` is a **negated** permission, which is meaningful — it is not the same as
omitting the node. `context` is an array of `{key, value}` pairs; an empty array means
global. `expiry` is epoch seconds and is optional.

> **Verified:** hyphenated context values such as `project-0` are accepted, even
> though the OpenAPI schema declares context keys and values as `^[a-z0-9]+$`.
> The schema is stricter than the implementation. `context` is sent as an array
> of `{key, value}` pairs.

### Examples

Resolve a username to a UUID:

```bash
curl -H "Authorization: Bearer $LUCKPERMS_SECRET" \
  'https://mc-admin.illiniredstone.org/luckperms/user/lookup?username=Notch'
```

Grant a permission on one server only:

```bash
curl -H "Authorization: Bearer $LUCKPERMS_SECRET" \
  -H 'Content-Type: application/json' \
  -X POST \
  -d '{"key":"minecraft.command.gamemode","value":true,"context":[{"key":"server","value":"survival"}]}' \
  https://mc-admin.illiniredstone.org/luckperms/user/<uuid>/nodes
```

Promote along the onboarding track:

```bash
curl -H "Authorization: Bearer $LUCKPERMS_SECRET" \
  -H 'Content-Type: application/json' \
  -X POST -d '{"track":"onboarding"}' \
  https://mc-admin.illiniredstone.org/luckperms/user/<uuid>/promote
```

## Behavior a remote service must account for

### Permission changes do not propagate instantly everywhere

| Target | Propagation |
| --- | --- |
| Fabric servers, Velocity | Via the SQL messaging service. Near-immediate; call `POST /messaging/update` to force it. |
| **MCHPRS** | **Only on player relog.** It reads the database directly, has no messaging support, and rebuilds its cache when a player joins. |

After any change that should take effect immediately, call `POST /messaging/update`. For
MCHPRS, tell the operator the player must reconnect.

### MCHPRS ignores parts of the permission model

MCHPRS reads only the `luckperms_user_permissions` and `luckperms_group_permissions`
tables and resolves inheritance through `group.`-prefixed nodes. Therefore:

- **Group membership must exist as an explicit `group.<name>` node on the user.** Setting
  a primary group alone is invisible to MCHPRS.
- **Only `global` and `mchprs` server contexts are visible to it.**
- **Never create a node that is a strict prefix of another node MCHPRS will query.** Its
  matcher panics with an index-out-of-bounds in that case. Use exact keys or explicit `*`
  wildcards.

### Some groups are managed in code

Groups declared in `src/luckperms-init/permissions.yml` are re-applied on every
`docker compose up`, and their node sets are **replaced wholesale**. Changes a remote
service makes to a managed group will be reverted on the next deployment.

Groups *not* in that file are never touched and are safe for runtime management. A remote
administration service should read that file, or maintain its own list, and mark managed
groups read-only in its UI.

**"Never touched" is not the same as "always effective."** A user's parent groups resolve
highest-weight-first and the first value found wins, so an ad-hoc group weighted below a
managed group that **denies** the same key loses — silently, with no error anywhere.
Measured against the live API: against `onboarder`'s deny of `irc.server.survival` at
weight 10, an ad-hoc grant of that key resolves false at weight 0 and true at weight 11.
Give an ad-hoc group a weight above every managed group that denies a key it grants.

### Actions and audit

`GET /action` exposes the LuckPerms action log — who changed what, as recorded by
LuckPerms. `POST /action` lets an external service write its own entries, which is worth
doing so that changes made through the remote service are attributable to a human rather
than to the shared API key.

WebDAV writes are **not** logged this way. Attribution for file changes must come from
the remote service's own audit trail.

## Health checks

| Check | Request | Healthy response |
| --- | --- | --- |
| LuckPerms | `GET /luckperms/health` | `200` with `"healthy":true` in the body |
| WebDAV | `PROPFIND /files/ Depth: 0` | `207` |

**The field is `healthy`, not `up`.** Measured through Caddy on a running stack:

```json
{"healthy":true,"details":{"storageConnected":true,"storagePing":2}}
```

This table previously said `"up":true`. That is the needle the LuckPerms base image's
own healthcheck greps for, and it can never match this version -- the same mistake
`AGENTS.md` item 1 documents for the container healthcheck, repeated here in the document
an external administration tool would be built against. The REST API on 8080 and the
heartbeat server on 3001 were both checked: they return the same schema.

WebDAV has no dedicated health endpoint — the image is built `FROM scratch` and contains
no shell or HTTP client, so a cheap `PROPFIND` is the liveness probe.

## References

- [LuckPerms REST API](https://github.com/LuckPerms/rest-api)
- [LuckPerms OpenAPI specification](https://github.com/LuckPerms/rest-api/blob/main/src/main/resources/luckperms-openapi.yml)
- [LuckPerms context system](https://luckperms.net/wiki/Context)
- [hacdias/webdav](https://github.com/hacdias/webdav)
- [RFC 4918 — HTTP Extensions for WebDAV](https://www.rfc-editor.org/rfc/rfc4918)

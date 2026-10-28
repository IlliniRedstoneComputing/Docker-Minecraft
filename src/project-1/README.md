# Docker Fabric Server Template (1.21.8 + Velocity)

This repository is a template for a Dockerized, version-controlled Minecraft backend server:

- Server type: Fabric
- Minecraft version: 1.21.8
- Base image: `itzg/minecraft-server`
- Proxy setup: Velocity (with FabricProxy-Lite)

Use this template to keep your server config, mods, and startup behavior in Git while still running the world data in a mounted volume.

## What this template gives you

- Reproducible server runtime from `Dockerfile`
- Runtime initialization from `entrypoint.sh`
- Git-tracked server baseline in `server/`:
  - `mods/`
  - `config/FabricProxy-Lite.toml`
  - `server.properties`
- Environment-driven runtime settings via `.env`

At startup, the image copies template files from `/usr/src/init_data` into `/data` and injects your Velocity secret into FabricProxy-Lite config.

## Project layout

```
.
├── Dockerfile
├── entrypoint.sh
├── .env.example
└── server/
    ├── mods/
    ├── config/
    │   └── FabricProxy-Lite.toml
    └── server.properties
```

## Prerequisites

- Docker installed
- At least 2 GB RAM available for the container
- A Velocity proxy configured to forward players to this backend

## Quick start

1. Copy the environment template:

   PowerShell:

   ```powershell
   Copy-Item .env.example .env
   ```

   Bash:

   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and set at least:

   ```dotenv
   JAVA_OPTS=-Xmx2G -Xms1G
   VELOCITY_SECRET=replace-with-your-velocity-forwarding-secret
   ```

3. Build the image:

   ```bash
   docker build -t project0-mc-server .
   ```

4. Run the container with `server/` mounted to `/data`:

   PowerShell:

   ```powershell
   docker run -d --name project0-mc-server -p 25565:25565 --env-file .env -v "${PWD}\server:/data" project0-mc-server
   ```

   Bash:

   ```bash
   docker run -d \
      --name project0-mc-server \
      -p 25565:25565 \
      --env-file .env \
      -v "${PWD}/server:/data" \
      project0-mc-server
   ```

5. Check logs:

   ```bash
   docker logs -f project0-mc-server
   ```

6. Stop and remove when needed:

   ```bash
   docker stop project0-mc-server
   docker rm project0-mc-server
   ```

## How Velocity integration works

This template expects clients to connect through Velocity, not directly to the backend.

1. `server/config/FabricProxy-Lite.toml` includes:
   - `disconnectMessage` for direct-join attempts
   - `secret = "${VELOCITY_SECRET}"` placeholder
2. `entrypoint.sh` replaces `${VELOCITY_SECRET}` with your real secret at container startup.
3. The backend starts through `/image/scripts/start` from the base image.

Your Velocity proxy must use the same forwarding secret.

## Customizing the template

### 1. Server settings

Edit `server/server.properties` for gameplay/network settings.

### 2. Mods

Add or remove Fabric `.jar` files in `server/mods/`.

### 3. Fabric mod configs

Commit config files in `server/config/` (including `FabricProxy-Lite.toml`) so they are version-controlled with your server.

### 4. JVM memory and runtime env

Set `JAVA_OPTS` in `.env`, for example:

```dotenv
JAVA_OPTS=-Xmx4G -Xms2G
```

### 5. Minecraft version

Change `VERSION` in `Dockerfile` (currently `1.21.8`) and rebuild the image.

## Version-control workflow

Treat this repo as the source of truth for your server template:

1. Edit files under `server/`, `Dockerfile`, or `entrypoint.sh`
2. Test locally with `docker build` + `docker run`
3. Commit changes to Git
4. Rebuild/redeploy from that commit

Recommended: keep world save data and other large mutable runtime data out of Git, but keep template config and mods in Git.

## Common operations

Rebuild after template changes:

```bash
docker build --no-cache -t project0-mc-server .
```

Restart an existing container:

```bash
docker restart project0-mc-server
```

## Connection model

- Preferred: connect players to Velocity only
- Backend direct address (for ops/testing): `<host-ip>:25565`

## Troubleshooting

- Container exits quickly: `docker logs project0-mc-server`
- Velocity players cannot join:
  - confirm `VELOCITY_SECRET` exists in `.env`
  - confirm proxy and backend secrets match
  - confirm forwarding is enabled and configured in Velocity
- Port 25565 in use: change published port or stop conflicting service
- Out of memory: increase `JAVA_OPTS` (for example `-Xmx4G -Xms2G`)

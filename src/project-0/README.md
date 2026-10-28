# Project 0 Container

This project runs a Fabric Minecraft server from a custom Docker image based on `itzg/minecraft-server`.

The image seeds `/data` with:

- `mods/` from `server/mods/`
- `server.properties` from `server/server.properties`

The `assembler/` directory is intentionally unrelated to running the container and is ignored in this guide.

## What’s in this project

```
.
├── Dockerfile
├── entrypoint.sh
├── .env.example
└── server/
    ├── mods/
    └── server.properties
```

## Prerequisites

- Docker installed
- At least 2 GB RAM available for the container

## Quick start

1. Build the image:

   ```bash
   docker build -t project0-mc-server .
   ```

2. (Optional) Copy environment template:

   PowerShell:

   ```powershell
   Copy-Item .env.example .env
   ```

   Bash:

   ```bash
   cp .env.example .env
   ```

   `.env.example` currently defines:

   ```dotenv
   JAVA_OPTS=-Xmx2G -Xms1G
   ```

3. Run the container with `server/` mounted to `/data`:

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

   If you do not want to use an env file, pass memory options directly:

   ```powershell
   docker run -d --name project0-mc-server -p 25565:25565 -e JAVA_OPTS="-Xmx2G -Xms1G" -v "${PWD}\server:/data" project0-mc-server
   ```

4. Follow logs:

   ```bash
   docker logs -f project0-mc-server
   ```

5. Stop and remove:

   ```bash
   docker stop project0-mc-server
   docker rm project0-mc-server
   ```

## How startup works

`entrypoint.sh` performs initialization before launching the server process:

1. Copies `mods` from `/usr/src/init_data/mods` into `/data/mods`
2. Copies `server.properties` from `/usr/src/init_data/server.properties` into `/data/server.properties`
3. Starts the upstream server launcher (`/image/scripts/start`)

## Configuration

### Server properties

Edit `server/server.properties` and restart the container.

### Mods

Place Fabric mod `.jar` files in `server/mods/`, then restart the container.

### Memory

Adjust `JAVA_OPTS` in `.env` (or pass `-e JAVA_OPTS=...` to `docker run`).

## Operations

Rebuild after changing `Dockerfile` or `entrypoint.sh`:

```bash
docker build --no-cache -t project0-mc-server .
```

Restart container:

```bash
docker restart project0-mc-server
```

## Connect to server

- Local: `localhost:25565`
- Remote: `<host-ip>:25565`

## Troubleshooting

- Container exits immediately: check logs with `docker logs project0-mc-server`
- Port conflict: ensure nothing else is using `25565`
- Memory issues: increase `JAVA_OPTS`, for example `-Xmx4G -Xms2G`

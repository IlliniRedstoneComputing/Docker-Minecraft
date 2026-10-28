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
  # FabricProxy-Lite.toml, ends WITHOUT a trailing newline (174 bytes, CR=4 LF=4
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
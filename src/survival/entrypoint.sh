#!/bin/bash
set -e

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
#   - envsubst only expands bare ${VAR} — it doesn't understand the
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

  # The `; printf x` / `%x` dance preserves trailing newlines. A bare
  # $(cat file) strips every trailing newline and `printf '%s'` does not put
  # one back, so rendering a CRLF file silently drops its final CRLF --
  # measured at 14 bytes in, 12 out, CR 2->1 and LF 2->1 on a two-line
  # fixture. That is the same mixed-ending damage AGENTS.md warns about for
  # sed, caused here by the function written to replace sed.
  content=$(cat "$file"; printf x); content="${content%x}"
  result=""
  # Matches ${NAME} or ${NAME:-default}. The default text may be empty
  # (${NAME:-}) but cannot itself contain a literal '}'.
  pattern='\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}'

  while [[ "$content" =~ $pattern ]]; do
    full="${BASH_REMATCH[0]}"      # e.g. ${LUCKPERMS_DATA_ADDRESS:-localhost:5432}
    varname="${BASH_REMATCH[1]}"   # e.g. LUCKPERMS_DATA_ADDRESS
    default="${BASH_REMATCH[3]}"   # e.g. localhost:5432 (empty if no :- clause)
    value="${!varname-}"           # current value of $varname, or "" if unset

    # Match bash's own ${VAR:-default} semantics: treat "unset OR empty"
    # as the trigger for falling back to the default.
    if [[ -z "$value" ]]; then
      value="$default"
    fi

    # Literal split-and-splice -- "$full" is quoted so its glob-special
    # characters (there are none here, but this is the safe habit) are
    # matched literally, not interpreted as patterns.
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
# player-owned state. Contrast with lobby and onboarding, whose worlds are
# code artifacts re-synced from the image on every start.

echo "Initialization complete. Starting server..."

# This executes the CMD from your Dockerfile
exec "/image/scripts/start"
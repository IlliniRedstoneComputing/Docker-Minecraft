#!/bin/bash
set -e

CONFIG_DIR="/usr/src/init_data"

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

  # Preserve the file's trailing newline. A bare $(cat "$file") strips it and
  # `printf '%s'` does not put it back. Measured inside this image on a 14-byte
  # CRLF fixture: 14 bytes in, 13 out, LF 2->1, CR unchanged -- so the file
  # comes back ending in a dangling bare CR with mixed endings. velocity.toml
  # is CRLF and genuinely hits this. The sentinel byte restores it exactly.
  #
  # `&&`, not `;`. With `;` the substitution takes printf's exit status, which
  # is always 0, so a missing or unreadable file would NOT trip `set -e`: the
  # function would fall through with content="", truncate the file to zero
  # bytes, and let the proxy start on it. For forwarding.secret that means an
  # empty secret, which every backend would then reject.
  content=$(cat "$file" && printf x); content="${content%x}"
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
# irc-minecraft-lobby and irc-minecraft-survival both REPLACE the entrypoint and
# still report the base mc-health check. AGENTS.md item 2 states those two facts
# side by side; do not read a causal link into it.
#
# "$@" forwards anything appended at `docker run`, and expands to nothing when
# there is nothing to forward.
exec /usr/bin/run-bungeecord.sh "$@"

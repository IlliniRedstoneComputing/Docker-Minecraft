#!/bin/bash
set -e

CONFIG_DIR="/data"
TEMPLATE_CONFIG="/etc/mchprs/Config.toml"

# Copy template to volume if destination config does not exist
if [ ! -f "$CONFIG_DIR/Config.toml" ]; then
    echo "Config not found in $CONFIG_DIR. Copying default template..."
    cp "$TEMPLATE_CONFIG" "$CONFIG_DIR/Config.toml"
fi

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

  content=$(cat "$file")
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

# ROTATION CAVEAT. The five Fabric entrypoints each carry one of these; mchprs is
# also a backend holding the forwarding secret, and it needs the same warning for a
# different reason. Those render the IMAGE's copy; this one renders the VOLUME's copy,
# in place -- so the first boot substitutes the placeholders and destroys them, and
# every later boot finds no ${...} token left to substitute. The render below is a
# permanent no-op after the first start, and /data/mchprs/Config.toml keeps whatever
# the environment held on that first boot. Every templated value is affected, not just
# the secret: the Velocity forwarding secret AND the LuckPerms database credentials.
#
# To rotate: change the value, delete /data/mchprs/Config.toml, then RECREATE this
# container. `docker compose restart` is NOT enough. Deleting
# /data/config/FabricProxy-Lite.toml on the five Fabric backends -- which is what their
# own caveats tell you to do -- does NOT cover this file, so following those
# instructions alone leaves mchprs on the old secret, presenting as mchprs alone
# refusing proxy connections.
render_env_placeholders "$CONFIG_DIR/Config.toml"

echo "Initialization complete. Starting server..."

cd "/data"

# Hand off to the MCHPRS binary. There is no CMD anywhere in this image:
# src/mchprs/Dockerfile copies the binary out of stackdoubleflow/mchprs onto an
# alpine base and sets ENTRYPOINT to this script, so this line is the only thing
# that starts the server. "$@" forwards anything appended at `docker run`.
exec /mchprs "$@"
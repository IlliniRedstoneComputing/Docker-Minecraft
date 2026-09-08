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

render_env_placeholders "$CONFIG_DIR/velocity.toml"
render_env_placeholders "$CONFIG_DIR/forwarding.secret"
render_env_placeholders "$CONFIG_DIR/plugins/luckperms/config.yml"

echo "Secrets injected successfully."

# Use 'cp -n' to copy ONLY if the file doesn't exist in the volume
# Or use 'cp -u' to copy only if the source is newer than the destination
cp -a /usr/src/init_data/plugins /server/plugins
cp -a /usr/src/init_data/velocity.toml /server/velocity.toml
cp -a /usr/src/init_data/forwarding.secret /server/forwarding.secret
cp -a /usr/src/init_data/server-icon.png /server/server-icon.png

echo "Copying complete. Starting Velocity..."

# This executes the CMD from your Dockerfile
exec "/usr/bin/run-bungeecord.sh"
#!/usr/bin/env bash
# Normalize every server's luckperms.conf.
#
# Connection and messaging settings now come from LUCKPERMS_* environment
# variables in compose.yml, which LuckPerms resolves ahead of this file on
# every platform. This script strips the ${...} placeholders that used to
# carry them, leaving stock values behind, and disables the Redis messenger
# that pointed at a service which does not exist.
#
# The `server = "<name>"` line is deliberately left alone: that is the
# server's identity and belongs with the server.
#
# WHY PERL AND NOT SED. These files are CRLF (684 CR / 684 LF each). On Git
# Bash for Windows, `sed`, `awk` and `grep` are PE binaries that open files
# in TEXT mode: they silently translate CRLF to LF on read and never restore
# it, so `sed -i` strips the carriage return from EVERY line, not just the
# ones it rewrites, and `grep -q $'\r'` cannot detect a carriage return at
# all. Measured on this toolchain: sed -i, sed with redirection and awk with
# redirection all reduce CR from 3 to 0 on a three-line CRLF fixture, while
# `perl -i -pe` preserves all 3. Hence perl.
#
# The patterns use [^\r\n]* rather than .* for the same reason: `.` matches
# a carriage return, so `.*` would swallow it and the replacement would emit
# an LF-only line into an otherwise CRLF file, leaving mixed endings.
set -euo pipefail

cd "$(dirname "$0")/.."

for conf in src/*/server/config/luckperms/luckperms.conf; do
  echo "normalizing $conf"

  perl -i -pe '
    s|^storage-method = [^\r\n]*|storage-method = "h2"|;
    s|^  address = "\$\{LUCKPERMS_DATA_ADDRESS[^\r\n]*|  address = "localhost:3306"|;
    s|^  database = "\$\{LUCKPERMS_DATA_DATABASE[^\r\n]*|  database = "minecraft"|;
    s|^  username = "\$\{LUCKPERMS_DATA_USERNAME[^\r\n]*|  username = "root"|;
    s|^  password = "\$\{LUCKPERMS_DATA_PASSWORD[^\r\n]*|  password = ""|;
    s|^messaging-service = [^\r\n]*|messaging-service = "sql"|;
    s|^  address = "\$\{LUCKPERMS_REDIS_ADDRESS[^\r\n]*|  address = "localhost"|;
    s|^  username = "\$\{LUCKPERMS_REDIS_USERNAME[^\r\n]*|  username = ""|;
    s|^  password = "\$\{LUCKPERMS_REDIS_PASSWORD[^\r\n]*|  password = ""|;

    # Disable the Redis messenger, and ONLY the redis block: the nats and
    # rabbitmq blocks have an identically-spelled `enabled` line.
    $inredis = 1 if /^redis \{/;
    if ($inredis && s|^  enabled = true|  enabled = false|) { $inredis = 0; }
    $inredis = 0 if /^\}/;
  ' "$conf"
done

echo "done"

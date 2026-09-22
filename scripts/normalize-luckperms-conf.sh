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
# src/mchprs/Config.toml is NOT handled here, even though it carries the same
# placeholders. MCHPRS reads the database directly and has no environment
# variable override, so its placeholders must survive; it is rendered at
# container start instead. There is nothing for this script to do to it.
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

cd "$(dirname "$0")/.." || exit 1

# Assert the full set is present before touching anything. Four of these five
# live in git submodules, and an uninitialized checkout is the DEFAULT state of
# a fresh clone. Without this guard the glob quietly matches one file, the
# script normalizes it, prints "done" and exits 0 -- leaving four servers still
# pointing at a Redis messenger that does not exist, with nothing in the output
# to say so. `set -e` does not help: `perl -i` on a missing file warns to
# stderr and still exits 0.
shopt -s nullglob
confs=(src/*/server/config/luckperms/luckperms.conf)
if [ "${#confs[@]}" -ne 5 ]; then
  printf 'expected 5 luckperms.conf files, found %d:\n' "${#confs[@]}" >&2
  printf '  %s\n' "${confs[@]}" >&2
  printf 'run: git submodule update --init --recursive\n' >&2
  exit 1
fi

for conf in "${confs[@]}"; do
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
    # rabbitmq blocks have an identically-spelled `enabled` line. Top-level
    # blocks close at column 0 while nested ones close at "  }", so /^\}/ is
    # a safe reset.
    #
    # Matching the line and flipping it are deliberately separate steps. On a
    # second run the line already reads `enabled = false`, so keying the
    # assertion below on a successful substitution would make a correct
    # re-run fail.
    our ($in_redis, $seen_redis);
    $in_redis = 1 if /^redis \{/;
    if ($in_redis && /^  enabled = (?:true|false)/) {
      s|^  enabled = true|  enabled = false|;
      $in_redis = 0;
      $seen_redis = 1;
    }
    $in_redis = 0 if /^\}/;

    # The match is coupled to exact indentation and spacing. If upstream ever
    # reformats the file it would silently miss, leaving LuckPerms dialling a
    # Redis host that does not exist -- the precise failure this script exists
    # to remove. Refuse to exit 0 on that.
    END {
      our $seen_redis;
      die "redis `enabled` line never matched -- file reformatted?\n"
        unless $seen_redis;
    }
  ' "$conf"
done

# Prove the result rather than assuming it. The CRLF check is the one that
# matters most: it catches the next person who reaches for `sed -i` here.
for conf in "${confs[@]}"; do
  cr=$(tr -cd '\r' < "$conf" | wc -c)
  lf=$(tr -cd '\n' < "$conf" | wc -c)
  if [ "$cr" -ne "$lf" ]; then
    printf 'CRLF damaged in %s: CR=%s LF=%s\n' "$conf" "$cr" "$lf" >&2
    exit 1
  fi
  if grep -qF '${LUCKPERMS' "$conf"; then
    printf 'placeholders remain in %s\n' "$conf" >&2
    exit 1
  fi
done

printf 'done: normalized and verified %d files\n' "${#confs[@]}"

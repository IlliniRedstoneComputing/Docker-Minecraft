#!/usr/bin/env bash
# WebDAV behavior through Caddy. Requires the stack to be running.
#
# Caddy publishes no port in normal operation, so this test talks to it through
# a temporary container attached to the frontend network. That keeps the test
# honest -- it exercises the real Caddy -> webdav path, prefix and all.
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=lib.sh
. tests/lib.sh

USER_NAME=$(grep -E '^WEBDAV_USERNAME=' .env | cut -d= -f2-)
PASS=$(grep -E '^WEBDAV_PASSWORD=' .env | cut -d= -f2-)
BASE="http://caddy:80"

# dav <curl-args...> -- runs curl inside the frontend network against Caddy.
dav() {
  docker run --rm --network irc-frontend-network curlimages/curl:latest \
    -s -u "$USER_NAME:$PASS" "$@"
}

echo "webdav through caddy"

# A request without the /files prefix must be refused by the WebDAV server.
CODE=$(dav -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' "$BASE/files/")
assert_eq "$CODE" "207" "PROPFIND /files/ returns multi-status"

# A request missing the /files prefix must be refused, proving the prefix is
# reaching the server rather than being stripped by Caddy.
CODE=$(dav -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' "$BASE/survival/")
assert_in "$CODE" "400 404 502" "a request without the /files prefix is refused"

# Unauthenticated access must be rejected.
CODE=$(docker run --rm --network irc-frontend-network curlimages/curl:latest \
  -s -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' "$BASE/files/")
assert_eq "$CODE" "401" "unauthenticated PROPFIND is rejected"

# Write, read back, move, and delete.
CODE=$(dav -o /dev/null -w '%{http_code}' -X PUT --data 'hello' "$BASE/files/survival/webdav-test.txt")
assert_in "$CODE" "201 204" "PUT creates a file"

BODY=$(dav "$BASE/files/survival/webdav-test.txt")
assert_eq "$BODY" "hello" "GET returns the written content"

CODE=$(dav -o /dev/null -w '%{http_code}' -X MOVE \
  -H 'Destination: /files/survival/webdav-moved.txt' \
  "$BASE/files/survival/webdav-test.txt")
assert_in "$CODE" "201 204" "MOVE with a path-only Destination succeeds"

# The same MOVE with an absolute Destination must also work, because Caddy
# rewrites it. This is the regression guard for the @hasDest rule -- without
# it, this returns 502 or 400.
CODE=$(dav -o /dev/null -w '%{http_code}' -X MOVE \
  -H "Destination: http://caddy/files/survival/webdav-test.txt" \
  "$BASE/files/survival/webdav-moved.txt")
assert_in "$CODE" "201 204" "MOVE with an absolute Destination succeeds"

CODE=$(dav -o /dev/null -w '%{http_code}' -X DELETE "$BASE/files/survival/webdav-test.txt")
assert_in "$CODE" "200 204" "DELETE removes the file"

# Directory creation and nested writes -- what the administration service
# will actually do. Self-contained: no Minecraft server has run at this
# point, so /files/survival/ is empty and nothing deeper exists yet. WebDAV
# PUT does not create parent collections, so the MKCOL is required, not
# decorative. (The harder case -- writing into a directory a Minecraft
# server created as uid 1000 -- needs a server to have run, so it lives in
# the full-stack task.)
CODE=$(dav -o /dev/null -w '%{http_code}' -X MKCOL "$BASE/files/survival/davtest/")
assert_in "$CODE" "201" "MKCOL creates a collection"

CODE=$(dav -o /dev/null -w '%{http_code}' -X PUT --data 'nested' \
  "$BASE/files/survival/davtest/nested.txt")
assert_in "$CODE" "201 204" "PUT into a newly created collection succeeds"

dav -o /dev/null -X DELETE "$BASE/files/survival/davtest/nested.txt"
dav -o /dev/null -X DELETE "$BASE/files/survival/davtest/"

finish

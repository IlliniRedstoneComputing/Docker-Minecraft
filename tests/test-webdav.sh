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

# A path outside both admin routes falls through to the catch-all redirect.
# (The 207 above is what proves the /files prefix actually reaches webdav: if
# Caddy stripped it, webdav would see "/" and answer 400. A path like
# /survival/ never reaches webdav at all, so it cannot test that.)
CODE=$(dav -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' "$BASE/survival/")
assert_in "$CODE" "301 302 307 308" "an unrouted path hits the catch-all redirect"

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

# The same MOVE with an absolute Destination whose host does NOT match the
# request Host. This is the real regression guard for the @hasDest rule.
#
# A matching host would prove nothing: golang.org/x/net/webdav, which this
# server is built on, already accepts an absolute Destination whenever its
# host equals the request's Host, so "http://caddy/..." succeeds with or
# without the rewrite. Only a foreign host exercises it -- verified: 502
# without the rewrite, 201 with it.
CODE=$(dav -o /dev/null -w '%{http_code}' -X MOVE \
  -H "Destination: http://other-host.example:9999/files/survival/webdav-test.txt" \
  "$BASE/files/survival/webdav-moved.txt")
assert_in "$CODE" "201 204" "MOVE with a foreign-host absolute Destination succeeds"

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

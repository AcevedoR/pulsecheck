#!/usr/bin/env bash
# Tests for the options handed straight through to curl: --head, --insecure
# and --resolve.
#
# Each one is checked against a real server rather than by looking for the flag
# in a config file, because the interesting failure is not "the option was not
# written down" but "the option was written down and curl ignored it" — which is
# what a wrong config-file keyword does, silently.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh

PC=./pulsecheck
TMP=$(mktemp -d)
SRV=
TLS=
cleanup() {
  [ -n "$SRV" ] && kill "$SRV" 2>/dev/null
  [ -n "$TLS" ] && kill "$TLS" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "argument validation"

assert_status "--resolve rejects a spec without two colons" 2 -- \
  $PC --resolve nonsense http://127.0.0.1:1/
assert_status "--resolve rejects a missing value" 2 -- $PC --resolve
assert_contains "--resolve says what it wanted" "HOST:PORT:ADDRESS" \
  "$($PC --resolve nonsense http://127.0.0.1:1/ 2>&1)"
assert_status "--head needs no value" 0 -- $PC --head --diag
assert_status "--insecure needs no value" 0 -- $PC --insecure --diag

command -v python3 >/dev/null || { echo "python3 not found; skipping the rest" >&2; summary; exit; }

# probe URL EXTRA... -> the lines of a short run
probe() {
  local out=$TMP/out
  : > "$out"
  ( $PC -p -i 0.1 -t 2 "$@" >"$out" 2>"$TMP/err" & echo $! > "$TMP/pid" )
  local pid; pid=$(cat "$TMP/pid")
  # One line is enough for every assertion here, and waiting for three tripled
  # the window in which a slow runner could produce nothing at all.
  local i=0
  while [ ! -s "$out" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if [ -s "$out" ]; then
    cat "$out"
  else
    # An empty result is indistinguishable from a wrong one, and the reason is
    # on stderr. Surfacing it here puts it in the failure message instead of
    # leaving the next reader to guess from a CI log.
    # Distinguish the two ways this can be empty: the server never answered,
    # or it answered and pulsecheck said nothing about it. One direct request
    # settles which, and without it the next reader is where I was — guessing.
    direct=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "${@: -1}" 2>&1 || echo "curl-failed")
    printf '(no output after %ss; stderr: %s; a direct curl to the same url got %s; %s curl procs alive)\n' \
      "$((i / 10))" "$(tr '\n' ' ' < "$TMP/err" | cut -c1-200)" "$direct" \
      "$(pgrep -c curl 2>/dev/null || echo 0)"
  fi
}

echo
echo "--head sends HEAD"

export SEEN_METHODS=$TMP/methods
: > "$SEEN_METHODS"
exec 3< <(python3 tests/serve.py)
SRV=$!
read -r PORT <&3 || true
[ -n "${PORT:-}" ] || { echo "server did not start" >&2; exit 1; }
URL="http://127.0.0.1:$PORT/"

out=$(probe "$URL")
assert_contains "a plain run still gets a 200" "HTTP 200" "$out"
assert_eq "and the server saw GET" "GET" "$(sort -u < "$SEEN_METHODS" | tr -d '\n')"

: > "$SEEN_METHODS"
out=$(probe --head "$URL")
assert_contains "--head still gets a 200" "HTTP 200" "$out"
assert_eq "and the server saw HEAD" "HEAD" "$(sort -u < "$SEEN_METHODS" | tr -d '\n')"

echo
echo "--resolve pins a host that does not exist"

# .invalid is reserved by RFC 2606 and can never resolve, so a 200 here can only
# come from the pin.
BAD="http://pulsecheck.invalid:$PORT/"
out=$(probe "$BAD")
assert_contains "an unresolvable host fails" "HTTP 000" "$out"
out=$(probe --resolve "pulsecheck.invalid:$PORT:127.0.0.1" "$BAD")
assert_contains "--resolve makes it reachable" "HTTP 200" "$out"

echo
echo "--insecure accepts a certificate curl would otherwise reject"

if ! command -v openssl >/dev/null; then
  skip_msg="openssl not available"
  echo "  skip $skip_msg"
else
  openssl req -x509 -newkey rsa:2048 -keyout "$TMP/k.pem" -out "$TMP/c.pem" \
    -days 1 -nodes -subj "/CN=localhost" >/dev/null 2>&1
  if [ ! -s "$TMP/c.pem" ]; then
    echo "  skip could not generate a self-signed certificate"
  else
    python3 - "$TMP" <<'PY' &
import ssl, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
tmp = sys.argv[1]
class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', '2')
        self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self, *a): pass
# Threaded for the same reason tests/serve.py is: the first probe here fails
# TLS on every request, and a single-threaded server can stall under that,
# leaving the next probe with no response at all.
srv = ThreadingHTTPServer(('127.0.0.1', 0), H)
srv.daemon_threads = True
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(tmp + '/c.pem', tmp + '/k.pem')
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
with open(tmp + '/tlsport', 'w') as fh:
    fh.write(str(srv.server_port))
srv.serve_forever()
PY
    TLS=$!
    i=0
    while [ ! -s "$TMP/tlsport" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
    if [ ! -s "$TMP/tlsport" ]; then
      echo "  skip the TLS server did not start"
    else
      TP=$(cat "$TMP/tlsport")
      out=$(probe "https://127.0.0.1:$TP/")
      assert_contains "a self-signed certificate is rejected by default" "HTTP 000" "$out"
      out=$(probe --insecure "https://127.0.0.1:$TP/")
      assert_contains "--insecure accepts it" "HTTP 200" "$out"
    fi
  fi
fi

summary

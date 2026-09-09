#!/usr/bin/env bash
# End-to-end smoke test: run pulsecheck in plain mode against a local server
# and check the lines it prints.
#
# Plain mode is the testable one — stdout is not a terminal here, so the TUI is
# off by construction and each line carries its own aggregates.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh

command -v python3 >/dev/null || { echo "python3 not found; skipping e2e" >&2; exit 0; }

TMP=$(mktemp -d)
PORT=
SRV=
cleanup() {
  [ -n "$SRV" ] && kill "$SRV" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

exec 3< <(python3 tests/serve.py)
SRV=$!
read -r PORT <&3 || true
[ -n "$PORT" ] || { echo "server did not start" >&2; exit 1; }
URL="http://127.0.0.1:$PORT/"

# run_probe URL EXTRA... -> stdout of a bounded run
#
# The run ends itself with --count. It used to be killed once the reader had
# enough lines, which is what made these tests flaky: on one CI runner the
# output never arrived at all, while the server logged the requests and a direct
# curl to the same url answered 200 — the tool working and the harness unable to
# see it. Killing the process under test races its own output; a run that exits
# on its own has flushed and closed everything it owns first.
run_probe() {
  : > "$TMP/out"
  ./pulsecheck -p -i 0.05 -t 2 -c 3 "$@" > "$TMP/out" 2> "$TMP/err"
  if [ -s "$TMP/out" ]; then
    cat "$TMP/out"
  else
    # An empty result is indistinguishable from a wrong one, and the reason is
    # on stderr. Put it in the failure message rather than leaving the next
    # reader to guess from a CI log.
    printf '(no output; stderr: %s)\n' "$(tr '\n' ' ' < "$TMP/err" | cut -c1-200)"
  fi
}

echo "plain mode against a local server"

OUT=$(run_probe "$URL")
LINES=$(printf '%s\n' "$OUT" | grep -c 'HTTP' || true)
assert_eq "at least three samples were printed" "1" "$([ "$LINES" -ge 3 ] && echo 1 || echo 0)"
assert_contains "a 200 is reported" "HTTP 200" "$OUT"
assert_contains "the line carries p95" "p95" "$OUT"
assert_contains "a healthy run reports no errors" "err   0.0%" "$OUT"
assert_eq "no colour escapes when stdout is not a terminal" "" \
  "$(printf '%s' "$OUT" | tr -d '\n' | grep -o $'\033' | head -1)"

# The count is the window occupancy, so it must climb rather than sit at 1.
FIRST=$(printf '%s\n' "$OUT" | grep 'HTTP' | head -1 | sed 's/.*n=//')
THIRD=$(printf '%s\n' "$OUT" | grep 'HTTP' | sed -n 3p | sed 's/.*n=//')
assert_eq "the first sample has n=1" "1" "$FIRST"
assert_eq "the third sample has n=3" "3" "$THIRD"

echo
echo "--expect decides what counts as a failure"

# An unexpected status is an error even though the request itself succeeded.
OUT=$(run_probe "http://127.0.0.1:$PORT/503")
assert_contains "a 503 is reported" "HTTP 503" "$OUT"
assert_contains "an unexpected status counts as an error" "err 100.0%" "$OUT"

# ...and the same status is clean when it is the one asked for.
OUT=$(run_probe -e 503 "http://127.0.0.1:$PORT/503")
assert_contains "the expected status is not an error" "err   0.0%" "$OUT"

echo
echo "a dead endpoint"

# Nothing is listening on this port: every request fails, and the run must keep
# printing lines rather than exit or stall.
OUT=$(run_probe -t 1 "http://127.0.0.1:1/")
assert_contains "a connection failure is reported as an error" "err 100.0%" "$OUT"

summary

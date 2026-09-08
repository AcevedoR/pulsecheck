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

# run_probe URL EXTRA... -> stdout of a short run
# The run is bounded by the number of samples, not by a timer: pulsecheck runs
# until killed, so the reader closes the pipe once it has enough lines.
run_probe() {
  local out=$TMP/out
  : > "$out"
  ( ./pulsecheck -i 0.05 -t 2 "$@" >"$out" 2>"$TMP/err" & echo $! > "$TMP/pid" )
  local pid; pid=$(cat "$TMP/pid")
  local i=0
  while [ "$(wc -l < "$out")" -lt 3 ] && [ $i -lt 100 ]; do
    sleep 0.1; i=$((i+1))
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  cat "$out"
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

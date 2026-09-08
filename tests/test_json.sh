#!/usr/bin/env bash
# Tests for the machine-readable side: --json, --count, --summary and the
# threshold gates. This is the surface another program consumes, so the JSON is
# parsed rather than pattern-matched.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh

PC=./pulsecheck
TMP=$(mktemp -d)
SRV=
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

echo "flags that cannot be honoured are refused"

# A gate on a run with no end can never deliver its verdict.
assert_status "--fail-over without --count exits 2" 2 -- $PC --fail-over 100 http://127.0.0.1:1/
assert_status "--fail-err without --count exits 2"  2 -- $PC --fail-err 5 http://127.0.0.1:1/
assert_status "--count rejects a non-number" 2 -- $PC -c abc http://127.0.0.1:1/
assert_status "--fail-over rejects a non-number" 2 -- $PC -c 1 --fail-over abc http://127.0.0.1:1/

command -v python3 >/dev/null || { echo "python3 not found; skipping the rest" >&2; summary; exit; }

exec 3< <(python3 tests/serve.py)
SRV=$!
read -r PORT <&3 || true
[ -n "${PORT:-}" ] || { echo "server did not start" >&2; exit 1; }
URL="http://127.0.0.1:$PORT/"

echo
echo "--count stops the run, and the exit status is the verdict"

out=$($PC --json -i 0.02 -c 5 "$URL"); rc=$?
assert_eq "exit 0 when no gate is set" "0" "$rc"
assert_eq "exactly --count objects" "5" "$(printf '%s\n' "$out" | grep -c '^{')"

echo
echo "every line is a JSON object with the fields a consumer needs"

printf '%s\n' "$out" > "$TMP/json.txt"
res=$(python3 - "$TMP/json.txt" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
need = {'t','epoch','code','ok','ms','reconnect','n','p50','p95','max','err_pct','ok_in_window','window_s'}
problems = []
for i, r in enumerate(rows, 1):
    miss = need - set(r)
    if miss: problems.append('row %d missing %s' % (i, sorted(miss)))
    if r['n'] != i: problems.append('row %d has n=%s' % (i, r['n']))
    if not isinstance(r['ok'], bool): problems.append('ok is not a boolean')
    if not isinstance(r['ms'], (int, float)): problems.append('ms is not a number')
# p95 must be null while the rank cannot exclude a sample
if any(r['p95'] is not None for r in rows): problems.append('p95 is not null below 20 samples')
print(problems[0] if problems else 'OK')
PY
)
assert_eq "the stream parses and carries the contract" "OK" "$res"

# ...and becomes a number once there are twenty successes to rank.
out=$($PC --json -i 0.02 -c 21 "$URL")
last=$(printf '%s\n' "$out" | tail -1)
res=$(printf '%s' "$last" | python3 -c 'import json,sys; r=json.load(sys.stdin); print("number" if isinstance(r["p95"],(int,float)) else "null")')
assert_eq "p95 becomes a number at twenty successes" "number" "$res"

echo
echo "--summary reports the run, not the window"

out=$($PC -p -i 0.02 -c 25 --summary "$URL")
assert_contains "it prints a summary block" "pulsecheck summary" "$out"
assert_contains "with the request count"   "requests   25" "$out"
assert_contains "and the outcome"          "25 ok, 0 failed" "$out"
assert_contains "and the sample size behind the percentiles" "over 25 successful request" "$out"

echo
echo "the gates decide the exit status"

$PC -p -i 0.02 -c 25 --fail-over 5000 "$URL" >/dev/null 2>&1
assert_eq "a p95 ceiling that holds exits 0" "0" "$?"
$PC -p -i 0.02 -c 25 --fail-over 0.001 "$URL" >/dev/null 2>&1
assert_eq "a p95 ceiling that is breached exits 1" "1" "$?"
$PC -p -i 0.02 -c 25 --fail-err 50 "$URL" >/dev/null 2>&1
assert_eq "an error ceiling that holds exits 0" "0" "$?"

# Against a dead port every request fails, so the error gate must trip.
$PC -p -i 0.02 -c 5 -t 1 --fail-err 10 "http://127.0.0.1:1/" >/dev/null 2>&1
assert_eq "an error ceiling that is breached exits 1" "1" "$?"

# A p95 gate cannot be judged without enough successes, and guessing would be
# worse than failing: a green CI run that measured nothing is the bad outcome.
$PC -p -i 0.02 -c 5 -t 1 --fail-over 100 "http://127.0.0.1:1/" >/dev/null 2>&1
assert_eq "a p95 gate with nothing to measure exits 1" "1" "$?"

summary

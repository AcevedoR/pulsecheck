#!/usr/bin/env bash
# Tests for what the window reports, driving the whole awk program.
#
# tests/test_awk.sh unit-tests the pure functions; this one feeds the complete
# program a stream of samples and reads the lines it prints. That is the only
# way to test decisions that live in the rendering path rather than in a
# function — chiefly whether a statistic is shown at all.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh

SRC=pulsecheck
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The whole awk program, lifted out of the single-quoted shell string it lives
# in. Deliberately not tests/extract.awk, which pulls out one function.
sed -n "/^BEGIN {/,/^}' </p" "$SRC" | sed "\$s/}' <.*/}/" > "$TMP/prog.awk"

# feed <<samples -> the plain-mode lines the program prints, one per sample
feed() {
  awk -v win=60 -v color=0 -v expect=200 -v tui=0 -v cols=100 -v rows=24 -v hdr=8 \
      -v url=http://x -v ivl=1 -v tmo=5 -v ver=test -v wv=1 -v frm=0.1 -v nsok=1 \
      -v mode=reuse -v modenote= -v hdrn=0 -f "$TMP/prog.awk"
}

# sample N CODE MS -> one line of the awk stdin contract
sample() {
  awk -v n="$1" -v code="$2" -v ms="$3" \
    'BEGIN { printf "12:00:%02d %d.000000 %s %.6f 0\n", n % 60, 1788800000 + n, code, ms / 1000 }'
}

# p95_at N <file -> what p95 read on the Nth line
p95_at() { sed -n "$1p" "$2" | sed -n 's/.*p95 \([^ ]*\).*/\1/p'; }

echo "p95 is withheld until the rank can exclude something"

# Nearest rank ceil(0.95*m) equals m for every m below 20, so with fewer than
# twenty samples p95 IS the maximum. A run opens on a connection handshake,
# which is the maximum, so this used to render a steady endpoint as five times
# slower than it is for its first nineteen samples.
: > "$TMP/warmup.txt"
sample 0 200 90 >> "$TMP/warmup.txt"                 # the handshake
i=1; while [ $i -lt 26 ]; do sample $i 200 16 >> "$TMP/warmup.txt"; i=$((i+1)); done
feed < "$TMP/warmup.txt" > "$TMP/warmup.out"

assert_eq "withheld on the first sample"      "—" "$(p95_at 1  "$TMP/warmup.out")"
assert_eq "withheld at nineteen samples"      "—" "$(p95_at 19 "$TMP/warmup.out")"
assert_eq "reported at twenty"           "16.0ms" "$(p95_at 20 "$TMP/warmup.out")"
assert_eq "and stays reported after"     "16.0ms" "$(p95_at 26 "$TMP/warmup.out")"

# The point of the threshold: at twenty the rank finally excludes the top
# sample, so the handshake no longer decides the answer.
assert_eq "the handshake does not decide p95 once it is shown" \
  "16.0ms" "$(p95_at 21 "$TMP/warmup.out")"

echo
echo "the split display still shows max, which is what p95 would have been"

# Nothing is hidden from a terminal user by withholding p95: the header carries
# max on the same row, under the name that actually describes it. Plain mode has
# no max column, so there the aggregate is simply absent until it is real — each
# line still reports its own sample.
feed_tui() {
  awk -v win=60 -v color=0 -v expect=200 -v tui=1 -v cols=100 -v rows=24 -v hdr=8 \
      -v url=http://x -v ivl=1 -v tmo=5 -v ver=test -v wv=1 -v frm=0.1 -v nsok=1 \
      -v mode=reuse -v modenote= -v hdrn=0 -f "$TMP/prog.awk"
}
head -5 "$TMP/warmup.txt" | feed_tui > "$TMP/warmup.tui"
if grep -q 'p95 —' "$TMP/warmup.tui"; then ok "the header withholds p95 too"
else bad "the header withholds p95 too"; fi
if grep -q 'max 90.0ms' "$TMP/warmup.tui"; then ok "the header still reports max 90.0ms"
else bad "the header still reports max 90.0ms"; fi

echo
echo "the threshold counts successful samples, not all samples"

# Aggregates cover successes only, so the rank threshold has to as well:
# thirty samples of which fifteen failed is fifteen usable samples, not thirty.
: > "$TMP/mixed.txt"
i=0
while [ $i -lt 30 ]; do
  if [ $((i % 2)) -eq 0 ]; then sample $i 200 20 >> "$TMP/mixed.txt"
  else sample $i 000 0.2 >> "$TMP/mixed.txt"; fi
  i=$((i+1))
done
feed < "$TMP/mixed.txt" > "$TMP/mixed.out"
assert_eq "withheld with fifteen successes among thirty samples" \
  "—" "$(p95_at 30 "$TMP/mixed.out")"

# ...and appears once twenty successes have accumulated, however many failures
# are interleaved.
: > "$TMP/mixed2.txt"
i=0
while [ $i -lt 45 ]; do
  if [ $((i % 2)) -eq 0 ]; then sample $i 200 20 >> "$TMP/mixed2.txt"
  else sample $i 000 0.2 >> "$TMP/mixed2.txt"; fi
  i=$((i+1))
done
feed < "$TMP/mixed2.txt" > "$TMP/mixed2.out"
assert_eq "reported once twenty successes are in the window" \
  "20.0ms" "$(p95_at 45 "$TMP/mixed2.out")"

echo
echo "a window with no successes reports no latency at all"

: > "$TMP/dead.txt"
i=0; while [ $i -lt 25 ]; do sample $i 000 0.2 >> "$TMP/dead.txt"; i=$((i+1)); done
feed < "$TMP/dead.txt" > "$TMP/dead.out"
assert_eq "p95 is absent"  "—" "$(p95_at 25 "$TMP/dead.out")"
assert_contains "err is total" "err 100.0%" "$(sed -n '25p' "$TMP/dead.out")"

summary

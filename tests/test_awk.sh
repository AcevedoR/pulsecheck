#!/usr/bin/env bash
# Unit tests for the pure functions inside pulsecheck's awk program.
#
# Each test extracts the function under test (plus whatever it calls) with
# tests/extract.awk and runs it from a BEGIN-block driver. These are the parts
# where a wrong answer is invisible on screen — a percentile off by one rank,
# or a scale that flattens a healthy trace — so they are worth pinning down
# without a terminal in the loop.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh

SRC=pulsecheck

# run_awk DRIVER FN... -> stdout of the driver
#
# $HELPERS, if set, is awk source spliced in at top level alongside the
# extracted functions — awk has no nested functions, so a driver-local helper
# cannot live inside the BEGIN block.
HELPERS=
run_awk() {
  local driver=$1; shift
  local prog=""
  local fn
  for fn in "$@"; do
    prog+=$(awk -v fn="$fn" -f tests/extract.awk "$SRC") || return 1
    prog+=$'\n'
  done
  awk "$prog"$'\n'"$HELPERS"$'\nBEGIN {'"$driver"$'\n}' </dev/null
}

echo "pct() — nearest-rank percentile"

# Ten samples 10..100. Nearest rank ceil(p*n): p50 -> rank 5 -> 50.
D='split("10 20 30 40 50 60 70 80 90 100", a, " ");
   printf "%d %d %d %d\n", pct(a,10,0.50), pct(a,10,0.95), pct(a,10,1.00), pct(a,10,0.05)'
assert_eq "p50/p95/max/p05 over 10 sorted samples" "50 100 100 10" "$(run_awk "$D" pct)"

# Unsorted input must give the same answer: pct() sorts a copy.
D='split("70 10 100 40 90 20 60 30 80 50", a, " ");
   printf "%d %d\n", pct(a,10,0.50), pct(a,10,0.95)'
assert_eq "input order does not change the result" "50 100" "$(run_awk "$D" pct)"

# The caller must still see its own array afterwards — pct() sorts into a local
# copy, and a sort in place would silently reorder the ring buffer.
D='split("30 10 20", a, " "); pct(a,3,0.5); printf "%d %d %d\n", a[1], a[2], a[3]'
assert_eq "caller array is not mutated" "30 10 20" "$(run_awk "$D" pct)"

D='split("42", a, " "); printf "%d %d %d\n", pct(a,1,0.05), pct(a,1,0.5), pct(a,1,1.0)'
assert_eq "single sample: every percentile is that sample" "42 42 42" "$(run_awk "$D" pct)"

# p*m below 1 must clamp to rank 1 rather than index b[0].
D='split("5 6", a, " "); printf "%d\n", pct(a,2,0.05)'
assert_eq "rank clamps to 1, never index 0" "5" "$(run_awk "$D" pct)"

echo
echo "fmt() — millisecond/second boundary"

D='printf "%s %s %s %s\n", fmt(0), fmt(53.24), fmt(999.9), fmt(1000)'
assert_eq "under 1000 in ms, at 1000 in s" "0.0ms 53.2ms 999.9ms 1.00s" "$(run_awk "$D" fmt)"
assert_eq "seconds keep two decimals" "12.34s" "$(run_awk 'printf "%s\n", fmt(12340)' fmt)"

echo
echo "col() — colour thresholds are network numbers, not localhost ones"

# The thresholds exist so a healthy 53ms API is not painted orange; assert the
# boundaries themselves, since being one class off is invisible in a screenshot.
D='GRN="G"; YEL="Y"; ORG="O"; RED="R";
   printf "%s%s%s%s%s%s\n", col(0,0), col(99,0), col(100,0), col(299,0), col(300,0), col(1000,0)'
assert_eq "0/99 green, 100/299 yellow, 300 orange, 1000 red" "GGYYOR" "$(run_awk "$D" col)"
assert_eq "a failed request is red at any latency" "R" \
  "$(run_awk 'GRN="G"; RED="R"; printf "%s\n", col(1,1)' col)"

echo
echo "clock() / span_s() — elapsed time"

D='printf "%s %s %s\n", clock(0), clock(59), clock(3671)'
assert_eq "clock zero-pads h:mm:ss" "00:00:00 00:00:59 01:01:11" "$(run_awk "$D" clock)"
D='printf "%s %s %s\n", span_s(0.5), span_s(59), span_s(187)'
assert_eq "span_s: tenths under a minute, m:ss over" "0.5s 59.0s 3:07" "$(run_awk "$D" span_s)"

echo
echo "rep()"
assert_eq "rep repeats" "xxx" "$(run_awk 'printf "%s\n", rep("x",3)' rep)"
assert_eq "rep of zero is empty" "" "$(run_awk 'printf "%s\n", rep("x",0)' rep)"
assert_eq "rep of a negative count is empty" "" "$(run_awk 'printf "%s\n", rep("x",-1)' rep)"

echo
echo "wscale() — the trace scale must not let one outlier flatten the shape"

# fill(list): a window of ordinary successes with the given latencies.
HELPERS='function fill(s,  i,n,v) { n=split(s, v, " ");
        for (i=1;i<=n;i++) { wms[i]=v[i]; wbad[i]=0; wcon[i]=0 }
        wn=n; ww=n }'

# A 50ms baseline with one 320ms spike: min/max scaling put every other sample
# on the bottom row. p5/p95 must keep the band near the baseline and say the
# spike clipped. (40 samples, so the 95th percentile is rank 38 and the spike
# falls outside the band — at 16 samples ceil(0.95*16) is the maximum itself.)
D='
   s = ""; for (i=0;i<39;i++) s = s " " (48 + i%6)
   fill(s " 320");
   wscale();
   printf "%d %d %d %d %d\n", wlo, whi, clipt, clipb, flat'
read -r lo hi ct cb fl <<<"$(run_awk "$D" pct wscale wlevel)"
assert_eq "one spike does not drag the top of the band up" "1" "$([ "$hi" -le 60 ] && echo 1 || echo 0)"
assert_eq "the spike is reported as clipping the top" "1" "$ct"
assert_eq "a spread this wide is not flat" "0" "$fl"

# A low success outlier clips the bottom the same way.
D='
   s = ""; for (i=0;i<39;i++) s = s " " (48 + i%6)
   fill("1" s);
   wscale();
   printf "%d %d\n", wlo, clipb'
read -r lo cb <<<"$(run_awk "$D" pct wscale wlevel)"
assert_eq "a fast outlier does not drag the floor down" "1" "$([ "$lo" -ge 40 ] && echo 1 || echo 0)"
assert_eq "the fast outlier is reported as clipping the bottom" "1" "$cb"

# A sub-percent spread must render flat rather than amplify noise into drama.
D='fill("50 50 50 50 50 50"); wscale(); printf "%d\n", flat'
assert_eq "identical samples are flat" "1" "$(run_awk "$D" pct wscale wlevel)"
D='fill("50.0 50.1 50.0 50.1 50.0 50.1"); wscale(); printf "%d\n", flat'
assert_eq "a 0.2% spread is flat, not amplified" "1" "$(run_awk "$D" pct wscale wlevel)"

# An empty window has no scale and must not divide by zero downstream.
D='wn=0; ww=8; wscale(); printf "%d %d %d\n", wlo, whi, flat'
assert_eq "empty window is flat with a zero band" "0 0 1" "$(run_awk "$D" pct wscale wlevel)"

# Failures are excluded from the scale while there is ordinary traffic to
# shape it: a microsecond refusal must not pull the floor to zero.
D='
   fill("100 100 100 100 100 100"); wms[3]=0.2; wbad[3]=1;
   wscale(); printf "%d %d\n", wlo, clipb'
read -r lo cb <<<"$(run_awk "$D" pct wscale wlevel)"
assert_eq "a refusal does not drop the floor" "1" "$([ "$lo" -ge 90 ] && echo 1 || echo 0)"
# The clip markers describe the band against the samples that set it, and an
# excluded failure never enters that comparison — so no "-" appears for it.
# Pinned here because it is the kind of thing a later change to wscale() would
# flip without anyone noticing.
assert_eq "an excluded failure sets no clip marker" "0" "$cb"

# ...but with fewer than two ordinary successes there is no shape to keep, so
# everything is included rather than drawing an empty trace during an outage.
D='
   fill("5 6 7 8"); wbad[1]=1; wbad[2]=1; wbad[3]=1;
   wscale(); printf "%d\n", (whi > 0) ? 1 : 0'
assert_eq "during an outage failures still get a scale" "1" "$(run_awk "$D" pct wscale wlevel)"

echo
echo "wlevel() — sample to one of 24 rows"

D='fill("10 20 30 40 50 60 70 80 90 100"); wscale();
   printf "%d %d %d %d\n", wlevel(wlo), wlevel(whi), wlevel(wlo-1000), wlevel(whi+1000)'
read -r a b c d <<<"$(run_awk "$D" pct wscale wlevel)"
assert_eq "the bottom of the band is row 1" "1" "$a"
assert_eq "the top of the band is row 24" "24" "$b"
assert_eq "below the band clamps to row 1" "1" "$c"
assert_eq "above the band clamps to row 24" "24" "$d"
assert_eq "a flat window draws at mid height" "12" \
  "$(run_awk 'fill("50 50 50"); wscale(); printf "%d\n", wlevel(50)' pct wscale wlevel)"

summary

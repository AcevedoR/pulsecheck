#!/usr/bin/env bash
# Regression test for locale-sensitive numeric parsing.
#
# awk parses and formats numbers according to the locale. Under one whose
# decimal separator is a comma, "0.0532" * 1000 evaluates to 0 and printf
# "%.1f" emits "53,0" — so every latency on screen reads 0,0ms and the tool
# silently reports nothing at all. Measured on BWK awk and reported for mawk;
# gawk is the one that mitigates it. That is most of Europe by default.
#
# The script defends itself by exporting LC_ALL=C, which is cheap here: every
# string it formats is either a number it produced or a byte sequence it passes
# through, and the terminal decodes the UTF-8 glyphs by its own rules anyway.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh

SRC=pulsecheck

echo "the fix is present"

# Static, and worth asserting separately: the end-to-end checks below can only
# run where a comma-decimal locale is installed, which is not true of every CI
# image, and a silently skipped test protects nothing.
assert_contains "the script forces the C locale" "LC_ALL=C" "$(grep '^LC_ALL=' $SRC)"
assert_contains "and exports it, so awk and curl inherit it" \
  "export LC_ALL" "$(grep '^export LC_ALL' $SRC)"

echo
echo "the hazard is real"

# Demonstrate the underlying awk behaviour, so this test still says something
# useful if someone ever decides the LC_ALL line is unnecessary.
LOC=
for c in de_DE.UTF-8 fr_FR.UTF-8 de_DE.utf8 fr_FR.utf8 nl_NL.UTF-8; do
  if locale -a 2>/dev/null | grep -qx "$c"; then LOC=$c; break; fi
done

if [ -z "$LOC" ]; then
  echo "  skip no comma-decimal locale installed; cannot exercise the hazard"
else
  got=$(LC_ALL=$LOC awk 'BEGIN { printf "%s", "0.0532" * 1000 }' 2>/dev/null)
  case $got in
    53.2) echo "  note this awk is not locale-sensitive under $LOC (gawk behaves this way)" ;;
    *)    echo "  note this awk reads 0.0532*1000 as [$got] under $LOC — the hazard is live here" ;;
  esac

  echo
  echo "the script is immune to it end to end"
  command -v python3 >/dev/null || { echo "  skip python3 not found"; summary; exit; }

  TMP=$(mktemp -d); SRV=
  cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$TMP"; }
  trap cleanup EXIT

  exec 3< <(python3 tests/serve.py)
  SRV=$!
  read -r PORT <&3 || true
  [ -n "${PORT:-}" ] || { echo "  server did not start" >&2; exit 1; }

  ( LC_ALL=$LOC ./pulsecheck -p -i 0.05 -t 2 "http://127.0.0.1:$PORT/" \
      > "$TMP/out" 2>"$TMP/err" & echo $! > "$TMP/pid" )
  pid=$(cat "$TMP/pid")
  i=0
  while [ "$(wc -l < "$TMP/out")" -lt 3 ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

  line=$(head -1 "$TMP/out")
  # A dot, not a comma, and a latency that is not zero: both halves of the bug.
  case $line in
    *,*ms*) bad "latency uses a decimal point under $LOC"
            printf '      actual: %s\n' "$line" ;;
    *)      ok  "latency uses a decimal point under $LOC" ;;
  esac
  case $line in
    *" 0.0ms"*) bad "latency is not silently zero under $LOC"
                printf '      actual: %s\n' "$line" ;;
    *ms*)       ok  "latency is not silently zero under $LOC" ;;
    *)          bad "latency is not silently zero under $LOC"
                printf '      no latency found in: %s\n' "$line" ;;
  esac
  assert_eq "no stderr noise under $LOC" "" "$(cat "$TMP/err")"
fi

summary

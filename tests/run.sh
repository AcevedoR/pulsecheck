#!/usr/bin/env bash
# Run the whole suite. Exits non-zero if any test fails.
#
#   tests/run.sh            all suites
#   tests/run.sh cli awk    only the named ones
set -u
cd "$(dirname "$0")/.."

SUITES=${*:-static cli awk window json locale screen e2e}
RC=0

for s in $SUITES; do
  printf '\n=== %s ===\n' "$s"
  case $s in
    screen) python3 tests/test_screen.py 2>&1 || RC=1 ;;
    *)
      [ -f "tests/test_$s.sh" ] || { echo "no such suite: $s" >&2; RC=1; continue; }
      bash "tests/test_$s.sh" || RC=1 ;;
  esac
done

printf '\n'
[ $RC -eq 0 ] && echo "all suites passed" || echo "FAILURES"
exit $RC

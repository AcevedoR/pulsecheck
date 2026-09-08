#!/usr/bin/env bash
# Static checks on the script itself, for the two mistakes that this codebase
# makes silently and repeatedly.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh

SRC=pulsecheck
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "every variable the awk program uses is one it receives"

# awk has no undefined-variable error. A name never assigned, never a function
# local and never passed with -v is just empty — or zero in arithmetic. That has
# produced a division by zero, a glint that stopped moving, a scale guard that
# never fired, and an entire --json/--summary feature that did nothing because
# its bindings were added to the wrong line. None of them warned.
if command -v python3 >/dev/null; then
  assert_eq "no unbound identifiers" "" "$(python3 tests/awkvars.py $SRC)"

  # A silent audit is worse than no audit, so the audit is itself audited:
  # remove a binding that is definitely there and it has to notice.
  sed 's/-v hdrn="\$HDRN"/ /' $SRC > "$TMP/broken"
  assert_eq "the audit catches a removed binding" "hdrn" \
    "$(python3 tests/awkvars.py "$TMP/broken")"
else
  echo "  skip python3 not available"
fi

echo
echo "the awk program contains no apostrophe"

# It lives inside a single-quoted shell string, so one apostrophe anywhere in
# it — including in a comment — ends the quote and hands the remainder of the
# program to bash. The closing delimiter is the only legitimate match.
assert_eq "only the closing delimiter matches" "1" \
  "$(sed -n "/^BEGIN {/,/^}' </p" $SRC | grep -c "'")"

echo
echo "the script parses"

assert_status "bash -n" 0 -- bash -n $SRC
if [ -x /bin/bash ]; then
  assert_status "/bin/bash -n (3.2 on macOS)" 0 -- /bin/bash -n $SRC
fi

summary

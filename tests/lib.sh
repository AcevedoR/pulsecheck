# Minimal assertion helpers. Sourced by every tests/test_*.sh.
#
# No framework: pulsecheck depends on nothing but bash, curl and awk, and a
# test suite that needs bats installed would be one more thing to get working
# on a fresh machine (and in CI) than the program it tests.

PASS=0; FAIL=0

_red()  { [ -t 1 ] && printf '\033[31m%s\033[0m' "$1" || printf '%s' "$1"; }
_green(){ [ -t 1 ] && printf '\033[32m%s\033[0m' "$1" || printf '%s' "$1"; }

ok()   { PASS=$((PASS+1)); printf '  %s %s\n' "$(_green ok)" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s %s\n' "$(_red FAIL)" "$1"; }

# assert_eq NAME EXPECTED ACTUAL
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"
  else bad "$1"; printf '      expected: %s\n      actual:   %s\n' "$2" "$3"; fi
}

# assert_contains NAME NEEDLE HAYSTACK
assert_contains() {
  case $3 in
    *"$2"*) ok "$1" ;;
    *) bad "$1"; printf '      expected to contain: %s\n      actual: %s\n' "$2" "$3" ;;
  esac
}

# assert_status NAME EXPECTED_CODE -- CMD...
assert_status() {
  _name=$1; _want=$2; shift 3
  "$@" >/dev/null 2>&1; _got=$?
  assert_eq "$_name" "$_want" "$_got"
}

summary() {
  printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

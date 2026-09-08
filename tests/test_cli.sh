#!/usr/bin/env bash
# Unit tests for pulsecheck's command-line contract and its shell helpers.
#
# Nothing here makes a network request: every case either exits during argument
# parsing or calls an extracted shell function directly.
set -u
cd "$(dirname "$0")/.."
. tests/lib.sh

PC=./pulsecheck

echo "--version / --help"

assert_status "--version exits 0" 0 -- $PC --version
assert_contains "--version prints the name and a version" "pulsecheck 0." "$($PC --version)"
assert_eq "-V matches --version" "$($PC --version)" "$($PC -V)"
assert_status "--help exits 0" 0 -- $PC --help
assert_contains "--help documents the usage line" "pulsecheck [options] <url>" "$($PC --help 2>&1)"
assert_contains "--help lists --window" "--window" "$($PC --help 2>&1)"
assert_contains "--help lists --header" "--header" "$($PC --help 2>&1)"

echo
echo "argument errors exit 2 and say why on stderr"

assert_status "no arguments is a usage error" 2 -- $PC
assert_contains "no arguments prints usage to stderr" "pulsecheck [options] <url>" "$($PC 2>&1 >/dev/null)"

assert_status "unknown option" 2 -- $PC --nope https://example.com
assert_contains "unknown option names the option" "unknown option: --nope" \
  "$($PC --nope https://example.com 2>&1 >/dev/null)"

assert_status "a second URL is rejected" 2 -- $PC https://a.example https://b.example
assert_contains "the second URL is named" "unexpected argument: https://b.example" \
  "$($PC https://a.example https://b.example 2>&1 >/dev/null)"

# Every value-taking flag must reject a missing value rather than swallow the
# URL as its argument, which would leave the run with no target at all.
for f in -w --window -i --interval -t --timeout -e --expect -H --header --color --record; do
  assert_status "$f with no value" 2 -- $PC "$f"
  assert_contains "$f says it needs a value" "needs a" "$($PC "$f" 2>&1 >/dev/null)"
done

echo
echo "--window and --interval are validated before anything divides by them"

for w in 0 -1 abc 1.5 ""; do
  assert_status "--window '$w' is rejected" 2 -- $PC --window "$w" https://example.com
done
assert_contains "--window error explains the rule" "--window must be a positive integer" \
  "$($PC --window 0 https://example.com 2>&1 >/dev/null)"

for i in 0 0.0 abc 1.2.3 -1 ""; do
  assert_status "--interval '$i' is rejected" 2 -- $PC --interval "$i" https://example.com
done
assert_contains "--interval error explains the rule" "--interval must be" \
  "$($PC --interval abc https://example.com 2>&1 >/dev/null)"

echo
echo "--header must look like a header"

# A header missing its colon is a quoting mistake, and curl would otherwise
# send the whole string as a header name — a silent wrong request.
assert_status "a header with no colon is rejected" 2 -- $PC -H "Authorization Bearer x" https://example.com
assert_contains "the rejection quotes what was given" 'got: Authorization Bearer x' \
  "$($PC -H "Authorization Bearer x" https://example.com 2>&1 >/dev/null)"
# The three shapes curl itself accepts must all get through argument parsing.
# --diag exits before any request, so this reaches the end of parsing and stops.
for h in "Name: value" "Name;" "@/dev/null"; do
  assert_status "--header '$h' is accepted" 0 -- $PC --diag -H "$h" https://example.com
done

echo
echo "to_ms() — decimal seconds to integer milliseconds"

# The function is lifted out of the script rather than reached by running it:
# sourcing pulsecheck would start a probe loop.
eval "$(sed -n '/^to_ms() {/,/^}/p' pulsecheck)"

assert_eq "whole seconds"        "1000" "$(to_ms 1)"
assert_eq "sub-second"           "500"  "$(to_ms 0.5)"
assert_eq "no leading zero"      "500"  "$(to_ms .5)"
assert_eq "milliseconds"         "1250" "$(to_ms 1.25)"
assert_eq "truncates below 1ms"  "1001" "$(to_ms 1.0019)"
assert_eq "zero"                 "0"    "$(to_ms 0)"
assert_eq "large value"          "300000" "$(to_ms 300)"
# A leading zero must not be read as octal: "059" out of date +%N is exactly
# how a loop that looks correct aborts at runtime.
assert_eq "08 is decimal, not octal" "8000" "$(to_ms 08)"
assert_eq "a 09x fraction is decimal, not octal" "1099" "$(to_ms 1.099)"

summary

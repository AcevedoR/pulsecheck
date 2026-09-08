#!/bin/sh
# Install pulsecheck.
#
#   curl -fsSL https://raw.githubusercontent.com/AcevedoR/pulsecheck/main/install.sh | sh
#   PREFIX=~/.local/bin sh install.sh        # somewhere that needs no sudo
#
# POSIX sh on purpose: this runs before pulsecheck is installed, so it cannot
# assume the bash the script itself needs.
set -eu

REPO=${REPO:-AcevedoR/pulsecheck}
REF=${REF:-main}
PREFIX=${PREFIX:-/usr/local/bin}
URL="https://raw.githubusercontent.com/$REPO/$REF/pulsecheck"

say()  { printf '%s\n' "$*"; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required (it is also what pulsecheck probes with)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pulsecheck-install.XXXXXX") || die "cannot create a temp directory"
trap 'rm -rf "$TMP"' EXIT INT TERM

say "fetching $URL"
curl -fsSL "$URL" -o "$TMP/pulsecheck" || die "download failed"

# Downloading a script and running it deserves at least a look at what arrived:
# a proxy error page or a 404 body would otherwise be installed as a program.
head -1 "$TMP/pulsecheck" | grep -q '^#!.*bash' || die "that does not look like the script (no bash shebang)"
grep -q '^VERSION=' "$TMP/pulsecheck" || die "that does not look like the script (no VERSION)"
bash -n "$TMP/pulsecheck" 2>/dev/null || die "the downloaded script does not parse"
chmod +x "$TMP/pulsecheck"

VER=$("$TMP/pulsecheck" --version 2>/dev/null || echo "pulsecheck ?")

if [ -w "$PREFIX" ]; then
  mv "$TMP/pulsecheck" "$PREFIX/pulsecheck"
elif command -v sudo >/dev/null; then
  say "$PREFIX is not writable; using sudo"
  sudo mv "$TMP/pulsecheck" "$PREFIX/pulsecheck"
else
  die "$PREFIX is not writable and sudo is not available — try PREFIX=~/.local/bin"
fi

say "installed $VER to $PREFIX/pulsecheck"
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) say "note: $PREFIX is not on your PATH" ;;
esac

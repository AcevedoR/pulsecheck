#!/usr/bin/env python3
"""Report identifiers the embedded awk program uses but never receives.

awk has no undefined-variable error: a name that was never assigned, never
declared as a function local and never passed with -v is simply the empty
string, or zero in numeric context. In this script that has meant a division by
zero (an interval read as 0), a glint that silently stopped moving, a scale
guard that never fired, and a whole --json/--summary feature that did nothing
because its -v bindings were added to the wrong line. None of them raised so
much as a warning.

Prints the offending names, or nothing when clean.
"""
import re
import sys

src = open(sys.argv[1], encoding='utf-8').read()

m = re.search(r"^BEGIN \{.*?^\}'", src, re.S | re.M)
if not m:
    print('could not find the awk program in ' + sys.argv[1])
    sys.exit(1)
prog = m.group(0)

# Strings first — otherwise a # inside one reads as a comment, and the text of
# every message would be scanned for identifiers.
prog = re.sub(r'"(\\.|[^"\\])*"', '""', prog)
prog = re.sub(r'#[^\n]*', '', prog)

AWK_KEYWORDS = set('''
BEGIN END function return if else for while do break continue next exit
print printf sprintf substr length split index sub gsub match getline close
system fflush log exp sqrt int rand srand tolower toupper in delete
NR NF FS OFS ORS RS FILENAME SUBSEP
'''.split())

passed = set(re.findall(r'-v\s+([A-Za-z_]\w*)=', src))
defined = set(re.findall(r'function\s+(\w+)\s*\(', prog))

local = set()
for f in re.finditer(r'function\s+\w+\s*\(([^)]*)\)', prog):
    local |= {a.strip() for a in f.group(1).split(',') if a.strip()}

assigned = set(re.findall(r'([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*(?:=[^=]|\+\+|\+=|-=)', prog))
assigned |= set(re.findall(r'for\s*\(\s*([A-Za-z_]\w*)', prog))
assigned |= set(re.findall(r'\(\s*([A-Za-z_]\w*)\s+in\s', prog))

used = set(re.findall(r'\b([A-Za-z_]\w*)\b(?!\s*\()', prog))

missing = sorted(used - AWK_KEYWORDS - defined - local - assigned - passed)

# A parameter that shares a function's name shadows it for the whole body.
# gawk and BWK awk allow it; mawk refuses the definition outright and then
# reads the entire function body as top-level code, which is a wall of
# unrelated syntax errors pointing nowhere near the actual mistake. Ours was a
# summary function with a local called `line`, next to a function called
# `line()`.
shadow = []
for f in re.finditer(r'function\s+(\w+)\s*\(([^)]*)\)', prog):
    for a in f.group(2).split(','):
        a = a.strip()
        if a and a in defined:
            shadow.append('%s() parameter %s shadows the function %s()' % (f.group(1), a, a))

# Assigning to a function's name is the same mistake without the parameter
# list: legal-looking, accepted by gawk and BWK awk, fatal in mawk.
for a in sorted(assigned & defined):
    shadow.append('%s is assigned to, but it is a function' % a)

for s_ in shadow:
    print(s_)
print(' '.join(missing))

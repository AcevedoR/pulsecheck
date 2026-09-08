#!/usr/bin/env python3
"""Count apostrophes inside the embedded awk program.

The program lives in a single-quoted shell string, so one apostrophe anywhere
in it — including in a comment — closes the quote and hands the remainder of
the file to bash. This has happened.

Counted here rather than with sed and grep because those disagreed across
platforms for the same file: 1 locally, 0 on a macOS CI runner. A check that
answers differently depending on where it runs is worse than no check.

Prints the count in the body, excluding the closing delimiter. 0 is clean.
"""
import re
import sys

src = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"^BEGIN \{.*?^\}'", src, re.S | re.M)
if not m:
    print('could not find the awk program')
    sys.exit(1)
print(m.group(0)[:-2].count("'"))

#!/usr/bin/env python3
"""Replay a `pulsecheck --record` stream into a character grid and print it.

usage: tests/replay.py FILE [ROWS COLS]

Asserting on escape sequences proves nothing about what a user sees; this
renders the stream the way a terminal would, so the assertion becomes "how many
list rows hold a request" or "is row 11 blank".
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen import Screen

path = sys.argv[1]
rows = int(sys.argv[2]) if len(sys.argv) > 2 else 59
cols = int(sys.argv[3]) if len(sys.argv) > 3 else 200
data = open(path, encoding='utf-8', errors='replace').read()
sc = Screen(rows, cols).feed(data)
grid = sc.text()
print('+' + '-' * cols + '+')
for i, line in enumerate(grid, 1):
    print('|' + line.ljust(cols) + '|')
print('+' + '-' * cols + '+')
listed = [l for l in grid[6:] if 'HTTP' in l]
stamps = set(l.split()[0] for l in listed)
print('%d of %d list rows hold a request; %d distinct timestamps' % (
    len(listed), len(grid) - 6, len(stamps)))

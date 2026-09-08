#!/usr/bin/env python3
"""Turn a `pulsecheck --record` capture into an animated SVG.

    tools/svgcast.py CAPTURE ROWS COLS SECONDS OUT.svg

The README needs to show the thing moving — a rolling window is the whole point
of this tool and it is invisible in static text — and the usual route to that
(asciinema plus agg) is two more dependencies for anyone regenerating it. The
capture format is already ours, so this replays it into a grid and writes the
frames out as an SVG that animates with CSS. No dependencies, and it renders
inline on GitHub.

The screen model here is deliberately separate from tests/screen.py: that one
answers "what characters does a user see" and is kept as small as possible on
purpose. This one also has to track colour, which the tests do not care about.
"""
import re
import sys

# xterm's first 8 colours, plus the 256-colour entry the script uses for orange
BASE = {30: '#2e3436', 31: '#e05252', 32: '#4e9a06', 33: '#c4a000', 34: '#3465a4',
        35: '#75507b', 36: '#06989a', 37: '#d3d7cf', 90: '#666666', 97: '#eeeeee'}
ORANGE = '#f57900'
FG = '#d0d0d0'
BG = '#1c1c1c'
DIM = '#7a7a7a'


class Cell:
    __slots__ = ('ch', 'fg', 'bold')

    def __init__(self, ch=' ', fg=FG, bold=False):
        self.ch, self.fg, self.bold = ch, fg, bold


class Term:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[Cell() for _ in range(cols)] for _ in range(rows)]
        self.r = self.c = 0
        self.fg, self.bold, self.dim = FG, False, False

    def sgr(self, params):
        for p in params or [0]:
            if p == 0:
                self.fg, self.bold, self.dim = FG, False, False
            elif p == 1:
                self.bold = True
            elif p == 2:
                self.dim = True
            elif p in BASE:
                self.fg = BASE[p]
            elif p == 208:                      # from the 38;5;208 orange
                self.fg = ORANGE

    def put(self, ch):
        if self.c >= self.cols:
            self.c = 0
            self.r = min(self.r + 1, self.rows - 1)
        colour = DIM if (self.dim and self.fg == FG) else self.fg
        self.grid[self.r][self.c] = Cell(ch, colour, self.bold)
        self.c += 1

    def feed(self, data, on_frame):
        i = 0
        while i < len(data):
            ch = data[i]
            if ch == '\x1b':
                m = re.match(r'\x1b\[([?0-9;]*)([A-Za-z])', data[i:])
                if not m:
                    i += 2 if data[i:i + 2] in ('\x1b7', '\x1b8') else 1
                    continue
                ps, fin = m.group(1), m.group(2)
                if not ps.startswith('?'):
                    a = [int(x) for x in ps.split(';') if x != '']
                    if fin == 'H':
                        # A repaint of row 1 or row 5 starts a new frame: row 1
                        # is a fresh sample, row 5 is an animation tick.
                        row = (a[0] - 1) if a else 0
                        if row in (0, 4):
                            on_frame()
                        self.r = min(max(row, 0), self.rows - 1)
                        self.c = min(max((a[1] - 1) if len(a) > 1 else 0, 0), self.cols - 1)
                    elif fin == 'K':
                        for x in range(self.c, self.cols):
                            self.grid[self.r][x] = Cell()
                    elif fin == 'J':
                        self.grid = [[Cell() for _ in range(self.cols)] for _ in range(self.rows)]
                    elif fin == 'm':
                        self.sgr(a)
                i += m.end()
                continue
            if ch == '\n':
                self.r = min(self.r + 1, self.rows - 1)
                i += 1
                continue
            if ch == '\r':
                self.c = 0
                i += 1
                continue
            self.put(ch)
            i += 1


def snapshot(t):
    return tuple(tuple((c.ch, c.fg, c.bold) for c in row) for row in t.grid)


def esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def main():
    cap, rows, cols, secs, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), \
        float(sys.argv[4]), sys.argv[5]
    data = open(cap, encoding='utf-8', errors='replace').read()

    term = Term(rows, cols)
    frames = []

    def on_frame():
        s = snapshot(term)
        if not frames or frames[-1] != s:
            frames.append(s)

    term.feed(data, on_frame)
    on_frame()

    # Keep the file small enough to sit in a README: take an even spread rather
    # than the first N, so the demo still shows the window filling up.
    CAP = 72
    if len(frames) > CAP:
        step = len(frames) / CAP
        frames = [frames[int(i * step)] for i in range(CAP)]
    n = len(frames)
    if n == 0:
        sys.exit('no frames in ' + cap)

    CW, CH, PAD = 8.4, 17.0, 14
    W, H = int(cols * CW + PAD * 2), int(rows * CH + PAD * 2)
    slice_pct = 100.0 / n

    # One shared keyframe plus a per-frame negative delay, rather than one
    # keyframe block per frame: same effect, a fraction of the CSS.
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
             'viewBox="0 0 %d %d" font-family="SFMono-Regular,Menlo,Consolas,monospace" '
             'font-size="13">' % (W, H, W, H)]
    parts.append('<style>.f{opacity:0;animation:s %.2fs steps(1,end) infinite}'
                 '@keyframes s{0%%,%.4f%%{opacity:1}%.4f%%,100%%{opacity:0}}'
                 % (secs, slice_pct, slice_pct))
    for i in range(1, n):
        parts.append('.d%d{animation-delay:-%.2fs}' % (i, i * secs / n))
    parts.append('</style>')
    parts.append('<rect width="100%%" height="100%%" rx="6" fill="%s"/>' % BG)

    for i, fr in enumerate(frames):
        parts.append('<g class="f d%d">' % i if i else '<g class="f">')
        for r, row in enumerate(fr):
            y = int(PAD + (r + 1) * CH - 4)
            runs, cur = [], None
            for c, (chx, fgx, boldx) in enumerate(row):
                if cur and cur[0] == fgx and cur[1] == boldx and cur[3] == c:
                    cur[2] += chx
                    cur[3] = c + 1
                else:
                    cur = [fgx, boldx, chx, c + 1, c]
                    runs.append(cur)
            spans = []
            for fgx, boldx, text, _end, start in runs:
                if not text.strip():
                    continue
                spans.append('<tspan x="%d" fill="%s"%s>%s</tspan>'
                             % (int(PAD + start * CW), fgx,
                                ' font-weight="bold"' if boldx else '', esc(text)))
            if spans:
                parts.append('<text y="%d">%s</text>' % (y, ''.join(spans)))
        parts.append('</g>')
    parts.append('</svg>')

    open(out, 'w', encoding='utf-8').write(''.join(parts))
    print('%s: %d frames, %.1fs loop, %d bytes' %
          (out, n, secs, len(''.join(parts))))


if __name__ == '__main__':
    main()

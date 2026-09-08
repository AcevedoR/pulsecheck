# Minimal ANSI screen model: CUP, EL, ED, DECSTBM, LF with scroll region, SGR.
import re
class Screen:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.buf=[[' ']*cols for _ in range(rows)]
        self.r=self.c=0; self.top=0; self.bot=rows-1
    def feed(self, data):
        i=0
        while i < len(data):
            ch=data[i]
            if ch=='\x1b':
                m=re.match(r'\x1b\[([?0-9;]*)([A-Za-z])', data[i:])
                if m:
                    ps,fin=m.group(1),m.group(2)
                    if ps.startswith('?'):        # private modes (cursor hide/show,
                        i+=m.end(); continue      # alt screen): no effect on the grid
                    a=[int(x) for x in ps.split(';') if x!=''] if ps else []
                    if fin=='H':
                        # a terminal clamps addressing to the screen; so must
                        # this, or a row beyond the bottom raises instead of
                        # showing the clamping a user would actually see
                        self.r=min(max(a[0]-1,0), self.rows-1) if a else 0
                        self.c=min(max(a[1]-1,0), self.cols-1) if len(a)>1 else 0
                    elif fin=='K':
                        self.r=min(self.r, self.rows-1)
                        for x in range(self.c, self.cols): self.buf[self.r][x]=' '
                    elif fin=='J':
                        self.buf=[[' ']*self.cols for _ in range(self.rows)]
                    elif fin=='r':
                        if len(a)>=2: self.top, self.bot = a[0]-1, a[1]-1
                        else: self.top, self.bot = 0, self.rows-1
                    i+=m.end(); continue
                if data[i:i+2] in ('\x1b7','\x1b8'): i+=2; continue
                i+=1; continue
            if ch=='\n':
                self.r=min(self.r, self.rows-1)
                if self.r==self.bot:
                    del self.buf[self.top]; self.buf.insert(self.bot, [' ']*self.cols)
                else: self.r=min(self.r+1, self.rows-1)
                i+=1; continue
            if ch=='\r': self.c=0; i+=1; continue
            # wrap at the right margin the way a terminal does, scrolling if the
            # cursor is on the last row — without this the model raises on any
            # line longer than the screen instead of showing what a user sees
            if self.c >= self.cols:
                self.c=0
                if self.r==self.bot:
                    del self.buf[self.top]; self.buf.insert(self.bot, [' ']*self.cols)
                elif self.r < self.rows-1:
                    self.r+=1
            self.buf[self.r][self.c]=ch; self.c+=1
            i+=1
        return self
    def text(self): return [''.join(r).rstrip() for r in self.buf]

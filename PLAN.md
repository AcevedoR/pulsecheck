# pulsecheck — plan (draft)

Status: **v0.3.0.** Published at github.com/AcevedoR/pulsecheck (public, MIT).
Last updated: 2026-09-08

---

## 1. What it is

A single bash + awk script that probes one HTTP endpoint on an interval and
prints, per request: latency, status, and a **rolling** p95 and error rate over
the last N samples.

## 2. The gap it fills

This started as a `while true; do curl ...; done | awk` one-liner. That gives one
request at a time and aggregates nothing. The obvious alternatives were tried and
measured before writing any code:

| Tool | Live p95? | Rolling? | Verdict |
|---|---|---|---|
| `curl` in a loop | no | — | no aggregation at all |
| `vegeta attack \| report -every=1s` | **yes** | **no** | percentiles cumulative since start |
| `oha -q 1 -z <dur>` | yes (TUI) | no | same, plus it's a load generator |
| `k6` | yes | no | far too heavy for a health probe |

`vegeta` was confirmed working and does print p95 + success ratio + status-code
counts every second. Its one disqualifying property: **stats are cumulative from
process start.** A single three-second stall in hour one pins p95 for the rest of
the day, which makes it useless as a *live* signal on a long-running watch.

**The differentiator is therefore the rolling window, not the health check.**
Anything that dilutes that (a binary up/down verdict, a load-generation mode) is
off-strategy. See §7.

## 3. Naming — decided

`pulsecheck`. Free on crates.io, Homebrew, and npm, with no GitHub collision.

Rejected, with the reason, so this isn't relitigated:

| Candidate | Why not |
|---|---|
| `httpwatch` | existing commercial HTTP sniffer |
| `httpbeat` | `christiangalsterer/httpbeat` (105★) is an *Elastic Beat that calls HTTP endpoints* — same name, same domain; `-beat` reads as "Elasticsearch shipper" |
| `blip` | `apenwarr/blip` (1.8k★) is literally "a tool for seeing your Internet latency" |
| `httphealth` | `d6o/HttpHealth` already does this; `http*` CLI namespace is saturated (`httping`, `httpstat`, `httpie`, `httpx`, `http-prompt` all taken in brew) and `httping` in particular gets conflated |
| `hcheck` | free, but `h` is unresolvable and nobody searches it; `hipache-hchecker` (85★) is adjacent. Get the ergonomics from a local shell alias instead |
| `vitals` / `pester` / `tacho` / `steth` | owned by web-vitals, sethgrid/pester, google/tachometer, facebook/stetho |

## 4. Current state

### v0.2 — the measurement fixes

The question that drove this release was "what would it take for a lot of devs
to use this, like vegeta?" The answer turned out not to be features: three of
the numbers were wrong, and each would have got the tool dismissed by exactly
the people worth convincing.

**1. Most of the reported latency was connection setup.** One `curl`
process per request pays a full TCP+TLS handshake every sample. Measured on
`https://example.com`: **51ms** fresh (dns 2.4 / tcp 13.7 / tls 30.4) against
**19ms** on a reused connection — about two thirds of it setup, and the same
shape on every TLS endpoint tried. Anyone cross-checking against vegeta,
which keeps connections alive, would have seen a 3x discrepancy and concluded
the tool was broken. Reuse is now the default; `--fresh` restores the old
behaviour, which is the right measurement if cold-connect cost is the question.

How reuse works, because it is not obvious and each piece was forced by a
measurement:
- **One `curl` per batch of `20 * WIN` requests** (clamped 256..4096), holding
  one connection. At 20x the window a reconnect sample is inside the rolling
  window only `WIN/BATCH` = 5% of the time, and is `1/WIN` = 1.7% of it when it
  is — below what p95 can see, so a boundary handshake can move `max` and not
  p95.
- **A `-K` config file with paired `url` / `output` entries.** A bare
  `-o /dev/null` applies only to the *first* url; with repeated urls every other
  response body lands on stdout and corrupts the stream awk reads. Verified
  leak, and it was initially mistaken for evidence that curl streams (below).
- **`-w '%{stderr}...'`, not plain `-w`.** curl block-buffers `-w` through a
  pipe and delivers a whole batch at exit, which would freeze the display and
  then dump it; `-N` does not help. stderr is unbuffered and streams. The main
  session had "verified" streaming earlier and was wrong: the leaking response
  bodies were flushing the buffer.
- **`--rate N/d`**, requests per *day*, so any interval is expressible —
  `86400000 / interval_ms`. `/s` and `/m` only take integers and cannot say
  0.5s. `--rate` needs curl >= 7.84, probed by capability
  (`curl --rate 1/s --help`) rather than by parsing a version string.
- **The absolute grid still wraps it.** `--rate` paces well *inside* a batch
  (+0.9%) but fires the first request of the next batch immediately (measured
  0.07s gap, against 0.52s with the grid), and its per-batch drift never
  self-corrects. Both mechanisms, at different granularities.
- **One `date` fork per sample**, in a `while read` loop between curl's stderr
  and awk. awk has no `systime()` and curl has no wall-clock `-w` variable, so
  the timestamp has to come from the shell either way — same cost as before.

**2. The window was not the duration it claimed.** The old loop slept the full
interval *after* each request, so the period was interval + request time:
measured **+16.7%** at `-i 0.5`, and **+92%** against a 0.9s endpoint. Naive
`interval - time_total` still ran +5.4% because it cannot see its own fork cost.
Pacing is now against an **absolute grid** (`target = T0 + n*interval`), which
measured **+0.3% to +0.4%** at `-i 1`, `-i 0.5` and `-i 0.2`. A request that
overruns its slot skips the missed slots; it never queues and never fires back
to back, so a recovering endpoint cannot be turned into a burst load test. The
header now also prints the window's **real time span** (`window 32/60 samples /
15.6s`), so "60 samples" can no longer imply a duration it does not have.

**3. p50/p95/max mixed successful and failed requests.** A refusal returns in
microseconds, so the aggregates got *better* as an endpoint went down. They are
now computed over successful samples only, with the denominator stated
(`over 32 ok`), and all three render `—` when the window holds no success at
all — absence rather than a number derived from failures. `err%` still covers
every request, because that is what err means. This also let `acol()` go: it
greyed out the aggregates whenever the window held any error, which had been a
mitigation for the contamination and was destroying signal (one error in sixty
greyed out three numbers describing fifty-nine clean samples).

Supporting changes: a dim `⇄` marks a list row that paid for a handshake, so a
tall bar in a field of short ones explains itself; the mode field degrades to
`reuse · server closes` when more than half the window reconnected, which is
what a `Connection: close` server produces (python's `http.server` does exactly
this), so the tool reports the mode it is *getting* rather than the one it asked
for; the trace scale ignores failures and reconnects, because a run begins with
a handshake by definition and at `-i 0.5` that one sample otherwise owns the
scale for the first thirty seconds; and `NO_COLOR` plus `--color
never|always|auto` are honoured.

**Teardown was rebuilt.** The old shape relied on SIGPIPE reaching a producer
that wrote every interval. A long-lived curl holds an open socket, so SIGPIPE
could arrive an interval late or never. awk and the producer are now two
separately tracked background jobs joined by a fifo — bash 3.2 cannot report the
pid of a non-final pipeline element — plus pid files for curl and the ticker and
a `stop` sentinel file that closes the race where killing curl makes the
producer start a new batch. Verified on SIGTERM: exits in **100ms** in both
modes with no orphaned curl, awk, ticker or sleep. **SIGINT is unverified in
this sandbox**, where a background job from a non-interactive shell has SIGINT
set to `SIG_IGN` (no trap can override that) and the pty harnesses that could
test it properly hung repeatedly, and a second, independent attempt hit the
same wall. INT and TERM share one handler, so this is a testing gap, not a known
defect — but it is a gap.

**The awk stdin contract gained one APPENDED field**, so every existing `$1..$4`
kept its meaning:
`<HH:MM:SS> <epoch.ffffff> <http_code> <time_total> <paid_for_a_handshake>`.
Field 5 is normalised in the producer, not in awk: in `--fresh` mode every
request reconnects, so it emits a constant 0 rather than flagging every row.

### Inventory

`pulsecheck` (v0.2.0) — flags `-w/--window`, `-i/--interval`, `-t/--timeout`,
`-e/--expect`, `-p/--plain`, `--fresh`, `--color`, `--no-wave`, `--diag`,
`--record`, `-h`, `-V`; argument validation; TTY-aware colour;
`curl` presence check. `README.md` — usage, output guide, caveats.

**Split display (added after the first prototype).** On a TTY the screen is two
regions: a five-line fixed header (target, probe settings, `last`/`p50`/`p95`/
`max`, `err` with the bad/total count, `n`, `elapsed`) and a scrolling list of
one line per request underneath. Mechanics, since they constrain future changes:

- **No scroll region, and no scrolling.** The list is a ring of the visible
  lines, repainted row by row with `ESC[row;1H` + `ESC[K`. Two earlier designs
  failed on a real terminal, both presenting as *the entire list collapsing onto
  one row*: (1) a DEC scroll region plus newline-at-the-bottom, with the header
  repaint wrapped in DECSC/DECRC — a terminal that does not preserve the saved
  cursor parks it on the rule row and every line overwrites the last; (2) the
  same region with the list row tracked in awk and addressed absolutely. Only
  the repaint design depends on nothing but cursor addressing and erase-to-EOL.
  Verified against a screen model that ignores scroll regions entirely, and one
  whose screen is smaller than the size reported to the script.
- While the list is filling only the new row is written; once full the ring
  shifts and the whole area is repainted (~2KB per sample at 40 rows).
- The header repaints in place on every sample by addressing rows 1–6
  absolutely. It emits no newline, so it cannot itself scroll the list.
- **The list cursor is tracked in awk, not saved and restored with
  DECSC/DECRC.** The first version wrapped each repaint in `ESC 7` / `ESC 8`;
  on a terminal that does not preserve the saved position that leaves the
  cursor parked on the rule row, so *every list line overwrites the previous
  one* and the whole list is a single line. The geometry is known, so awk keeps
  the next list row in `crow`, writes it absolutely, and scrolls the region with
  one explicit newline on its bottom row.
- The scroll must fire only once the bottom row has actually been written
  (`crow > rows`, not `crow >= rows`). The `>=` version scrolled while the last
  row was still blank, which left one permanent empty line drifting up through
  the list.
- No row is ever written to its last column: a row filled to the right margin
  leaves the terminal in pending-wrap, and a wrap on the rule row would scroll
  the list. Hence the rule and the trace are `cols - 1` wide and the list bar is
  sized to `cols - 32`.
- Minimum width for the split display is 72 columns — the header rows run to
  ~60 visible columns, and clipping them correctly would mean measuring visible
  width through the colour escapes.
- Teardown (region reset, cursor unhide, park below the list) runs from a shell
  trap. The probe pipeline is therefore backgrounded with `wait` on it rather
  than run in the foreground — bash defers a trap until the foreground command
  returns, so a plain `kill` on the script would otherwise leave the terminal
  with a scroll region set. Verified under a real pty: region reset and cursor
  restore are emitted on both SIGINT and SIGTERM, with no orphaned children.
- Degrades to the original one-line-per-sample stream (which carries its own
  aggregates) when stdout is not a TTY, with `--plain`, when the size cannot be
  measured, or when the terminal is under 10 rows or 40 columns.
- **The terminal is asked its own size first, with DSR.** Park the cursor past
  the bottom right (`ESC[9999;9999H`) and read back where it actually landed
  (`ESC[6n`, answered as `ESC[rows;colsR`); that is the real grid, whatever the
  kernel or terminfo believe. Needs raw mode on `/dev/tty` and a 1s timeout, and
  falls back to `stty size` then `tput`. This matters because a size larger than
  the real screen makes every row past the bottom clamp onto the last one, which
  freezes the list and leaves exactly one line changing — indistinguishable, to
  the user, from the two drawing bugs above.
- **`stty size </dev/tty` is preferred over `tput`.** Inside
  `$(...)` stdout is a pipe, so ncurses falls back to *stderr* to find the
  terminal — which means `COLS=$(tput cols 2>/dev/null)` silently returns
  terminfo's 80x24 default rather than the real size, with no error anywhere.
  Every run before this was drawing an 80x24 header regardless of the window.
  `tput` remains the fallback, but with its stderr left alone. Caught only by a
  test that set the pty size before exec and then checked the rule width
  against it — an easy bug to stare straight through.
- The list bar uses the same p05-p95 window scale as the trace, for the same
  reason: on an absolute scale every bar in a healthy run came out the same
  width. The absolute numbers live in the header and on the trace axis, so the
  bar is free to show position within the window instead.
- The list drops the literal "HTTP" and dims the status while it matches
  `--expect`. Repeating "HTTP 200" down forty rows is noise that competes with
  the one row that will eventually say something else.
- p50 and max landed early as a side effect: the header has room for them and
  they come free from the buffer already being sorted for p95.

**Heartbeat trace (three animated rows).** One column per sample, oldest left,
three rows of eight block steps for 24 levels, a glint band sweeping across once
per interval, and the newest column landing lit. Design points worth not
rediscovering:

- **It auto-scales to the window between p05 and p95**, with clip markers on the
  axis (`59.4ms+`, `48.6ms-`). Three scalings were tried and two were wrong:
  absolute log decades drew 51ms and 58ms at *identical* height, so a healthy
  endpoint was one solid straight line — the version the user (correctly) called
  ugly; min-to-max let a single 320ms spike, or a single microsecond-fast
  refusal, flatten everything else onto one row. The percentile band keeps the
  detail where the samples actually are and clips the outliers, which is what an
  auto-ranging monitor does.
- Colour still comes from the *absolute* thresholds while the shape comes from
  the *relative* scale, so a lively waveform in green reads as "moving around,
  but healthy" — the shape cannot make a healthy endpoint look alarming.
- A sub-percent spread is treated as flat (drawn as a level line at mid height)
  rather than amplified: auto-scaling noise into a dramatic waveform would be
  the same lie in the other direction.
- Failures are drawn at their measured height in red, not as a full-height wall.
  A refusal that returned in 0.2ms and a 503 that took 1.2s are different facts.
- **Latency colour thresholds are 100 / 300 / 1000ms.** The original 10/50/500
  were localhost numbers and painted an entirely healthy 53ms endpoint orange,
  which is what made the first version look like an alarm going off.

- Animation needs frames *between* samples, so a second producer emits `TICK`
  lines into the same pipe at 10fps and awk repaints only the trace row on one.
  awk has to stay the single writer to the screen, so interleaving into its
  stdin is the mechanism rather than a second process drawing. Each `printf` is
  one short write, well under `PIPE_BUF`, so lines cannot tear.
- The glint crosses in `--interval` (`SHF = interval/frame`, clamped to 4–40
  frames), so it arrives at the right edge as the next sample lands. It sweeps
  only the *populated* columns; spanning the full width meant it spent most of
  its travel over an empty tail while the window filled.
- It is a band (centre plus two cells either side), not a point: at 10fps and
  ~10 columns per frame a single bright cell reads as a flicker rather than a
  sweep.
- Colour is emitted only when it changes between columns, so a flat trace costs
  a few bytes per frame instead of one escape per column. Measured cost of the
  whole animation: ~0.06s CPU over 8s (<1% of a core), ~2KB/s to the terminal.
  `--no-wave` removes the row, the ticker and the repaint.
- Per-column colour uses each sample's own latency threshold, *not* the
  uncoloured-when-errors rule below: a column is one request, so its own
  threshold is honest. That rule exists only for aggregates.
- `substr()` is byte-based in BWK awk, so the glyph ramp lives in an array; a
  one-string ramp silently sliced UTF-8 in half.

**Verified by hand:** help/version/unknown-flag/missing-URL exit codes; colour
suppressed when stdout is not a TTY; `HTTP 000` on connection-refused counted as
an error; `-e 401` reclassifying 401 as success; window filling to `n`.

**A third bug, found when the header made it visible:** during a total outage the
header rendered `p95` **green** next to `err 100.0%` — the §5 limitation that
refusals are microsecond-fast, now printed large in the most prominent part of
the screen. Aggregate latency is therefore uncoloured whenever the window holds
any error; the thresholds apply only to a clean window. This does not fix the
underlying mixing of successful and failed samples — that is still v0.2.

**Two bugs found and fixed during earlier testing** — both worth keeping in mind as
the shape of mistake this tool invites:

1. A refused connection returns in ~0.2ms, which the latency thresholds painted
   **green** — an outage rendering as healthy. Failed requests are now red
   regardless of speed.
2. The nearest-rank percentile index used `int()` (floor) where the definition
   needs ceil, so p95 **systematically understated** whenever `0.95 × n` wasn't a
   whole number — at n=3 it returned the *lowest* sample. Now `ceil(p*m)`,
   re-verified at n=2, n=3, and n=100-with-one-outlier.

**Two more bugs, both from the animation work, both bash/awk-boundary mistakes
rather than logic errors:**

1. A comment inside the single-quoted awk program contained an apostrophe
   (`doesn't`), which closed the quote and handed the rest of the program to
   bash. `bash -n` catches this instantly — worth running after every edit to
   the awk block, and worth keeping apostrophes out of it entirely.
2. `frm` (the frame interval) was used in awk before the `-v frm=` that passes
   it was actually added, so `int(ivl/frm)` divided by zero on startup. The unit
   tests passed the variable explicitly and therefore could not see it: testing
   the awk program in isolation does not test the invocation that builds it.
   Only running the real script caught it.
3. `COLS=$(tput cols 2>/dev/null)` always returned 80x24 — see the size note
   above.

**A shell detail worth remembering:** redirections apply left to right, so
`stty size </dev/tty 2>/dev/null` leaks bash's own "/dev/tty: Device not
configured" error onto the display on a system with no controlling terminal.
The stderr redirect has to come first: `stty size 2>/dev/null </dev/tty`.

**Debugging aids added, because two of the three display bugs were only
reproducible on the user's terminal:** `--diag` prints the DSR/stty/tput answers
and the geometry actually chosen, and `--record FILE` tees the exact byte stream
sent to the screen (via `exec > >(tee FILE)`, placed after the geometry probes so
it cannot perturb them). `tests/replay.py FILE ROWS COLS` renders a recording
back into a character grid. One recording from a broken terminal is therefore
enough to see what the user saw. Note the first version of `--diag` reported
`stdout is a tty: no` on a real terminal, because `[ -t 1 ]` was evaluated inside
`$(...)` where stdout is the substitution pipe — a diagnostic that lies is worse
than none.

**On exit the cursor is parked on the cleared last row rather than newline-ing
past it:** a newline on the bottom row scrolls the whole screen and pushes the
header off the top, discarding the final frame — which is the thing worth
keeping after Ctrl-C. The alternate screen buffer was considered and rejected
for the same reason: it would wipe the last numbers off the display on exit.

**A whole feature that did nothing, silently:** the `--json` and `--summary`
work was written, and its `-v` bindings were added to a line that existed only
on a different branch. awk therefore saw `json`, `summary` and `rundir` as empty
strings, took every false branch, and produced no JSON and no summary while
exiting 0. Nothing warned — this is the fourth time an unbound awk variable has
cost real time here, after the interval division by zero, the dead glint and the
scale guard that never fired. `tests/test_static.sh` now compares the set of
identifiers the awk program uses against the set it receives, and audits itself
by deleting a binding it knows about and checking that it complains, because a
silent audit is worse than none.

**A number that was wrong on every run, for the first twenty seconds of it:**
nearest rank `ceil(0.95*m)` equals `m` for every `m` below 20, so with a
partially filled window "p95" was simply the maximum under another name. Every
run opens on a connection handshake, which is the maximum. Measured on a steady
16ms endpoint: p95 read **90.0ms** from the first sample to the nineteenth, then
snapped to 16.8ms at the twentieth — the tool contradicting itself inside the
first twenty seconds of every run, and doing it in the place a new user looks
first. Nothing about the percentile code was wrong; the mistake was printing a
statistic whose rank could not yet exclude a single sample. It is now withheld
until 20 successful samples are in the window, on the same principle as the
dashes for a window with no successes: `max` was already on that row and is the
honest name for the number it was showing. `tests/test_window.sh` drives the
whole awk program to pin it, which is also the first test here that exercises
the rendering path rather than an extracted function.

**The worst bug in the project so far, found by a portability audit rather than
by use:** awk parses and formats numbers according to the locale, so under one
with a comma decimal separator — German, French, most of Europe — `"0.0532" *
1000` evaluates to **0** and `printf "%.1f"` emits `53,0`. Every latency on
screen reads `0,0ms`. Not a crash, not a warning: the tool simply reports
nothing at all, confidently, to a third of its potential users. Reproduced here
on BWK awk under `de_DE.UTF-8` and `fr_FR.UTF-8`, and reported for mawk, which
is Ubuntu default awk; gawk is the one implementation that mitigates it, which
means the bug would have been invisible on a developer machine with gawk and
live on the same code in CI. The fix is one line — the script runs in the C
locale — and it costs nothing, because every string it formats is either a
number it produced or a byte sequence it passes through, and the terminal
decodes the UTF-8 glyphs by its own rules regardless. `tests/test_locale.sh`
pins it, and the CI matrix installs `de_DE.UTF-8` so the check has teeth.

**A fourth, which cost five CI rounds:** the end-to-end tests killed a probe
after N lines in order to read its output. On one runner the output never
arrived at all — the server logged the requests, a direct curl to the same url
answered 200, stderr was empty, and the tool was plainly working while the
harness could not see it. Each rerun failed on a different assertion, which is
the signature of a harness race rather than a defect. Two real bugs came out of
chasing it (both test servers were single-threaded and stalled on a killed
keep-alive connection), but the fix in the end was to stop killing the thing
under test: with `--count` a run ends itself, having flushed and closed what it
owns before the test reads a byte. That also took the suite from tens of
seconds to about two.

**Three harness failures that each looked like a bug in the program:**

- SIGINT "did not terminate the script". It does, in 0.01s. The first harness
  started pulsecheck as a background job of a non-interactive shell, where
  POSIX requires SIGINT to be ignored and no `trap` can override it. The second
  killed its own process group and took python with it. The third stopped
  reading the pty after signalling, so cleanup blocked writing to a full
  terminal buffer and never reached its own exit. Three separate ways to
  measure the wrong thing.
- A "hang" that was an unbounded drain loop in the test, spinning while the
  program under test was already dead.
- Every awk-dialect claim in the audit was marked UNVERIFIED because gawk and
  mawk are not installed on this machine, which is exactly why the CI matrix
  now selects the awk implementation instead of trusting whichever one happens
  to be on PATH.

**Five more from the v0.2 round, in the same spirit:**

1. **`spos` was read but never assigned** after the trace became three rows, so
   the glint stopped sweeping and columns 1 and 2 were simply lit forever — a
   stationary smudge that is visible in the screenshot that prompted the
   redesign. Nobody spotted it by looking; it fell out of a mechanical audit
   that lists every identifier the awk program uses and every `-v` it is passed,
   and diffs the sets. That audit is now the first thing to run after any awk
   edit: it caught this and `sok` in the same pass.
2. **`sok` was used but never declared**, so the "scale over successful samples
   only" fix was silently inactive: the guard `sok >= 2` was comparing against
   an uninitialised zero and never fired. Same class as the shipped
   division-by-zero, same audit, same lesson — awk will not tell you.
3. **A scripted edit clobbered the file**: reassembling it from slices kept
   everything *after* the anchor and dropped the 250 lines before it. `bash -n`
   still passed, because what was left was valid shell. Recovered from a backup
   made minutes earlier. Any structural rewrite of this file needs a backup
   first and a `head -3` check after, not just a syntax check.
4. **The startup handshake owned the trace scale for the first thirty seconds**
   at `-i 0.5`, flattening a healthy 15ms baseline onto the bottom row. Exactly
   the "one outlier hides every bit of shape" failure that min/max scaling had,
   arriving through a new door. The fix keeps the sample in every statistic and
   excludes it only from the drawing scale.
5. **A background probe loop outlived the thing that started it**, and kept
   hitting a live endpoint for hours before anyone noticed. Anything that
   spawns a probe loop has to die with its parent — which is also the reason
   the teardown in section 4 tracks every pid explicitly instead of trusting
   SIGPIPE to arrive.

**The testing lesson from all of these, worth acting on before v0.4:** asserting
on the *escape sequences* proves nothing about what a user sees. Every one of
these bugs produced a stream that looked correct under `grep`-style checks — the
one-line-list bug survived several rounds of "is the region set? are frames
painted?" and was only caught when the user ran it. What found them in the end
was a ~40-line ANSI screen model (CUP / EL / ED / DECSTBM / LF-with-region) that
replays the output into a character grid, so the assertion becomes "row 11 is
blank" or "the list holds 14 lines". That model is kept as `tests/screen.py`; it
belongs in the `bats` suite in v0.4 and is a prerequisite for any further
display work.

**Portability, measured on this machine:** runs on stock macOS `/bin/bash` 3.2.57
and stock `/usr/bin/awk` (BWK awk 20200816) — no bash arrays, no gawk extensions,
no `strftime` (the timestamp comes from `date` in the shell loop). `fflush()` is
used and is present in BWK awk. **Untested on Linux** (gawk/mawk) — see §6.

## 5. Known limitations

- p95 is nearest-rank, not interpolated, and is withheld below 20 successful
  samples because that is where the rank stops excluding anything (see the bug
  records). A `--window` under 20 therefore never shows a p95.
- **Aggregates cover successes only, which means a failing endpoint has fewer
  samples behind its numbers than the `n` beside them.** `over N ok` states the
  denominator for exactly this reason. With no successes at all the percentiles
  render `—`.
- **A batch boundary costs a handshake**, once every `20 * WIN` samples. It is
  marked with `⇄`, counted in every statistic, and excluded only from the
  drawing scale. It can move `max`; it is arithmetically too rare to move p95
  except in the first `WIN` samples of a run, where the startup handshake is
  unavoidably in the window.
- **In reuse mode a sample is stamped at completion, not at start** — curl never
  reports a request start. The window span is a difference of like-for-like
  stamps so it stays correct, but `$2` is not comparable across a mode switch.
- The window span has 1ms resolution where `date +%N` exists (it does on this
  macOS) and 1s resolution where it does not, in which case the fresh-mode grid
  also degrades to interval-minus-elapsed pacing.
- **Reuse mode is unavailable on curl < 7.84** (no `--rate`). It silently falls
  back to fresh and says so in the header: `fresh · no --rate`.
- One request at a time, no concurrency. Not a load generator. Note one mode
  difference: curl fires a single back-to-back catch-up request after a
  mid-batch overrun, where the fresh-mode grid skips the missed slot. Never more
  than one in flight either way.
- One process per endpoint.
- The header and the list are sized once, from the terminal, at startup. A
  resize mid-run is not detected.
- Killing with SIGKILL leaves the run directory behind, as nothing can run on
  SIGKILL. SIGINT and SIGTERM both remove it.

## 6. Roadmap — what "usable by a lot of devs" actually requires

Ordered by what blocks adoption, not by what is interesting to build. The tier 0
work is done; it is listed because the reasoning is the useful part.

**v0.2 — the numbers must be right. DONE.** Three defects, each fatal to trust:
connection setup dominating the reported latency, a window that was not the
duration it claimed, and percentiles contaminated by failures. All measured, all
fixed, all recorded in section 4. Nothing else mattered until these did.

**v0.3 — table stakes for a CLI other people run. IN PROGRESS.**
- ~~`-H/--header` pass-through~~ **DONE in 0.3.0.** Repeatable, and passed to
  curl through a config file in the 0700 run directory rather than on its
  command line, so a credential is not copied into the argv of every request
  curl makes — in fresh mode that is one new process per interval.
  **The claim stops there, and the first version of this note overstated it:**
  an inline `-H` is still in *this script own* argv and nothing here can change
  that. Measured both ways against `ps`: with `-H @file` the token appears in no
  process argv at all; inline it appears in two. So `@file` is documented as the
  way to watch an authenticated endpoint without leaking to process listings,
  and the display only ever shows a count (`· 2 headers`), never a name or a
  value. ~~Still open from this bullet: `--head`, `--insecure`, `--resolve`~~ — **also
  done**, passed through the same config file, each verified against a real
  server rather than by checking the flag was written down: HEAD is asserted by
  a server that records the methods it saw, `--resolve` by pinning a
  `.invalid` host that can never resolve, and `--insecure` against a generated
  self-signed certificate. `--head` measures a different thing from a GET and
  the README says so; `--insecure` is rendered in yellow on the header, since
  not verifying a certificate qualifies every number underneath it.
- ~~Portability and CI~~ **IN PROGRESS.** A suite exists (`tests/`, 127
  assertions across cli, awk, locale, screen and e2e) and CI runs it on
  ubuntu-latest and macos-latest across mawk, gawk and BWK awk, with a
  comma-decimal locale installed so the locale regression has something to bite
  on. What that shook out is above: the locale bug, an unclamped geometry that
  would have handed mawk a sprintf overrun, and `--record` built on process
  substitution — unportable, unwaited (so recordings truncated, weakening the
  very harness CI depends on), and enough to make the file unparseable to a
  POSIX shell. Still open: busybox awk, and bash 5.x is only covered
  incidentally by whatever Ubuntu ships.
- ~~`--json`, a summary on exit, and a non-zero exit on a breached threshold~~
  **DONE.** With `-c/--count`, which the rest depends on: a gate cannot deliver
  a verdict on a run that never ends, so the thresholds refuse to start without
  it rather than exiting 0 on a run that never reached one. Gates judge the
  whole run rather than the last window, since a CI check asking "was this
  healthy for the duration" must not be decided by the contents of a buffer at
  an arbitrary moment. Run percentiles come from a reservoir of up to 10,000
  successful samples (algorithm R, fixed seed so a run is reproducible) because
  keeping every latency is unbounded — a day at one per second is 86,400 — and
  the summary states the sample size rather than implying exactness.
- `SIGWINCH` handling. A monitor that has to be restarted after a window resize
  reads as broken.
- Multiple URLs in one process.

**v0.4 — distribution**
- ~~A one-line install script~~ **DONE.** `install.sh`, POSIX sh because it runs
  before the bash the tool needs is known to be there, and it verifies what it
  downloaded is the script — shebang, version line, `bash -n` — before putting
  it on a PATH. A proxy error page installed as a program is a worse outcome
  than a failed install.
- ~~Homebrew~~ **PARTLY.** `Formula/pulsecheck.rb` is HEAD-only and installable
  by URL; a stable `url`/`sha256` block wants a tagged release, and
  `brew install AcevedoR/pulsecheck/pulsecheck` wants a second repository named
  `homebrew-pulsecheck`. Both are decisions rather than work.
- A man page.
- ~~A moving demo at the top of the README~~ **DONE**, though not with
  asciinema. `tools/svgcast.py` replays a `--record` capture into an animated
  SVG: the capture format was already ours, and asciinema plus agg would have
  been two dependencies for anyone regenerating it. One shared CSS keyframe with
  a per-frame negative delay rather than one keyframe block per frame, which is
  what brings a 20-second, 72-frame demo down to something a README can carry.
  It has its own small terminal model, separate from the one in `tests/`,
  because that one deliberately ignores colour and a demo cannot.

**v1.0 — the frozen CLI surface**

The point of freezing it now is that a Go rewrite (section 8) must be able to
implement it unchanged, so nobody has to relearn the tool:

```
pulsecheck [options] <url>...
  -w, --window N        rolling window, in samples
  -i, --interval S      seconds between requests
  -t, --timeout S       per-request timeout
  -e, --expect SPEC     success predicate: 200, 2xx, 200,204, 200-299
  -H, --header H        request header, repeatable
      --fresh           a new connection per request
      --json            one JSON object per sample on stdout
      --summary         totals and percentiles on exit
      --fail-over MS    exit non-zero if p95 exceeds MS
      --fail-err PCT    exit non-zero if the error rate exceeds PCT
  -p, --plain           one self-contained line per sample
      --color WHEN      auto, always, never
      --no-wave         drop the heartbeat trace
      --diag            print terminal detection and exit
  -h, --help / -V, --version
```

**v1.0 acceptance criteria** — all of these, or it is still 0.x:
1. CI green on macOS and Linux, across bash 3.2/5.x and BWK/gawk/mawk.
2. The statistics proven against synthetic streams with hand-computed answers,
   including every degenerate window (all-fail, one-success, first sample).
3. The display proven through the screen model at six geometries, including the
   fallbacks to no-trace and to the plain stream.
4. Reported latency within a few percent of an independent measurement (curl
   with `%{num_connects}`) in both connection modes.
5. Sample cadence within a few percent of `--interval`, including against an
   endpoint slower than the interval.
6. Teardown verified for SIGINT and SIGTERM: no orphans, terminal restored.
7. `-H` supported, so an authenticated endpoint can actually be watched.
8. Installable with one command, and a GIF in the README showing it running.

## 7. Non-goals

- **Not a load generator.** No concurrency, no rate ramping. Use vegeta, oha, k6.
- **Not a monitoring system.** No storage, no history, no alert routing.
- **Not a general HTTP client.** No auth flows, no request bodies, no scripting.
  If a probe needs that, it's a different tool.

## 8. Open questions

1. **Rewrite in Go? Decided for now: not yet, but design as if.** bash+awk is
   both the charm and the ceiling. v0.2 is the evidence for both halves: reuse
   needed a `-K` config file, a stderr-only write-out, a per-day rate and a fifo
   with four tracked pids — all of which a persistent HTTP client gives away for
   free, in maybe 150 lines of Go, with a static binary, `brew`/`scoop`/`go
   install`, no awk-variant matrix and Windows support. Against that: the
   current version has no dependency beyond `curl`, which is why it exists.
   The decision: fix the numbers in bash (done), ship 0.2 to a small audience,
   rewrite only on traction — and freeze the CLI surface now (section 6) so the
   rewrite is drop-in and nobody has to relearn it. `pulsecheck` is free on
   crates.io and npm either way.
2. Is the rolling window the headline, or is it too subtle to explain? It's the
   only reason this exists rather than `vegeta report -every=1s`, so the README
   and any announcement should lead with it.
3. Publish at all, or keep it as a personal tool? Nothing here is committed yet.

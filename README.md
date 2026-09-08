# pulsecheck

Watch an HTTP endpoint's pulse: live per-request latency, plus a **rolling** p95
and error rate over the last N samples.

On a terminal the display is split: a fixed header holds the target, the probe
settings, the rolling aggregates and a heartbeat trace of the window, with the
requests listed underneath.

```
pulsecheck 0.2.0 https://example.com · reuse
expect 200 · every 0.5s · timeout 5s · window 29/60 samples / 14.0s
last 46.4ms    p50 50.1ms    p95 87.2ms    max 195.5ms   over 29 ok
err  0.0%      (0/29 bad) n 29/60 elapsed 00:00:13
█  ▄ █   ▃ ▂ █       ▁                          ┤ 80.2ms+
█ ▁█▁█▅  █▂███    ▃▆ █    ▂                     ┤
█▁█████▅▃█████▅▄▇▁██▄█▁▄▄▂█▆▇                   ┤ 33.3ms-
─────────────────────────────────────────────────────────
19:14:58   200    54.5ms  ██████████
19:14:58   200    60.9ms  █████████████
19:14:59   200    40.6ms  █████
19:14:59   200    67.6ms  █████████████████
19:15:00   200    35.1ms  █
```

That is a real run, not a mockup: `example.com` genuinely wobbles between 33ms
and 87ms, and the trace shows it. The axis on the right gives the band the shape
is drawn against, with `+`/`-` marking samples that clipped outside it.

A row that had to open a new connection is marked `⇄` and is visibly slower —
see below.

With `--plain`, or whenever stdout is not a terminal, each line carries its own
aggregates instead so the stream stays greppable:

```
19:14:58  HTTP 200  54.5ms   │ p95 87.2ms    err   0.0%  n=14
19:14:59  HTTP 200  40.6ms   │ p95 87.2ms    err   0.0%  n=15
19:14:59  HTTP 000  0.2ms    │ p95 87.2ms    err   6.3%  n=16
```

## Why

`curl` in a `while` loop tells you about one request at a time and aggregates
nothing. Load generators like [vegeta](https://github.com/tsenart/vegeta) and
[oha](https://github.com/hatoo/oha) aggregate beautifully but report percentiles
**cumulatively since start** — one three-second stall in hour one pins your p95
for the rest of the day.

pulsecheck keeps a fixed-size circular buffer instead, so a stall ages out of the
window and the numbers describe *now*. It is one bash script and one awk program,
with no dependency beyond `curl`.

## Install

```sh
curl -fsSLo /usr/local/bin/pulsecheck \
  https://raw.githubusercontent.com/AcevedoR/pulsecheck/main/pulsecheck
chmod +x /usr/local/bin/pulsecheck
```

## Usage

```
pulsecheck [options] <url>

  -w, --window N     rolling window, in samples (default: 60)
  -i, --interval S   seconds between requests (default: 1)
  -t, --timeout S    per-request timeout, in seconds (default: 5)
  -e, --expect CODE  HTTP status treated as success (default: 200)
  -p, --plain        one self-contained line per sample, no fixed header
      --fresh        a new connection per request (default: reuse one)
      --color WHEN   auto, always or never (default: auto; NO_COLOR honoured)
      --no-wave      drop the animated heartbeat trace from the header
      --diag         print what the display detects about this terminal, exit
      --record F     also write the raw display stream to F, for replay
  -h, --help         show this help
  -V, --version      show version
```

```sh
pulsecheck https://api.example.com/health
pulsecheck -w 300 https://api.example.com/health      # 5-minute window
pulsecheck -e 401 -i 0.5 https://api.example.com/me   # expect 401, 2 req/s
pulsecheck -p https://api.example.com | tee probe.log # pipe-friendly stream
```

## What it measures

By default **one connection is reused for many requests**, which is what a real
client does. A fresh TCP+TLS handshake per request costs more than many
endpoints do — measured on one API:

| | dns | tcp | tls | total |
|---|---|---|---|---|
| new connection each request (`--fresh`) | 2.4ms | 13.7ms | 30.4ms | **51ms** |
| reused connection (default) | ~0 | 0 | 0 | **19ms** |

So on that endpoint about two thirds of what a naive probe calls "latency" is
setup it pays and a real client does not. Both numbers are legitimate — they answer different
questions — so the header always names the active mode, and `--fresh` is there
when cold-connect cost *is* the question.

One connection covers `20 x --window` requests, then reconnects; that row is
marked `⇄`. It is counted in every statistic (it really happened) but excluded
from the drawing scale, because one handshake would otherwise flatten the shape
of everything around it.

If the server closes every connection — `Connection: close`, which some servers
and most trivial dev servers do — the header says `reuse · server closes`, so
you learn you asked for reuse and did not get it.

Sampling is paced against an absolute schedule, so the period is `--interval`
regardless of how slow the endpoint is. The header prints the window's real time
span (`window 32/60 samples / 15.6s`), because "60 samples" on its own implies a
duration it may not have. If a request overruns its slot, the missed slots are
skipped rather than queued — a recovering endpoint never gets a burst.

## Reading the output

**The header** describes the trailing window. `last` is the most recent request;
`p50`/`p95`/`max` cover the **successful** requests in the window and `over N ok`
says how many that is; `err` covers **every** request; `n` shows how full the
window is; `elapsed` is the run's wall time. It repaints in place on every
sample.

Latency aggregates exclude failures deliberately. A refused connection returns
in microseconds, so mixing failures in makes p95 *improve* as an endpoint goes
down. With no successful request in the window at all, the three percentiles
show `—` rather than a number derived from failures.

**The trace** is the window itself, one column per request, oldest on the left,
three rows tall for 24 levels of vertical resolution. It **auto-scales between
the 5th and 95th percentile of the window**, and the axis on the right prints
that band — `59.4ms+` means samples clipped above it, `48.6ms-` below. Scaling
that way is what makes it a waveform rather than a straight line: an endpoint
sitting at 51-58ms has real structure, and one 320ms spike or one
microsecond-fast refusal would flatten it against min/max scaling. A failed
request is drawn at its measured height in red, so a refusal that returned
instantly is a notch at the floor and a slow 503 is a tall red column.

A glint sweeps left to right across the trace once per interval and the newest
column lands lit — so the display is visibly alive, and a stalled probe is
obvious because the pulse stops. `--no-wave` drops the three rows and the ~10fps
repaint that drives them.

**The list** below it is one line per request: time, status, latency, and a bar
on the same p05-p95 scale as the trace. The status is dimmed while it matches
`--expect`, so only failures catch the eye.

Colour follows latency: green < 100ms, yellow < 300ms, orange < 1s, red beyond.
A request whose status is not `--expect` is red regardless of how fast it was.
`NO_COLOR` is honoured, and `--color never|always|auto` overrides it.

Colour and the split display are disabled automatically when stdout is not a
terminal, so piping to a file or `grep` gives clean text.

A request that times out or cannot connect is reported as `HTTP 000` and counted
as an error.

## Caveats

- **p95 is nearest-rank, not interpolated.** With `-w 20` the "p95" is just the
  worst sample in the window. Use `-w 100` or more for the number to mean much.
- **A batch boundary costs a handshake**, once every `20 x --window` requests.
  Marked `⇄`, counted everywhere, excluded only from the drawing scale. It can
  move `max`; it is too rare to move p95 except in the first window of a run,
  where the startup handshake is unavoidably present.
- **Reuse needs curl 7.84+** (for `--rate`). Older curl falls back to a new
  connection per request and the header says `fresh · no --rate`.
- **Not tested on Linux yet** — only macOS `/bin/bash` 3.2 with BWK awk. gawk,
  mawk and busybox awk are unverified.
- **The animation costs a little.** The trace is driven by a 10fps ticker, which
  measured at ~0.06s of CPU over 8 seconds (under 1% of one core) and ~2KB/s to
  the terminal. Over ssh on a bad link, or on battery, use `--no-wave`.
- **The header is sized once, at startup.** Resizing the terminal mid-run leaves
  the rule and the scroll region at the old width and height; restart to resize.
- **The split display needs at least 72 columns and 10 rows**; the trace needs
  13 rows and is dropped below that. Under either limit it falls back to the
  plain one-line-per-sample stream.
- **Not a load generator.** One request at a time, no concurrency. If you want to
  apply pressure and measure under it, use vegeta, oha, or k6.

## Debugging the display

If the split display misbehaves on a given terminal:

```sh
pulsecheck --diag                      # what size it detects, and from where
pulsecheck --record /tmp/p.raw <url>   # tee the exact bytes sent to the screen
tests/replay.py /tmp/p.raw 59 200      # render that stream back into a grid
```

`--diag` reports the DSR (`ESC[6n`) reply, `stty size`, `tput`, and which of
them it chose. A recording plus the geometry from `--diag` is enough to
reproduce what a terminal showed without having that terminal.

## License

MIT

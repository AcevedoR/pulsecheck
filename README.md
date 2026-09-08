# pulsecheck

Watch an HTTP endpoint's pulse: live per-request latency, plus a **rolling** p95
and error rate over the last N samples.

<img src="docs/demo.svg" alt="pulsecheck watching an endpoint: a fixed header with rolling p50, p95, max and error rate over a three-row heartbeat trace, above a scrolling list of requests" width="100%">

*A real run against `example.com`, replayed from a `--record` capture — not a mockup.*

On a terminal the display splits into a fixed header — target, probe settings,
rolling aggregates and a heartbeat trace of the window — with the requests
listed underneath.

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
and 87ms, and the trace shows it. The trace is the window itself, one column per
request, oldest on the left, auto-scaled between the window's 5th and 95th
percentile — the axis on the right prints that band, with `+`/`-` marking
samples that clipped outside it. Latency aggregates cover **successful**
requests only, because a refused connection returns in microseconds and would
otherwise make p95 *improve* as an endpoint goes down. Colour follows latency
(green < 100ms, yellow < 300ms, orange < 1s, red beyond) and a status that is
not `--expect` is red however fast it was. A row that had to open a new
connection is marked `⇄`.

With `--plain`, or whenever stdout is not a terminal, each line carries its own
aggregates instead so the stream stays greppable:

```
19:14:58  HTTP 200  54.5ms   │ p95 87.2ms    err   0.0%  n=14
19:14:59  HTTP 200  40.6ms   │ p95 87.2ms    err   0.0%  n=15
19:14:59  HTTP 000  0.2ms    │ p95 87.2ms    err   6.3%  n=16
```

## Why

Load generators like [vegeta](https://github.com/tsenart/vegeta) and
[oha](https://github.com/hatoo/oha) aggregate beautifully but report percentiles
**cumulatively since start** — one three-second stall in hour one pins your p95
for the rest of the day. pulsecheck keeps a fixed-size circular buffer instead,
so a stall ages out of the window and the numbers describe *now*. It is one bash
script and one awk program, with no dependency beyond `curl`.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/AcevedoR/pulsecheck/main/install.sh | sh
```

Somewhere that needs no `sudo`:

```sh
curl -fsSL https://raw.githubusercontent.com/AcevedoR/pulsecheck/main/install.sh \
  | PREFIX=~/.local/bin sh
```

The installer checks that what it downloaded is actually the script — a shebang,
a version line, and `bash -n` — before putting it on your PATH, because a proxy
error page installed as a program is a worse outcome than a failed install.

With Homebrew:

```sh
brew install --HEAD https://raw.githubusercontent.com/AcevedoR/pulsecheck/main/Formula/pulsecheck.rb
```

Or just take the file: it is one script with no dependency beyond `curl` and
`awk`, both of which you already have.

```sh
curl -fsSLo ~/bin/pulsecheck \
  https://raw.githubusercontent.com/AcevedoR/pulsecheck/main/pulsecheck
chmod +x ~/bin/pulsecheck
```

## Usage

```
pulsecheck [options] <url>

  -w, --window N     rolling window, in samples (default: 60)
  -i, --interval S   seconds between requests (default: 1)
  -t, --timeout S    per-request timeout, in seconds (default: 5)
  -e, --expect CODE  HTTP status treated as success (default: 200)
  -H, --header H     request header, repeatable ("Name: value")
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

## Authenticated endpoints

`-H` passes a header through to curl and is repeatable:

```sh
pulsecheck -H "Authorization: Bearer $TOKEN" https://api.example.com/me
pulsecheck -H "X-Api-Key: k" -H "Accept: application/json" https://api.example.com/health
```

Headers reach curl through a config file in a private (0700) temp directory
rather than its command line, so a credential is not copied into the argv of
every request curl makes — in `--fresh` mode that is one new process per
interval. **Your own invocation is still visible in `ps`**, though, so for a
real secret put the header in a file and use curl's `@` form:

```sh
umask 077; printf 'Authorization: Bearer %s\n' "$TOKEN" > auth.txt
pulsecheck -H @auth.txt https://api.example.com/me
```

Verified both ways: with `@auth.txt` the token appears in no process's argv;
passed inline it appears in pulsecheck's own. Header values are never printed —
the display shows only a count (`· 2 headers`).

## What it measures

One connection is reused across requests, like a real client — on one API that
is 19ms against 51ms with `--fresh`, i.e. two thirds of a naive probe's
"latency" is setup a real client never pays. Both are legitimate answers to
different questions, so the header always names the active mode (and says
`reuse · server closes` when the server refuses to keep it open). Sampling
follows an absolute schedule, so the period is `--interval` however slow the
endpoint is; overrun slots are skipped, never queued.

## Caveats

- **p95 is nearest-rank, not interpolated, and is withheld until it means
  something.** Nearest rank `ceil(0.95*m)` equals `m` for any window under 20
  samples, so below that "p95" would just be the maximum wearing a percentile
  label — and since every run opens on a connection handshake, that maximum is
  the handshake. It shows `—` until 20 *successful* samples are in the window;
  `max` is on the same row meanwhile. A `-w` under 20 therefore never reports a
  p95 at all, which is the honest outcome.
- **A batch boundary costs a handshake**, once every `20 x --window` requests.
  Marked `⇄`, counted everywhere, excluded only from the drawing scale. It can
  move `max`, rarely p95.
- **Reuse needs curl 7.84+** (for `--rate`). Older curl falls back to a new
  connection per request and the header says `fresh · no --rate`.
- **Not tested on Linux yet** — only macOS `/bin/bash` 3.2 with BWK awk.
- **The animation costs a little** — a 10fps ticker, ~1% of one core and ~2KB/s
  to the terminal. Over ssh on a bad link, or on battery, use `--no-wave`.
- **The header is sized once, at startup.** Restart to resize the terminal.
- **The split display needs 72 columns and 10 rows**; the trace needs 13 rows
  and is dropped below that. Under either limit it falls back to the plain
  one-line-per-sample stream.
- **Not a load generator.** One request at a time, no concurrency.

## Debugging the display

```sh
pulsecheck --diag                      # what size it detects, and from where
pulsecheck --record /tmp/p.raw <url>   # tee the exact bytes sent to the screen
tests/replay.py /tmp/p.raw 59 200      # render that stream back into a grid
```

A recording plus the geometry from `--diag` (the DSR reply, `stty size`, `tput`,
and which it chose) reproduces what a terminal showed without having it.

## Tests

```sh
tests/run.sh                # everything
tests/run.sh cli awk        # one or more suites by name
```

Four suites, no framework and nothing to install — the same bash, awk, curl and
python3 the tool itself already needs:

| suite | what it covers |
| --- | --- |
| `cli` | the command-line contract: exit codes and messages for every bad flag, and `to_ms()` |
| `awk` | the pure functions inside the awk program — `pct`, `wscale`, `wlevel`, `col`, `fmt` |
| `screen` | the ANSI screen model in `tests/screen.py` that the display assertions are built on |
| `e2e` | a plain-mode run against a throwaway local HTTP server: sample lines, `--expect`, a dead port |

The awk suite lifts each function out of the script with `tests/extract.awk` and
calls it from a driver, so the scale and percentile logic can be checked without
a terminal, a network or a clock in the loop. CI runs all four on Linux and
macOS, since bash 3.2 and BWK awk are where portability actually gets decided.

## License

MIT

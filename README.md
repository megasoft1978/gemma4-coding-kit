# gemma4-coding-kit

One command that gets Gemma-4-26B-A4B running locally as a coding assistant, correctly configured, on any
16GB Apple Silicon Mac. No cloud API, no account, nothing sent anywhere once the model is downloaded.

```
curl -fsSL https://raw.githubusercontent.com/megasoft1978/gemma4-coding-kit/main/setup.sh | bash
```

That's it. It checks your hardware, downloads the model (once), starts the server, configures the coding
agent, and drops you into an interactive session.

## What this actually is

This is **not** a new AI agent. It's a configuration and prompt package on top of
[`pi`](https://github.com/earendil-works/pi), an existing local-model coding agent. Everything this kit does —
the server flags, the context-window settings, the prompt guidance — comes from a measurement session on a
16GB Mac mini M1, not from guessing. Every number below is either measured directly or explicitly marked as an
estimate.

Close prior art worth knowing about, since none of this claims to be first: [Animus
Ferric](https://github.com/crussella0129/Animus_Ferric) gates agent autonomy by a model's measured capability
tier; [Claudette](https://github.com/mrdushidush/claudette) ships the best published local-model coding
benchmark (Q56); [Kestrel](https://github.com/FPSZ/kestrel) argues the same bytes-and-context framing this kit
is built on. None targets Gemma-4-26B-A4B specifically, and the wider ecosystem generally assumes this model
needs 24GB+ (running it at Q4_K_M, ~17-18GB weights). This kit runs it at a smaller quant that was measured to
still hold real quality at 16GB — that's the actual gap it fills.

## What one run does

1. **Checks your hardware.** Apple Silicon + 16GB required. On an M1, the speed number below is measured. On
   anything else (M2/M3/M4), it's an estimate scaled from that chip's published memory bandwidth relative to
   M1's — clearly labeled as such, never presented as a measurement.
2. **Checks for `llama.cpp` and `pi`.** Asks before installing either one — never silently installs software.
3. **Downloads the model** (`unsloth/gemma-4-26B-A4B-it-GGUF`, the `UD-IQ2_M` quant, ~9.3GB), verified by
   exact byte size, not just a successful download. An interrupted download resumes where it stopped on the
   next run rather than starting over.
4. **Starts `llama-server`** with every flag this measured as worth having, and a real smoke-test (not just a
   health check) before trusting the boot.
5. **Configures `pi`** with the context window and token settings that avoid a real failure mode this session
   hit directly (see below).
6. **Writes a calibrated `AGENTS.md`** into your current directory — instructions for how to actually get good
   results from this specific model, loaded automatically by `pi`.
7. **Starts an interactive `pi` session**, ready to use.

## The numbers behind each setting

| Setting | Value | Why |
|---|---|---|
| Model | `UD-IQ2_M` quant | Measured at 90% quality on a symptom-report coding suite at this size — not the smallest quant available, the one actually tested. |
| `--spec-type ngram-simple` | on | 1.42× decode speed on the repair suite (24.9 vs 17.5 tok/s). Not perfectly lossless: one bug in 36 flipped (see "Levers measured" below). |
| Prompt prefix caching | automatic, no flag | 100× faster time-to-first-token on repeated context (1262-token prompt: 7.4s cold → 0.07s on repeat, measured). An earlier version of this kit credited `--cache-reuse 256` for this; llama-server actually logs that flag as *disabled* on Gemma 4's sliding-window context — the win was the built-in prefix cache all along, so the flag is gone. |
| `--reasoning off` | on, not optional | With thinking enabled, this model produced 46,615 characters of internal reasoning and a **completely empty final answer**, even at 24k context and a 16k output ceiling. It doesn't converge on coding tasks. |
| Context window | 24576 | Validated boot + smoke-test size on this model. |
| `pi` `maxTokens` | 3072 | The naive default (12000) halves the usable input budget for no benefit. |
| `pi` compaction `reserveTokens`/`keepRecentTokens` | 3072 / 6000 | The library defaults (16384 / 20000) exceed a 24576-token window entirely, causing endless compaction — reproduced directly as a **143-round loop that edited nothing.** |

## How it performs on real React/Node/TypeScript bugs

The numbers above aren't from a generic benchmark. They come from a purpose-built suite of 7 realistic
multi-file coding-repair projects — React + Express + TypeScript, one with a WebSocket server — each with
several **interacting** bugs described the way a real user would report them (by symptom, never by naming the
cause). Three examples, taken directly from the suite, to make this concrete rather than abstract:

- **`items-search`** (React + Express + TypeScript) — the results list re-sorts correctly the first time, then
  scrambles on every sort after that. Root cause: the sort handler mutates the shared in-memory data store
  in place (`ITEMS.sort(...)`) instead of sorting a copy, so every other consumer of that store sees the
  mutation too.
- **`cart-checkout`** (React + Express + TypeScript) — a returning customer's discount code makes the total
  *higher* than list price on some carts. Root cause: tax is calculated before the discount is applied instead
  of after, and the two orderings only produce different rounded totals for specific subtotal/discount
  combinations — the kind of bug that survives casual manual testing.
- **`realtime-sync`** (React + Express + `ws` + TypeScript) — a client that just sent an edit sees its own
  change applied twice. Root cause: the WebSocket broadcast loop sends to every connected client including the
  one that originated the message, instead of excluding the sender.

Grading is by **real execution**, not text matching, wherever the bug is pure logic (an executable oracle
imports the fixed code and calls it with real inputs) — the same instrument used to produce every number here.

**Measured on a Mac mini M1, 16GB, this exact kit's configuration:**

| Mode | What it means | Score |
|---|---|---|
| Unaided discovery | No bug report at all — find every defect yourself | 13/24 (54%) |
| Symptom report | A user-style bug report, no cause named | **27/30 (90%)** |
| Precise instructions | Told exactly which file and which defect | **29/30 (97%)** |
| Discovery + defect checklist | Unaided, but handed a checklist of defect categories | 17/24 (71%) |

The gap between the first two rows is the finding that matters most: this model is far better at fixing a bug
you can describe than at finding one you can't. That's exactly why the included `AGENTS.md` pushes toward
"here's what's wrong" requests over "find what's wrong" ones — see below.

These four scores cover 6 of the suite's 7 scenarios — `api-versioning` is excluded from quality comparisons
because 3 of its 6 "bugs" are actually a missing feature (add a v2 endpoint), not a defect; every model tested
scores near-ceiling on it, so it doesn't discriminate quality. It's still part of the benchmark suite shipped in
this repo (`benchmarks/`) for functional coverage, just not part of the numbers above.

**Decode speed on the same suite, extended to other Apple Silicon chips the same way as the setup-time
estimate** (scaled from each chip's published memory bandwidth relative to the M1's measured number — real
math, not a real measurement on anything but M1):

| Chip | Bandwidth (GB/s, spec) | tokens/sec |
|---|---|---|
| M1 | 68 | **18.6 — measured** |
| M2 | 100 | ~27.4 — estimated |
| M2 Pro | 200 | ~54.7 — estimated |
| M3 | 100 | ~27.4 — estimated |
| M3 Pro | 150 | ~41.0 — estimated |
| M1 Max / M2 Max / M3 Max | 400 | ~109.4 — estimated |
| M4 | 120 | ~32.8 — estimated |
| M4 Pro | 273 | ~74.7 — estimated |
| M4 Max | 546 | ~149.3 — estimated |

Run `setup.sh --doctor` any time to check an existing install against this exact configuration. If you're on
any chip above other than M1, `setup.sh --report-speed` measures your real number (two timed completions
against your already-running server; the second, past the cold mmap-page-in cost, is the one that matters) and
prints a pre-filled issue link — nothing is sent automatically, and it prints the number in the terminal first
either way. Turning an accepted report into an updated row is a one-line diff on this end.

## Levers measured, and why the defaults are what they are

Every server flag above was re-tested with `setup.sh --benchmark all` (7 scenarios, 36 bugs, temperature 0)
against the same server binary, one change at a time. (The sweep also caught one flag that did nothing — see
the prefix-caching row above.) Generation speed is llama-server's own `predicted_per_second`
(prompt processing excluded); memory is macOS `footprint` (dirty pages — the number that actually competes with
your other apps; the 9.3GB of model weights are clean file-backed pages on top of it).

| Config | Bugs fixed | Generation tok/s | Draft acceptance | Verdict |
|---|---|---|---|---|
| no speculative decoding | 34/36 | 17.5 | — | reference |
| **`ngram-simple` (default)** | **33/36** | **24.9** | 47% | **fastest; kept** |
| `ngram-simple`, draft length 64 | 33/36 | 23.8 | 42% | no gain |
| `ngram-mod` | 34/36 | 23.0 | 49% | 8% slower than default |
| `ngram-map-k4v` | 34/36 | 19.3 | 45% | slow |
| default + KV cache q8_0 | 34/36 | 19.7 | 48% | −20% speed, −39% peak memory |

Three things worth knowing from this table:

- **Speculative decoding is where the speed comes from, and it's workload-dependent.** Draft acceptance runs
  50–64% when the model is *repairing* files it was shown (it copies most of them back) and 16–27% when it's
  writing *new* code (`notify-channel`, `realtime-sync`). Expect ~25 tok/s on fixes and ~18 on fresh code; the
  18.6 headline number above is the conservative one.
- **It is not perfectly lossless.** At temperature 0 the same prompt gave `realtime-sync` 5/6 without speculation
  and 4/6 with it — different batch shapes change floating-point rounding, and one near-tie flipped. One bug in
  36 is inside the suite's noise floor, but it's real and deterministic, so the "identical output" claim you may
  have seen elsewhere is not true in general. The default still wins on quality×speed (22.8 vs 21.7 for
  `ngram-mod`, 16.5 with no speculation).
- **Memory: the KV cache is the part that grows.** Dirty footprint is ~0.9GB idle, ~1.4GB after one long
  scenario, and reaches ~4.8GB across a long session as more of the 24k-token cache gets touched. With the
  9.3GB of weights that is ~14GB on a 16GB machine — enough that heavy apps alongside it will cause paging.
  `-ctk q8_0 -ctv q8_0` cuts the KV cache in half (peak 0.86GB vs 1.41GB on the same scenario) at a 20% speed
  cost, with no measurable quality change. The kit ships the fast setting; if you're routinely memory-squeezed,
  add those two flags to `SERVER_FLAGS` in `setup.sh` — that's the one edit, and `--doctor` will then report
  the flag difference as expected. `-ub 256` was also tried: −7% memory for −3% speed, not worth a default.

## Why the `AGENTS.md` matters as much as the config

This model was measured — independently, in [AgentFloor](https://arxiv.org/abs/2605.00334), and reproduced
directly against this exact setup — at a sharp capability cliff: **96% success on a single tool call, 72% on a
two-step chain, 0% on open-ended "find every bug in this project" requests.** One such request made 143, then
247 tool-call rounds and edited nothing. The included `AGENTS.md` tells both the model and the person using it
how to work with that constraint — scope requests to a named file or symptom, prefer whole-file rewrites, use
a defect-class checklist when unaided bug-finding is unavoidable (the single largest quality lever measured on
this model: +17 points, 54%→71%, on unaided discovery).

## Honesty

- **Speed is measured only on an M1 Mac mini.** On other Apple Silicon chips it's an estimate scaled from
  published memory bandwidth — real, but not independently verified.
- **Capacity behavior (what fits in memory, what runs out) is expected to hold across the M-series at 16GB**,
  because it's driven by a memory-proportional Metal working-set limit rather than chip generation. This is
  reasoning, not a measurement on anything but M1.
- If you want the full research behind these numbers — the audit that found the pattern-based test suite this
  session used was wrong on over half its checks before hardening, the tensor-offload pilot that closed a
  promising-looking capacity idea, the harness comparisons — it lives in a separate research repository. This
  kit is deliberately the small, practical slice of that work.

## Other commands

Passing a flag through a pipe needs `bash -s --` (otherwise bash reads the flag itself, not the script):

```
curl -fsSL <raw-url>/setup.sh | bash -s -- --doctor         # diagnose an existing install, read-only
curl -fsSL <raw-url>/setup.sh | bash -s -- --config-only     # rewrite pi's config + AGENTS.md only
curl -fsSL <raw-url>/setup.sh | bash -s -- --start-only      # (re)start the server with the validated flags
curl -fsSL <raw-url>/setup.sh | bash -s -- --force-download  # re-download the model even if one is present
curl -fsSL <raw-url>/setup.sh | bash -s -- --check            # compare your install against the latest release
curl -fsSL <raw-url>/setup.sh | bash -s -- --upgrade           # reapply the current config + restart the server
curl -fsSL <raw-url>/setup.sh | bash -s -- --report-speed      # measure real tokens/sec on a non-M1 chip
```

Two modifiers: `--no-exec` does the whole setup but doesn't start the interactive `pi` session at the end, and
`--yes` answers yes to every prompt — **including "install `llama.cpp` / `pi` now?"** — so it's explicit consent
for a fully unattended install, not a shortcut to use casually.

`--check` fetches [`VERSION`](VERSION) (a small staleness beacon, never sourced or executed, never a source of
values this script acts on) and reports three independent signals: whether this copy of `setup.sh` itself is
behind the latest release, whether a different model is now recommended, and whether your installed config
matches what this script would write today. No network access is treated as "up to date," never as a failure.
`--upgrade` re-applies the current script's config (restarting the server, since a flag change needs one) and
offers to delete an old model file if the recommended one changed since your last install.

To remove everything this kit installed, see [`uninstall.sh`](uninstall.sh) — same curl-pipe pattern, with
`--dry-run`, `--purge-model`, and `--all` (also reverses `llama.cpp`/`pi` installs, but only if this kit
installed them):

```
curl -fsSL <raw-url>/uninstall.sh | bash -s -- --dry-run
curl -fsSL <raw-url>/uninstall.sh | bash
```

`--doctor` is the one to reach for first if something's wrong — it checks hardware, prerequisites, the model
file, the running server (including whether its actual flags still match this kit's validated set), and both
of `pi`'s config files, and points at the specific command above that fixes whatever it finds.

`--benchmark` reproduces the results table above on your own hardware — it's the one command that needs a real
git clone rather than the curl-pipe install, since the scenario data is too large to embed in a single script:

```
git clone https://github.com/megasoft1978/gemma4-coding-kit && cd gemma4-coding-kit
./setup.sh --start-only        # start the server first -- --benchmark never boots one itself
./setup.sh --benchmark          # all 7 scenarios
./setup.sh --benchmark cart-checkout   # or just one
```

It sends each scenario's symptom-mode prompt to your already-running server, grades the response the same way
this README's table was produced (pattern rules plus real execution for the 5 executable-oracle scenarios),
and prints a per-scenario and aggregate score. Your numbers won't match the table exactly — temperature-0
determinism only guarantees a given server build reproduces itself, not that it reproduces another session's
tokens — but they should land in the same range.

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4), 16GB unified memory or more
- ~10GB free disk space for the model
- [Homebrew](https://brew.sh) (to install `llama.cpp` if you don't have it)
- [Node.js](https://nodejs.org) (to install `pi` if you don't have it)

## Manual setup

If you'd rather not pipe a script into `bash`, read `setup.sh` first — it's a single self-contained file with
no hidden steps, and every command it runs is visible in it.

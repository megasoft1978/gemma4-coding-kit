<p align="center"><img src="assets/logo.png" width="140" alt="gemma4-coding-kit logo"></p>

# gemma4-coding-kit

**A real 26B coding model, on a 16GB Mac, in one command.**

```
curl -fsSL https://raw.githubusercontent.com/megasoft1978/gemma4-coding-kit/main/setup.sh | bash
```

Checks your hardware, downloads Gemma-4-26B-A4B (once), starts a correctly-tuned `llama-server`, configures the
[`pi`](https://github.com/earendil-works/pi) coding agent, and drops you into a session. No cloud API, no
account, nothing sent anywhere once the model's on disk.

## Why this exists

The wider ecosystem assumes this model needs 24GB+ (Q4_K_M, ~17-18GB). It doesn't — a smaller quant holds real
quality at 16GB, and every setting here (server flags, context window, prompt guidance) comes from measuring
that quant on a Mac mini M1, not from guessing. That's the actual gap this fills: not a new agent, just a
config and prompt package on top of `pi`, built from numbers.

Related prior art, since none of this claims to be first: [Animus
Ferric](https://github.com/crussella0129/Animus_Ferric) (capability-tiered agent autonomy), [Claudette](https://github.com/mrdushidush/claudette)
(the Q56 local-coding benchmark), [Kestrel](https://github.com/FPSZ/kestrel) (the same bytes-and-context framing).
None targets this model specifically at this footprint.

## What one run does

1. Checks Apple Silicon + 16GB. Speed is measured on M1; other chips get an estimate scaled from published
   memory bandwidth, clearly labeled as such.
2. Asks before installing `llama.cpp` or `pi` — never silently.
3. Downloads the model (`unsloth/gemma-4-26B-A4B-it-GGUF`, `UD-IQ2_M`, ~9.3GB), verified by exact byte size.
   Resumes an interrupted download instead of restarting it.
4. Starts `llama-server` with every flag measured worth having, then a real smoke-test before trusting the boot.
5. Configures `pi`'s context window and token budget to dodge a failure mode this session hit directly (below).
6. Writes a calibrated `AGENTS.md` — how to actually get good results from this specific model.
7. Drops you into an interactive `pi` session.

## The config, and why

| Setting | Value | Why |
|---|---|---|
| Model | `UD-IQ2_M` | 90% quality on a symptom-report coding suite at this size — measured, not the smallest available. |
| `--spec-type ngram-simple` | on | 1.42× decode speed (24.9 vs 17.5 tok/s). Not perfectly lossless — one bug in 36 flips (see below). |
| `--ctx-checkpoints 0 --cache-ram 0` | on | Cuts peak memory 4.87GB → **1.02GB** over a long session, same speed, same score. These two llama-server defaults, not the KV cache, were what grew memory — KV itself is a fixed 780MB here. |
| Prompt prefix caching | automatic | 100× faster repeat prompts (7.4s cold → 0.07s). Built into llama-server — no flag needed. |
| `--reasoning off` | on, not optional | With thinking on, this model burned 46,615 characters of reasoning and returned an **empty answer**. It doesn't converge on coding tasks. |
| Context window | 24576 | Validated boot + smoke-test size. |
| `pi` `maxTokens` | 3072 | The library default (12000) halves your usable input for no benefit. |
| `pi` compaction reserve/keep | 3072 / 6000 | Library defaults exceed a 24576-token window outright — reproduced directly as a **143-round loop that edited nothing.** |

## How it does on real bugs

Not a generic benchmark: 7 realistic multi-file repair projects (React + Express + TypeScript, one with a
WebSocket server), each with interacting bugs reported the way a real user would — by symptom, never by cause.
One example: in `realtime-sync`, a client sees its own edit applied twice because the broadcast loop doesn't
exclude the sender. Grading is real execution wherever the bug is pure logic, not text matching.

**Measured on a Mac mini M1, 16GB:**

| Mode | Score |
|---|---|
| Unaided discovery (no bug report) | 13/24 (54%) |
| Symptom report | **27/30 (90%)** |
| Precise instructions | **29/30 (97%)** |
| Discovery + defect checklist | 17/24 (71%) |

The gap between the first two rows is what matters: this model fixes what you describe far better than what
you don't. That's why `AGENTS.md` pushes "here's what's wrong" over "find what's wrong" — see below.

(`api-versioning`, the suite's 7th scenario, is excluded above — 3 of its "bugs" are a missing feature, not a
defect, so every model tested scores near-ceiling. Still shipped in `benchmarks/` for coverage.)

**Speed, scaled to other chips** the same way as the hardware check (real math, measured only on M1):

| Chip | Bandwidth (GB/s) | tokens/sec |
|---|---|---|
| M1 | 68 | **18.6 — measured** |
| M2 / M3 | 100 | ~27.4 — estimated |
| M2 Pro | 200 | ~54.7 — estimated |
| M3 Pro | 150 | ~41.0 — estimated |
| M1/M2/M3 Max | 400 | ~109.4 — estimated |
| M4 | 120 | ~32.8 — estimated |
| M4 Pro | 273 | ~74.7 — estimated |
| M4 Max | 546 | ~149.3 — estimated |

`setup.sh --doctor` checks an existing install against this config anytime. On a non-M1 chip, `--report-speed`
measures your real number and prints a pre-filled issue link — nothing sent automatically.

## Levers measured

Every flag above was re-tested with `setup.sh --benchmark all` (7 scenarios, 36 bugs, temperature 0), one
change at a time against the same binary. Speed is llama-server's `predicted_per_second`; memory is macOS
`footprint` (dirty pages — what actually competes with your other apps; the 9.3GB of weights sit on top as
clean, evictable file-backed pages). Full per-bug breakdown — what each of the 36 checks tests, and why it
passed or failed on every configuration — is in [`BENCHMARKS.md`](BENCHMARKS.md) and this
[interactive report](https://claude.ai/code/artifact/3284dc64-5776-438a-b349-e76012b49945).

| Config | Bugs fixed | tok/s | Draft accept | Memory | Verdict |
|---|---|---|---|---|---|
| no speculative decoding | 34/36 | 17.5 | — | — | reference |
| **`ngram-simple` (default)** | **33/36** | **24.9** | 47% | — | **fastest; kept** |
| `ngram-mod` | 34/36 | 23.0 | 49% | — | 8% slower |
| Gemma 4's official MTP drafter | 33/36 | 22.1 | **94%** | +440MB | slower despite near-perfect drafts |
| 6 experts/token instead of 8 | 30/36 | 26.3 | 47% | — | +6% speed, −3 bugs: rejected |
| 4 experts/token | 27/36 | 28.6 | 47% | — | +15% speed, −6 bugs: rejected |
| KV cache q8_0 | 34/36 | 19.7 | 48% | −39% | −20% speed for a cache that's already small: rejected |
| **`--ctx-checkpoints 0 --cache-ram 0` (default)** | 33–34/36 | 24.4–24.9 | 47% | **4.87GB → 1.02GB** | **adopted; no speed or quality cost** |

Every challenger loses on quality×speed except the memory fix, which is free. What's worth knowing:

- **Speculation barely pays on a mixture-of-experts model, however good the drafter.** Gemma 4's official MTP
  head hits 94% draft acceptance and is still *slower* than crude n-gram lookup at 47%. The reason is bytes, not
  compute: verifying *k* drafted tokens routes each one through its own 8-of-128 experts, so expert traffic grows
  ~k× per step — on a bandwidth-bound machine that eats most of what accepted tokens saved. N-gram wins purely
  because its drafts are free to produce. The community's block-diffusion "DFlash" drafter tells the same story
  a third time: it doesn't even fit alongside the shipped model (out of GPU memory at boot) and, on the smaller
  optional quant below, still loses to n-gram at 83% acceptance (21.6 vs 26.25 tok/s) — it only wins writing
  brand-new code, where n-gram's free drafts have nothing to copy from.
- **Cheaper routing isn't free.** 6 or 4 experts instead of 8 buys +6%/+15% speed for a clean −3/−6 bugs — well
  outside the suite's noise. Gemma 4's one shared expert doesn't absorb the loss the way larger always-on paths do.
- **TTFT lives in prompt processing, and the cache does the real work.** This MoE prefills at only ~175 tok/s
  (a 6k-token prompt is ~35s cold), but the built-in prefix cache turns a *repeated* prompt from 7.4s to 0.07s
  with zero configuration.
- **N-gram acceptance is workload-dependent**: 50–64% when repairing shown code, 16–27% writing new code.
  Expect ~25 tok/s on fixes, ~18 on fresh code — the 18.6 headline above is the conservative number.
- **Not perfectly lossless.** At temperature 0, `realtime-sync` flips one bug (5/6 → 4/6) with speculation on —
  different batch shapes change floating-point rounding. One bug in 36 is inside the suite's noise floor, real
  and deterministic, but worth knowing before trusting an "identical output" claim from anywhere.
- **The memory story was wrong, and now it's fixed.** An earlier version of this README blamed the KV cache
  for footprint growing to ~4.8GB over a session. It doesn't grow — Gemma 4's KV is a fixed 780MB here (25 of
  30 layers use a 1024-token window). The real cause was two llama-server defaults (32 context checkpoints,
  an 8GiB RAM prompt cache) doing their own bookkeeping. Turning them off is free: same speed, same score,
  **3.85GB back.**

Two more ideas were tried and rejected the same way: quantizing the shared/expert FFN tensors further (−5.5%
more bytes, but 3 more bugs — the routed experts are where this model's quality actually lives) and a
coding-pruned 98-expert alternative (fewer bytes, same speed, but 1.3–3.4× more verbose per turn — enough to
blow the output budget on one scenario). Both ruled out on the same suite; what's shipped is what survived.

## Optional: another 9% for free (not shipped by default)

Requantizing only the always-on tensors — attention and the tied embedding, `Q5_K` → `Q4_K` — while leaving
every expert tensor untouched cuts bytes read per token by 10% and measured **+9.4% decode speed (llama-bench
tg128) with no quality loss** on the benchmark suite — confirmed across two independent runs at 28/30 counted
scenarios, +12% suite-level tok/s over the shipped default ([full numbers](BENCHMARKS.md)). It's not the
shipped default because it produces a new model file this kit doesn't host — but it's three commands if you
want it:

```
curl -fsSL -o imatrix.gguf https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/imatrix_unsloth.gguf_file
llama-quantize --allow-requantize --imatrix imatrix.gguf \
  --tensor-type-file optional/attn-embed-q4k.tensor-types.txt \
  ~/.gemma4-coding-kit/models/gemma-4-26B-A4B-it-UD-IQ2_M.gguf \
  ~/.gemma4-coding-kit/models/gemma-4-26B-A4B-it-UD-IQ2_M-attnQ4K.gguf \
  Q4_K_M
```

Then point `MODEL_FILE` in `setup.sh` at the new file (or just pass `-m` yourself) and `--upgrade`. Takes about
a minute of CPU time, no GPU. `optional/attn-embed-q4k.tensor-types.txt` in this repo is the exact tensor map
used to produce the measured number above.

## Why `AGENTS.md` matters as much as the config

This model was measured — independently in [AgentFloor](https://arxiv.org/abs/2605.00334), and reproduced
directly here — at a sharp capability cliff: **96% on a single tool call, 72% on a two-step chain, 0% on
open-ended "find every bug" requests.** One such request ran 143, then 247 tool-call rounds and edited nothing.
`AGENTS.md` tells both the model and you how to work with that: scope to a named file or symptom, prefer
whole-file rewrites, use a defect-class checklist when unaided discovery is unavoidable — the single largest
quality lever measured here, +17 points (54%→71%) on unaided discovery.

## Honesty

- Speed is measured only on an M1 Mac mini; other chips are estimates from published bandwidth, not verified.
- Capacity behavior (what fits, what runs out) is expected to hold across the M-series at 16GB, since it's
  driven by a memory-proportional Metal limit rather than chip generation — reasoning, not an M1-only measurement.
- The full research behind these numbers — a grading-suite audit that found it wrong on over half its checks
  before hardening, a tensor-offload pilot that closed a promising capacity idea, the harness comparisons —
  lives in a separate research repository. This kit is deliberately the small, practical slice of that work.

## Other commands

Passing a flag through a pipe needs `bash -s --` (otherwise bash reads the flag itself):

```
curl -fsSL <raw-url>/setup.sh | bash -s -- --doctor          # diagnose an existing install, read-only
curl -fsSL <raw-url>/setup.sh | bash -s -- --config-only      # rewrite pi's config + AGENTS.md only
curl -fsSL <raw-url>/setup.sh | bash -s -- --start-only       # (re)start the server with the validated flags
curl -fsSL <raw-url>/setup.sh | bash -s -- --force-download   # re-download the model even if one is present
curl -fsSL <raw-url>/setup.sh | bash -s -- --check            # compare your install against the latest release
curl -fsSL <raw-url>/setup.sh | bash -s -- --upgrade          # reapply the current config + restart the server
curl -fsSL <raw-url>/setup.sh | bash -s -- --report-speed     # measure real tokens/sec on a non-M1 chip
```

`--no-exec` runs the whole setup without starting the interactive session. `--yes` answers yes to every
prompt — **including installing `llama.cpp`/`pi`** — explicit consent for an unattended install, not a shortcut
for casual use.

`--check` fetches [`VERSION`](VERSION) (a staleness beacon only — never sourced, never a source of truth for
what your machine runs) and reports whether the script, the recommended model, or your config are behind.
No network access reads as "up to date," never as failure. `--upgrade` reapplies the current config and offers
to delete an old model file if the recommendation changed.

Remove everything with [`uninstall.sh`](uninstall.sh) (`--dry-run`, `--purge-model`, `--all`):

```
curl -fsSL <raw-url>/uninstall.sh | bash -s -- --dry-run
curl -fsSL <raw-url>/uninstall.sh | bash
```

`--doctor` is the first thing to run if something's wrong — checks hardware, prerequisites, the model file, the
running server's actual flags, and both of `pi`'s config files.

`--benchmark` reproduces the table above on your hardware — needs a real clone, since the scenario data is too
large to embed in a single script:

```
git clone https://github.com/megasoft1978/gemma4-coding-kit && cd gemma4-coding-kit
./setup.sh --start-only
./setup.sh --benchmark          # all 7 scenarios
./setup.sh --benchmark cart-checkout   # or just one
```

Temperature-0 determinism guarantees a build reproduces itself, not that it reproduces another session's
tokens — your numbers should land in the same range, not match exactly.

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4), 16GB unified memory or more
- ~10GB free disk for the model
- [Homebrew](https://brew.sh) (for `llama.cpp`) and [Node.js](https://nodejs.org) (for `pi`), if you don't have them

## Manual setup

Rather not pipe a script into `bash`? Read `setup.sh` first — one self-contained file, every command visible.

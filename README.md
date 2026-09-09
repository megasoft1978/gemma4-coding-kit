<p align="center"><img src="assets/logo.png" width="140" alt="gemma4-coding-kit logo"></p>

# gemma4-coding-kit

**A real 26B coding model, on a 16GB Mac, in one command.**

```
curl -fsSL https://raw.githubusercontent.com/megasoft1978/gemma4-coding-kit/main/setup.sh | bash
```

Checks your hardware, downloads Gemma-4-26B-A4B (once), starts a correctly-tuned `llama-server`, configures the
[`pi`](https://github.com/earendil-works/pi) coding agent, and drops you into a session. No cloud API, no
account, nothing sent anywhere once the model's on disk.

## Why

The wider ecosystem assumes this model needs 24GB+. It doesn't — a smaller quant holds real quality at 16GB,
and every setting here (server flags, context window, prompt guidance) comes from measuring that quant on a
Mac mini M1, not from guessing. This is a config and prompt package on top of `pi`, built from numbers, not a
new agent.

<details>
<summary><strong>Advanced options</strong></summary>

Passing a flag through a pipe needs `bash -s --` (otherwise bash reads the flag itself):

```
curl -fsSL <raw-url>/setup.sh | bash -s -- --doctor          # diagnose an existing install, read-only
curl -fsSL <raw-url>/setup.sh | bash -s -- --start-only       # (re)start the server with the validated flags
curl -fsSL <raw-url>/setup.sh | bash -s -- --upgrade          # reapply the current config + restart the server
curl -fsSL <raw-url>/setup.sh | bash -s -- --report-speed     # measure real tokens/sec on a non-M1 chip
curl -fsSL <raw-url>/uninstall.sh | bash                      # remove everything
```

`--doctor` is the first thing to run if something's wrong. `setup.sh --help` and `uninstall.sh --help` list
every other flag.

**Requirements:** Apple Silicon Mac (M1/M2/M3/M4), 16GB unified memory or more, ~10GB free disk, and
[Homebrew](https://brew.sh) + [Node.js](https://nodejs.org) if you don't already have them. Rather not pipe a
script into `bash`? Read `setup.sh` first — one self-contained file, every command visible.

</details>

## Benchmarks

Graded on 7 realistic multi-file repair projects (React + Express + TypeScript), 36 bugs total, reported the
way a real user would — by symptom, never by cause.

| Mode | Score |
|---|---|
| Unaided discovery (no bug report) | 13/24 (54%) |
| Symptom report | **27/30 (90%)** |
| Precise instructions | **29/30 (97%)** |
| Discovery + defect checklist | 17/24 (71%) |

| Chip | tokens/sec | Peak memory |
|---|---|---|
| M1 | **18.6 — measured** | **~1.0GB** |
| M2 / M3 | ~27.4 — estimated | ~1.0GB |
| M2 Pro | ~54.7 — estimated | ~1.0GB |
| M3 Pro | ~41.0 — estimated | ~1.0GB |
| M1/M2/M3 Max | ~109.4 — estimated | ~1.0GB |
| M4 | ~32.8 — estimated | ~1.0GB |
| M4 Pro | ~74.7 — estimated | ~1.0GB |
| M4 Max | ~149.3 — estimated | ~1.0GB |

Memory is what the running server actually holds dirty in RAM — not the ~9.3GB of model weights, which sit on
disk as clean, evictable pages and don't compete with your other apps. It used to run closer to 4.9GB over a
long session; two llama-server flags (below) fixed that for free.

Non-M1 numbers are estimated from published memory bandwidth, not measured — run `--report-speed` to contribute
a real one. `setup.sh --benchmark` reproduces the table above on your own hardware (needs a full clone; the
scenario data doesn't fit in a single script).

<details>
<summary><strong>What was tried and what shipped</strong></summary>

| Config | Bugs fixed | tok/s | Peak memory | Verdict |
|---|---|---|---|---|
| Before the memory fix | 33/36 | 22.3 | 4.9GB | reference |
| **Shipped default** | **34/36** | **23.6** | **1.0GB** | `--ctx-checkpoints 0 --cache-ram 0` — the "growth" was two llama-server bookkeeping defaults, not the KV cache (which is a fixed 780MB here). Turning them off costs nothing. |
| Optional recipe (not shipped) | 33/36 | 26.5 | 1.0GB | Requantizing only the always-on attention/embedding tensors, leaving every expert untouched, cuts bytes read per token 10% for +12% more speed. Not the default because it produces a model file this kit doesn't host — see `optional/` in this repo if you want to build it yourself. |
| A community speculative-decoding drafter | 33/36 | 21.6 | 1.4GB | 83% draft acceptance, still *slower* — on this model, verifying each drafted token costs its own expert lookup, so a better drafter doesn't help. Rejected. |
| Quantizing experts further too | 30/36 | 21.6 | 1.0GB | 3 more bugs lost for no speed gain — the experts are where this model's quality actually lives. Rejected. |
| A smaller pruned variant | 27/36 | 21.5 | 1.0GB | Fewer bytes, same speed, but answers ran 1.3–3.4× longer and one scenario hit the output-length ceiling before finishing. Rejected. |

Not perfectly lossless: at temperature 0, one bug in 36 flips depending on speculative decoding being on or
off — a real, deterministic side effect of batch-shape-dependent floating-point rounding, not noise.

</details>

<details>
<summary><strong>Every scenario: the prompt, and every bug — pass, fail, and why</strong></summary>

Only 3 of the 7 scenarios have any failures on the shipped config or the optional recipe; the other 4
(`auth-session`, `cart-checkout`, `items-search`, `notify-channel`) are 100% on both and omitted below for
length — see `benchmarks/scenarios/` in this repo for their prompts and bugs.

<details>
<summary><code>api-versioning</code> — 5/6 shipped, 5/6 optional recipe</summary>

**Prompt (symptom report):**
> We need to ship a v2 of the users endpoint at `/v2/users`, returning each user as `{ id, firstName, lastName,
> email, createdAt }` — the full name split on the first space, with everything after it as the last name. The
> existing `/v1/users` endpoint must keep working exactly as before. Also add limit/offset pagination to both
> endpoints, defaulting to 20 items, with sane bounds if the caller passes something silly.

*This scenario's A/B/C bugs are excluded from every score above — they describe a feature to add, not a defect,
so every model tested passes them near-ceiling.*

| Bug | What it tests | Shipped | Optional recipe |
|---|---|---|---|
| B | v2 serializer splits the name correctly | ✅ pass | ❌ fail — none of the expected name-splitting patterns were found in the output |

This is also the one scenario where "precise instructions" mode — the model told exactly what to do, not just
the symptom — isn't a clean pass either: it's why that row above reads 29/30 (97%) and not 100%. Given literal,
step-by-step instructions, this model still gets 3 of 6 bugs wrong here: the name-splitting logic (B), keeping
the v1 response shape untouched while adding v2 (C), and clamping a negative `offset` to zero (F). A multi-field
response-shaping task with several simultaneous constraints is where it slips even when told exactly what to do.

</details>

<details>
<summary><code>orders-dashboard</code> — 4/5 shipped, 4/5 optional recipe</summary>

**Prompt (symptom report):**
> The orders table sometimes spins on "Loading…" forever and the network tab shows the request never completing
> normally — it happens when the backend hits an unexpected condition rather than one that's handled cleanly.
> Separately: order totals are occasionally off by a cent from what the line items add up to, "today's orders"
> sometimes includes or misses orders depending on what time of day you check, and a filter panel on the
> frontend seems to cause endless re-fetching once you touch it.

| Bug | What it tests | Shipped | Optional recipe |
|---|---|---|---|
| A | async route errors reach the error handler instead of hanging | ❌ fail — the model never wrote `server/routes/orders` at all | ❌ fail — same: the file was never emitted |

</details>

<details>
<summary><code>realtime-sync</code> — 5/6 shipped, 5/6 optional recipe</summary>

**Prompt (symptom report):**
> When two people have the document open, whoever made an edit sees their own edit appear twice. If the
> connection drops and comes back, edits made while offline are lost — they never reach the server. Reconnecting
> repeatedly seems to make things worse over time. Edits can occasionally be acknowledged before they're actually
> saved. And once in a while two different edits get merged together as if they were the same one.

| Bug | What it tests | Shipped | Optional recipe |
|---|---|---|---|
| B | a failed send re-queues its edit instead of discarding it | ❌ fail — the model never wrote `client/src/sync/queue` at all | ❌ fail — it did write the file, but cleared the queue unconditionally instead of re-queuing the failed send |

</details>

</details>

Full raw results, every configuration, every run: `results/EXP-048` through `EXP-055` in the
[research repository](https://github.com/megasoft1978/llm-memory-wall-research).

<p align="center"><img src="assets/logo.png" width="140" alt="gemma4-coding-kit logo"></p>

# gemma4-coding-kit

**A real 26B coding model that fits in your pocket-sized Mac. One command, and it's fixing bugs.**

```
curl -fsSL https://raw.githubusercontent.com/megasoft1978/gemma4-coding-kit/main/setup.sh | bash
```

Checks your hardware, downloads Gemma-4-26B-A4B (once), starts a correctly-tuned `llama-server`, configures the
[`pi`](https://github.com/earendil-works/pi) coding agent, and drops you straight into a session. No cloud API,
no account, nothing leaves your machine once the model's on disk.

## Why

The wider ecosystem assumes this model needs 24GB+. It doesn't. A smaller quant holds real quality at 16GB —
and every setting here (server flags, context window, prompt shape) comes from actually measuring that quant,
not guessing. This is a config and prompt package on top of `pi`, built from numbers, not a new agent.

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

**28/30 (93%)** — bugs fixed across 7 realistic multi-file projects (React + Express + TypeScript), reported
the way you'd actually describe them to a coding agent: by symptom, never by cause. That's the number that
matters, because that's how people use one.

Runs in about 10GB total: ~9.3GB of model weights on disk, plus ~1GB of working memory while the server runs.

| Chip | tokens/sec |
|---|---|
| M1 | **18.6 — measured** |
| M2 / M3 | ~27.4 — estimated |
| M2 Pro | ~54.7 — estimated |
| M3 Pro | ~41.0 — estimated |
| M1/M2/M3 Max | ~109.4 — estimated |
| M4 | ~32.8 — estimated |
| M4 Pro | ~74.7 — estimated |
| M4 Max | ~149.3 — estimated |

Non-M1 numbers are estimated from published memory bandwidth, not measured — run `--report-speed` to contribute
a real one. `setup.sh --benchmark` reproduces the score above on your own hardware (needs a full clone; the
scenario data doesn't fit in a single script).

<details>
<summary><strong>What was tried and what shipped</strong></summary>

| Config | Bugs fixed | tok/s | Verdict |
|---|---|---|---|
| Before the memory fix | 27/30 | 22.3 | reference (4.9GB peak memory) |
| **Shipped default** | **28/30** | **23.6** | `--ctx-checkpoints 0 --cache-ram 0` — the memory growth was two llama-server bookkeeping defaults, not the KV cache (a fixed 780MB here). Turning them off costs nothing and drops peak memory to ~1GB. |
| Optional recipe (not shipped) | 28/30 | 26.5 | Requantizing only the always-on attention/embedding tensors, leaving every expert untouched, cuts bytes read per token 10% for +12% more speed. Not the default because it produces a model file this kit doesn't host — see `optional/` in this repo if you want to build it yourself. |
| A community speculative-decoding drafter | 28/30 | 21.6 | 83% draft acceptance, still *slower* — on this model, verifying each drafted token costs its own expert lookup, so a better drafter doesn't help. Rejected. |
| Quantizing experts further too | 25/30 | 21.6 | 3 more bugs lost for no speed gain — the experts are where this model's quality actually lives. Rejected. |
| A smaller pruned variant | 23/30 | 21.5 | Fewer bytes, same speed, but answers ran 1.3–3.4× longer and one scenario hit the output-length ceiling before finishing. Rejected. |

Not perfectly lossless: at temperature 0, one bug flips depending on speculative decoding being on or off — a
real, deterministic side effect of batch-shape-dependent floating-point rounding, not noise.

</details>

<details>
<summary><strong>Every bug report, and every bug — pass, fail, and why</strong></summary>

Only 3 of the 7 scenarios have any failures on the shipped config or the optional recipe; the other 4
(`auth-session`, `cart-checkout`, `items-search`, `notify-channel`) are 100% on both and omitted below for
length.

<details>
<summary><code>api-versioning</code> — 5/6 shipped, 5/6 optional recipe</summary>

**Bug report:**
> We need to ship a v2 of the users endpoint at `/v2/users`, returning each user as `{ id, firstName, lastName,
> email, createdAt }` — the full name split on the first space, with everything after it as the last name. The
> existing `/v1/users` endpoint must keep working exactly as before. Also add limit/offset pagination to both
> endpoints, defaulting to 20 items, with sane bounds if the caller passes something silly.

*This scenario's A/B/C bugs are excluded from the score above — they describe a feature to add, not a defect,
so every model tested passes them near-ceiling.*

| Bug | What it tests | Shipped | Optional recipe |
|---|---|---|---|
| B | v2 serializer splits the name correctly | ✅ pass | ❌ fail — none of the expected name-splitting patterns were found in the output |

</details>

<details>
<summary><code>orders-dashboard</code> — 4/5 shipped, 4/5 optional recipe</summary>

**Bug report:**
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

**Bug report:**
> When two people have the document open, whoever made an edit sees their own edit appear twice. If the
> connection drops and comes back, edits made while offline are lost — they never reach the server. Reconnecting
> repeatedly seems to make things worse over time. Edits can occasionally be acknowledged before they're actually
> saved. And once in a while two different edits get merged together as if they were the same one.

| Bug | What it tests | Shipped | Optional recipe |
|---|---|---|---|
| B | a failed send re-queues its edit instead of discarding it | ❌ fail — the model never wrote `client/src/sync/queue` at all | ❌ fail — it did write the file, but cleared the queue unconditionally instead of re-queuing the failed send |

</details>

</details>

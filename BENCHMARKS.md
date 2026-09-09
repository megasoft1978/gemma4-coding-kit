# Benchmark results

Every configuration tested on gemma4-coding-kit's 7-scenario, 36-bug suite, with per-bug pass/fail and, where the check failed, why. Generated from `scripts/kit_benchmark_report.py` in the [research repository](https://github.com/megasoft1978/llm-memory-wall-research) against `results/EXP-048` through `EXP-055`. Interactive version with filtering: [live report](https://claude.ai/code/artifact/3284dc64-5776-438a-b349-e76012b49945).

`shipped` and `optional_recipe` are each two independent runs (a cold warm-up, discarded for the speed number but not the score, plus a confirmation run) — every other config below is the single measurement from the original pilot session. "Counted" excludes `api-versioning`, whose bugs are an added feature rather than a defect (every model scores near-ceiling there); it does **not** exclude `notify-channel`, whose bugs never discriminate between models but are still real checks.

## Levers tested

| Config | Status | Model | Score | Counted | tok/s (mean) | Why |
|---|---|---|---|---|---|---|
| Baseline (before memory fix) | reference | `gemma-4-26B-A4B-it-UD-IQ2_M.gguf` | 33/36 | 27/30 | 22.3 | Two runs; the first is a cold-boot warm-up (LED-103: first run after boot decodes ~20% slower on byte-identical output). |
| Shipped default | **adopted** | `gemma-4-26B-A4B-it-UD-IQ2_M.gguf` | 34/36 | 28/30 | 23.6 | This is exactly what setup.sh installs today. First run of this group discarded as warm-up for the speed comparison; score is compared across all runs. |
| Optional speed recipe | **optional** | `gemma-4-26B-A4B-it-UD-IQ2_M-attnQ4K.gguf` | 33/36 | 28/30 | 26.5 | Not shipped by default (produces a model file this kit doesn't host) -- see README's 'Optional: another 9% for free'. |
| Rejected: DFlash drafter | rejected | `gemma-4-26B-A4B-it-UD-IQ2_M-attnQ4K.gguf (OOM on the shipped 10.01GB file)` | 33/36 | 28/30 | 21.6 | 83% draft acceptance, still loses to free n-gram drafts (verification-bytes bound, LED-101/LED-105, NEG-OWN-010). |
| Rejected: deeper requant | rejected | `gemma-4-26B-A4B-it-UD-IQ2_M-step23.gguf (deleted after this result)` | 30/36 | 25/30 | 21.6 | A further 5.5% fewer bytes/token cost 3 counted bugs with no speed gain -- routed experts are where this model's quality actually lives (LED-106, NEG-OWN-011). |
| Rejected: pruned model | rejected | `gemma-4-A4B-98e-v6-coder-it-IQ3_XS.gguf (deleted after this result)` | 27/36 | 23/30 | 21.5 | Fewer bytes/token, flat decode speed, but 1.3-3.4x more verbose per turn -- ran one scenario to the 3072-token ceiling (LED-108, NEG-OWN-012). |

## Every bug

One row per bug check, one column per configuration. `pass`/`fail` only for `baseline`, `dflash`, `deeper_requant`, and `pruned_model` (measured before the grading fix that captures *why* a check failed); `shipped` and `optional_recipe` carry a reason on every failure. Long reason text (regex patterns) is truncated for table readability; the full text is in the interactive report and the raw JSONL.

| Scenario | # | What it tests | Graded by | Baseline | Shipped default | Optional recipe | DFlash drafter | Deeper requant | Pruned model |
|---|---|---|---|---|---|---|---|---|---|
| api-versioning | A | v2 route added *(excluded from counted score)* | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | B | v2 serializer splits name correctly *(excluded from counted score)* | pattern | ✅ pass | ✅ pass | ❌ fail — none of 4 expected patterns found | ❌ fail | ❌ fail | ✅ pass |
|  | C | v1 shape left untouched while v2 added *(excluded from counted score)* | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | D | NaN limit falls back to default *(excluded from counted score)* | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | E | limit capped *(excluded from counted score)* | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ❌ fail |
|  | F | negative offset clamped *(excluded from counted score)* | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ❌ fail |
| auth-session | A | token expiry compares seconds against milliseconds | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ❌ fail |
|  | B | password never actually verified | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | C | setInterval never cleared on unmount | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | D | login failure never surfaced to the user | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ❌ fail | ❌ fail |
|  | E | saved session never restored on load | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
| cart-checkout | A | cart state mutated in place, no re-render | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | B | tax applied before discount | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | C | reserveStock not awaited, rejection unhandled | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | D | double submit not prevented | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
| items-search | A | mutating sort of shared store | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ❌ fail | ✅ pass |
|  | B | totalCount/total contract mismatch | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | C | stale-response guard on fetch | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ❌ fail |
|  | D | reset page on new search | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ❌ fail |
| notify-channel | A | sms channel module created *(non-discriminating floor check)* | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | B | E.164 validation *(non-discriminating floor check)* | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | C | invalid_number returned not thrown *(non-discriminating floor check)* | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | D | 160-char truncation *(non-discriminating floor check)* | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | E | registered in dispatch CHANNELS *(non-discriminating floor check)* | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | F | render failure returned as unknown_template result *(non-discriminating floor check)* | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
| orders-dashboard | A | async route errors never reach error handler | pattern | ❌ fail | ❌ fail — file not found in output: server/routes/orders | ❌ fail — file not found in output: server/routes/orders | ❌ fail | ❌ fail | ❌ fail |
|  | B | float money arithmetic | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | C | UTC vs local date boundary for 'today' | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | D | requireUser registered after routes (data leak) | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | E | unstable filter object causes infinite refetch | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
| realtime-sync | A | broadcast echoes back to the sender | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | B | drain() empties the queue before send is confirmed | pattern | ❌ fail | ❌ fail — file not found in output: client/src/sync/queue | ❌ fail — matched forbidden pattern: ^(?![\\s\\S]*(?:requeue\|pending\\s*\\.\\s*unshift\|pending\... | ❌ fail | ❌ fail | ✅ pass |
|  | C | reconnect stacks listeners / no backoff cap | pattern | ❌ fail | ✅ pass | ✅ pass | ✅ pass | ❌ fail | ❌ fail |
|  | D | persist not awaited before ack | oracle | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |
|  | E | opId from Math.random collides | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ❌ fail |
|  | F | no cleanup on unmount, reconnect loop continues | pattern | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass | ✅ pass |

## Methodology

- Every run: `llama-server` 0.4.0 (build 10809), `-ngl 99 -fa on -c 24576 -np 1 --spec-type ngram-simple --reasoning off`, temperature 0, on a Mac mini M1 / 16GB.
- The first run after a cold boot decodes roughly 20% slower on byte-identical output (mmap page-in cost) — every speed comparison here uses only warm runs.
- Full experiment records: `experiments/EXP-048` through `EXP-055` in the research repository; raw JSONL under `results/EXP-048` through `EXP-055`.

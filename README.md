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
   exact byte size, not just a successful download.
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
| `--spec-type ngram-simple` | on | 1.36× decode speed, lossless (identical output, identical token counts). |
| `--cache-reuse 256` | on | 41× faster time-to-first-token on repeated context (7.08s → 0.17s, measured). |
| `--reasoning off` | on, not optional | With thinking enabled, this model produced 46,615 characters of internal reasoning and a **completely empty final answer**, even at 24k context and a 16k output ceiling. It doesn't converge on coding tasks. |
| Context window | 24576 | Validated boot + smoke-test size on this model. |
| `pi` `maxTokens` | 3072 | The naive default (12000) halves the usable input budget for no benefit. |
| `pi` compaction `reserveTokens`/`keepRecentTokens` | 3072 / 6000 | The library defaults (16384 / 20000) exceed a 24576-token window entirely, causing endless compaction — reproduced directly as a **143-round loop that edited nothing.** |

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

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4), 16GB unified memory or more
- ~10GB free disk space for the model
- [Homebrew](https://brew.sh) (to install `llama.cpp` if you don't have it)
- [Node.js](https://nodejs.org) (to install `pi` if you don't have it)

## Manual setup

If you'd rather not pipe a script into `bash`, read `setup.sh` first — it's a single self-contained file with
no hidden steps, and every command it runs is visible in it.

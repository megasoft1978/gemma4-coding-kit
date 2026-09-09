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

## How to use

```
curl -fsSL <raw-url>/setup.sh | bash -s -- --doctor          # diagnose an existing install, read-only
curl -fsSL <raw-url>/setup.sh | bash -s -- --start-only       # (re)start the server with the validated flags
curl -fsSL <raw-url>/setup.sh | bash -s -- --upgrade          # reapply the current config + restart the server
curl -fsSL <raw-url>/setup.sh | bash -s -- --report-speed     # measure real tokens/sec on a non-M1 chip
curl -fsSL <raw-url>/uninstall.sh | bash                      # remove everything
```

Passing a flag through a pipe needs `bash -s --`. `--doctor` is the first thing to run if something's wrong.
`setup.sh --help` and `uninstall.sh --help` list every other flag.

**Requirements:** Apple Silicon Mac (M1/M2/M3/M4), 16GB unified memory or more, ~10GB free disk, and
[Homebrew](https://brew.sh) + [Node.js](https://nodejs.org) if you don't already have them. Rather not pipe a
script into `bash`? Read `setup.sh` first — one self-contained file, every command visible.

## Benchmarks

Graded on 7 realistic multi-file repair projects (React + Express + TypeScript), 36 bugs total, reported the
way a real user would — by symptom, never by cause. Full per-bug breakdown, every configuration tried
(including what was rejected and why), and a live filterable version: **[BENCHMARKS.md](BENCHMARKS.md)** ·
[interactive report](https://claude.ai/code/artifact/3284dc64-5776-438a-b349-e76012b49945).

| Mode | Score |
|---|---|
| Unaided discovery (no bug report) | 13/24 (54%) |
| Symptom report | **27/30 (90%)** |
| Precise instructions | **29/30 (97%)** |
| Discovery + defect checklist | 17/24 (71%) |

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
a real one. `setup.sh --benchmark` reproduces the table above on your own hardware (needs a full clone; the
scenario data doesn't fit in a single script).

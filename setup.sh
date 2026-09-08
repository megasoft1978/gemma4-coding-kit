#!/usr/bin/env bash
# Gemma-4 coding kit — one command, no clone.
#
#   curl -fsSL https://raw.githubusercontent.com/megasoft1978/gemma4-coding-kit/main/setup.sh | bash
#
# Other modes (note the `bash -s --` needed once you pass a flag through a pipe -- without it, bash parses
# `--doctor` as its own flag rather than the script's):
#
#   curl -fsSL <raw>/setup.sh | bash -s -- --doctor        # diagnose an existing install, read-only
#   curl -fsSL <raw>/setup.sh | bash -s -- --config-only    # rewrite pi's config + AGENTS.md, no download/boot
#   curl -fsSL <raw>/setup.sh | bash -s -- --start-only     # (re)start the server with the validated flags
#   curl -fsSL <raw>/setup.sh | bash -s -- --force-download # re-download the model even if a same-size file exists
#   curl -fsSL <raw>/setup.sh | bash -s -- --check           # compare this install against the latest release
#   curl -fsSL <raw>/setup.sh | bash -s -- --upgrade         # reapply current config + restart the server
#   curl -fsSL <raw>/setup.sh | bash -s -- --report-speed    # measure real tokens/sec on an estimate-only chip
#
# Modifiers: --yes answers yes to EVERY prompt, including "install llama.cpp / pi now?" (brew/npm) -- it is
# explicit consent for an unattended install, so only pass it when that is what you want. --no-exec sets up
# everything but doesn't start the interactive pi session at the end.
#
# One mode needs a real git checkout, not the curl-pipe install, because it has data too large to embed here:
#
#   ./setup.sh --benchmark [scenario-id|all]   # grade a running server against the 7-scenario suite in benchmarks/
#
# Self-contained on purpose: when piped through `curl | bash`, there is no local checkout to reference sibling
# files from, so every step lives in this one file. Prompts read from /dev/tty rather than stdin, because a
# pipe consumes stdin for the script itself -- reading from stdin inside a piped script gets EOF, not a
# terminal's actual input.
#
# What this does, in order, and why each number is what it is: see README.md in this repo.
set -euo pipefail

# --help is a heredoc rather than a grep of this file's own header: when piped through `curl | bash`, $0 is
# /bin/bash itself, so there is no source file to read.
usage() {
  cat << 'EOF'
gemma4-coding-kit -- Gemma-4-26B-A4B as a local coding assistant on a 16GB Apple Silicon Mac.

  curl -fsSL https://raw.githubusercontent.com/megasoft1978/gemma4-coding-kit/main/setup.sh | bash

Other modes (pass flags through a pipe with `bash -s --`, otherwise bash reads them as its own):

  --doctor          diagnose an existing install, read-only
  --config-only     rewrite pi's config + AGENTS.md, no download/boot
  --start-only      (re)start the server with the validated flags
  --force-download  re-download the model even if a same-size file exists
  --check           compare this install against the latest release
  --upgrade         reapply the current config + restart the server
  --report-speed    measure real tokens/sec on a chip this kit only estimates for
  --benchmark [id]  grade a running server against the 7-scenario suite (needs a git checkout)

Modifiers:
  --yes             answer yes to EVERY prompt, including installing llama.cpp / pi via brew / npm
  --no-exec         set everything up but don't start the interactive pi session at the end

Details and the numbers behind every setting: README.md in the repo.
EOF
}

# ============================================================================================================
# Argument dispatch — parsed first, before anything touches hardware or disk, so hardware-untouched modes
# (--print-sig, --help) can run with zero side effects, including on Linux CI runners.
# ============================================================================================================
MODE=install
NO_EXEC=0
ASSUME_YES=0
FORCE_DOWNLOAD=0
BENCH_TARGET=all
while [ $# -gt 0 ]; do
  case "$1" in
    --doctor) MODE=doctor ;;
    --config-only) MODE=config-only ;;
    --start-only) MODE=start-only ;;
    --print-sig) MODE=print-sig ;;
    --print-node-snippets) MODE=print-node-snippets ;;
    --selftest) MODE=selftest ;;
    --check) MODE=check ;;
    --upgrade) MODE=upgrade ;;
    --report-speed) MODE=report-speed ;;
    --benchmark)
      MODE=benchmark
      # optional positional scenario id/"all" right after the flag, e.g. `--benchmark cart-checkout`
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then BENCH_TARGET="$2"; shift; fi
      ;;
    --no-exec) NO_EXEC=1 ;;
    --yes) ASSUME_YES=1 ;;
    --force-download) FORCE_DOWNLOAD=1 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1 (see --help)" >&2
      exit 64
      ;;
  esac
  shift
done

# ============================================================================================================
# Constants — the single source of truth for the validated config. Nothing below this block should contain a
# literal that also appears above it. SERVER_FLAGS is a bash array (not a string) so it can be checked
# element-by-element (doctor's flag-drift check) and hashed as a whole (config_sig).
# ============================================================================================================
KIT_VERSION="2026.09.08"
KIT_DIR="$HOME/.gemma4-coding-kit"
MODEL_DIR="$KIT_DIR/models"
PORT=8114
MODEL_REPO="unsloth/gemma-4-26B-A4B-it-GGUF"
MODEL_FILE="gemma-4-26B-A4B-it-UD-IQ2_M.gguf"
MODEL_BYTES=10014755296
MODEL_MIN_FREE_GB=12   # model size plus headroom, checked before downloading
PROVIDER_KEY="gemma4-kit"
MODEL_ID="gemma4"
CTX=24576
MAX_TOKENS=3072
COMPACT_RESERVE=3072
COMPACT_KEEP=6000
SERVER_FLAGS=(-ngl 99 -fa on -c "$CTX" --no-warmup -np 1 --spec-type ngram-simple --reasoning off --cache-reuse 256)
# Pinned into config_sig deliberately: --spec-type ngram-simple's acceptance rate is prompt-dependent, so if
# this text ever changed without a version bump, reports collected before and after the change would silently
# describe two different measurements while claiming to be the same number.
REPORT_PROMPT="Write a small TypeScript function that debounces another function by N milliseconds, plus one example call. Explain briefly."
# Fetched by --check ONLY as a staleness beacon -- never sourced or executed, and never supplies a value this
# script acts on (every constant above is still what actually runs). A compromised or lagging beacon can tell
# you you're behind; it cannot change what your machine does.
VERSION_URL="https://raw.githubusercontent.com/megasoft1978/gemma4-coding-kit/main/VERSION"
# Substrings doctor checks for in the running server's own command line -- kept separate from SERVER_FLAGS
# because some flags take a value (`-c 24576`) and checking that as one substring is more reliable than
# checking `-c` and `24576` independently, which could each appear for unrelated reasons.
CHECK_STRINGS=("-c $CTX" "-ngl 99" "-fa on" "-np 1" "--no-warmup" "--spec-type ngram-simple" "--reasoning off" "--cache-reuse 256")

# Only used by --benchmark, which needs a real git checkout (benchmarks/ is too large to embed in this
# self-contained script) -- every other mode ignores these.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
BENCH_DIR="$SCRIPT_DIR/benchmarks"

DEST="$MODEL_DIR/$MODEL_FILE"
INSTALL_ENV="$KIT_DIR/install.env"
AGENTS_LIST="$KIT_DIR/agents-md.list"
AGENTS_MARKER="<!-- gemma4-coding-kit v${KIT_VERSION} -- generated by setup.sh; safe to edit, uninstall.sh will then leave it alone -->"

AGENTS_MD_BODY=$(cat << 'EOF'
# Working with Gemma-4-26B-A4B

This project is configured to talk to a local Gemma-4-26B-A4B model. Its measured strengths and weaknesses on
this hardware are specific enough to change how you should ask it for things.

## Scope every request

This model was measured (independently, in AgentFloor arXiv 2605.00334, and reproduced directly against this
exact setup) at 96% success on a single tool call, 72% on a two-step chain, and 0% on open-ended "find every
bug in this project" requests -- one such request made 143, then 247 tool-call rounds and edited nothing.

Ask it to look at a named file, or fix a named symptom. Don't ask it to review a whole project unaided.

## Prefer whole-file rewrites

Diffs and line-numbered patches measurably fail more often at this model's scale than "rewrite the whole file
correctly." When asking for a fix, ask for the complete corrected file, not a patch.

## Use a defect checklist for unaided bug-finding

If you do need it to find problems without pointing at them, handing it a short checklist of defect
categories (mutation of shared state, unhandled async rejection, contract mismatches across a boundary, stale
closures, resource leaks, off-by-one/timezone/float-money errors, missing state resets, missing authorization
checks) measurably helps -- the single largest quality lever measured on this model, +17 points on unaided
discovery in this session's own testing.

## Never enable reasoning/thinking mode

Measured directly: with thinking enabled, this model produced 46,615 characters of internal reasoning and a
completely empty final answer, even given 24k tokens of context and a 16k-token output ceiling. This kit
disables it (`reasoning: false`) for that reason -- don't turn it back on for coding tasks.
EOF
)

# ============================================================================================================
# Shared functions
# ============================================================================================================

ask() {  # ask "question" -> reads y/N from the real terminal, not the pipe's stdin
  if [ "$ASSUME_YES" = "1" ]; then return 0; fi
  local prompt="$1" reply="n"
  # /dev/tty can exist and pass `-r` yet still fail at actual read time ("Device not configured") in some
  # sandboxed/detached-process environments with no controlling terminal at all -- confirmed by testing, not
  # just a theoretical case. `read`'s own exit status, not just -t 0 / -r /dev/tty, decides the fallback, so a
  # failed read can never leave `reply` unset under `set -u`.
  if [ -t 0 ]; then
    read -r -p "$prompt " reply || reply="n"
  elif [ -r /dev/tty ] && read -r -p "$prompt " reply 2>/dev/null < /dev/tty; then  # 2> first: the open of /dev/tty is what fails
    :
  else
    echo "(no terminal available to ask '$prompt' -- assuming no)" >&2
    reply="n"
  fi
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Read one field out of a JSON blob with no jq dependency. EXPR is a JS expression over `j` (the parsed
# object), passed via env rather than string-interpolated -- interpolating a shell variable into a `node -e`
# single-quoted string can't be done safely, and this is the one channel that is safe everywhere.
# Usage: printf '%s' "$json" | EXPR='j.timings.predicted_per_second' json_field
json_field() {
  node -e '
    let s = "";
    process.stdin.on("data", d => s += d);
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s);
        const v = (new Function("j", "return " + process.env.EXPR))(j);
        process.stdout.write(v === undefined ? "" : String(v));
      } catch (e) {
        process.exitCode = 3;
      }
    });
  '
}

# config_sig is computed from the live constants, never hand-maintained, so it cannot drift from the code that
# defines it. CI's version-sync job checks this against the repo's own VERSION file.
config_sig() {
  {
    printf '%s\n' "$MODEL_FILE" "$MODEL_BYTES" "${SERVER_FLAGS[@]}" "$CTX" "$MAX_TOKENS" "$COMPACT_RESERVE" "$COMPACT_KEEP" "$REPORT_PROMPT"
    printf '%s' "$AGENTS_MD_BODY"
  } | shasum -a 256 | cut -c1-16
}

detect_hw() {  # sets CHIP, MEM_BYTES, MEM_GB, ARCH -- no exit, callers decide what to do with the result
  if [ "${GEMMA4_KIT_SELFTEST:-0}" = "1" ]; then
    echo "!! GEMMA4_KIT_SELFTEST=1: hardware values may be faked -- for CI and testing only !!" >&2
    CHIP="${GEMMA4_KIT_FAKE_CHIP:-$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip/ {print $2}')}"
    MEM_BYTES="${GEMMA4_KIT_FAKE_MEMBYTES:-$(sysctl -n hw.memsize 2>/dev/null || echo 0)}"
    ARCH="${GEMMA4_KIT_FAKE_ARCH:-$(uname -m)}"
  else
    CHIP=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip/ {print $2}')
    MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    ARCH=$(uname -m)
  fi
  MEM_GB=$(( MEM_BYTES / 1073741824 ))
}

# The two refusals. Returns 1 (does not exit) so callers -- install and selftest -- decide what "refused"
# means for them; install exits the whole script, selftest just reports the outcome.
hw_gate() {
  if [ "$ARCH" != "arm64" ] || [ -z "$CHIP" ]; then
    echo "This kit is built for Apple Silicon Macs (M1/M2/M3/M4). Detected: $ARCH, chip: '${CHIP:-none}'." >&2
    echo "It won't run on Intel Macs -- the model quant and memory tuning are Apple-Silicon-specific." >&2
    return 1
  fi
  if [ "$MEM_GB" -lt 15 ]; then
    echo "This kit needs 16GB of unified memory. Detected: ~${MEM_GB}GB." >&2
    echo "The model alone needs ~10GB resident; 8GB and 12GB Macs cannot run it at usable quality." >&2
    return 1
  fi
  return 0
}

# Published spec memory bandwidth per chip, GB/s -- used ONLY to scale a speed estimate, never presented as a
# measurement. Multi-die variants (Pro/Max/Ultra) differ a lot; unrecognised chips fall back to M1's number,
# which under-estimates anything newer rather than over-promising.
chip_bandwidth() {
  case "$1" in
    "Apple M1")        echo 68  ;; "Apple M1 Pro") echo 200 ;; "Apple M1 Max") echo 400 ;; "Apple M1 Ultra") echo 800 ;;
    "Apple M2")        echo 100 ;; "Apple M2 Pro") echo 200 ;; "Apple M2 Max") echo 400 ;; "Apple M2 Ultra") echo 800 ;;
    "Apple M3")        echo 100 ;; "Apple M3 Pro") echo 150 ;; "Apple M3 Max") echo 400 ;;
    "Apple M4")        echo 120 ;; "Apple M4 Pro") echo 273 ;; "Apple M4 Max") echo 546 ;;
    *)                 echo 68  ;;
  esac
}

# TPS_MEASURED is set (non-empty) only for chips this project has a real measurement for. Filling one in here
# plus one README row is the entire workflow for accepting a community chip report (see README "Measured
# chips" section) -- no other code path changes.
chip_measured_tps() {
  case "$1" in
    "Apple M1") echo 18.6 ;;   # Mac mini M1 16GB, EXP-047, --spec-type ngram-simple --reasoning off --cache-reuse 256
    *)          echo ""   ;;
  esac
}

speed_line() {  # prints the measured-or-estimated speed line for $CHIP; requires detect_hw to have run
  local bw m1_bw=68 m1_tps=18.6 measured est
  bw=$(chip_bandwidth "$CHIP")
  measured=$(chip_measured_tps "$CHIP")
  if [ -n "$measured" ]; then
    echo "Speed target: ~${measured} tokens/sec -- MEASURED on this exact chip."
  else
    est=$(awk -v bw="$bw" -v m1bw="$m1_bw" -v m1tps="$m1_tps" 'BEGIN { printf "%.1f", (bw/m1bw)*m1tps }')
    echo "Speed estimate: ~${est} tokens/sec -- ESTIMATED by scaling the M1's measured speed to this chip's"
    echo "published memory bandwidth (${bw} vs M1's ${m1_bw} GB/s spec). NOT independently measured on this chip."
    echo "Capacity (what fits, what OOMs) is expected to behave the same as M1 at 16GB; decode speed is not."
  fi
}

free_disk_gb() {  # free space on the filesystem holding $1 (a directory, must already exist)
  df -g "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# Finds the PID of a server that is genuinely ours: matches the port AND has our exact model path on its
# command line. `pgrep -f "llama-server.*port $PORT"` alone (the original check) has no right anchor and would
# also match a server on port 81145 -- confirmed by inspection, fixed here.
server_pid() {
  local pid cmd
  for pid in $(pgrep -f "llama-server.*--port ${PORT}([^0-9]|$)" 2>/dev/null || true); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
    if printf '%s' "$cmd" | grep -qF -- "--port $PORT" && printf '%s' "$cmd" | grep -qF -- "$DEST"; then
      echo "$pid"
      return 0
    fi
  done
  return 1
}

# Sets ACTUAL_BYTES and MODEL_STATUS ("ok"/"wrong-size"/"missing") directly -- must be called plainly
# (`model_status`), never via `x=$(model_status)`. A command substitution forks a subshell, and a variable a
# subshelled function sets never propagates back to the caller -- confirmed the hard way: every caller that
# did `status=$(model_status)` and then read $ACTUAL_BYTES afterward crashed under `set -u` the first time a
# model file actually existed on disk (the "missing" case never triggers the crash, which is why this survived
# earlier testing -- nothing had exercised it with a real downloaded/present file).
model_status() {
  if [ ! -f "$DEST" ]; then
    ACTUAL_BYTES=0
    MODEL_STATUS=missing
    return
  fi
  ACTUAL_BYTES=$(stat -f%z "$DEST" 2>/dev/null || stat -c%s "$DEST" 2>/dev/null)
  if [ "$ACTUAL_BYTES" = "$MODEL_BYTES" ]; then MODEL_STATUS=ok; else MODEL_STATUS=wrong-size; fi
}

server_health() {
  curl -s -m 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q ok
}

# A /health-passing server can still fail every real completion -- confirmed the hard way this session.
# `|| true` on the curl matters: without it, a connection failure under `set -e` kills the whole script with
# no diagnostic, in exactly the situation this check exists to diagnose. Confirmed by inspection: the original
# had no `|| true` here.
smoke_test() {  # prints the raw response body; does not fail the script on a bad response
  curl -s -m "${1:-60}" "http://127.0.0.1:$PORT/v1/chat/completions" -H 'content-type: application/json' \
    -d '{"messages":[{"role":"user","content":"Reply with the single word: ok"}],"max_tokens":8,"temperature":0}' \
    || true
}

check_smoke() {  # prints ok/empty-reasoning/failed; takes the smoke_test() body on stdin
  local body; body=$(cat)
  if [ -z "$body" ] || ! printf '%s' "$body" | grep -qi '"content"'; then
    echo "failed:$body"
    return 1
  fi
  if printf '%s' "$body" | grep -q '"reasoning_content":"[^"]'; then
    echo "empty-reasoning"
    return 0
  fi
  echo "ok"
}

# ============================================================================================================
# Step functions -- each is the one place that step's logic lives; every mode composes these rather than
# duplicating them (this is what keeps --doctor's remediation text pointing at real, working commands).
# ============================================================================================================

step_hw_gate() {
  echo "== Checking hardware =="
  detect_hw
  hw_gate || exit 1
  echo "Detected: $CHIP, ${MEM_GB}GB unified memory."
  speed_line
}

step_prereqs() {
  echo
  echo "== Checking prerequisites =="
  WE_INSTALLED_LLAMA_SERVER=0
  WE_INSTALLED_PI=0
  if ! command -v llama-server >/dev/null 2>&1; then
    if ! command -v brew >/dev/null 2>&1; then
      echo "llama.cpp is missing, and so is Homebrew (needed to install it)." >&2
      echo 'Install Homebrew first: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
      exit 1
    fi
    echo "llama.cpp (llama-server) is not installed. Install with: brew install llama.cpp"
    if ask "Install it now? [y/N]"; then brew install llama.cpp; WE_INSTALLED_LLAMA_SERVER=1
    else echo "Skipped -- re-run after installing it." >&2; exit 1; fi
  fi
  if ! command -v pi >/dev/null 2>&1; then
    if ! command -v npm >/dev/null 2>&1; then
      echo "pi is missing, and so is npm (needed to install it)." >&2
      echo "Install Node.js first (includes npm): brew install node" >&2
      exit 1
    fi
    echo "pi (the coding agent CLI) is not installed. Install with: npm install -g @earendil-works/pi-coding-agent"
    if ask "Install it now? [y/N]"; then npm install -g @earendil-works/pi-coding-agent; WE_INSTALLED_PI=1
    else echo "Skipped -- re-run after installing it." >&2; exit 1; fi
  fi
  echo "Prerequisites OK: $(llama-server --version 2>&1 | head -1), pi $(pi --version 2>/dev/null)"
}

step_download() {
  echo
  echo "== Downloading model =="
  mkdir -p "$MODEL_DIR"
  local free; free=$(free_disk_gb "$MODEL_DIR")
  if [ -n "$free" ] && [ "$free" -lt "$MODEL_MIN_FREE_GB" ]; then
    echo "Only ${free}GB free on the volume holding $MODEL_DIR; need at least ${MODEL_MIN_FREE_GB}GB for the model." >&2
    echo "Free up space first -- a 9.3GB download failing at 99% after 40 minutes is worse than refusing now." >&2
    exit 1
  fi

  model_status; local status="$MODEL_STATUS"
  if [ "$FORCE_DOWNLOAD" = "1" ] && [ -f "$DEST" ]; then
    echo "Forcing re-download."
    rm -f "$DEST"
    status=missing
  fi
  if [ "$status" = ok ]; then
    echo "Already downloaded and verified: $DEST"
    return
  fi
  if [ "$status" = wrong-size ]; then
    echo "Existing file is the wrong size ($ACTUAL_BYTES bytes, expected $MODEL_BYTES) -- re-downloading."
    rm -f "$DEST"
  fi

  local url="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}"
  local partial_bytes=0
  if [ -f "$DEST.partial" ]; then
    partial_bytes=$(stat -f%z "$DEST.partial" 2>/dev/null || stat -c%s "$DEST.partial" 2>/dev/null || echo 0)
  fi
  if [ "$partial_bytes" = "$MODEL_BYTES" ]; then
    # A previous run finished the download but was killed before the rename -- nothing left to fetch.
    echo "Found a complete download from an earlier run; verifying it instead of re-downloading."
  else
    if [ "$partial_bytes" -gt 0 ]; then
      echo "Resuming an interrupted download ($partial_bytes of $MODEL_BYTES bytes already on disk)..."
    else
      echo "Downloading $MODEL_FILE (~9.3GB, this takes a while)..."
    fi
    # -C - resumes from whatever is already in the .partial file; a 9.3GB download that dies at 80% should
    # cost 20% to finish, not 100%. Hugging Face serves byte ranges, which is what makes this work.
    curl -fL -C - --progress-bar -o "$DEST.partial" "$url"
  fi
  local actual; actual=$(stat -f%z "$DEST.partial" 2>/dev/null || stat -c%s "$DEST.partial" 2>/dev/null)
  if [ "$actual" != "$MODEL_BYTES" ]; then
    echo "Download finished but the file size is wrong: got $actual bytes, expected $MODEL_BYTES." >&2
    echo "Not moving an incomplete/corrupt file into place. Re-run this script." >&2
    rm -f "$DEST.partial"; exit 1
  fi
  mv "$DEST.partial" "$DEST"
  echo "Downloaded and verified: $DEST"
}

step_server() {  # $1: "reuse" (default) or "restart" -- restart is what --upgrade will need later
  local mode="${1:-reuse}"
  echo
  echo "== Starting server =="
  local pid; pid=$(server_pid || true)
  if [ -n "$pid" ] && [ "$mode" = "restart" ]; then
    echo "Restarting the running server (pid $pid) to apply current flags."
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
    pid=""
  fi
  if [ -n "$pid" ]; then
    echo "A server is already running on port $PORT (pid $pid). Reusing it."
  else
    if [ ! -f "$DEST" ]; then
      echo "No model at $DEST -- nothing to start. Run setup.sh (without --start-only) to download it first." >&2
      exit 1
    fi
    mkdir -p "$KIT_DIR"
    nohup llama-server -m "$DEST" "${SERVER_FLAGS[@]}" --port "$PORT" \
      > "$KIT_DIR/server.log" 2>&1 &
    disown
    for _ in $(seq 1 60); do
      server_health && break
      sleep 3
    done
  fi
  if ! server_health; then
    echo "Server did not come up. Check $KIT_DIR/server.log" >&2
    exit 1
  fi
  local smoke; smoke=$(smoke_test 60)
  local verdict; verdict=$(printf '%s' "$smoke" | check_smoke) || {
    echo "Server is up but a real request failed. Response: $smoke" >&2
    exit 1
  }
  if [ "$verdict" = "empty-reasoning" ]; then
    echo "Warning: the server is emitting a non-empty reasoning channel. Thinking mode was measured this" >&2
    echo "session to never converge on coding tasks for this model -- --reasoning off should prevent it." >&2
  fi
  echo "Server ready on port $PORT."
}

# Writes pi's provider config. Prints ONLY the PRIOR compaction values on stdout, as
# "reserve=<n-or-empty> keep=<n-or-empty> had_block=<0-or-1>", so a caller doing `prior=$(step_config)` gets a
# clean, parseable value -- every progress message below goes to stderr instead, precisely so it isn't
# swallowed into that capture (an earlier version of this function mixed the two streams, which both hid
# install's progress output from the terminal and made this function unsafe to call more than once).
step_config() {
  echo >&2
  echo "== Configuring pi ==" >&2
  mkdir -p "$HOME/.pi/agent"
  # Every snippet below REFUSES to proceed on a models.json/settings.json that exists but isn't valid JSON.
  # The earlier version swallowed the parse error and started from `{}`, which would have silently replaced a
  # user's entire provider list with just ours the moment they had a stray trailing comma in the file.
  PROVIDER_KEY="$PROVIDER_KEY" MODEL_ID="$MODEL_ID" CTX="$CTX" MAX_TOKENS="$MAX_TOKENS" PORT="$PORT" \
  node -e '
    const fs = require("fs");
    const path = process.env.HOME + "/.pi/agent/models.json";
    let cfg = { providers: {} };
    if (fs.existsSync(path)) {
      try { cfg = JSON.parse(fs.readFileSync(path, "utf8")); }
      catch (e) { console.error(path + " exists but is not valid JSON (" + e.message + ") -- fix or move it first; refusing to overwrite it."); process.exit(3); }
    }
    if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) cfg = { providers: {} };
    cfg.providers = cfg.providers || {};
    cfg.providers[process.env.PROVIDER_KEY] = {
      baseUrl: "http://127.0.0.1:" + process.env.PORT + "/v1",
      api: "openai-completions",
      apiKey: "local",
      compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
      models: [{
        id: process.env.MODEL_ID, name: process.env.PROVIDER_KEY,
        contextWindow: Number(process.env.CTX), maxTokens: Number(process.env.MAX_TOKENS), reasoning: false,
      }],
    };
    fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
    console.error("wrote " + path);
  ' || return 3
  # Explicit `|| return 3` on every node call in this function, not just `set -e`: callers capture this
  # function with `prior=$(step_config)`, and bash does not carry -e into a command-substitution subshell, so
  # without these a refused/failed write would print its error and the install would carry on as if it worked.
  local prior
  prior=$(node -e '
    const fs = require("fs");
    const path = process.env.HOME + "/.pi/agent/settings.json";
    let cfg = {};
    if (fs.existsSync(path)) {
      try { cfg = JSON.parse(fs.readFileSync(path, "utf8")); }
      catch (e) { console.error(path + " exists but is not valid JSON (" + e.message + ") -- fix or move it first; refusing to overwrite it."); process.exit(3); }
    }
    if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) cfg = {};
    const c = cfg.compaction || {};
    process.stdout.write(
      "reserve=" + (c.reserveTokens === undefined ? "" : c.reserveTokens) +
      " keep=" + (c.keepRecentTokens === undefined ? "" : c.keepRecentTokens) +
      " had_block=" + (cfg.compaction ? 1 : 0)
    );
  ') || return 3
  COMPACT_RESERVE="$COMPACT_RESERVE" COMPACT_KEEP="$COMPACT_KEEP" \
  node -e '
    const fs = require("fs");
    const path = process.env.HOME + "/.pi/agent/settings.json";
    let cfg = {};
    if (fs.existsSync(path)) {
      try { cfg = JSON.parse(fs.readFileSync(path, "utf8")); }
      catch (e) { console.error(path + " exists but is not valid JSON (" + e.message + ") -- refusing to overwrite it."); process.exit(3); }
    }
    if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) cfg = {};
    cfg.compaction = cfg.compaction || {};
    // The library defaults (reserveTokens 16384, keepRecentTokens 20000) exceed a 24576-token window and cause
    // endless compaction, reproduced directly this session as a 143-round loop that made zero edits.
    cfg.compaction.reserveTokens = Number(process.env.COMPACT_RESERVE);
    cfg.compaction.keepRecentTokens = Number(process.env.COMPACT_KEEP);
    fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n");
    console.error("wrote " + path);
  ' || return 3
  printf '%s' "$prior"
}

configure_or_die() {  # PRIOR=$(step_config) with the failure actually stopping the run -- see step_config's note
  PRIOR=$(step_config) || {
    echo "pi's config was NOT written (see the message above) -- nothing else was changed by this step." >&2
    exit 1
  }
}

# Writes AGENTS.md into the CURRENT directory. If one already exists and isn't ours (no marker line, or a
# marker from a different write than we're about to do isn't checkable here -- that's uninstall's job to
# decide, not install's), it's backed up rather than silently destroyed. The original `cat > ./AGENTS.md`
# clobbered a hand-written file with no warning at all -- confirmed by inspection, fixed here.
step_agents_md() {
  echo
  echo "== Writing AGENTS.md =="
  local backup="" here; here="$(pwd)"
  if [ -f ./AGENTS.md ] && ! grep -qF "gemma4-coding-kit" ./AGENTS.md 2>/dev/null; then
    backup="$here/AGENTS.md.pre-gemma4-kit"
    cp ./AGENTS.md "$backup"
    echo "An existing ./AGENTS.md wasn't ours -- backed it up to $backup before writing."
  fi
  { printf '%s\n\n%s\n' "$AGENTS_MD_BODY" "$AGENTS_MARKER"; } > ./AGENTS.md
  echo "wrote ./AGENTS.md"
  local sha; sha=$(shasum -a 256 ./AGENTS.md | cut -d' ' -f1)
  mkdir -p "$KIT_DIR"
  # One line per path: a re-install or --upgrade over the same directory replaces that path's recorded sha
  # rather than appending a stale duplicate uninstall.sh would then trip over.
  if [ -f "$AGENTS_LIST" ]; then
    grep -vF -- "$(printf '\t')$here/AGENTS.md" "$AGENTS_LIST" > "$AGENTS_LIST.tmp" || true
    mv "$AGENTS_LIST.tmp" "$AGENTS_LIST"
  fi
  printf '%s\t%s\n' "$sha" "$here/AGENTS.md" >> "$AGENTS_LIST"
  AGENTS_MD_BACKUP="$backup"
}

manifest_get() {  # manifest_get KEY -> value from the existing install.env, or empty
  [ -f "$INSTALL_ENV" ] || return 0
  grep "^$1=" "$INSTALL_ENV" | cut -d= -f2- || true
}

write_manifest() {  # $1: prior compaction line from step_config ("reserve=X keep=Y had_block=Z")
  local reserve keep had_block
  reserve=$(printf '%s' "$1" | sed -n 's/.*reserve=\([0-9]*\).*/\1/p')
  keep=$(printf '%s' "$1" | sed -n 's/.*keep=\([0-9]*\).*/\1/p')
  had_block=$(printf '%s' "$1" | sed -n 's/.*had_block=\([0-9]\).*/\1/p')
  # A re-install or --upgrade over an existing install must NOT overwrite what the FIRST install recorded
  # about the world before this kit touched it: by now settings.json already holds our compaction values, so
  # re-reading it would record our own numbers as the "prior" ones and make uninstall's revert a no-op; and
  # the prerequisites are now present, so re-detecting them would forget that the kit was what installed them.
  local we_llama="${WE_INSTALLED_LLAMA_SERVER:-0}" we_pi="${WE_INSTALLED_PI:-0}" backup="${AGENTS_MD_BACKUP:-}"
  local first_install_at; first_install_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ -f "$INSTALL_ENV" ]; then
    if [ "$(manifest_get SETTINGS_HAD_COMPACTION)" != "" ]; then
      had_block=$(manifest_get SETTINGS_HAD_COMPACTION)
      reserve=$(manifest_get SETTINGS_PRIOR_RESERVE)
      keep=$(manifest_get SETTINGS_PRIOR_KEEP)
    fi
    [ "$(manifest_get WE_INSTALLED_LLAMA_SERVER)" = "1" ] && we_llama=1
    [ "$(manifest_get WE_INSTALLED_PI)" = "1" ] && we_pi=1
    [ -z "$backup" ] && backup=$(manifest_get AGENTS_MD_BACKUP)
    [ -n "$(manifest_get INSTALLED_AT)" ] && first_install_at=$(manifest_get INSTALLED_AT)
  fi
  mkdir -p "$KIT_DIR"
  cat > "$INSTALL_ENV" << EOF
KIT_VERSION=$KIT_VERSION
CONFIG_SIG=$(config_sig)
INSTALLED_AT=$first_install_at
UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MODEL_PATH=$DEST
MODEL_BYTES=$MODEL_BYTES
PORT=$PORT
PROVIDER_KEY=$PROVIDER_KEY
WE_INSTALLED_LLAMA_SERVER=$we_llama
WE_INSTALLED_PI=$we_pi
SETTINGS_HAD_COMPACTION=$had_block
SETTINGS_PRIOR_RESERVE=$reserve
SETTINGS_PRIOR_KEEP=$keep
PI_VERSION=$(pi --version 2>/dev/null || echo "")
AGENTS_MD_BACKUP=$backup
EOF
  echo "wrote $INSTALL_ENV"
}

# ============================================================================================================
# --doctor -- strictly read-only. Never starts, writes, or downloads anything; every failure line names an
# existing mode (--config-only, --start-only, --force-download) rather than re-implementing what it would do.
# ============================================================================================================
doctor() {
  local fails=0 warns=0 passes=0
  tag() {  # tag ok|warn|fail "message..."
    local kind="$1"; shift
    case "$kind" in
      ok)   printf '[ ok ] %s\n' "$*"; passes=$((passes+1)) ;;
      warn) printf '[warn] %s\n' "$*"; warns=$((warns+1)) ;;
      fail) printf '[fail] %s\n' "$*"; fails=$((fails+1)) ;;
      skip) printf '[skip] %s\n' "$*" ;;
    esac
  }

  echo "== gemma4-coding-kit doctor =="
  if [ -f "$INSTALL_ENV" ]; then
    echo "kit $(manifest_get KIT_VERSION) (config $(manifest_get CONFIG_SIG)), installed $(manifest_get INSTALLED_AT)"
    local installed_sig; installed_sig=$(manifest_get CONFIG_SIG)
    if [ -n "$installed_sig" ] && [ "$installed_sig" != "$(config_sig)" ]; then
      echo "(this script's config is $(config_sig) -- differs from what was installed; see --check / --upgrade)"
    fi
  else
    echo "(no install.env found -- was this installed with an older kit version, or not installed at all?)"
  fi

  echo
  echo "== Hardware =="
  detect_hw
  local hwerr; hwerr=$(mktemp)
  if hw_gate 2>"$hwerr"; then
    tag ok "$CHIP, ${MEM_GB}GB unified memory, $ARCH"
  else
    tag fail "$(cat "$hwerr")"
  fi
  rm -f "$hwerr"
  # Read-only means read-only: probe the nearest directory that already exists rather than creating MODEL_DIR.
  local probe="$MODEL_DIR"
  [ -d "$probe" ] || probe="$HOME"
  local free; free=$(free_disk_gb "$probe")
  if [ -n "$free" ] && [ "$free" -ge "$MODEL_MIN_FREE_GB" ]; then
    tag ok "free disk on $MODEL_DIR: ${free}GB (model needs ~10GB)"
  else
    tag warn "free disk on $MODEL_DIR: ${free:-unknown}GB -- may not be enough for a fresh/re- download"
  fi
  tag ok "$(speed_line | head -1)"

  echo
  echo "== Prerequisites =="
  if command -v llama-server >/dev/null 2>&1; then
    tag ok "llama-server  $(llama-server --version 2>&1 | head -1)"
  else
    tag fail "llama-server not on PATH -- install with: brew install llama.cpp"
  fi
  if command -v pi >/dev/null 2>&1; then
    tag ok "pi  $(pi --version 2>/dev/null)"
    if [ -f "$INSTALL_ENV" ]; then
      local recorded_pi; recorded_pi=$(manifest_get PI_VERSION)
      local current_pi; current_pi=$(pi --version 2>/dev/null)
      if [ -n "$recorded_pi" ] && [ "$recorded_pi" != "$current_pi" ]; then
        tag warn "pi was $recorded_pi at install, is $current_pi now -- if something broke, try --config-only"
      fi
    fi
  else
    tag fail "pi not on PATH -- install with: npm install -g @earendil-works/pi-coding-agent"
  fi
  if command -v node >/dev/null 2>&1; then
    tag ok "node  $(node --version)"
  else
    tag fail "node not on PATH -- pi requires it"
  fi

  echo
  echo "== Model =="
  model_status; local status="$MODEL_STATUS"
  case "$status" in
    ok) tag ok "$MODEL_FILE  $ACTUAL_BYTES bytes (expected $MODEL_BYTES)" ;;
    wrong-size) tag fail "$MODEL_FILE is $ACTUAL_BYTES bytes, expected $MODEL_BYTES -- re-download: setup.sh --force-download" ;;
    missing) tag skip "not downloaded -- run setup.sh to install" ;;
  esac

  echo
  echo "== Server =="
  local pid; pid=$(server_pid || true)
  if [ -n "$pid" ]; then
    tag ok "running on port $PORT (pid $pid)"
    if server_health; then
      tag ok "/health -> ok"
      local smoke t0 t1; t0=$(date +%s)
      smoke=$(smoke_test 120)
      t1=$(date +%s)
      local verdict; verdict=$(printf '%s' "$smoke" | check_smoke) || verdict="failed"
      case "$verdict" in
        ok) tag ok "real completion succeeded in $((t1-t0))s" ;;
        empty-reasoning) tag fail "reasoning channel is non-empty -- thinking mode never converges on this model" ;;
        *) tag fail "a real completion request failed: ${smoke:0:200}" ;;
      esac
      local cmd; cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
      local missing=""
      for chk in "${CHECK_STRINGS[@]}"; do
        printf '%s' "$cmd" | grep -qF -- "$chk" || missing="$missing $chk"
      done
      if [ -z "$missing" ]; then
        tag ok "server flags match this kit's validated set"
      else
        tag warn "server flags differ from this kit's validated set: missing:$missing"
        echo "       -> restart it: setup.sh --start-only"
      fi
      local props n_ctx
      props=$(curl -s -m 5 "http://127.0.0.1:$PORT/props" 2>/dev/null || true)
      n_ctx=$(printf '%s' "$props" | EXPR='j.default_generation_settings && j.default_generation_settings.n_ctx' json_field 2>/dev/null || true)
      if [ -n "$n_ctx" ]; then
        if [ "$n_ctx" = "$CTX" ]; then tag ok "/props n_ctx = $n_ctx (expected $CTX)"
        else tag warn "/props n_ctx = $n_ctx, expected $CTX -- the server may have clamped it"; fi
      fi
    else
      tag fail "process is running but /health doesn't respond"
    fi
  else
    tag skip "no server running on port $PORT -- run setup.sh to start one, or setup.sh --start-only"
  fi

  echo
  echo "== pi config =="
  local models_json="$HOME/.pi/agent/models.json"
  if [ -f "$models_json" ]; then
    local summary
    summary=$(PROVIDER_KEY="$PROVIDER_KEY" PORT="$PORT" MODEL_ID="$MODEL_ID" node -e '
      const fs = require("fs");
      try {
        const cfg = JSON.parse(fs.readFileSync(process.env.HOME + "/.pi/agent/models.json", "utf8"));
        const p = cfg.providers && cfg.providers[process.env.PROVIDER_KEY];
        if (!p) { console.log("missing"); process.exit(0); }
        const m = (p.models || [])[0] || {};
        const portOk = (p.baseUrl || "").includes(":" + process.env.PORT + "/");
        const idOk = m.id === process.env.MODEL_ID;
        const reasoningOk = m.reasoning === false;
        console.log((portOk && idOk && reasoningOk ? "ok" : "mismatch") +
          " port=" + portOk + " id=" + idOk + " reasoning=" + reasoningOk);
      } catch (e) { console.log("parse-error " + e.message); }
    ')
    case "$summary" in
      ok*) tag ok "models.json  providers.$PROVIDER_KEY -> port $PORT, model $MODEL_ID, reasoning off" ;;
      missing) tag fail "models.json has no providers.$PROVIDER_KEY entry -- run: setup.sh --config-only" ;;
      parse-error*) tag fail "models.json: ${summary#parse-error }" ;;
      *) tag fail "models.json providers.$PROVIDER_KEY looks wrong ($summary) -- run: setup.sh --config-only" ;;
    esac
  else
    tag skip "no $models_json -- run setup.sh to install"
  fi
  local settings_json="$HOME/.pi/agent/settings.json"
  if [ -f "$settings_json" ]; then
    local creserve ckeep
    creserve=$(node -e 'const c=JSON.parse(require("fs").readFileSync(process.env.HOME+"/.pi/agent/settings.json","utf8")).compaction||{};process.stdout.write(String(c.reserveTokens??""))' 2>/dev/null || echo "")
    ckeep=$(node -e 'const c=JSON.parse(require("fs").readFileSync(process.env.HOME+"/.pi/agent/settings.json","utf8")).compaction||{};process.stdout.write(String(c.keepRecentTokens??""))' 2>/dev/null || echo "")
    if [ "$creserve" = "$COMPACT_RESERVE" ] && [ "$ckeep" = "$COMPACT_KEEP" ]; then
      tag ok "settings.json compaction.reserveTokens=$creserve keepRecentTokens=$ckeep"
    else
      tag fail "settings.json compaction.reserveTokens=$creserve keepRecentTokens=$ckeep (expected $COMPACT_RESERVE/$COMPACT_KEEP)"
      echo "       -> endless-compaction risk; a 143-round loop that edits nothing. Rewrite config only:"
      echo "          setup.sh --config-only"
    fi
  fi

  echo
  echo "== AGENTS.md =="
  if [ -f ./AGENTS.md ]; then
    if grep -qF "gemma4-coding-kit" ./AGENTS.md; then
      tag ok "./AGENTS.md present, appears to be ours"
    else
      tag skip "./AGENTS.md present but not ours (no marker) -- left alone"
    fi
  else
    tag skip "no ./AGENTS.md in the current directory"
  fi

  echo
  echo "== $fails failed, $warns warning(s), $passes passed =="
  if [ "$fails" -gt 0 ]; then return 1; elif [ "$warns" -gt 0 ]; then return 2; else return 0; fi
}

# ============================================================================================================
# --selftest -- prints detect_hw + hw_gate + speed_line output and the gate's own exit code, then returns
# WITHOUT installing anything. This is the only mode CI's hardware-detection tests exercise; it structurally
# cannot download, boot a server, write config, or exec pi.
# ============================================================================================================
selftest() {
  detect_hw
  echo "chip=$CHIP mem_gb=$MEM_GB arch=$ARCH"
  if hw_gate; then
    speed_line
    exit 0
  else
    exit 1
  fi
}

# ============================================================================================================
# --check -- fetches VERSION as a staleness beacon ONLY (see VERSION_URL's comment: never sourced/executed,
# never supplies a value this script acts on). Reports three independent signals with a single exit code:
# 0 everything current, 2 something is stale (never 1 -- an update check must never look like a hard failure).
# Unreachable network is treated as success, not failure: a version check must never fail loud on a plane.
# ============================================================================================================
check() {
  echo "== gemma4-coding-kit version check =="
  echo "local script: $KIT_VERSION (config $(config_sig))"
  local remote; remote=$(curl -fs -m 5 "$VERSION_URL" 2>/dev/null || true)
  local r_ver r_sig r_model r_bytes stale=0
  r_ver=$(printf '%s\n' "$remote" | grep '^KIT_VERSION=' | cut -d= -f2- || true)
  if [ -z "$remote" ] || [ -z "$r_ver" ]; then
    echo "Could not reach or parse $VERSION_URL -- treating as up to date, not a failure."
    exit 0
  fi
  r_sig=$(printf '%s\n' "$remote" | grep '^CONFIG_SIG=' | cut -d= -f2- || true)
  r_model=$(printf '%s\n' "$remote" | grep '^MODEL_FILE=' | cut -d= -f2- || true)
  r_bytes=$(printf '%s\n' "$remote" | grep '^MODEL_BYTES=' | cut -d= -f2- || true)

  if [ -n "$r_sig" ] && [ "$r_sig" != "$(config_sig)" ]; then
    echo "[stale] this setup.sh's config differs from the latest published one ($r_ver) -- re-download it."
    stale=1
  else
    echo "[ ok ] setup.sh matches the latest published config."
  fi
  if [ -n "$r_model" ] && { [ "$r_model" != "$MODEL_FILE" ] || [ "$r_bytes" != "$MODEL_BYTES" ]; }; then
    echo "[stale] a different model is now recommended: $r_model ($r_bytes bytes)."
    stale=1
  else
    echo "[ ok ] recommended model unchanged."
  fi
  if [ -f "$INSTALL_ENV" ]; then
    local installed_sig; installed_sig=$(manifest_get CONFIG_SIG)
    if [ "$installed_sig" != "$(config_sig)" ]; then
      echo "[stale] your installed config doesn't match this script's current config -- run: setup.sh --upgrade"
      stale=1
    else
      echo "[ ok ] your installed config matches this script."
    fi
  fi
  [ "$stale" = 1 ] && exit 2 || exit 0
}

# ============================================================================================================
# --upgrade -- a flagged variant of install: restarts the server (a flag change wouldn't otherwise take
# effect), rewrites AGENTS.md (step_agents_md already backs up a hand-edited one), and offers to prune an old
# model file left behind if MODEL_FILE changed since the last install. Requires a prior install (install.env)
# -- upgrading nothing isn't a meaningful operation.
# ============================================================================================================
upgrade() {
  if [ ! -f "$INSTALL_ENV" ]; then
    echo "No existing install found ($INSTALL_ENV missing). Run setup.sh normally first." >&2
    exit 1
  fi
  local old_model; old_model=$(manifest_get MODEL_PATH)
  step_hw_gate
  step_prereqs
  step_download
  step_server restart
  configure_or_die
  step_agents_md
  write_manifest "$PRIOR"
  if [ -n "$old_model" ] && [ "$old_model" != "$DEST" ] && [ -f "$old_model" ]; then
    echo
    if ask "Old model no longer used: $old_model -- delete it? [y/N]"; then
      rm -f "$old_model"
      echo "Deleted $old_model"
    else
      echo "Left in place: $old_model"
    fi
  fi
  echo
  echo "== Upgrade complete. =="
}

# ============================================================================================================
# --benchmark -- grades an already-running, already-validated server against the 7-scenario suite in
# benchmarks/. Never boots a server itself (same division of responsibility as --doctor: measures what's
# there, doesn't set it up). Needs a real git checkout, not the curl-pipe install, because the scenario data
# and oracle test trees are too large to embed in this file -- see run_benchmark's own precondition check.
# All prompt-construction, HTTP-calling and grading logic lives in benchmarks/bench.mjs and benchmarks/
# grade.mjs, reusing the already-verified grader rather than duplicating it here in bash.
# ============================================================================================================
run_benchmark() {
  if [ ! -f "$BENCH_DIR/grade.mjs" ] || [ ! -d "$BENCH_DIR/scenarios" ] || [ ! -d "$BENCH_DIR/oracle" ]; then
    echo "--benchmark needs the full repo checkout, not the curl-pipe install." >&2
    echo "Run: git clone https://github.com/megasoft1978/gemma4-coding-kit && cd gemma4-coding-kit && ./setup.sh --benchmark" >&2
    exit 1
  fi
  local pid; pid=$(server_pid || true)
  if [ -z "$pid" ] || ! server_health; then
    echo "No validated server running on port $PORT. Start one first: setup.sh --start-only" >&2
    exit 1
  fi

  echo "== gemma4-coding-kit benchmark: $BENCH_TARGET =="
  node "$BENCH_DIR/bench.mjs" "$BENCH_TARGET" --port "$PORT" --max-tokens "$MAX_TOKENS" | node -e '
    let fails = 0, warns = 0, totalPass = 0, totalBugs = 0, totalWall = 0, n = 0;
    const tag = (kind, msg) => {
      const label = { ok: "[ ok ] ", warn: "[warn] ", fail: "[fail] ", skip: "[skip] " }[kind];
      console.log(label + msg);
      if (kind === "fail") fails++;
      if (kind === "warn") warns++;
    };
    process.stdin.setEncoding("utf8");
    let buf = "";
    process.stdin.on("data", (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        if (!line.trim()) continue;
        const r = JSON.parse(line);
        n++;
        if (r.verdict === "skip") { tag("skip", `${r.scenario}: ${r.detail}`); continue; }
        if (r.verdict === "timeout") { tag("fail", `${r.scenario}: timed out waiting for a response`); continue; }
        if (r.verdict === "empty-reasoning") { tag("warn", `${r.scenario}: reasoning channel non-empty, content empty (in ${r.wall_s}s)`); continue; }
        if (r.verdict === "error") { tag("fail", `${r.scenario}: ${r.detail}`); continue; }
        totalPass += r.pass; totalBugs += r.total; totalWall += r.wall_s;
        const pct = Math.round((r.pass / r.total) * 100);
        const line2 = `${r.scenario}: ${r.pass}/${r.total} (${pct}%) in ${r.wall_s.toFixed(1)}s`;
        if (r.pass === r.total) tag("ok", line2);
        else if (r.pass > 0) tag("warn", line2);
        else tag("fail", line2);
      }
    });
    process.stdin.on("end", () => {
      if (totalBugs > 0) {
        const pct = Math.round((totalPass / totalBugs) * 100);
        console.log(`\n== benchmark: ${totalPass}/${totalBugs} (${pct}%) across ${n} scenario(s), ${totalWall.toFixed(1)}s wall ==`);
        console.log("(vs. the published baseline table in README.md -- exact match is not expected; temperature-0 determinism only guarantees a given server build reproduces itself)");
      }
      process.exit(fails > 0 ? 1 : warns > 0 ? 2 : 0);
    });
  '
}

# ============================================================================================================
# --report-speed -- measures real tokens/sec on chips this kit currently only estimates for, and prints a
# pre-filled GitHub issue link (never opened automatically -- the report is shown in full in the terminal
# first; this kit never phones home on its own). Accepting a report is then a one-line diff: fill in
# chip_measured_tps() and one README row, no other code path changes.
# ============================================================================================================
# Prints tokens/sec for one REPORT_PROMPT completion, or "0" if it couldn't measure. The request and the
# timing both live in one node process: llama-server's own `timings.predicted_per_second` (pure generation
# rate, prompt processing excluded) is preferred, with a millisecond wall-clock fallback. Whole-second `date`
# timing was rejected -- on the fast chips this exists to measure, 256 tokens finish in ~2s, where rounding to
# a whole second is a 30-50% error.
timed_completion() {
  REPORT_PROMPT="$REPORT_PROMPT" PORT="$PORT" node -e '
    const t0 = performance.now();
    fetch("http://127.0.0.1:" + process.env.PORT + "/v1/chat/completions", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ messages: [{ role: "user", content: process.env.REPORT_PROMPT }], max_tokens: 256, temperature: 0 }),
      signal: AbortSignal.timeout(120_000),
    }).then(async (r) => {
      const j = await r.json();
      const wall = (performance.now() - t0) / 1000;
      const fromServer = j && j.timings && Number(j.timings.predicted_per_second);
      const tok = j && j.usage && Number(j.usage.completion_tokens);
      const tps = fromServer > 0 ? fromServer : (tok > 0 && wall > 0 ? tok / wall : 0);
      process.stdout.write(tps > 0 ? tps.toFixed(1) : "0");
    }).catch(() => process.stdout.write("0"));
  '
}

report_speed() {
  echo "== gemma4-coding-kit chip speed report =="
  local pid; pid=$(server_pid || true)
  if [ -z "$pid" ] || ! server_health; then
    echo "No validated server running on port $PORT. Start one first: setup.sh --start-only" >&2
    exit 1
  fi
  detect_hw
  if [ -n "$(chip_measured_tps "$CHIP")" ]; then
    echo "$CHIP already has a measured number in this kit ($(chip_measured_tps "$CHIP") tokens/sec) -- no report needed."
    exit 0
  fi
  echo "Chip: $CHIP (currently only an ESTIMATE in this kit)"
  echo "Running two timed completions -- the first pays a cold mmap-page-in cost, the second is the real number."
  local tps1 tps2
  tps1=$(timed_completion)
  tps2=$(timed_completion)
  echo
  echo "First run:  ${tps1} tokens/sec"
  echo "Second run: ${tps2} tokens/sec  <- this is the number to report"
  if [ "$tps2" = "0" ]; then
    echo
    echo "Could not get a usable measurement (empty or malformed completion). Try again, or report by hand." >&2
    exit 1
  fi
  echo
  echo "To contribute this measurement, open an issue with these fields pre-filled (nothing is sent automatically):"
  REPORT_CHIP="$CHIP" REPORT_MAC="$(sw_vers -productVersion 2>/dev/null || true)" REPORT_TPS="$tps2" node -e '
    const params = new URLSearchParams({
      template: "chip-report.yml",
      chip: process.env.REPORT_CHIP || "",
      macos_version: process.env.REPORT_MAC || "",
      measured_tps: process.env.REPORT_TPS || "",
    });
    console.log("https://github.com/megasoft1978/gemma4-coding-kit/issues/new?" + params.toString());
  '
}

# ============================================================================================================
# Dispatch
# ============================================================================================================
case "$MODE" in
  print-sig)
    config_sig
    exit 0
    ;;
  print-node-snippets)
    # Extracts each `node -e '...'` program in this file between the opening quote and its matching closing
    # quote-plus-paren, so CI can run `node --check` on each without a shell interpreter seeing inside the
    # string. Relies on this file's own convention: every snippet is `node -e '` ... `'` on its own lines.
    # The closing-quote line is indented to match its snippet (e.g. "  '", or "  '"'"')" when the whole node -e
    # call is wrapped in a command substitution), not always exactly one column -- an exact-one-char version
    # silently never matched any closing line in this file, confirmed directly, so every extracted snippet used
    # to end with a stray quote (or quote-paren) line.
    # The quote character is passed in via -v rather than written as \x27, which not every awk (mawk on
    # Ubuntu, where CI's js-syntax job runs) understands inside a regex.
    # A closing line may carry shell after the quote -- `') || return 3` -- which is bash, not JS.
    case "$0" in
      *setup.sh) ;;
      *) echo "--print-node-snippets needs to read its own source; run it from a checkout, not a pipe." >&2; exit 64 ;;
    esac
    awk -v q="'" '
      /node -e .$/ { n++; print "--- snippet " n " ---"; capture=1; next }
      capture && $0 ~ ("^[ \t]*" q "\\)?( .*)?$") { capture=0; next }
      capture { print }
    ' "$0"
    exit 0
    ;;
  selftest)
    selftest
    ;;
  doctor)
    doctor
    exit $?
    ;;
  benchmark)
    run_benchmark
    exit $?
    ;;
  check)
    check
    ;;
  report-speed)
    report_speed
    ;;
  upgrade)
    upgrade
    ;;
  config-only)
    configure_or_die
    write_manifest "$PRIOR"
    step_agents_md
    echo
    echo "Config rewritten. Nothing was downloaded and the server was not touched."
    ;;
  start-only)
    step_server restart
    ;;
  install)
    step_hw_gate
    step_prereqs
    step_download
    step_server reuse
    configure_or_die
    step_agents_md
    write_manifest "$PRIOR"
    echo
    if [ "$NO_EXEC" = "1" ]; then
      echo "== Ready. (--no-exec set, not starting pi.) =="
    else
      echo "== Ready. Starting pi. =="
      exec pi --provider "$PROVIDER_KEY" --model "$MODEL_ID"
    fi
    ;;
esac

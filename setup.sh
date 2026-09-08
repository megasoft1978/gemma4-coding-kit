#!/usr/bin/env bash
# Gemma-4 coding kit — one command, no clone.
#
#   curl -fsSL https://raw.githubusercontent.com/<user>/gemma4-coding-kit/main/setup.sh | bash
#
# Self-contained on purpose: when piped through `curl | bash`, there is no local checkout to reference sibling
# files from, so every step lives in this one file. Prompts read from /dev/tty rather than stdin, because a
# pipe consumes stdin for the script itself -- reading from stdin inside a piped script gets EOF, not a
# terminal's actual input.
#
# What this does, in order, and why each number is what it is: see README.md in this repo.
set -euo pipefail

KIT_DIR="$HOME/.gemma4-coding-kit"
MODEL_DIR="$KIT_DIR/models"
mkdir -p "$KIT_DIR" "$MODEL_DIR"

ask() {  # ask "question" -> reads y/N from the real terminal, not the pipe's stdin
  local prompt="$1" reply
  if [ -t 0 ]; then
    read -r -p "$prompt " reply
  elif [ -r /dev/tty ]; then
    read -r -p "$prompt " reply < /dev/tty
  else
    echo "(no terminal available to ask '$prompt' -- assuming no)" >&2
    reply="n"
  fi
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------- 1. hardware gate + speed estimate ------------------------------------------------------------
echo "== Checking hardware =="
CHIP=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip/ {print $2}')
MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
MEM_GB=$(( MEM_BYTES / 1073741824 ))
ARCH=$(uname -m)

if [ "$ARCH" != "arm64" ] || [ -z "$CHIP" ]; then
  echo "This kit is built for Apple Silicon Macs (M1/M2/M3/M4). Detected: $(uname -m), chip: '${CHIP:-none}'." >&2
  echo "It won't run on Intel Macs -- the model quant and memory tuning are Apple-Silicon-specific." >&2
  exit 1
fi
if [ "$MEM_GB" -lt 15 ]; then
  echo "This kit needs 16GB of unified memory. Detected: ~${MEM_GB}GB." >&2
  echo "The model alone needs ~10GB resident; 8GB and 12GB Macs cannot run it at usable quality." >&2
  exit 1
fi

# Published spec memory bandwidth per chip, GB/s -- used ONLY to scale a speed estimate, never presented as a
# measurement. Multi-die variants (Pro/Max/Ultra) differ a lot; unrecognised chips fall back to M1's number,
# which under-estimates anything newer rather than over-promising.
case "$CHIP" in
  "Apple M1")        BW=68  ;; "Apple M1 Pro") BW=200 ;; "Apple M1 Max") BW=400 ;; "Apple M1 Ultra") BW=800 ;;
  "Apple M2")        BW=100 ;; "Apple M2 Pro") BW=200 ;; "Apple M2 Max") BW=400 ;; "Apple M2 Ultra") BW=800 ;;
  "Apple M3")        BW=100 ;; "Apple M3 Pro") BW=150 ;; "Apple M3 Max") BW=400 ;;
  "Apple M4")        BW=120 ;; "Apple M4 Pro") BW=273 ;; "Apple M4 Max") BW=546 ;;
  *)                 BW=68  ;;
esac
M1_BW=68; M1_TPS=18.6  # measured this session (EXP-047): --spec-type ngram-simple --reasoning off --cache-reuse 256

echo "Detected: $CHIP, ${MEM_GB}GB unified memory."
if [ "$CHIP" = "Apple M1" ]; then
  echo "Speed target: ~${M1_TPS} tokens/sec -- MEASURED on this exact chip (Mac mini M1, 16GB)."
else
  EST=$(awk -v bw="$BW" -v m1bw="$M1_BW" -v m1tps="$M1_TPS" 'BEGIN { printf "%.1f", (bw/m1bw)*m1tps }')
  echo "Speed estimate: ~${EST} tokens/sec -- ESTIMATED by scaling the M1's measured speed to this chip's"
  echo "published memory bandwidth (${BW} vs M1's ${M1_BW} GB/s spec). NOT independently measured on this chip."
  echo "Capacity (what fits, what OOMs) is expected to behave the same as M1 at 16GB; decode speed is not."
fi

# ---------- 2. prerequisites, ask before installing -------------------------------------------------------
echo
echo "== Checking prerequisites =="
if ! command -v llama-server >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "llama.cpp is missing, and so is Homebrew (needed to install it)." >&2
    echo 'Install Homebrew first: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
    exit 1
  fi
  echo "llama.cpp (llama-server) is not installed. Install with: brew install llama.cpp"
  if ask "Install it now? [y/N]"; then brew install llama.cpp; else echo "Skipped -- re-run after installing it." >&2; exit 1; fi
fi
if ! command -v pi >/dev/null 2>&1; then
  if ! command -v npm >/dev/null 2>&1; then
    echo "pi is missing, and so is npm (needed to install it)." >&2
    echo "Install Node.js first (includes npm): brew install node" >&2
    exit 1
  fi
  echo "pi (the coding agent CLI) is not installed. Install with: npm install -g @earendil-works/pi-coding-agent"
  if ask "Install it now? [y/N]"; then npm install -g @earendil-works/pi-coding-agent; else echo "Skipped -- re-run after installing it." >&2; exit 1; fi
fi
echo "Prerequisites OK: $(llama-server --version 2>&1 | head -1), pi $(pi --version 2>/dev/null)"

# ---------- 3. download the validated quant, verified by exact byte size -----------------------------------
echo
echo "== Downloading model =="
FILE="gemma-4-26B-A4B-it-UD-IQ2_M.gguf"
EXPECTED_BYTES=10014755296
URL="https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/${FILE}"
DEST="$MODEL_DIR/$FILE"

need_download=1
if [ -f "$DEST" ]; then
  ACTUAL=$(stat -f%z "$DEST" 2>/dev/null || stat -c%s "$DEST" 2>/dev/null)
  if [ "$ACTUAL" = "$EXPECTED_BYTES" ]; then
    echo "Already downloaded and verified: $DEST"
    need_download=0
  else
    echo "Existing file is the wrong size (${ACTUAL:-0} bytes, expected $EXPECTED_BYTES) -- re-downloading."
    rm -f "$DEST"
  fi
fi
if [ "$need_download" = "1" ]; then
  echo "Downloading $FILE (~9.3GB, this takes a while)..."
  curl -fL --progress-bar -o "$DEST.partial" "$URL"
  ACTUAL=$(stat -f%z "$DEST.partial" 2>/dev/null || stat -c%s "$DEST.partial" 2>/dev/null)
  if [ "$ACTUAL" != "$EXPECTED_BYTES" ]; then
    echo "Download finished but the file size is wrong: got $ACTUAL bytes, expected $EXPECTED_BYTES." >&2
    echo "Not moving an incomplete/corrupt file into place. Re-run this script." >&2
    rm -f "$DEST.partial"; exit 1
  fi
  mv "$DEST.partial" "$DEST"
  echo "Downloaded and verified: $DEST"
fi

# ---------- 4. boot the server with every validated flag, smoke-test before trusting it --------------------
echo
echo "== Starting server =="
PORT=8114
if pgrep -f "llama-server.*port $PORT" >/dev/null 2>&1; then
  echo "A server is already running on port $PORT. Reusing it."
else
  nohup llama-server -m "$DEST" -ngl 99 -fa on -c 24576 --no-warmup -np 1 \
    --spec-type ngram-simple --reasoning off --cache-reuse 256 --port "$PORT" \
    > "$KIT_DIR/server.log" 2>&1 &
  disown
  for i in $(seq 1 60); do
    curl -s -m 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q ok && break
    sleep 3
  done
fi
if ! curl -s -m 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q ok; then
  echo "Server did not come up. Check $KIT_DIR/server.log" >&2
  exit 1
fi
# A /health-passing server can still fail every real completion -- confirmed the hard way this session.
SMOKE=$(curl -s -m 60 "http://127.0.0.1:$PORT/v1/chat/completions" -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"Reply with the single word: ok"}],"max_tokens":8,"temperature":0}')
if ! echo "$SMOKE" | grep -qi '"content"'; then
  echo "Server is up but a real request failed. Response: $SMOKE" >&2
  exit 1
fi
if echo "$SMOKE" | grep -q '"reasoning_content":"[^"]'; then
  echo "Warning: the server is emitting a non-empty reasoning channel. Thinking mode was measured this" >&2
  echo "session to never converge on coding tasks for this model -- --reasoning off should prevent it." >&2
fi
echo "Server ready on port $PORT."

# ---------- 5. write pi's config, merged so other providers are never clobbered -----------------------------
echo
echo "== Configuring pi =="
mkdir -p "$HOME/.pi/agent"
node -e '
const fs = require("fs");
const path = process.env.HOME + "/.pi/agent/models.json";
let cfg = { providers: {} };
if (fs.existsSync(path)) { try { cfg = JSON.parse(fs.readFileSync(path, "utf8")); } catch {} }
cfg.providers = cfg.providers || {};
cfg.providers["gemma4-kit"] = {
  baseUrl: "http://127.0.0.1:8114/v1",
  api: "openai-completions",
  apiKey: "local",
  compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
  models: [{ id: "gemma4", name: "gemma4-kit", contextWindow: 24576, maxTokens: 3072, reasoning: false }],
};
fs.writeFileSync(path, JSON.stringify(cfg, null, 2));
console.log("wrote " + path);
'
node -e '
const fs = require("fs");
const path = process.env.HOME + "/.pi/agent/settings.json";
let cfg = {};
if (fs.existsSync(path)) { try { cfg = JSON.parse(fs.readFileSync(path, "utf8")); } catch {} }
cfg.compaction = cfg.compaction || {};
// The defaults (reserveTokens 16384, keepRecentTokens 20000) exceed a 24576-token window and cause endless
// compaction, reproduced directly this session as a 143-round loop that made zero edits.
cfg.compaction.reserveTokens = 3072;
cfg.compaction.keepRecentTokens = 6000;
fs.writeFileSync(path, JSON.stringify(cfg, null, 2));
console.log("wrote " + path);
'

# ---------- 6. drop the calibrated AGENTS.md into the current directory ------------------------------------
echo
echo "== Writing AGENTS.md =="
cat > ./AGENTS.md << 'EOF'
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
echo "wrote ./AGENTS.md"

# ---------- 7. hand off to pi ------------------------------------------------------------------------------
echo
echo "== Ready. Starting pi. =="
exec pi --provider gemma4-kit --model gemma4

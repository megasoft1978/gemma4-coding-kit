#!/usr/bin/env bash
# Reverses gemma4-coding-kit's setup.sh, driven by the install manifest setup.sh writes at
# $HOME/.gemma4-coding-kit/install.env. Self-contained on purpose (same reason as setup.sh: no local checkout
# to source a shared file from over a pipe) -- it duplicates exactly one thing from setup.sh, the `ask()`
# helper, and nothing else. Everything it needs to know about what was installed, it reads from the manifest.
#
#   curl -fsSL https://raw.githubusercontent.com/megasoft1978/gemma4-coding-kit/main/uninstall.sh | bash
#
# Flags (remember `bash -s --` when piping one through curl):
#   --dry-run      print the plan and exit, touch nothing
#   --yes          skip confirmation prompts (the model file is still kept by default -- see --purge-model)
#   --purge-model  also delete the downloaded model file (the only irreversible, expensive-to-redo step here)
#   --keep-model   explicitly keep it without being asked (useful with --yes)
#   --all          also reverse llama.cpp/pi installs, but ONLY for whichever this kit's own install actually did
set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
PURGE_MODEL=0
KEEP_MODEL=0
DO_ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --purge-model) PURGE_MODEL=1 ;;
    --keep-model) KEEP_MODEL=1 ;;
    --all) DO_ALL=1 ;;
    --help|-h)
      # Only the CONTIGUOUS comment block at the top of the file -- a plain `grep '^#'` also matches every
      # "---------- N. section ------" header comment scattered through the file's body (same bug fixed in
      # setup.sh's --help).
      awk '/^#!/ { next } /^#/ { print; next } { exit }' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $1 (see --help)" >&2; exit 64 ;;
  esac
  shift
done

ask() {  # duplicated from setup.sh deliberately -- see header comment for why
  if [ "$DRY_RUN" = "1" ]; then echo "  (dry-run) would ask: $1"; return 0; fi  # so run() can show the full plan
  if [ "$ASSUME_YES" = "1" ]; then return 0; fi
  local prompt="$1" reply="n"
  # /dev/tty can exist and pass `-r` yet still fail at actual read time ("Device not configured") in some
  # sandboxed/detached-process environments with no controlling terminal at all -- confirmed by testing, not
  # just a theoretical case. `read`'s own exit status decides the fallback, so a failed read can never leave
  # `reply` unset under `set -u`.
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

run() {  # run <description> -- <command...>  ; honors --dry-run uniformly
  local desc="$1"; shift
  if [ "$DRY_RUN" = "1" ]; then
    echo "  (dry-run) would: $desc"
    return 0
  fi
  "$@"
}

KIT_DIR="$HOME/.gemma4-coding-kit"
INSTALL_ENV="$KIT_DIR/install.env"
AGENTS_LIST="$KIT_DIR/agents-md.list"

# Fallback defaults for when install.env is missing (older kit, or install never completed) -- deliberately
# the most conservative values: never delete AGENTS.md without a marker match, never delete the model without
# an explicit flag, never assume we installed a prerequisite.
PORT=8114
PROVIDER_KEY=gemma4-kit
MODEL_PATH=""
WE_INSTALLED_LLAMA_SERVER=0
WE_INSTALLED_PI=0
SETTINGS_HAD_COMPACTION=0
SETTINGS_PRIOR_RESERVE=""
SETTINGS_PRIOR_KEEP=""

MANIFEST_FOUND=0
if [ -f "$INSTALL_ENV" ]; then
  MANIFEST_FOUND=1
  # Read with grep/cut, never `source` -- this file is only ever written by setup.sh itself, but the same
  # habit that protects against a remote VERSION file (see the version-check design) costs nothing here either.
  PORT=$(grep '^PORT=' "$INSTALL_ENV" | cut -d= -f2- || echo "$PORT")
  PROVIDER_KEY=$(grep '^PROVIDER_KEY=' "$INSTALL_ENV" | cut -d= -f2- || echo "$PROVIDER_KEY")
  MODEL_PATH=$(grep '^MODEL_PATH=' "$INSTALL_ENV" | cut -d= -f2- || echo "")
  WE_INSTALLED_LLAMA_SERVER=$(grep '^WE_INSTALLED_LLAMA_SERVER=' "$INSTALL_ENV" | cut -d= -f2- || echo 0)
  WE_INSTALLED_PI=$(grep '^WE_INSTALLED_PI=' "$INSTALL_ENV" | cut -d= -f2- || echo 0)
  SETTINGS_HAD_COMPACTION=$(grep '^SETTINGS_HAD_COMPACTION=' "$INSTALL_ENV" | cut -d= -f2- || echo 0)
  SETTINGS_PRIOR_RESERVE=$(grep '^SETTINGS_PRIOR_RESERVE=' "$INSTALL_ENV" | cut -d= -f2- || echo "")
  SETTINGS_PRIOR_KEEP=$(grep '^SETTINGS_PRIOR_KEEP=' "$INSTALL_ENV" | cut -d= -f2- || echo "")
else
  echo "no install manifest found at $INSTALL_ENV -- falling back to this uninstaller's defaults." >&2
  echo "anything an older/newer setup.sh did differently will be left in place." >&2
fi

echo "== gemma4-coding-kit uninstall $([ "$DRY_RUN" = "1" ] && echo "(dry run)") =="
echo

# ---------- 1. stop the server, but only if it's genuinely ours --------------------------------------------
echo "== Server =="
MINE=""
for pid in $(pgrep -f "llama-server.*--port ${PORT}([^0-9]|$)" 2>/dev/null || true); do
  cmd=$(ps -o command= -p "$pid" 2>/dev/null || true)
  if [ -n "$MODEL_PATH" ] && printf '%s' "$cmd" | grep -qF -- "$MODEL_PATH"; then
    MINE="$MINE $pid"
  elif [ -z "$MODEL_PATH" ] && printf '%s' "$cmd" | grep -qF -- "--port $PORT"; then
    # No manifest to confirm the model path -- still port-matched, ask before touching it.
    MINE="$MINE $pid"
  fi
done
if [ -z "$MINE" ]; then
  echo "no server on port $PORT matching this kit's model -- nothing to stop"
else
  for pid in $MINE; do
    echo "found our server: pid $pid, model $MODEL_PATH"
    if ask "Stop it? [y/N]"; then
      run "kill pid $pid" bash -c "kill '$pid' 2>/dev/null || true"
      if [ "$DRY_RUN" != "1" ]; then
        for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -9 "$pid" 2>/dev/null || true
      fi
    else
      echo "left running -- port $PORT and $MODEL_PATH stay in use"
    fi
  done
fi
# Also report (never touch) a same-port process that is NOT ours.
for pid in $(pgrep -f "llama-server.*--port ${PORT}([^0-9]|$)" 2>/dev/null || true); do
  case " $MINE " in *" $pid "*) continue ;; esac
  echo "note: pid $pid is also on port $PORT but doesn't match our model path -- left alone"
done

# ---------- 2. models.json -- remove only our provider key --------------------------------------------------
echo
echo "== pi provider config =="
MODELS_JSON="$HOME/.pi/agent/models.json"
if [ -f "$MODELS_JSON" ] && [ "$DRY_RUN" != "1" ]; then
  PROVIDER_KEY="$PROVIDER_KEY" node -e '
    const fs = require("fs");
    const p = process.env.HOME + "/.pi/agent/models.json";
    const key = process.env.PROVIDER_KEY;
    const raw = fs.readFileSync(p, "utf8");
    let cfg;
    try { cfg = JSON.parse(raw); }
    catch (e) { console.error("models.json is not valid JSON (" + e.message + ") -- leaving it untouched"); process.exit(3); }
    if (!cfg.providers || typeof cfg.providers !== "object" || Array.isArray(cfg.providers)
        || !Object.prototype.hasOwnProperty.call(cfg.providers, key)) {
      console.log("skip: no providers." + key + " entry"); process.exit(0);
    }
    fs.writeFileSync(p + ".bak-gemma4-uninstall", raw);
    delete cfg.providers[key];
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
    console.log("removed providers." + key + "; " + Object.keys(cfg.providers).length + " provider(s) remain");
  '
elif [ -f "$MODELS_JSON" ]; then
  echo "  (dry-run) would remove providers.$PROVIDER_KEY from $MODELS_JSON"
else
  echo "no $MODELS_JSON -- nothing to do"
fi

# ---------- 3. settings.json -- REVERT compaction, don't just leave it --------------------------------------
# Leaving reserveTokens=3072/keepRecentTokens=6000 behind isn't harmless: those numbers are correct for a
# 24576-token window, and pi's compaction settings are global. Against a 200k-context cloud provider after
# uninstall, keepRecentTokens=6000 throws away context aggressively for no benefit -- a silent, quality-
# degrading failure mode, the worst kind to leave behind. So: restore what was there before, if anything;
# remove the keys entirely if we created the block; leave a key alone if it was changed since install.
echo
echo "== pi compaction settings =="
SETTINGS_JSON="$HOME/.pi/agent/settings.json"
if [ -f "$SETTINGS_JSON" ] && [ "$DRY_RUN" != "1" ]; then
  OUR_RESERVE=3072 OUR_KEEP=6000 \
  PRIOR_RESERVE="$SETTINGS_PRIOR_RESERVE" PRIOR_KEEP="$SETTINGS_PRIOR_KEEP" \
  SETTINGS_HAD_COMPACTION="$SETTINGS_HAD_COMPACTION" \
  node -e '
    const fs = require("fs");
    const p = process.env.HOME + "/.pi/agent/settings.json";
    const ours = { reserveTokens: Number(process.env.OUR_RESERVE), keepRecentTokens: Number(process.env.OUR_KEEP) };
    const prior = { reserveTokens: process.env.PRIOR_RESERVE, keepRecentTokens: process.env.PRIOR_KEEP };
    const weCreatedBlock = process.env.SETTINGS_HAD_COMPACTION !== "1";
    const raw = fs.readFileSync(p, "utf8");
    let cfg;
    try { cfg = JSON.parse(raw); }
    catch (e) { console.error("settings.json is not valid JSON -- leaving it untouched"); process.exit(3); }
    const c = cfg.compaction;
    if (!c || typeof c !== "object") { console.log("skip: no compaction block"); process.exit(0); }
    fs.writeFileSync(p + ".bak-gemma4-uninstall", raw);
    for (const k of ["reserveTokens", "keepRecentTokens"]) {
      if (c[k] !== ours[k]) { console.log("kept compaction." + k + "=" + c[k] + " (changed since install)"); continue; }
      if (prior[k] !== "" && prior[k] !== undefined) { c[k] = Number(prior[k]); console.log("restored compaction." + k + "=" + c[k]); }
      else { delete c[k]; console.log("removed compaction." + k); }
    }
    if (weCreatedBlock && Object.keys(c).length === 0) { delete cfg.compaction; console.log("removed empty compaction block"); }
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
  '
elif [ -f "$SETTINGS_JSON" ]; then
  echo "  (dry-run) would revert compaction.reserveTokens/keepRecentTokens (prior: reserve=${SETTINGS_PRIOR_RESERVE:-<none>} keep=${SETTINGS_PRIOR_KEEP:-<none>})"
else
  echo "no $SETTINGS_JSON -- nothing to do"
fi

# ---------- 4. AGENTS.md -- sha256 + marker decide whether it's safe to touch -------------------------------
echo
echo "== AGENTS.md files =="
if [ -f "$AGENTS_LIST" ]; then
  while IFS=$'\t' read -r sha path; do
    [ -z "$path" ] && continue
    if [ ! -f "$path" ]; then
      echo "skip: $path no longer exists"
      continue
    fi
    local_sha=$(shasum -a 256 "$path" 2>/dev/null | cut -d' ' -f1)
    has_marker=$(grep -qF "gemma4-coding-kit" "$path" 2>/dev/null && echo yes || echo no)
    if [ "$has_marker" = "no" ]; then
      echo "keep: $path -- not ours (no marker)"
      continue
    fi
    if [ "$local_sha" != "$sha" ]; then
      echo "keep: $path -- edited since install (marker present, content changed)"
      echo "      remove the trailing marker comment yourself if you want to disown it"
      continue
    fi
    echo "unmodified since install: $path"
    if ask "Delete it? [y/N]"; then
      run "delete $path" rm -f "$path"
      backup_line=$(grep '^AGENTS_MD_BACKUP=' "$INSTALL_ENV" 2>/dev/null | cut -d= -f2- || echo "")
      if [ -n "$backup_line" ] && [ -f "$backup_line" ] && [ "$backup_line" != "${path}.pre-gemma4-kit" ]; then
        : # backup path recorded doesn't match this file; leave it, don't guess
      elif [ -f "${path}.pre-gemma4-kit" ]; then
        run "restore ${path}.pre-gemma4-kit -> $path" mv "${path}.pre-gemma4-kit" "$path"
        [ "$DRY_RUN" = "1" ] || echo "restored your original AGENTS.md from the pre-install backup"
      fi
    else
      echo "kept: $path"
    fi
  done < "$AGENTS_LIST"
else
  echo "no record of any AGENTS.md written -- nothing to do"
fi

# ---------- 5. bookkeeping files, always safe to remove ------------------------------------------------------
echo
echo "== Kit bookkeeping =="
if [ "$MANIFEST_FOUND" = "1" ] || [ -d "$KIT_DIR" ]; then
  # An unmatched glob is passed through literally and rm -f ignores it, so no shell -c re-quoting is needed.
  run "remove $KIT_DIR/server.log, install.env, agents-md.list, *.partial" \
    rm -f "$KIT_DIR/server.log" "$INSTALL_ENV" "$AGENTS_LIST" "$KIT_DIR/models/"*.partial
  [ "$DRY_RUN" = "1" ] || echo "removed"
else
  echo "nothing to do"
fi

# ---------- 6. the model file -- report, ask once, default no ------------------------------------------------
echo
echo "== Model file =="
if [ -z "$MODEL_PATH" ] || [ ! -f "$MODEL_PATH" ]; then
  echo "no model file on record (or already gone) -- nothing to do"
else
  size_bytes=$(stat -f%z "$MODEL_PATH" 2>/dev/null || stat -c%s "$MODEL_PATH" 2>/dev/null || echo 0)
  size_gb=$(awk -v b="$size_bytes" 'BEGIN { printf "%.1f", b/1073741824 }')
  echo "Model file:  $MODEL_PATH"
  echo "Size:        ${size_gb}GB ($size_bytes bytes)"
  echo "Re-download: the same amount again from Hugging Face if you reinstall"
  if [ "$KEEP_MODEL" = "1" ]; then
    echo "kept (--keep-model)"
  elif [ "$PURGE_MODEL" = "1" ]; then
    run "delete $MODEL_PATH" rm -f "$MODEL_PATH"
    [ "$DRY_RUN" = "1" ] || echo "deleted"
  elif [ "$DRY_RUN" = "1" ]; then
    echo "  (dry-run) would ask whether to delete it -- default no; --purge-model deletes without asking"
  elif [ "$ASSUME_YES" = "1" ]; then
    # ask() returns yes unconditionally under --yes, which would make plain --yes delete the model file --
    # exactly the outcome the header comment promises will NOT happen. This is the one step --yes must never
    # answer on its own; only an explicit --purge-model may delete it, confirmed as a real bug by testing.
    echo "kept (--yes alone never deletes this -- pass --purge-model too if you want it gone)"
  elif ask "Delete it? [y/N]"; then
    run "delete $MODEL_PATH" rm -f "$MODEL_PATH"
    echo "deleted"
  else
    echo "kept -- delete it yourself later with: rm '$MODEL_PATH'"
  fi
fi
if [ "$DRY_RUN" != "1" ]; then
  rmdir "$HOME/.gemma4-coding-kit/models" 2>/dev/null || true
  rmdir "$HOME/.gemma4-coding-kit" 2>/dev/null || true
fi

# ---------- 7. prerequisites -- only what we installed, only under --all -------------------------------------
echo
echo "== Prerequisites (llama.cpp / pi) =="
if [ "$WE_INSTALLED_LLAMA_SERVER" = "1" ] || [ "$WE_INSTALLED_PI" = "1" ]; then
  # Plain if/then here, not `[ ... ] && { ask && run; }`: under `set -e`, a braces group that ends with a
  # failed `ask` (the user answering "no") is the final command of the && list, so the whole script would
  # exit right there -- before pi's prompt and before "Done".
  if [ "$WE_INSTALLED_LLAMA_SERVER" = "1" ]; then
    echo "this kit installed llama.cpp -- reverse with: brew uninstall llama.cpp"
    if [ "$DO_ALL" = "1" ]; then
      if ask "Uninstall llama.cpp now? [y/N]"; then run "brew uninstall llama.cpp" brew uninstall llama.cpp; else echo "kept llama.cpp"; fi
    fi
  fi
  if [ "$WE_INSTALLED_PI" = "1" ]; then
    echo "this kit installed pi -- reverse with: npm uninstall -g @earendil-works/pi-coding-agent"
    if [ "$DO_ALL" = "1" ]; then
      if ask "Uninstall pi now? [y/N]"; then run "npm uninstall -g pi" npm uninstall -g @earendil-works/pi-coding-agent; else echo "kept pi"; fi
    fi
  fi
  if [ "$DO_ALL" != "1" ]; then echo "(pass --all to be offered removal, since these are general-purpose tools)"; fi
else
  echo "neither was installed by this kit (or that isn't recorded) -- nothing offered"
fi

echo
if [ "$DRY_RUN" != "1" ]; then
  for f in "$HOME/.pi/agent/models.json.bak-gemma4-uninstall" "$HOME/.pi/agent/settings.json.bak-gemma4-uninstall"; do
    [ -f "$f" ] && echo "backup of the pre-uninstall file left at $f (delete it once you're happy)"
  done
fi
echo "== Done. =="

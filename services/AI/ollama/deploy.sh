#!/bin/bash
# deploy.sh (services/AI/ollama)
# Purpose: Deploy Ollama — the model provider the rest of DockHub's AI
# services talk to. See docker-compose.yml for why it publishes no port by
# default and why the GPU settings are written at deploy time rather than
# baked in.
#
# This is a single-instance service, under ~/docker/ollama/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Ollama on the shared 'ai-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/ollama"
LOGFILE="$INSTALL_DIR/deploy.log"

# Shared helpers — sourced from a git checkout if present, self-fetched
# otherwise so standalone curl usage still works with no extra steps.
LIB_DIR="$SOURCE_DIR/../../../lib"
if [[ ! -f "$LIB_DIR/common.sh" ]]; then
    LIB_DIR="$(mktemp -d)"
    curl -fsSL -o "$LIB_DIR/common.sh" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
    curl -fsSL -o "$LIB_DIR/gpu.sh"    "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/gpu.sh"
fi
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/gpu.sh"

check_prerequisites

# Providers are alternatives, not companions — see lib/common.sh.
ensure_single_provider "ollama" || exit 0

mkdir -p "$INSTALL_DIR"

# ai-net, not main-net: there is no web UI here for NPM to serve.
ensure_ai_net
# This provider is the hub between the two consumer groups — see
# lib/common.sh, ensure_models_net. Both networks must exist before it starts.
ensure_models_net

# ── GPU ─────────────────────────────────────────────────────────────────
# Runs on every deploy, not just the first: a user who installs the NVIDIA
# driver later should be able to rerun this and get GPU acceleration without
# removing anything. Sets GPU_DOCKER_OK — CAN the GPU be used.
echo
gpu_setup

# SHOULD it be used, is a different question, and the answer belongs to the
# user rather than to the probe. Read before .env is written so a first run
# can ask; persisted afterwards so a rerun never re-decides it silently.
# This used to be derived from GPU_DOCKER_OK alone, which meant a working
# toolkit forced GPU use with no supported way to opt out — the override
# file is regenerated every run, so editing it by hand didn't survive.
STORED_ACCEL=$(read_env_value "AI_ACCELERATION" "$INSTALL_DIR/.env")
gpu_resolve_acceleration "$STORED_ACCEL"

# One shared location for every AI service, asked once and remembered in
# ~/docker/.dockhub-env. Resolved HERE, before the branch, so the question
# lands in the same place in every provider's flow — it used to sit inside
# the fresh-deploy branch here and before it in llama.cpp and LocalAI, which
# meant the order depended on which service you happened to install first.
ENV_MODELS_PATH=$(read_env_value "AI_MODELS_PATH" "$INSTALL_DIR/.env")
if [[ -z "$ENV_MODELS_PATH" ]]; then
    resolve_ai_models_dir
    ENV_MODELS_PATH="$AI_MODELS_DIR/ollama"
fi

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    echo
    print_info "Ollama has no login and no web interface — it's an API other services use."
    print_info "Pair it with Open WebUI (in this repo) for a chat interface."
    echo

    prompt_mem_limit "ollama" "4g"

    # Offered, not default. An unauthenticated API on the LAN is a real
    # exposure, and consumers inside Docker never need it.
    echo
    print_warn "Ollama's API has NO authentication. A published port means anyone who"
    print_warn "can reach this machine can use your models and read your prompts."
    print_info "Other DockHub services reach it as http://ollama:11434 without a port."
    prompt_host_port "11434"

    # ── Context length ──────────────────────────────────────────────────
    # Ollama picks this itself — 4k, 32k or 256k "based on VRAM" — and on a
    # modest card it picks 4k. That is fine for chat and quietly useless for
    # agents, which spend most of the window before you type anything:
    # system prompt, tool schemas, skills. Measured on a live box, OpenHands
    # with gemma4:e4b opened at 17742 tokens — over four times the entire
    # 4096 window, on an empty conversation.
    #
    # The trap is that nothing reports it. The model advertises its trained
    # capacity (gemma4:e4b says 131072) and every consumer believes that
    # number, including DockHub's own HERMES_MIN_CONTEXT gate — while the
    # server allocates 4096 and silently truncates.
    #
    # So it is asked here, once, with its price stated.
    echo
    print_info "Context length — how much the model can hold at once."
    print_warn "Ollama's automatic choice is VRAM-based and is often 4096."
    print_warn "That is too small for agents: OpenHands opens at ~17700 tokens"
    print_warn "before your first word, and Hermes asks for 64000."
    print_warn "Raising it costs GPU memory in proportion. Too high and the"
    print_warn "model spills to CPU or fails to load — lower it if that happens."
    print_info "Blank = let Ollama decide (its default behaviour)."
    read -rp "Context length in tokens [32768, blank for automatic]: " OLLAMA_CTX || OLLAMA_CTX=""
    OLLAMA_CTX="${OLLAMA_CTX:-32768}"
    if [[ ! "$OLLAMA_CTX" =~ ^[0-9]+$ ]]; then
        print_warn "Not a number — leaving it to Ollama."
        OLLAMA_CTX=""
    fi

    # Recorded per service, so changing the global default later never moves
    # a running deployment out from under itself.
    cat > "$INSTALL_DIR/.env" <<EOF
OLLAMA_VERSION=latest
OLLAMA_KEEP_ALIVE=5m
AI_ACCELERATION=$AI_ACCELERATION
AI_MODELS_PATH=$ENV_MODELS_PATH
EOF
    [[ -n "$OLLAMA_CTX" ]] && echo "OLLAMA_CONTEXT_LENGTH=$OLLAMA_CTX" >> "$INSTALL_DIR/.env"
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    print_info "Generated .env at $INSTALL_DIR."
    # No secrets file: Ollama generates no credentials, because it has none.
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    # OFFERED, not just announced — and here it is more than tidiness. This
    # container is now the hub joining 'ai-net' and 'models-net' (see
    # lib/common.sh, ensure_models_net). A kept compose from before that
    # change is on ai-net alone, so a Flowise/Langflow/Dify that has already
    # moved to models-net cannot reach this provider AT ALL. Declining is
    # still fine — it just has to be a decision, not a default.
    offer_compose_update "$INSTALL_DIR/docker-compose.yml" "$SOURCE_DIR/docker-compose.yml" \
        "rm $INSTALL_DIR/docker-compose.yml && bash $0"
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

# Appends on a deployment made before this setting existed, replaces on any
# other. Without this an older .env would be re-prompted on every single run.
set_env_value "AI_ACCELERATION" "$AI_ACCELERATION" "$INSTALL_DIR/.env"

ENV_MEM_LIMIT=$(read_env_value "MEM_LIMIT" "$INSTALL_DIR/.env")
ENV_HOST_PORT=$(read_env_value "HOST_PORT" "$INSTALL_DIR/.env")

# Appends on a deployment made before models moved out of a named volume,
# so an older .env gains the key instead of failing on an unset bind source.
set_env_value "AI_MODELS_PATH" "$ENV_MODELS_PATH" "$INSTALL_DIR/.env"

# Created and PROVEN writable before compose starts. A bind mount the
# container can't write to fails later, mid-download, with an error that
# reads like a network problem — see prepare_model_dir() in lib/common.sh.
prepare_model_dir "$ENV_MODELS_PATH" "ollama/ollama:$(read_env_value "OLLAMA_VERSION" "$INSTALL_DIR/.env")" \
    || print_error "Fix the permissions above and rerun."
print_info "Models: $ENV_MODELS_PATH"

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from what .env and the GPU probe say.
OVERRIDE_BODY=$(
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    if [[ -n "$ENV_HOST_PORT" ]]; then
        echo "    ports:"
        echo "      - \"$ENV_HOST_PORT:11434\""
    fi
    if (( GPU_ENABLED )); then
        # GPU_ENABLED, not GPU_DOCKER_OK: written only when a test container
        # proved the GPU is reachable AND the user chose to use it. Compose's
        # device reservation is the modern equivalent of `docker run --gpus all`.
        echo "    deploy:"
        echo "      resources:"
        echo "        reservations:"
        echo "          devices:"
        echo "            - driver: nvidia"
        echo "              count: all"
        echo "              capabilities: [gpu]"
    fi
    true
)
if [[ -n "$OVERRIDE_BODY" ]]; then
    { echo "services:"; echo "  ollama:"; printf '%s\n' "$OVERRIDE_BODY"; } \
        > "$INSTALL_DIR/docker-compose.override.yml"
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

[[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'ollama' container."
[[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published — remember there is no authentication behind it."
(( GPU_ENABLED )) && print_info "GPU acceleration enabled in the compose override."

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Ollama..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Ollama. Check log: $LOGFILE"

# ── Self-test ───────────────────────────────────────────────────────────
# "Container started" is not "the API answers".
#
# Uses the shared helper rather than a bare retry loop. `docker exec` fails
# identically whether the container is still starting or already dead, so a
# plain loop reports "the API did not answer" for a crash — the exact failure
# that cost twenty minutes on llama.cpp before the helper existed. This one
# checks the container's state each round and prints its logs when it stops.
print_info "Waiting for the API to answer..."
set +e
wait_for_container_ready "ollama" "ollama list" 20 2
API_RC=$?
set -e
API_OK=$(( API_RC == 0 ? 1 : 0 ))

# ── First model ─────────────────────────────────────────────────────────
# Without this the realistic path is: deploy Ollama ✅, deploy a chat UI ✅,
# open it, and find an empty model list with nothing explaining why. A
# provider with no model is not a working deployment.
MODEL_COUNT=0
if (( API_OK )); then
    MODEL_COUNT=$(docker exec ollama ollama list 2>/dev/null | tail -n +2 | grep -c . || true)
fi

# Offered on EVERY run, not only when the count is zero.
#
# The guard here used to be `MODEL_COUNT == 0`, which meant the menu vanished
# for good the moment you had one model. Adding a second, or importing a GGUF
# downloaded after the first deploy, was then only possible from the CLI —
# while llama.cpp's own menu appears on every rerun with a "keep it" option.
# Two providers in the same catalogue behaved differently for no reason a
# reader could see.
#
# Ollama serves MANY models at once, so the wording differs from llama.cpp's:
# there, picking another REPLACES the one model it can serve; here it is an
# addition and nothing is lost.
if (( API_OK )); then
    echo
    if (( MODEL_COUNT == 0 )); then
        print_info "No models are installed yet — Ollama can't answer anything without one."
    else
        print_info "$MODEL_COUNT model(s) already installed:"
        docker exec ollama ollama list 2>/dev/null | tail -n +2 \
            | awk 'NF {printf "     · %s\n", $0}' || true
        print_info "Ollama serves several at once — adding one replaces nothing."
    fi
    echo
    # ── What is already on this machine ──────────────────────────────────
    #
    # Scans the SHARED PARENT of the provider directories, not Ollama's own.
    # Every provider gets its own subdirectory under AI_MODELS_DIR, so a
    # llama.cpp download is a SIBLING of Ollama's store and never inside it.
    # This is the reason the old flow could never notice one.
    #
    # Two things make the obvious scan wrong, both found on a live host:
    #
    #   · llama.cpp stores in the Hugging Face cache layout. The only things
    #     named *.gguf are SYMLINKS under snapshots/; the weights themselves
    #     are hash-named blobs with no extension. `ls *.gguf` finds nothing
    #     even when two models are sitting there.
    #
    #   · A repo can ship an mmproj-*.gguf — a vision projector, a companion
    #     to a model and not a model. Ollama's Modelfile has no instruction
    #     for one (ADAPTER is LoRA), so offering it would hand someone a
    #     model that cannot answer. It is filtered out, and a model that has
    #     one is flagged, because importing that model loses its vision.
    # The scan root is the parent of this provider's directory — which is only
    # a shared models tree when the path follows the convention. AI_MODELS_PATH
    # can be set by hand, and `AI_MODELS_PATH=/models` makes the parent `/`,
    # turning a helpful lookup into a find over the entire filesystem.
    # Refuse the obviously-wrong roots rather than scanning them.
    MODELS_PARENT="$(dirname "$ENV_MODELS_PATH")"
    case "$MODELS_PARENT" in
        / | /home | /mnt | /media | /root | "$HOME")
            print_info "Skipping the local-file scan: '$ENV_MODELS_PATH' has no models"
            print_info "directory of its own to look beside."
            MODELS_PARENT=""
            ;;
    esac
    # Two parallel arrays on purpose. The weights live in a hash-named blob,
    # but the human name is on the SYMLINK that points at it. Keeping only the
    # resolved path made the suggested model name a 64-character sha256 — the
    # blob's filename — which is what a live run offered.
    GGUF_PATHS=(); GGUF_NAMES=(); GGUF_LABELS=(); GGUF_NOTES=(); GGUF_DUPS=()
    if [[ -n "$MODELS_PARENT" && -d "$MODELS_PARENT" ]]; then
        while IFS= read -r g; do
            [[ -z "$g" ]] && continue
            base="$(basename "$g")"
            # 'mmproj' ANYWHERE in the name, not as a prefix. The first repo
            # this was written against called it mmproj-Ornith-1.5-9B-f16.gguf;
            # Google ships gemma-4-E4B-it-mmproj.gguf. A prefix match passed
            # the second straight through and offered a vision projector as a
            # model. One naming sample was not a convention.
            shopt -s nocasematch
            if [[ "$base" == *mmproj* ]]; then shopt -u nocasematch; continue; fi
            shopt -u nocasematch
            real="$(readlink -f "$g" 2>/dev/null || echo "$g")"
            [[ -f "$real" ]] || continue
            note=""
            # A projector beside it means this model is multimodal and Ollama
            # would import only half of it.
            # Same reason: the companion file may be named either way round.
            if compgen -G "$(dirname "$g")/*mmproj*.gguf" >/dev/null 2>&1 \
            || compgen -G "$(dirname "$g")/*MMPROJ*.gguf" >/dev/null 2>&1; then
                note="⚠ has a vision projector — Ollama imports the text half only"
            fi
            # Which provider fetched it. Every provider owns one subdirectory
            # under the shared parent, so the first path component after it
            # names the owner. Worth showing: with two providers installed the
            # list becomes a flat set of filenames with no way to tell which
            # is which, and the answer changes what importing costs — llama.cpp
            # reads its own file in place, Ollama copies.
            rel="${g#"$MODELS_PARENT"/}"; owner="${rel%%/*}"
            [[ "$owner" == "$rel" ]] && owner="?"

            # Is this exact file ALREADY in Ollama's store?
            #
            # A live run imported a model that was listed as installed three
            # lines above, copied 4.9 GB to do it, and finished with the same
            # model count it started with — Ollama reported "using existing
            # layer" for every layer and wrote nothing.
            #
            # The check is free, because both stores are content-addressed by
            # the same function: the Hugging Face cache names a blob with the
            # sha256 of its contents, and Ollama names its own blobs
            # sha256-<the same hex>. So this is a filename lookup, not a 5 GB
            # hash. If the layout ever differs the lookup simply misses and the
            # behaviour is what it was before — never a wrong claim.
            hex="$(basename "$real")"
            if [[ "$hex" =~ ^[0-9a-f]{64}$ ]] \
               && [[ -e "$ENV_MODELS_PATH/models/blobs/sha256-$hex" ]]; then
                dup="  ✓ already imported"
            else
                dup=""
            fi
            GGUF_PATHS+=("$real")
            GGUF_NAMES+=("$base")
            GGUF_LABELS+=("$base   $(du -h "$real" 2>/dev/null | cut -f1)   from $owner$dup")
            GGUF_NOTES+=("$note")
            GGUF_DUPS+=("$dup")
        done < <(find "$MODELS_PARENT" -name '*.gguf' 2>/dev/null | sort)
    fi

    echo "   1) llama3.2:3b     ~2 GB   fast, modest quality — fine on CPU"
    echo "   2) llama3.1:8b     ~5 GB   the usual default; wants a GPU or patience"
    echo "   3) qwen2.5-coder:7b ~5 GB  tuned for code"
    # Labels 4 and 5 describe what happens, in the same voice as 1 to 3.
    #
    # Four used to read "Any model on Hugging Face — 45k GGUF repos". Both
    # halves were wrong by the time it printed: the option now offers Ollama's
    # library as well, so naming one source was a lie about what it does, and
    # "45k" is a figure that goes stale on its own — the same reason no service
    # count is printed on the social card.
    #
    # Five said "Import a .gguf", which is the mechanism, not the choice, and
    # said nothing about the one thing that separates it from 4: Ollama copies
    # the weights, so the file ends up on this disk twice.
    echo "   4) Another model — Ollama's library or Hugging Face"
    if (( ${#GGUF_PATHS[@]} > 0 )); then
        echo "   5) A file already on this disk — no download, but Ollama copies it:"
        for i in "${!GGUF_LABELS[@]}"; do
            printf "        %d. %s\n" "$((i+1))" "${GGUF_LABELS[$i]}"
            # The projector caveat gets its own line. Appended, it pushed the
            # row past any sensible terminal width and buried the size and the
            # source it needed to sit beside.
            [[ -n "${GGUF_NOTES[$i]}" ]] && printf "           %s\n" "${GGUF_NOTES[$i]}"
        done
    fi
    # Wording follows the situation: with nothing installed, declining leaves
    # Ollama unable to answer and should say so; with models present, declining
    # is the ordinary answer and should not read like a warning.
    if (( MODEL_COUNT == 0 )); then
        echo "   0) Skip — I'll pull one myself later"
    else
        echo "   0) Keep what I have — add nothing"
    fi
    echo
    read -rp "Pull a model now? " model_choice
    OLLAMA_MODEL=""
    OLLAMA_MODEL_GB=0
    # Both initialised, not just the one the guard tests. They are always set
    # together today, so this changes nothing — and that is exactly the state
    # install_dockhub.sh was in before an unset read aborted a whole run under
    # `set -u`. Declaring costs a line; the failure costs the run.
    IMPORT_SRC=""
    IMPORT_NAME_SRC=""
    case "$model_choice" in
        1) OLLAMA_MODEL="llama3.2:3b";      OLLAMA_MODEL_GB=3 ;;
        2) OLLAMA_MODEL="llama3.1:8b";      OLLAMA_MODEL_GB=6 ;;
        3) OLLAMA_MODEL="qwen2.5-coder:7b"; OLLAMA_MODEL_GB=6 ;;
        4)
            # ASK WHICH SOURCE FIRST, then take the name in that source's own
            # notation.
            #
            # This offered Hugging Face only, and required typing the "hf.co/"
            # prefix by hand — a syntax the user has already communicated by
            # choosing it. Ollama's own library, which is where its three
            # suggestions above come from, could not be browsed at all: any
            # model not in that hardcoded list of three was unreachable from
            # this menu.
            #
            # Each branch prints its own browse URL, because "you give the
            # name" is only useful once you know where to look the name up.
            echo
            echo "   Which source?"
            echo "     1) Ollama's own library    https://ollama.com/library"
            echo "     2) Hugging Face            https://huggingface.co/models?library=gguf"
            read -rp "   Source (1-2): " src_choice
            src_choice="${src_choice//[[:space:]]/}"
            case "$src_choice" in
                1)
                    print_info "  Names look like 'gemma3:4b' or 'qwen2.5-coder:7b' — model:tag."
                    read -rp "  Model: " ol_name
                    ol_name="${ol_name//$'\r'/}"; ol_name="${ol_name//[[:space:]]/}"
                    if [[ "$ol_name" =~ ^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]]; then
                        OLLAMA_MODEL="$ol_name"
                        OLLAMA_MODEL_GB=5
                    elif [[ -n "$ol_name" ]]; then
                        print_warn "  That does not look like a model name — skipped."
                    fi
                    ;;
                2)
                    print_info "  Give it as <user>/<repo>, optionally with ':<quant>'."
                    print_info "  The quant defaults to Q4_K_M when the repo has one."
                    print_info "  Example: bartowski/Llama-3.2-3B-Instruct-GGUF:Q8_0"
                    print_warn "  GGUF only. Raw safetensors weights cannot be pulled this way."
                    read -rp "  Repo: " hf_repo
                    hf_repo="${hf_repo//$'\r'/}"; hf_repo="${hf_repo//[[:space:]]/}"
                    # A pasted full URL or an already-prefixed reference is
                    # accepted rather than rejected — both are what someone
                    # naturally has in hand, and the prefix is this script's
                    # job to add, not the user's to remember.
                    hf_repo="${hf_repo#https://}"; hf_repo="${hf_repo#http://}"
                    hf_repo="${hf_repo#huggingface.co/}"; hf_repo="${hf_repo#hf.co/}"
                    if [[ "$hf_repo" =~ ^[^/]+/[^/]+$ ]]; then
                        OLLAMA_MODEL="hf.co/$hf_repo"
                        print_info "  Pulling as: $OLLAMA_MODEL"
                        # The size is unknown before the pull, so the disk check
                        # below gets a figure big enough to be worth a warning
                        # rather than a number invented to look precise.
                        OLLAMA_MODEL_GB=5
                    elif [[ -n "$hf_repo" ]]; then
                        print_warn "  Expected <user>/<repo> — skipped."
                    fi
                    ;;
                *) print_warn "  Not 1 or 2 — skipped." ;;
            esac
            ;;
        5)
            if (( ${#GGUF_PATHS[@]} > 0 )); then
                echo
                read -rp "  Which file? (1-${#GGUF_PATHS[@]}): " gi
                if [[ "$gi" =~ ^[0-9]+$ ]] && (( gi >= 1 && gi <= ${#GGUF_PATHS[@]} )); then
                    # Ask before spending the copy, not after. Re-importing an
                    # identical file is not harmful — Ollama recognises every
                    # layer and writes nothing — but it still costs a full
                    # staging copy of several gigabytes to reach that
                    # conclusion, and a live run did exactly that.
                    if [[ -n "${GGUF_DUPS[$((gi-1))]}" ]]; then
                        print_warn "  That file is already in Ollama's store — the same content,"
                        print_warn "  byte for byte. Importing it again copies it, then Ollama"
                        print_warn "  finds every layer already present and writes nothing new."
                        read -rp "  Import it anyway, under a different name? (y/N): " dup_ok
                        if [[ "${dup_ok,,}" != "y" ]]; then
                            print_info "  Skipped."
                            gi=""
                        fi
                    fi
                fi
                if [[ "$gi" =~ ^[0-9]+$ ]] && (( gi >= 1 && gi <= ${#GGUF_PATHS[@]} )); then
                    IMPORT_SRC="${GGUF_PATHS[$((gi-1))]}"
                    IMPORT_NAME_SRC="${GGUF_NAMES[$((gi-1))]}"
                else
                    print_warn "  Not one of the listed numbers — skipped."
                fi
            else
                # Option 5 is only printed when something was found, but a
                # number can still be typed. Say why nothing happened rather
                # than returning to a silent prompt.
                print_warn "  No .gguf files were found on this machine — nothing to import."
            fi
            ;;
        *)
            if (( MODEL_COUNT == 0 )); then
                print_info "Skipped. Pull one later with: docker exec -it ollama ollama pull <model>"
            else
                print_info "Keeping the $MODEL_COUNT model(s) already installed."
            fi
            ;;
    esac

    if [[ -n "$IMPORT_SRC" ]]; then
        # From the symlink's name, not the blob's. Trailing .gguf removed and
        # lowercased, because an Ollama model name is typed at a prompt.
        default_name="$(basename "${IMPORT_NAME_SRC%.gguf}" | tr 'A-Z' 'a-z')"
        read -rp "  Name it in Ollama [$default_name]: " import_name
        import_name="${import_name:-$default_name}"
        import_name="${import_name%.gguf}"
        stage="$ENV_MODELS_PATH/.import.gguf"
        # Hard link first: both directories sit under one parent, so when it
        # works it is instant and free. `ollama create` still copies the weights
        # into its own content-addressed store — that copy is unavoidable — but
        # staging should not add a third.
        if ln "$IMPORT_SRC" "$stage" 2>/dev/null; then
            print_info "  Staged by hard link — no extra space used for this step."
        else
            # Do NOT name a cause here. This said "different filesystem", which
            # was wrong on the machine it was written for: both paths were on
            # one disk, and the real reason was almost certainly
            # fs.protected_hardlinks — on by default in Ubuntu, and it forbids
            # linking a file you do not own. The blob belonged to root, written
            # by another provider's container. Several causes produce this exact
            # failure; picking one and stating it as fact is how a message
            # sends someone to fix the wrong thing.
            print_warn "  Could not hard-link the file, so this stage needs a full copy."
            print_info "  Usually one of: a different filesystem, or the kernel's"
            print_info "  fs.protected_hardlinks, which forbids linking a file you do not own"
            print_info "  (weights fetched by another provider's container belong to root)."
            print_info "  Copying $(du -h "$IMPORT_SRC" 2>/dev/null | cut -f1) — this is temporary and removed afterwards."
            cp "$IMPORT_SRC" "$stage" || { print_warn "  Copy failed — skipped."; stage=""; }
        fi
        if [[ -n "$stage" ]]; then
            printf 'FROM /root/.ollama/.import.gguf\n' > "$ENV_MODELS_PATH/.import.Modelfile"
            if docker exec ollama ollama create "$import_name" -f /root/.ollama/.import.Modelfile; then
                MODEL_COUNT=$(docker exec ollama ollama list 2>/dev/null | tail -n +2 | grep -c . || true)
                print_info "  Imported as '$import_name'."
                print_warn "  The weights now exist twice: the original, and Ollama's own copy."
            else
                print_warn "  Import failed. The original file is untouched."
            fi
            rm -f "$stage" "$ENV_MODELS_PATH/.import.Modelfile"
        fi
    fi

    if [[ -n "$OLLAMA_MODEL" ]]; then
        if ! check_free_disk_gb "$OLLAMA_MODEL_GB" "$ENV_MODELS_PATH"; then
            read -rp "Not much room. Download anyway? (y/N): " disk_answer
            [[ "${disk_answer,,}" == "y" ]] || OLLAMA_MODEL=""
        fi
    fi

    if [[ -n "$OLLAMA_MODEL" ]]; then
        print_info "Pulling $OLLAMA_MODEL — this is a large download, progress is shown below."
        if docker exec ollama ollama pull "$OLLAMA_MODEL"; then
            MODEL_COUNT=$(docker exec ollama ollama list 2>/dev/null | tail -n +2 | grep -c . || true)
            print_info "Model $OLLAMA_MODEL is ready."
        else
            print_warn "The pull failed. Retry with: docker exec -it ollama ollama pull $OLLAMA_MODEL"
        fi
    fi
fi

echo
echo "──────────────────────────────────────────────"
echo "🔌 API (internal):  http://ollama:11434   ← how other services reach it"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(host_lan_ip || true)
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🔌 API (host):      http://$SERVER_IP:$ENV_HOST_PORT   ⚠️ no authentication"
fi
# "CPU only" reads as a failure when it was a decision, so the two cases are
# spelled differently.
if (( GPU_ENABLED )); then
    ACCEL_LINE="GPU ✅"
elif (( GPU_DOCKER_OK )); then
    ACCEL_LINE="CPU only — by choice (AI_ACCELERATION=cpu in .env)"
else
    ACCEL_LINE="CPU only — no usable GPU on this host"
fi
echo "🖥️  Acceleration:    $ACCEL_LINE"
echo "📦 Models:          $MODEL_COUNT installed"
echo "📁 Model files:     $ENV_MODELS_PATH"
echo "📜 Log:             $LOGFILE"
echo "──────────────────────────────────────────────"
echo
if (( API_OK )); then
    print_info "Self-test passed — the API answered."
elif (( API_RC == 1 )); then
    # The helper already printed the container's own logs above; repeating
    # "check the logs" underneath them would be noise.
    print_warn "Ollama stopped instead of starting. Its output is shown above."
else
    print_warn "The API did not answer within 40 seconds. Check:"
    print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f ollama"
fi
if (( MODEL_COUNT == 0 )); then
    echo
    print_warn "No model installed — anything you point at Ollama will show an empty list."
    print_warn "  docker exec -it ollama ollama pull llama3.2:3b"
fi
echo
echo "📌 There is no web interface and no login — Ollama is an API."
echo "   Deploy Open WebUI next for a chat interface; it will find this"
echo "   automatically at http://ollama:11434 over 'ai-net'."
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"
echo "Models:    docker exec -it ollama ollama [list|pull <model>|rm <model>]"

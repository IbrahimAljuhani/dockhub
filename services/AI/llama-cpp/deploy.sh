#!/bin/bash
# deploy.sh (services/AI/llama-cpp)
# Purpose: Deploy llama.cpp's server as a model provider — see
# docker-compose.yml for how it differs from Ollama (one model, not many)
# and why the image tag is the entire GPU decision.
#
# This is a single-instance service, under ~/docker/llama-cpp/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy llama.cpp's server on the shared 'ai-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/llama-cpp"
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

# Before anything is created: providers share one GPU's memory, so a second
# one running alongside means either OOM or constant swapping.
ensure_single_provider "llama-cpp" || exit 0

mkdir -p "$INSTALL_DIR"

# ai-net only. No main-net: no web interface, no authentication.
ensure_ai_net

# Detects, reports, and offers to install the container toolkit — never
# installs a driver silently. Sets GPU_DOCKER_OK: CAN the GPU be used.
gpu_setup

# SHOULD it be, is the user's call, not the probe's. Persisted in .env so a
# rerun honours it instead of re-deriving it. See lib/gpu.sh for why "the
# hardware works" is not the same as "use the hardware".
STORED_ACCEL=$(read_env_value "AI_ACCELERATION" "$INSTALL_DIR/.env")
gpu_resolve_acceleration "$STORED_ACCEL"

# One shared location for every AI service, asked once and remembered in
# ~/docker/.dockhub-env. Resolved before the disk check, because the check is
# only meaningful against the filesystem the download will actually land on.
ENV_MODELS_PATH=$(read_env_value "AI_MODELS_PATH" "$INSTALL_DIR/.env")
if [[ -z "$ENV_MODELS_PATH" ]]; then
    resolve_ai_models_dir
    ENV_MODELS_PATH="$AI_MODELS_DIR/llama-cpp"
fi

# ── The model menu, shared by both paths ────────────────────────────────
# Mandatory here, unlike Ollama: llama-server loads a model at startup and
# serves that one, so with nothing to load there is no service.
#
# A rerun used to print "edit LLAMA_ARG_HF_REPO in .env and rerun" and then
# offer no way to do it — the only route to a different model was a text
# editor. Both paths call this now. Deliberately one function rather than a
# second menu: the repo names below were each checked to exist, and a copy
# would have to be kept in step with that by hand.
#
# $1 = the repo currently configured, empty on a fresh deploy.
# Sets HF_REPO_VALUE, MODEL_GB and MODEL_CHANGED.
pick_llama_model() {
    local current="$1" choice
    MODEL_CHANGED=0
    echo
    if [[ -n "$current" ]]; then
        print_info "Currently serving: $current"
        print_warn "llama.cpp serves ONE model, so picking another REPLACES this one."
        print_info "The old weights stay in $ENV_MODELS_PATH,"
        print_info "so switching back later re-downloads nothing."
    else
        print_info "llama.cpp serves ONE model. Pick it now — rerun this script"
        print_info "later to change it."
    fi
    echo
    [[ -n "$current" ]] && echo "   0) Keep it — just restart"
    # Note the different owners: the ggml-org org (llama.cpp's own) publishes
    # a small set, and the rest of the GGUF world lives mostly under
    # bartowski. Guessing a prefix produces a repo that looks plausible and
    # 401s at download time.
    echo "   1) ggml-org/gemma-3-1b-it-GGUF               ~1 GB  tiny, fast, fine on CPU"
    echo "   2) ggml-org/gemma-3-4b-it-GGUF               ~3 GB  small, good general quality"
    echo "   3) bartowski/Qwen2.5-Coder-7B-Instruct-GGUF  ~5 GB  tuned for code"
    echo "   4) Enter a Hugging Face repo myself"
    read -rp "Choice ($( [[ -n "$current" ]] && echo 0 || echo 1 )-4): " choice
    case "$choice" in
        1) HF_REPO_VALUE="ggml-org/gemma-3-1b-it-GGUF";              MODEL_GB=2; MODEL_CHANGED=1 ;;
        2) HF_REPO_VALUE="ggml-org/gemma-3-4b-it-GGUF";              MODEL_GB=4; MODEL_CHANGED=1 ;;
        3) HF_REPO_VALUE="bartowski/Qwen2.5-Coder-7B-Instruct-GGUF"; MODEL_GB=7; MODEL_CHANGED=1 ;;
        4)
            echo
            echo "Format: user/repo  or  user/repo:QUANT   (quant defaults to Q4_K_M)"
            echo "Browse: https://huggingface.co/models?library=gguf"
            while true; do
                read -rp "Hugging Face repo: " HF_REPO_VALUE
                # user/repo, optionally :QUANT. Catches a pasted full URL or
                # a bare model name, both of which fail much later otherwise
                # — after the container is up and the pull has begun.
                if [[ "$HF_REPO_VALUE" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(:[A-Za-z0-9._-]+)?$ ]]; then
                    break
                fi
                echo "Expected user/repo (e.g. ggml-org/gemma-3-4b-it-GGUF), not a URL." >&2
            done
            MODEL_GB=8; MODEL_CHANGED=1
            ;;
        *)
            # A typo must not tear down a working deployment, so this only
            # aborts on the fresh path, where there is nothing to protect.
            if [[ -n "$current" ]]; then
                HF_REPO_VALUE="$current"; MODEL_GB=0
                [[ "$choice" == "0" ]] || print_warn "Not a valid choice — keeping $current."
            else
                print_error "Invalid choice. Nothing was deployed."
            fi
            ;;
    esac
    # Picking the model already being served from the menu is a "keep", not a
    # switch — otherwise it announces a change and re-runs the disk check for
    # a download that will never happen.
    [[ "$HF_REPO_VALUE" == "$current" ]] && MODEL_CHANGED=0
    return 0
}

# Unlike Ollama, the model isn't optional here — llama-server has nothing to
# serve without one — so running short of disk is a decision point rather
# than something that can be skipped past. $1 = what to say on refusal.
confirm_model_disk() {
    (( MODEL_CHANGED )) || return 0
    check_free_disk_gb "$MODEL_GB" "$ENV_MODELS_PATH" && return 0
    local answer
    read -rp "Not much room. Download anyway? (y/N): " answer
    [[ "${answer,,}" == "y" ]] || print_error "$1"
    return 0
}

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."

    # The one setting worth revisiting on a rerun. Everything else in .env
    # (port, memory limit) is stable; the model is the thing people actually
    # come back to change, and it is the only one with no other route.
    CURRENT_REPO=$(read_env_value "LLAMA_ARG_HF_REPO" "$INSTALL_DIR/.env")
    if [[ -n "$CURRENT_REPO" ]]; then
        pick_llama_model "$CURRENT_REPO"
        if (( MODEL_CHANGED )); then
            confirm_model_disk "Keeping $CURRENT_REPO. Nothing was changed."
            set_env_value "LLAMA_ARG_HF_REPO" "$HF_REPO_VALUE" "$INSTALL_DIR/.env"
            print_info "Switching to $HF_REPO_VALUE — it downloads on the next start."
        fi
    fi
else
    pick_llama_model ""
    confirm_model_disk "Nothing was deployed."

    echo
    prompt_mem_limit "llama-cpp" "8g"

    echo
    print_warn "llama.cpp's API has NO authentication, exactly like Ollama's."
    print_info "Other DockHub services reach it as http://llama-cpp:8080 without a port."
    prompt_host_port "8081"

    cat > "$INSTALL_DIR/.env" <<EOF
AI_ACCELERATION=$AI_ACCELERATION
LLAMA_CPP_TAG=$( (( GPU_ENABLED )) && echo "server-cuda" || echo "server" )
LLAMA_ARG_HF_REPO=$HF_REPO_VALUE
AI_MODELS_PATH=$ENV_MODELS_PATH
# Commented out on purpose — an EMPTY value here is not "use the default",
# it is a parse error. llama.cpp reads this one with stoi, and an empty
# string put the container into a restart loop with:
#   error while handling environment variable "LLAMA_ARG_N_GPU_LAYERS": stoi
# Absent means auto, which is what you want. Uncomment and give it a NUMBER
# only to split a model between GPU and CPU, e.g. LLAMA_ARG_N_GPU_LAYERS=20
#LLAMA_ARG_N_GPU_LAYERS=
LLAMA_ARG_N_PARALLEL=1
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    print_info "Generated .env at $INSTALL_DIR."
    # No secrets file: llama.cpp has no accounts and generates no credentials.
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

# AI_ACCELERATION is the single source of truth, and LLAMA_CPP_TAG follows
# it — `server` has no CUDA compiled in at all, so the tag IS the hardware
# decision here. Keeping them in sync on every run is what lets someone flip
# the .env to `cpu` and get a genuinely CPU-only container next rerun, rather
# than a CUDA image with the GPU withheld from it.
set_env_value "AI_ACCELERATION" "$AI_ACCELERATION" "$INSTALL_DIR/.env"
set_env_value "AI_MODELS_PATH"   "$ENV_MODELS_PATH" "$INSTALL_DIR/.env"
set_env_value "LLAMA_CPP_TAG" \
    "$( (( GPU_ENABLED )) && echo "server-cuda" || echo "server" )" \
    "$INSTALL_DIR/.env"

ENV_MEM_LIMIT=$(read_env_value "MEM_LIMIT" "$INSTALL_DIR/.env")
ENV_HOST_PORT=$(read_env_value "HOST_PORT" "$INSTALL_DIR/.env")
ENV_HF_REPO=$(read_env_value "LLAMA_ARG_HF_REPO" "$INSTALL_DIR/.env")
ENV_TAG=$(read_env_value "LLAMA_CPP_TAG" "$INSTALL_DIR/.env")

ENV_NGL=$(read_env_value "LLAMA_ARG_N_GPU_LAYERS" "$INSTALL_DIR/.env")

OVERRIDE_BODY=$(
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    # Injected ONLY when set to something. See docker-compose.yml: passing it
    # empty is a parse error inside llama.cpp, not a fallback to the default.
    if [[ -n "$ENV_NGL" ]]; then
        echo "    environment:"
        echo "      LLAMA_ARG_N_GPU_LAYERS: \"$ENV_NGL\""
    fi
    if [[ -n "$ENV_HOST_PORT" ]]; then
        echo "    ports:"
        echo "      - \"$ENV_HOST_PORT:8080\""
    fi
    # Only meaningful with the CUDA image; harmless to omit otherwise.
    if [[ "$ENV_TAG" == "server-cuda" ]]; then
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
    { echo "services:"; echo "  llama-cpp:"; printf '%s\n' "$OVERRIDE_BODY"; } \
        > "$INSTALL_DIR/docker-compose.override.yml"
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

[[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'llama-cpp' container."
[[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published — remember there is no authentication behind it."
[[ "$ENV_TAG" == "server-cuda" ]] && print_info "GPU build selected ($ENV_TAG) and GPU access enabled in the compose override."

# Created and PROVEN writable before compose starts. A bind mount the
# container cannot write to fails later, mid-download, with an error that
# reads like a network problem — see prepare_model_dir() in lib/common.sh.
prepare_model_dir "$ENV_MODELS_PATH" "ghcr.io/ggml-org/llama.cpp:$ENV_TAG" \
    || print_error "Fix the permissions above and rerun."
print_info "Models: $ENV_MODELS_PATH"

print_info "Starting llama.cpp — first run downloads the model, which takes a while..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start llama.cpp. Check log: $LOGFILE"

# The model downloads *inside* the container on first start, so "container
# running" arrives long before "ready to answer". The image ships its own
# /health endpoint, which reports 503 while loading and 200 when serving —
# exactly the distinction worth waiting on.
print_info "Waiting for the model to download and load. Progress below."
# Shared helper — the state-checking and progress-echoing this used to do
# inline now lives in lib/common.sh, because LocalAI needed exactly the same
# thing and a second copy is how the two quietly drift apart.
set +e
wait_for_container_ready "llama-cpp" "curl -fsS http://localhost:8080/health" 120 10
WAIT_RC=$?
set -e
READY=$(( WAIT_RC == 0 ? 1 : 0 ))

if (( WAIT_RC == 1 )); then
    # Match the hint to what the log actually says. A fixed "check your model
    # name" message is worse than none when the real cause was a bad env var:
    # it sends you to rebuild a model download that was never the problem.
    FAILLOG=$(docker logs --tail 25 llama-cpp 2>&1 || true)
    case "$FAILLOG" in
        *"environment variable"*|*stoi*)
            print_warn "That is a malformed setting in $INSTALL_DIR/.env, not a model problem."
            print_warn "The named variable must hold a number, or be left out entirely —"
            print_warn "an empty value is a parse error, not a default."
            ;;
        *401*|*403*|*"not found"*|*"failed to download"*)
            print_warn "LLAMA_ARG_HF_REPO in $INSTALL_DIR/.env names a model that doesn't"
            print_warn "exist, or one that is gated and needs you to accept its licence on"
            print_warn "Hugging Face first. Check the exact name at:"
            print_warn "  https://huggingface.co/$ENV_HF_REPO"
            ;;
        *"out of memory"*|*CUDA*|*cuda*)
            print_warn "This looks like a GPU problem — most often a model too large for"
            print_warn "your VRAM. Try a smaller model, or set LLAMA_ARG_N_GPU_LAYERS in"
            print_warn ".env to a number lower than the model's layer count to split it"
            print_warn "between GPU and CPU."
            ;;
        *)
            print_warn "Full log: cd $INSTALL_DIR && $COMPOSE_CMD logs llama-cpp"
            ;;
    esac
    print_error "llama.cpp did not start."
fi

echo
echo "──────────────────────────────────────────────"
echo "🔌 API (internal):  http://llama-cpp:8080/v1   ← how other services reach it"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🔌 API (host):      http://$SERVER_IP:$ENV_HOST_PORT   ⚠️ no authentication"
fi
echo "🧠 Model:           $ENV_HF_REPO"
if (( GPU_ENABLED )); then
    ACCEL_LINE="GPU ✅"
elif (( GPU_DOCKER_OK )); then
    ACCEL_LINE="CPU only — by choice (AI_ACCELERATION=cpu in .env)"
else
    ACCEL_LINE="CPU only — no usable GPU on this host"
fi
echo "🖥️  Build:           $ENV_TAG  ($ACCEL_LINE)"
echo "📜 Log:             $LOGFILE"
echo "──────────────────────────────────────────────"
echo
if (( READY )); then
    print_info "Self-test passed — the model is loaded and the API is answering."
else
    print_warn "Not ready after 20 minutes. A large model on a slow link can take longer;"
    print_warn "this is not necessarily a failure. Watch it finish with:"
    print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f llama-cpp"
fi
echo
echo "📌 llama.cpp serves ONE model. Open WebUI and the agents will show"
echo "   '$ENV_HF_REPO' alone rather than a list — that is correct, not a fault."
echo "   To serve a different one, rerun this script — it offers the model menu"
echo "   with your current choice kept as the default."
echo "   Want SEVERAL models at once instead? That is Ollama or LocalAI, not this."
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"
echo "Cached:    docker exec llama-cpp ls /models   ← models already downloaded"

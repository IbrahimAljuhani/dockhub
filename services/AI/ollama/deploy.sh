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
    # sent 2051 tokens on a bare "hello" with nothing loaded.
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
    print_warn "That is too small for agents: OpenHands alone sends ~2000 tokens"
    print_warn "of prompt before your first word, and Hermes asks for 64000."
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
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
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

if (( API_OK )) && (( MODEL_COUNT == 0 )); then
    echo
    print_info "No models are installed yet — Ollama can't answer anything without one."
    echo
    echo "   1) llama3.2:3b     ~2 GB   fast, modest quality — fine on CPU"
    echo "   2) llama3.1:8b     ~5 GB   the usual default; wants a GPU or patience"
    echo "   3) qwen2.5-coder:7b ~5 GB  tuned for code"
    echo "   4) Skip — I'll pull one myself later"
    echo
    read -rp "Pull a model now? (1-4): " model_choice
    OLLAMA_MODEL=""
    OLLAMA_MODEL_GB=0
    case "$model_choice" in
        1) OLLAMA_MODEL="llama3.2:3b";      OLLAMA_MODEL_GB=3 ;;
        2) OLLAMA_MODEL="llama3.1:8b";      OLLAMA_MODEL_GB=6 ;;
        3) OLLAMA_MODEL="qwen2.5-coder:7b"; OLLAMA_MODEL_GB=6 ;;
        *) print_info "Skipped. Pull one later with: docker exec -it ollama ollama pull <model>" ;;
    esac

    if [[ -n "$OLLAMA_MODEL" ]]; then
        if ! check_free_disk_gb "$OLLAMA_MODEL_GB" "$ENV_MODELS_PATH"; then
            read -rp "Not much room. Download anyway? (y/N): " disk_answer
            [[ "${disk_answer,,}" == "y" ]] || OLLAMA_MODEL=""
        fi
    fi

    if [[ -n "$OLLAMA_MODEL" ]]; then
        print_info "Pulling $OLLAMA_MODEL — this is a large download, progress is shown below."
        if docker exec ollama ollama pull "$OLLAMA_MODEL"; then
            MODEL_COUNT=1
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
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
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

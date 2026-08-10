#!/bin/bash
# deploy.sh (services/AI/localai)
# Purpose: Deploy LocalAI as a model provider — see docker-compose.yml for
# what AIO means and why the image tag encodes two separate decisions.
#
# This is a single-instance service, under ~/docker/localai/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy LocalAI on the shared 'ai-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/localai"
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

ensure_single_provider "localai" || exit 0

mkdir -p "$INSTALL_DIR"
ensure_ai_net
gpu_setup

# Whether the GPU CAN be used (gpu_setup) and whether it SHOULD be
# (gpu_resolve_acceleration) are separate questions — see lib/gpu.sh.
STORED_ACCEL=$(read_env_value "AI_ACCELERATION" "$INSTALL_DIR/.env")
gpu_resolve_acceleration "$STORED_ACCEL"

# One shared location for every AI service, asked once and remembered in
# ~/docker/.dockhub-env. Resolved before the disk check, because a 40 GB
# check is only meaningful against the filesystem the download lands on.
ENV_MODELS_PATH=$(read_env_value "AI_MODELS_PATH" "$INSTALL_DIR/.env")
if [[ -z "$ENV_MODELS_PATH" ]]; then
    resolve_ai_models_dir
    ENV_MODELS_PATH="$AI_MODELS_DIR/localai"
fi

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    # ── AIO or empty ────────────────────────────────────────────────────
    echo
    print_info "LocalAI's whole point here is breadth: text, speech-to-text,"
    print_info "text-to-speech and image generation from one API."
    echo
    echo "   1) All-In-One — arrives with a model for each capability, named"
    echo "      the way OpenAI names them (gpt-4, whisper-1, tts-1, ...).  ← recommended"
    echo "      Downloads its model set on first start; large, and slow the first time."
    echo "   2) Empty — no models. You add each one yourself afterwards."
    read -rp "Choice (1-2): " aio_choice

    # These are DISK figures, not VRAM. The GPU profile's model set is simply
    # larger on disk; it says nothing about how big a card you need. AIO reads
    # the card's actual VRAM at startup and picks a profile to match — an 8 GB
    # card gets gpu-8g, with models sized for it — so a modest GPU is fine.
    case "$aio_choice" in
        # GPU_ENABLED, not GPU_DOCKER_OK: the figure has to match the image
        # that will actually be pulled. Someone with a working card who chose
        # CPU gets the smaller CPU image, and asking them for 40 GB would be
        # a warning about a download that is never going to happen.
        1) AIO_PART="aio-"; NEED_GB=$( (( GPU_ENABLED )) && echo 40 || echo 25 ) ;;
        2) AIO_PART="";     NEED_GB=5 ;;
        *) print_error "Invalid choice. Nothing was deployed." ;;
    esac

    # The tag is hardware + content. Both halves come from decisions already
    # made rather than from a guess: you chose the content, and the hardware
    # half follows GPU_ENABLED — detected capability AND your consent.
    if (( GPU_ENABLED )); then
        LOCALAI_TAG_VALUE="latest-${AIO_PART}gpu-nvidia-cuda-12"
    else
        LOCALAI_TAG_VALUE="latest-${AIO_PART}cpu"
    fi

    if ! check_free_disk_gb "$NEED_GB" "$ENV_MODELS_PATH"; then
        read -rp "Not much room. Continue anyway? (y/N): " disk_answer
        [[ "${disk_answer,,}" == "y" ]] || print_error "Nothing was deployed."
    fi

    echo
    prompt_mem_limit "localai" "8g"

    echo
    print_warn "LocalAI's API has NO authentication, like the other providers."
    print_info "Other DockHub services reach it as http://localai:8080 without a port."
    prompt_host_port "8082"

    cat > "$INSTALL_DIR/.env" <<EOF
AI_ACCELERATION=$AI_ACCELERATION
LOCALAI_TAG=$LOCALAI_TAG_VALUE
LOCALAI_DEBUG=false
AI_MODELS_PATH=$ENV_MODELS_PATH
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    print_info "Generated .env at $INSTALL_DIR."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

set_env_value "AI_ACCELERATION" "$AI_ACCELERATION" "$INSTALL_DIR/.env"
set_env_value "AI_MODELS_PATH"   "$ENV_MODELS_PATH" "$INSTALL_DIR/.env"

# Keep the tag's HARDWARE half in step with AI_ACCELERATION, and leave its
# CONTENT half alone — the tag encodes two decisions and only one of them is
# being changed here. The aio part is recovered from the existing tag rather
# than re-asked, because "All-In-One or empty" was answered on the first run
# and re-prompting for it would be a different question than the one the
# user came back to change.
CUR_TAG=$(read_env_value "LOCALAI_TAG" "$INSTALL_DIR/.env")
if [[ -n "$CUR_TAG" ]]; then
    KEEP_AIO=""; [[ "$CUR_TAG" == *aio* ]] && KEEP_AIO="aio-"
    if (( GPU_ENABLED )); then
        WANT_TAG="latest-${KEEP_AIO}gpu-nvidia-cuda-12"
    else
        WANT_TAG="latest-${KEEP_AIO}cpu"
    fi
    if [[ "$WANT_TAG" != "$CUR_TAG" ]]; then
        print_warn "Switching image: $CUR_TAG → $WANT_TAG"
        # LocalAI's backends are built per hardware target, so the ones
        # already in the volume don't carry over. Saying so up front beats
        # a second unexplained multi-gigabyte download.
        print_warn "LocalAI downloads its backends per hardware target, so the ones"
        print_warn "already downloaded do not carry over — expect it to fetch again."
        set_env_value "LOCALAI_TAG" "$WANT_TAG" "$INSTALL_DIR/.env"
    fi
fi

ENV_MEM_LIMIT=$(read_env_value "MEM_LIMIT" "$INSTALL_DIR/.env")
ENV_HOST_PORT=$(read_env_value "HOST_PORT" "$INSTALL_DIR/.env")
ENV_TAG=$(read_env_value "LOCALAI_TAG" "$INSTALL_DIR/.env")

OVERRIDE_BODY=$(
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    if [[ -n "$ENV_HOST_PORT" ]]; then
        echo "    ports:"
        echo "      - \"$ENV_HOST_PORT:8080\""
    fi
    if [[ "$ENV_TAG" == *gpu-nvidia* ]]; then
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
    { echo "services:"; echo "  localai:"; printf '%s\n' "$OVERRIDE_BODY"; } \
        > "$INSTALL_DIR/docker-compose.override.yml"
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

[[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'localai' container."
[[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published — remember there is no authentication behind it."
[[ "$ENV_TAG" == *gpu-nvidia* ]] && print_info "GPU build selected ($ENV_TAG) and GPU access enabled in the compose override."
[[ "$ENV_TAG" == *aio* ]] && print_info "All-In-One build — it will download its model set on first start."

# Created and PROVEN writable before compose starts. A bind mount the
# container cannot write to fails later, part-way through a 25 GB download,
# with an error that reads like a network problem — see prepare_model_dir().
prepare_model_dir "$ENV_MODELS_PATH" "localai/localai:$ENV_TAG" \
    || print_error "Fix the permissions above and rerun."
print_info "Models: $ENV_MODELS_PATH"

print_info "Starting LocalAI..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start LocalAI. Check log: $LOGFILE"

# /readyz is LocalAI's own readiness endpoint, and far better than "the
# container is running" — but treat it as "the server is serving", not "every
# AIO file finished downloading". A live run reported ready roughly half a
# minute after a model file was still logging as .partial, so the two are not
# the same claim. The post-deploy check below looks for leftovers rather than
# trusting readiness to have covered them.
#
# The budget is scaled to what is actually being fetched. A measured AIO GPU
# run on a fast connection took 25 minutes — five short of the flat 30-minute
# limit this used to have. A margin that thin means anyone on a slower link
# sees "not ready" printed over a download that was proceeding perfectly, so
# AIO gets an hour. The empty build fetches nothing and starts in seconds;
# giving it the same hour would only make a genuine failure take an hour to
# report.
if [[ "$ENV_TAG" == *aio* ]]; then
    WAIT_ROUNDS=360; WAIT_LABEL="an hour"
else
    WAIT_ROUNDS=90;  WAIT_LABEL="15 minutes"
fi
print_info "Waiting for LocalAI to be ready. Progress below."
set +e
wait_for_container_ready "localai" "curl -fsS http://localhost:8080/readyz" "$WAIT_ROUNDS" 10
WAIT_RC=$?
set -e

if (( WAIT_RC == 1 )); then
    FAILLOG=$(docker logs --tail 25 localai 2>&1 || true)
    case "$FAILLOG" in
        *"no space"*|*"No space"*)
            print_warn "The disk filled up. The AIO model set is large — free space and rerun." ;;
        *CUDA*|*cuda*|*"out of memory"*)
            print_warn "A GPU problem. If your card is small, the CPU build is a valid"
            print_warn "fallback: set LOCALAI_TAG in .env to latest-aio-cpu and rerun." ;;
        *)
            print_warn "Full log: cd $INSTALL_DIR && $COMPOSE_CMD logs localai" ;;
    esac
    print_error "LocalAI did not start."
fi

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"

echo
echo "──────────────────────────────────────────────"
echo "🔌 API (internal):  http://localai:8080/v1   ← how other services reach it"
[[ -n "$ENV_HOST_PORT" ]] && echo "🔌 API (host):      http://$SERVER_IP:$ENV_HOST_PORT   ⚠️ no authentication"
echo "🖥️  Build:           $ENV_TAG"
echo "📜 Log:             $LOGFILE"
echo "──────────────────────────────────────────────"
echo
if (( WAIT_RC == 0 )); then
    print_info "Self-test passed — LocalAI reports ready."
    # Readiness and completeness are different claims: LocalAI starts serving
    # and finishes the remaining downloads behind you. Observed live — it
    # reported ready with a file at 62%, and that file was complete and
    # loading normally after a reboot a minute later. So this is information,
    # NOT a fault, and deliberately suggests no cleanup: deleting a .partial
    # would throw away an in-progress download and re-fetch gigabytes.
    PARTIALS=$(docker exec localai sh -c 'ls -1 /models/*.partial 2>/dev/null | wc -l' 2>/dev/null | tr -dc '0-9')
    if [[ -n "${PARTIALS:-}" ]] && (( PARTIALS > 0 )); then
        echo
        print_info "$PARTIALS file(s) are still downloading in the background:"
        docker exec localai sh -c 'ls -1 /models/*.partial 2>/dev/null' | sed 's|.*/|     |'
        print_info "That is normal — LocalAI serves while it finishes. Leave it alone;"
        print_info "don't delete them or restart, or the download starts over. Watch with:"
        print_info "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f localai"
    fi
else
    print_warn "Not ready yet after $WAIT_LABEL. The container is still running and its"
    print_warn "log was moving, so this is not necessarily a failure — watch it with:"
    print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f localai"
fi
echo
if [[ "$ENV_TAG" == *aio* ]]; then
    echo "📌 Models are named the way OpenAI names them, so existing code works"
    echo "   unchanged: gpt-4, gpt-4-vision-preview, whisper-1, tts-1,"
    echo "   text-embedding-ada-002, stablediffusion."
    echo "   List what's actually loaded:"
    echo "     curl -s http://$SERVER_IP:${ENV_HOST_PORT:-8080}/v1/models"
else
    echo "📌 This build ships with NO models, so it cannot answer anything yet."
    if [[ -n "$ENV_HOST_PORT" ]]; then
        echo "   Easiest way to add some — LocalAI has its own web interface:"
        echo "     http://$SERVER_IP:$ENV_HOST_PORT  →  'Install Models' in the sidebar"
        echo "   Or from the command line:"
    else
        echo "   Add them from the gallery:"
    fi
    echo "     docker exec localai local-ai models list"
    echo "     docker exec localai local-ai models install <name>"
    echo "   A small one that suits a 6-8 GB card: llama-3.2-1b-instruct:q4_k_m"
fi
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

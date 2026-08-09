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

LIB_COMMON="$SOURCE_DIR/../../../lib/common.sh"
LIB_GPU="$SOURCE_DIR/../../../lib/gpu.sh"
if [[ ! -f "$LIB_COMMON" ]]; then
    _tmp="$(mktemp -d)"
    LIB_COMMON="$_tmp/common.sh"; LIB_GPU="$_tmp/gpu.sh"
    curl -fsSL -o "$LIB_COMMON" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
    curl -fsSL -o "$LIB_GPU"    "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/gpu.sh"
fi
# shellcheck source=/dev/null
source "$LIB_COMMON"
# shellcheck source=/dev/null
source "$LIB_GPU"

check_prerequisites

ensure_single_provider "localai" || exit 0

mkdir -p "$INSTALL_DIR"
ensure_ai_net
gpu_setup

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

    case "$aio_choice" in
        1) AIO_PART="aio-"; NEED_GB=$( (( GPU_DOCKER_OK )) && echo 40 || echo 25 ) ;;
        2) AIO_PART="";     NEED_GB=5 ;;
        *) print_error "Invalid choice. Nothing was deployed." ;;
    esac

    # The tag is hardware + content. Both halves come from decisions already
    # made rather than from a guess: gpu_setup detected the first, you chose
    # the second.
    if (( GPU_DOCKER_OK )); then
        LOCALAI_TAG_VALUE="latest-${AIO_PART}gpu-nvidia-cuda-12"
    else
        LOCALAI_TAG_VALUE="latest-${AIO_PART}cpu"
    fi

    if ! check_free_disk_gb "$NEED_GB" "$HOME"; then
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
LOCALAI_TAG=$LOCALAI_TAG_VALUE
LOCALAI_DEBUG=false
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

print_info "Starting LocalAI..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start LocalAI. Check log: $LOGFILE"

# /readyz is LocalAI's own readiness endpoint: it stays unready while the AIO
# model set downloads, which is exactly the distinction worth waiting on.
print_info "Waiting for LocalAI to be ready. Progress below."
set +e
wait_for_container_ready "localai" "curl -fsS http://localhost:8080/readyz" 180 10
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
else
    print_warn "Not ready yet after 30 minutes. The AIO model set is large, so this"
    print_warn "is not necessarily a failure — watch it finish with:"
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
    echo "📌 This build ships with NO models. Add them from the gallery:"
    echo "     docker exec localai local-ai models list"
    echo "     docker exec localai local-ai models install <name>"
fi
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

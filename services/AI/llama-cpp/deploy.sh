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

# Before anything is created: providers share one GPU's memory, so a second
# one running alongside means either OOM or constant swapping.
ensure_single_provider "llama-cpp" || exit 0

mkdir -p "$INSTALL_DIR"

# ai-net only. No main-net: no web interface, no authentication.
ensure_ai_net

# Detects, reports, and offers to install the container toolkit — never
# installs a driver silently. Sets GPU_DOCKER_OK.
gpu_setup

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    # ── The model ───────────────────────────────────────────────────────
    # Mandatory here, unlike Ollama. llama-server loads a model at startup
    # and serves that one; with nothing to load there is no service.
    echo
    print_info "llama.cpp serves ONE model. Pick it now — you can change it later"
    print_info "by editing LLAMA_ARG_HF_REPO in .env and rerunning this script."
    echo
    # Every repo below was checked to exist. Note the different owners: the
    # ggml-org org (llama.cpp's own) publishes a small set, and the rest of
    # the GGUF world lives mostly under bartowski. Guessing a prefix produces
    # a repo that looks plausible and 401s at download time.
    echo "   1) ggml-org/gemma-3-1b-it-GGUF               ~1 GB  tiny, fast, fine on CPU"
    echo "   2) ggml-org/gemma-3-4b-it-GGUF               ~3 GB  small, good general quality"
    echo "   3) bartowski/Qwen2.5-Coder-7B-Instruct-GGUF  ~5 GB  tuned for code"
    echo "   4) Enter a Hugging Face repo myself"
    read -rp "Choice (1-4): " model_choice
    case "$model_choice" in
        1) HF_REPO_VALUE="ggml-org/gemma-3-1b-it-GGUF";                MODEL_GB=2 ;;
        2) HF_REPO_VALUE="ggml-org/gemma-3-4b-it-GGUF";                MODEL_GB=4 ;;
        3) HF_REPO_VALUE="bartowski/Qwen2.5-Coder-7B-Instruct-GGUF";   MODEL_GB=7 ;;
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
            MODEL_GB=8
            ;;
        *) print_error "Invalid choice. Nothing was deployed." ;;
    esac

    # Unlike Ollama, the model isn't optional here — llama-server has nothing
    # to serve without one — so running short of disk is a decision point
    # rather than something that can be skipped past.
    if ! check_free_disk_gb "$MODEL_GB" "$HOME"; then
        read -rp "Not much room. Download anyway? (y/N): " disk_answer
        [[ "${disk_answer,,}" == "y" ]] || print_error "Nothing was deployed."
    fi

    echo
    prompt_mem_limit "llama-cpp" "8g"

    echo
    print_warn "llama.cpp's API has NO authentication, exactly like Ollama's."
    print_info "Other DockHub services reach it as http://llama-cpp:8080 without a port."
    prompt_host_port "8081"

    cat > "$INSTALL_DIR/.env" <<EOF
LLAMA_CPP_TAG=$( (( GPU_DOCKER_OK )) && echo "server-cuda" || echo "server" )
LLAMA_ARG_HF_REPO=$HF_REPO_VALUE
LLAMA_ARG_N_GPU_LAYERS=
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

print_info "Starting llama.cpp — first run downloads the model, which takes a while..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start llama.cpp. Check log: $LOGFILE"

# The model downloads *inside* the container on first start, so "container
# running" arrives long before "ready to answer". The image ships its own
# /health endpoint, which reports 503 while loading and 200 when serving —
# exactly the distinction worth waiting on.
print_info "Waiting for the model to download and load. Progress below."
READY=0
DIED=0
LAST_LINE=""
for i in $(seq 1 120); do
    # Checked FIRST, and every round. Without this the loop cannot tell a
    # slow download from a container that exited seconds after starting —
    # `docker exec` fails identically in both cases — and a crash caused by
    # a wrong model name would look like twenty minutes of downloading.
    state=$(docker inspect -f '{{.State.Status}}' llama-cpp 2>/dev/null || echo missing)
    if [[ "$state" != "running" ]]; then
        DIED=1
        break
    fi

    if docker exec llama-cpp curl -fsS http://localhost:8080/health >/dev/null 2>&1; then
        READY=1
        break
    fi

    # Echo the newest log line every ~30s. A download of several gigabytes
    # behind a silent prompt is indistinguishable from a hang, and the honest
    # fix is to show what the container is actually doing.
    if (( i % 3 == 0 )); then
        line=$(docker logs --tail 1 llama-cpp 2>&1 | tr -d '\r' | tail -n1)
        if [[ -n "$line" && "$line" != "$LAST_LINE" ]]; then
            echo "   … $line"
            LAST_LINE="$line"
        fi
    fi
    sleep 10
done

if (( DIED )); then
    echo
    print_warn "The container stopped (state: $state). Its last output:"
    echo "──────────────────────────────────────────────" >&2
    docker logs --tail 25 llama-cpp 2>&1 | sed 's/^/  /' >&2
    echo "──────────────────────────────────────────────" >&2
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
echo "🖥️  Build:           $ENV_TAG  ($( [[ "$ENV_TAG" == "server-cuda" ]] && echo "GPU ✅" || echo "CPU only" ))"
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
echo "   To serve a different one: edit LLAMA_ARG_HF_REPO in .env and rerun this script."
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

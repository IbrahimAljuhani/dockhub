#!/bin/bash
# deploy.sh (services/AI/open-webui)
# Purpose: Deploy Open WebUI — the chat interface in front of whichever model
# provider is running. See docker-compose.yml for why the image tag matters
# and why this joins two shared networks.
#
# This is a single-instance service, under ~/docker/open-webui/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Open WebUI behind 'main-net', talking to a provider on 'ai-net'."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/open-webui"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.open-webui-docker-secrets.txt"

# Shared helpers — sourced from a git checkout if present, self-fetched
# otherwise so standalone curl usage still works with no extra steps.
# gpu.sh is deliberately NOT sourced: this container never loads a model, so
# it has nothing for a GPU to accelerate.
LIB_DIR="$SOURCE_DIR/../../../lib"
if [[ ! -f "$LIB_DIR/common.sh" ]]; then
    LIB_DIR="$(mktemp -d)"
    curl -fsSL -o "$LIB_DIR/common.sh" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

check_prerequisites

mkdir -p "$INSTALL_DIR"

# Both: main-net so NPM can serve it, ai-net so it can reach the provider.
ensure_main_net
ensure_ai_net

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."

    # Providers are mutually exclusive, so deploying a new one STOPS the old
    # one — and leaves every consumer still pointing at a container that no
    # longer runs. The visible result is an empty model list with nothing
    # explaining it, so it's worth catching here rather than in the browser.
    CONFIGURED_URL=$(read_env_value "OLLAMA_BASE_URL" "$INSTALL_DIR/.env")
    [[ -z "$CONFIGURED_URL" ]] && CONFIGURED_URL=$(read_env_value "OPENAI_API_BASE_URL" "$INSTALL_DIR/.env")
    # Only local providers can go missing; a cloud endpoint is never "stopped".
    if [[ "$CONFIGURED_URL" == http://* ]]; then
        CONFIGURED_HOST=${CONFIGURED_URL#http://}
        CONFIGURED_HOST=${CONFIGURED_HOST%%:*}
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONFIGURED_HOST"; then
            echo
            print_warn "This deployment is configured to use '$CONFIGURED_HOST', which is not running."
            detect_ai_provider
            if [[ -n "$AI_PROVIDER_NAME" ]]; then
                print_warn "'$AI_PROVIDER_NAME' is running instead — you likely switched providers."
                read -rp "Point Open WebUI at $AI_PROVIDER_NAME? (Y/n): " switch_answer
                if [[ "${switch_answer,,}" != "n" ]]; then
                    # Rewrite both keys: exactly one must hold a value, and
                    # the choice of which depends on the provider's API.
                    if [[ "$AI_PROVIDER_NAME" == "ollama" ]]; then
                        NEW_OLLAMA="$AI_PROVIDER_BASE_URL"; NEW_OPENAI=""; NEW_KEY=""
                    else
                        NEW_OLLAMA=""; NEW_OPENAI="$AI_PROVIDER_BASE_URL/v1"; NEW_KEY="local"
                    fi
                    # set_env_value, not a bare sed: it appends when the key
                    # is absent. A bare sed silently does nothing on an .env
                    # that predates a key, and reports success while doing it.
                    set_env_value "OLLAMA_BASE_URL"     "$NEW_OLLAMA" "$INSTALL_DIR/.env"
                    set_env_value "OPENAI_API_BASE_URL" "$NEW_OPENAI" "$INSTALL_DIR/.env"
                    set_env_value "OPENAI_API_KEY"      "$NEW_KEY"    "$INSTALL_DIR/.env"
                    print_info "Switched to $AI_PROVIDER_NAME."
                fi
            else
                print_warn "No other provider is running either. Start one, or add a"
                print_warn "connection in Admin → Settings → Connections."
            fi
        fi
    fi
else
    WEBUI_SECRET=$(generate_secret_hex 32)
    OLLAMA_URL_VALUE=""
    OPENAI_BASE_VALUE=""
    OPENAI_KEY_VALUE=""

    # ── Where do the models come from? ──────────────────────────────────
    echo
    detect_ai_provider
    if [[ -n "$AI_PROVIDER_NAME" ]]; then
        print_info "Found a model provider on 'ai-net': $AI_PROVIDER_NAME"

        # Ollama can be asked what it has. Showing it here turns "is this
        # wired up?" into something you can see before the deploy finishes,
        # instead of after opening the UI and finding an empty dropdown.
        if [[ "$AI_PROVIDER_NAME" == "ollama" ]]; then
            local_models=$(docker exec ollama ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | paste -sd', ' - || true)
            if [[ -n "${local_models:-}" ]]; then
                print_info "It has: $local_models"
            else
                print_warn "It has NO models installed — the model list here will be empty."
                print_warn "  docker exec -it ollama ollama pull llama3.2:3b"
            fi
            # Ollama speaks a native API that Open WebUI supports directly.
            OLLAMA_URL_VALUE="$AI_PROVIDER_BASE_URL"
        else
            # llama.cpp and LocalAI are reached over OpenAI-compatible /v1.
            OPENAI_BASE_VALUE="$AI_PROVIDER_BASE_URL/v1"
            # A key is required by the protocol but ignored by local servers.
            OPENAI_KEY_VALUE="local"
        fi
    else
        print_warn "No model provider is running on 'ai-net'."
        echo
        echo "Where should Open WebUI get its models from?"
        echo "   1) OpenAI — or any OpenAI-compatible endpoint  (needs a key)"
        echo "   2) Skip — I'll add a connection in the web interface later"
        echo "   0) Stop here — I'll deploy Ollama first"
        read -rp "Choice (0-2): " backend_choice
        case "$backend_choice" in
            1)
                read -rp "API base URL (default: https://api.openai.com/v1): " OPENAI_BASE_VALUE
                OPENAI_BASE_VALUE="${OPENAI_BASE_VALUE:-https://api.openai.com/v1}"
                read -rsp "API key: " OPENAI_KEY_VALUE; echo
                [[ -n "$OPENAI_KEY_VALUE" ]] || print_error "An API key is required for that option."
                ;;
            2)
                # Genuinely fine here, unlike an agent: Open WebUI runs
                # without any connection and adds them from its own UI.
                print_info "Skipped. Add one later in Admin → Settings → Connections."
                ;;
            *)
                echo
                print_info "Nothing was deployed. Deploy a provider first:"
                print_info "  bash services/AI/ollama/deploy.sh"
                exit 0
                ;;
        esac
    fi

    echo
    prompt_mem_limit "open-webui" "1g"
    prompt_host_port "3000"
    if [[ -z "$HOST_PORT" ]]; then
        prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. chat.example.com): " "domain"
        WEBUI_DOMAIN="$PROMPTED_DOMAIN"
    else
        WEBUI_DOMAIN=""
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
OPEN_WEBUI_VERSION=main
WEBUI_SECRET_KEY=$WEBUI_SECRET
OLLAMA_BASE_URL=$OLLAMA_URL_VALUE
OPENAI_API_BASE_URL=$OPENAI_BASE_VALUE
OPENAI_API_KEY=$OPENAI_KEY_VALUE
WEBUI_DOMAIN=$WEBUI_DOMAIN
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Open WebUI secrets - DO NOT SHARE"
        echo "$(date '+%F %T')"
        echo "  Session signing key: $WEBUI_SECRET"
        echo "  (changing it signs every user out; it is not a login password)"
        echo
        echo "  Open WebUI has NO default account. The first person to register"
        echo "  at the site becomes the admin — do it promptly."
        [[ -n "$OPENAI_KEY_VALUE" && "$OPENAI_KEY_VALUE" != "local" ]] && echo "  An API key you supplied is stored in .env."
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved a copy of the secrets to $SECRETS_FILE."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

ENV_MEM_LIMIT=$(read_env_value "MEM_LIMIT" "$INSTALL_DIR/.env")
ENV_HOST_PORT=$(read_env_value "HOST_PORT" "$INSTALL_DIR/.env")
ENV_DOMAIN=$(read_env_value "WEBUI_DOMAIN" "$INSTALL_DIR/.env")
ENV_OLLAMA_URL=$(read_env_value "OLLAMA_BASE_URL" "$INSTALL_DIR/.env")
ENV_OPENAI_BASE=$(read_env_value "OPENAI_API_BASE_URL" "$INSTALL_DIR/.env")

OVERRIDE_BODY=$(
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    if [[ -n "$ENV_HOST_PORT" ]]; then
        echo "    ports:"
        echo "      - \"$ENV_HOST_PORT:8080\""
    fi
    true
)
if [[ -n "$OVERRIDE_BODY" ]]; then
    { echo "services:"; echo "  open-webui:"; printf '%s\n' "$OVERRIDE_BODY"; } \
        > "$INSTALL_DIR/docker-compose.override.yml"
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

[[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'open-webui' container."
[[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Open WebUI (first run initialises its database)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Open WebUI. Check log: $LOGFILE"

# ── Self-test, in two parts ─────────────────────────────────────────────
# "The page loads" and "it can reach the model provider" are different
# claims, and the second is the one that decides whether the model dropdown
# has anything in it.
print_info "Waiting for the interface to answer..."
UI_OK=0
for _ in $(seq 1 30); do
    if docker exec open-webui python -c "
import urllib.request
urllib.request.urlopen('http://localhost:8080/health', timeout=3)" >/dev/null 2>&1; then
        UI_OK=1
        break
    fi
    sleep 2
done

# Checked from INSIDE the container, because that's the only place the
# answer matters — the host may reach Ollama fine while the container
# can't, if something is wrong with ai-net.
PROVIDER_REACHABLE=-1
PROVIDER_URL="${ENV_OLLAMA_URL:-$ENV_OPENAI_BASE}"
if (( UI_OK )) && [[ -n "$PROVIDER_URL" ]] && [[ "$PROVIDER_URL" == http://* ]]; then
    PROVIDER_REACHABLE=0
    # Probe a path that actually exists. A bare OpenAI-compatible base URL
    # is not an endpoint — llama.cpp and LocalAI answer 404 on /v1 itself
    # while /v1/models is the real one. Ollama's root does return 200, so
    # only the OpenAI-style base needs extending.
    PROBE_URL="$PROVIDER_URL"
    [[ "$PROBE_URL" == */v1 ]] && PROBE_URL="$PROBE_URL/models"

    # An HTTPError still proves the connection worked — something answered.
    # Only a connection-level failure means the container genuinely cannot
    # reach the provider, which is the question being asked here. Treating
    # every non-200 as unreachable reported a healthy llama.cpp as broken.
    docker exec open-webui python -c "
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen('$PROBE_URL', timeout=5)
except urllib.error.HTTPError:
    pass
except Exception:
    sys.exit(1)" >/dev/null 2>&1 && PROVIDER_REACHABLE=1
fi

echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 URL:           http://$SERVER_IP:$ENV_HOST_PORT"
fi
[[ -n "$ENV_DOMAIN" ]] && echo "🌐 URL:           https://$ENV_DOMAIN"
echo "🔗 Proxy target:  open-webui:8080 on 'main-net'"
if [[ -n "$ENV_OLLAMA_URL" ]]; then
    echo "🧠 Model source:  ollama  ($ENV_OLLAMA_URL)"
elif [[ -n "$ENV_OPENAI_BASE" ]]; then
    echo "🧠 Model source:  $ENV_OPENAI_BASE"
else
    echo "🧠 Model source:  none yet — add one in Admin → Settings → Connections"
fi
echo "👤 First visit:   create your account — the first one registered becomes admin"
echo "📜 Log:           $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:       $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
if (( UI_OK )); then
    if (( PROVIDER_REACHABLE == 1 )); then
        print_info "Self-test passed — the interface answered, and it can reach the provider."
    elif (( PROVIDER_REACHABLE == 0 )); then
        print_warn "The interface answered, but it could NOT reach $PROVIDER_URL."
        print_warn "The model list will be empty. Check both are on 'ai-net':"
        print_warn "  docker inspect open-webui --format '{{json .NetworkSettings.Networks}}'"
    else
        print_info "Self-test passed — the interface answered."
    fi
else
    print_warn "The interface did not answer within a minute. Check:"
    print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f open-webui"
fi
echo
if [[ -z "$ENV_HOST_PORT" ]]; then
    echo "Set up NGINX Proxy Manager:"
    echo "   1. Forward to  open-webui : 8080  + enable 'Websockets Support'"
    echo "   2. Enable SSL with Let's Encrypt"
    print_tunnel_reminder_if_relevant
    echo
fi
echo "⚠️  Sign up promptly. Until you do, the first person who reaches this page"
echo "   becomes the admin. Afterwards turn signups off in Admin → Settings."
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

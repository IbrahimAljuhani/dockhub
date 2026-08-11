#!/bin/bash
# deploy.sh (services/AI-Agents/openclaw)
# Purpose: Deploy OpenClaw — the first AGENT in DockHub. See
# docker-compose.yml for why the Docker socket is absent by default and why
# upstream's setup.sh is not used, and ../README.md for the threat model.
#
# This is a single-instance service, under ~/docker/openclaw/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy OpenClaw on the shared 'ai-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/openclaw"
LOGFILE="$INSTALL_DIR/deploy.log"

# Shared helpers — sourced from a git checkout if present, self-fetched
# otherwise so standalone curl usage still works with no extra steps.
LIB_DIR="$SOURCE_DIR/../../../lib"
if [[ ! -f "$LIB_DIR/common.sh" ]]; then
    LIB_DIR="$(mktemp -d)"
    curl -fsSL -o "$LIB_DIR/common.sh" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

check_prerequisites

# Agents are alternatives, not companions — and NOT for the providers'
# reason. See ensure_single_agent() in lib/common.sh.
ensure_single_agent "openclaw" || exit 0

mkdir -p "$INSTALL_DIR"

# ai-net always: the model provider is what it actually needs.
ensure_ai_net

# No lib/gpu.sh here, deliberately. An agent never loads a model — the
# provider does. Same reasoning as Open WebUI.

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    echo
    print_info "OpenClaw is an AGENT: it acts on what it reads, using tools."
    print_info "That is different from every other service in DockHub, and the"
    print_info "questions below exist because of it. See ../README.md."

    # ── main-net, or not ────────────────────────────────────────────────
    # The one decision with a real security consequence, so it is asked
    # first, before anyone has stopped reading.
    prompt_agent_network "OpenClaw"

    # ── The Docker socket ───────────────────────────────────────────────
    # Optional here, per upstream's own docs: it powers sandbox mode, where
    # agent tools run in their own containers. Off by default. Saying yes
    # trades the category's core rule for isolation of the tools — a real
    # trade, not a free upgrade, so it is spelled out.
    echo
    print_info "OpenClaw can run its tools inside separate containers (sandbox mode)."
    print_warn "That needs the Docker socket. Understand the trade before saying yes:"
    print_warn "  gained — tools run isolated from the gateway itself"
    print_warn "  given  — anything reaching that socket can start a privileged"
    print_warn "           container, which is root-equivalent on this host"
    print_warn "OpenClaw runs fine WITHOUT it. This is not required."
    read -rp "Enable sandbox mode (mounts /var/run/docker.sock)? (y/N): " sandbox_answer
    if [[ "${sandbox_answer,,}" == "y" ]]; then
        OPENCLAW_SANDBOX_VALUE=1
        print_warn "Sandbox enabled. Keep this host behind a firewall."
    else
        OPENCLAW_SANDBOX_VALUE=0
        print_info "No Docker socket. Tools run inside the OpenClaw container."
    fi

    # ── Browser automation ──────────────────────────────────────────────
    # A separate image variant rather than a runtime flag, and a much larger
    # one — Chromium plus Xvfb baked in. Worth asking rather than assuming.
    echo
    print_info "Should OpenClaw be able to drive a browser (page automation)?"
    print_info "That is a different, considerably larger image variant."
    read -rp "Use the browser variant? (y/N): " browser_answer
    if [[ "${browser_answer,,}" == "y" ]]; then
        OPENCLAW_TAG_VALUE="latest-browser"
    else
        OPENCLAW_TAG_VALUE="latest"
    fi

    echo
    prompt_mem_limit "openclaw" "2g"

    # Its own web gateway, on 18789. Unlike the providers this DOES have
    # authentication — a gateway token generated during onboarding — so a
    # host port is a reasonable default rather than an exposure.
    echo
    print_info "OpenClaw serves its own web interface on 18789, protected by a"
    print_info "gateway token it generates during onboarding."
    prompt_host_port "18789"

    cat > "$INSTALL_DIR/.env" <<EOF
OPENCLAW_TAG=$OPENCLAW_TAG_VALUE
OPENCLAW_TZ=$(cat /etc/timezone 2>/dev/null || echo UTC)
OPENCLAW_SANDBOX=$OPENCLAW_SANDBOX_VALUE
AGENT_ON_MAIN_NET=$AGENT_ON_MAIN_NET
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
ENV_SANDBOX=$(read_env_value "OPENCLAW_SANDBOX" "$INSTALL_DIR/.env")
ENV_MAIN_NET=$(read_env_value "AGENT_ON_MAIN_NET" "$INSTALL_DIR/.env")
ENV_TAG=$(read_env_value "OPENCLAW_TAG" "$INSTALL_DIR/.env")

# These directories hold messaging tokens and model keys. Created here with
# 700 rather than left to Docker, which would make them root-owned and
# world-readable — for an agent's credential store that is the wrong default.
mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/workspace" "$INSTALL_DIR/auth"
chmod 700 "$INSTALL_DIR/config" "$INSTALL_DIR/auth"

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it is always safe to regenerate from what .env says.
OVERRIDE_BODY=$(
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    if [[ -n "$ENV_HOST_PORT" ]]; then
        echo "    ports:"
        echo "      - \"$ENV_HOST_PORT:18789\""
    fi
    if [[ "$ENV_SANDBOX" == "1" ]]; then
        echo "    environment:"
        echo "      OPENCLAW_SANDBOX: \"1\""
        echo "    volumes:"
        # Compose MERGES volume lists rather than replacing them, unlike
        # ports — so this adds the socket to the three mounts in the base
        # file instead of wiping them out.
        echo "      - /var/run/docker.sock:/var/run/docker.sock"
    fi
    if [[ "$ENV_MAIN_NET" == "1" ]]; then
        echo "    networks:"
        echo "      - ai-net"
        echo "      - main-net"
    fi
    true
)
if [[ -n "$OVERRIDE_BODY" ]]; then
    {
        echo "services:"
        echo "  openclaw:"
        printf '%s\n' "$OVERRIDE_BODY"
        # A network named in a service must also be declared at top level.
        if [[ "$ENV_MAIN_NET" == "1" ]]; then
            echo "networks:"
            echo "  main-net:"
            echo "    external: true"
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

[[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'openclaw' container."
[[ "$ENV_TAG" == "latest-browser" ]] && print_info "Browser variant selected — a larger image, first pull takes longer."
if [[ "$ENV_SANDBOX" == "1" ]]; then
    print_warn "Sandbox mode: /var/run/docker.sock is mounted (root-equivalent on host)."
fi
if [[ "$ENV_MAIN_NET" == "1" ]]; then
    ensure_main_net
    print_warn "On 'main-net' — it can reach every other DockHub service by name."
else
    print_info "On 'ai-net' only — it cannot reach your other services."
fi

print_info "Starting OpenClaw..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start OpenClaw. Check log: $LOGFILE"

# ── Self-test ───────────────────────────────────────────────────────────
# OpenClaw ships /healthz and /readyz, both unauthenticated — so unlike
# every provider so far, "is it actually up?" has a real answer from the
# first deploy rather than a guess based on the container being 'running'.
print_info "Waiting for the gateway to answer..."
set +e
wait_for_container_ready "openclaw" "curl -fsS http://localhost:18789/readyz" 45 4
WAIT_RC=$?
set -e

if (( WAIT_RC == 1 )); then
    print_error "OpenClaw did not start. Full log: cd $INSTALL_DIR && $COMPOSE_CMD logs openclaw"
fi

# ── What to paste into the wizard ───────────────────────────────────────
# The model is configured in OpenClaw's own onboarding, not by environment
# variable, so this prints the address rather than pretending to automate
# it. Upstream's docs say host.docker.internal, which is WRONG here: in
# DockHub the provider is a container on ai-net, reached by name.
detect_ai_provider

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"

echo
echo "──────────────────────────────────────────────"
[[ -n "$ENV_HOST_PORT" ]] && echo "🌐 Gateway:       http://$SERVER_IP:$ENV_HOST_PORT"
echo "🔗 Container:     openclaw:18789"
echo "🕸️  Networks:      $( [[ "$ENV_MAIN_NET" == "1" ]] && echo "ai-net + main-net" || echo "ai-net only" )"
echo "🔌 Docker socket: $( [[ "$ENV_SANDBOX" == "1" ]] && echo "MOUNTED ⚠️" || echo "not mounted ✅" )"
if [[ -n "$AI_PROVIDER_NAME" ]]; then
    echo "🧠 Provider:      $AI_PROVIDER_NAME  ($AI_PROVIDER_BASE_URL)"
else
    echo "🧠 Provider:      none running — deploy one from services/AI/ first"
fi
echo "📁 Workspace:     $INSTALL_DIR/workspace"
echo "🔒 Credentials:   $INSTALL_DIR/config  (mode 700)"
echo "📜 Log:           $LOGFILE"
echo "──────────────────────────────────────────────"
echo
if (( WAIT_RC == 0 )); then
    print_info "Self-test passed — the gateway answered on /readyz."
else
    print_warn "The gateway did not answer within 3 minutes. Watch it with:"
    print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f openclaw"
fi

echo
echo "📌 NEXT: finish onboarding in the web interface. It generates your"
echo "   gateway token and asks which model to use."
echo
if [[ -n "$AI_PROVIDER_NAME" ]]; then
    echo "   When it asks for the model endpoint, paste EXACTLY this:"
    echo
    echo "       $AI_PROVIDER_BASE_URL"
    echo
    echo "   ⚠️ OpenClaw's own docs say 'http://host.docker.internal:11434'."
    echo "      That is for Ollama running on the host. Yours is a container"
    echo "      on 'ai-net', so the address above is the correct one."
else
    echo "   No model provider is running yet. Deploy one first:"
    echo "     Ollama is the simplest — services/AI/ollama/"
    echo "   Or give OpenClaw a cloud API key during onboarding."
fi
echo
echo "⚠️  Give it its OWN credentials — a bot token and an API key created"
echo "   for this agent. An agent with your primary key can spend it."
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

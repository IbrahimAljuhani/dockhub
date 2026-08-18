#!/bin/bash
# deploy.sh (services/VPN/wireguard)
# Purpose: Deploy WireGuard via wg-easy — see docker-compose.yml for why
# this repo builds "WireGuard" as wg-easy specifically (plain WireGuard has
# no web UI at all) and the deliberate deviations from wg-easy's own
# docker-compose example.
#
# This is a single-instance service: one wg-easy deployment per host, under
# ~/docker/wireguard/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy WireGuard (via wg-easy) behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/wireguard"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.wireguard-docker-secrets.txt"

# Shared helpers — sourced from a git checkout if present, self-fetched
# otherwise so standalone curl usage still works with no extra steps.
LIB_COMMON="$SOURCE_DIR/../../../lib/common.sh"
if [[ ! -f "$LIB_COMMON" ]]; then
    LIB_COMMON="$(mktemp -d)/common.sh"
    curl -fsSL -o "$LIB_COMMON" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_COMMON"

check_prerequisites

mkdir -p "$INSTALL_DIR"

ensure_main_net

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    # INIT_HOST is the actual VPN endpoint peers dial over UDP — unlike
    # every other service's domain question, this is never optional/
    # conditional on the host-port choice, since WireGuard traffic can
    # never go through NPM (raw UDP, not HTTP). Always ask for it.
    # Re-asks rather than aborting the whole deploy on a stray Enter. Note
    # this deliberately does NOT use prompt_domain: that runs validate_domain,
    # which rejects colons (it reads them as a port), and a bare IPv6 endpoint
    # is a legitimate answer here. Emptiness is the only thing checked.
    while true; do
        read -rp "Enter the public IP or domain your WireGuard clients will connect to (e.g. vpn.example.com or your server's public IP): " INIT_HOST_VALUE
        [[ -n "$INIT_HOST_VALUE" ]] && break
        print_warn "A public IP or domain is required — this is the actual VPN endpoint clients connect to."
    done

    ADMIN_PASSWORD=$(generate_secret)
    prompt_mem_limit "wg-easy-app" "256m"
    prompt_host_port "51821"

    cat > "$INSTALL_DIR/.env" <<EOF
WG_EASY_VERSION=15
INIT_USERNAME=admin
INIT_PASSWORD=$ADMIN_PASSWORD
INIT_HOST=$INIT_HOST_VALUE
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    if [[ -n "$HOST_PORT" ]]; then
        echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
        # wg-easy refuses login over a connection it can't confirm was
        # HTTPS (checks X-Forwarded-Proto, absent on a direct connection).
        # Only flip this for the direct host-port path — NPM+SSL doesn't
        # need it (see docker-compose.yml's header comment and this
        # service's README Reverse Proxy section).
        echo "INSECURE=true" >> "$INSTALL_DIR/.env"
    fi
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated WireGuard/wg-easy secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): host=$INIT_HOST_VALUE"
        echo "  Web UI username: admin"
        echo "  Web UI password: $ADMIN_PASSWORD"
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved a copy of the secrets to $SECRETS_FILE."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from whatever .env currently has.
# Note: HOST_PORT here maps to the web UI (51821) — the VPN data port
# (51820/udp) is unconditional and already in the base compose file.
ENV_MEM_LIMIT=""
ENV_HOST_PORT=""
grep -qa '^MEM_LIMIT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_MEM_LIMIT=$(grep -a '^MEM_LIMIT=' "$INSTALL_DIR/.env" | cut -d= -f2)
grep -qa '^HOST_PORT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_HOST_PORT=$(grep -a '^HOST_PORT=' "$INSTALL_DIR/.env" | cut -d= -f2)

if [[ -n "$ENV_MEM_LIMIT" || -n "$ENV_HOST_PORT" ]]; then
    {
        echo "services:"
        echo "  wg-easy:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:51821/tcp\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'wg-easy-app' container."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct web-UI access."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting WireGuard (wg-easy)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start WireGuard. Check log: $LOGFILE"

INIT_HOST_SHOWN=$(grep -a '^INIT_HOST=' "$INSTALL_DIR/.env" | cut -d= -f2)

print_info "WireGuard (wg-easy) is starting."
echo
echo "──────────────────────────────────────────────"
echo "🔌 VPN endpoint: $INIT_HOST_SHOWN:51820 (UDP — always on)"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 Web UI:       http://$SERVER_IP:$ENV_HOST_PORT"
fi
echo "🔗 Proxy target: wg-easy-app:51821 on 'main-net'"
echo "👤 Web login:    username 'admin' + the generated password — see secrets file below"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
echo "Set up NGINX Proxy Manager for the web UI: forward to wg-easy-app,"
echo "port 51821, enable SSL. NPM sends X-Forwarded-Proto correctly by"
echo "default, so login should work through it without extra steps — if"
echo "wg-easy still says 'insecure connection', see the README's Reverse"
echo "Proxy section for what to check. Then log in and add your first"
echo "peer/device — each one gets a config file and a QR code for mobile."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

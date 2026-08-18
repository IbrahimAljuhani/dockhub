#!/bin/bash
# deploy.sh (services/DNS/pi-hole)
# Purpose: Deploy Pi-hole — see docker-compose.yml for the deliberate
# deviations from upstream's own docker-compose example.
#
# This is a single-instance service: one Pi-hole deployment per host, under
# ~/docker/pi-hole/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Pi-hole behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/pi-hole"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.pihole-docker-secrets.txt"

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

# Unlike every other service's optional host-port prompt, DNS port 53 is
# never optional — Pi-hole is useless without it. Check it up front with a
# specific, actionable fix instead of letting the container fail to start
# with a generic "port is already allocated" error. This is THE classic
# Pi-hole-on-Ubuntu gotcha: systemd-resolved binds port 53 by default on
# almost every fresh Ubuntu install.
if port_in_use 53; then
    print_warn "Port 53 (DNS) looks already in use — most likely systemd-resolved, which binds it by default on Ubuntu. Pi-hole cannot start without this port."
    print_warn "Fix: edit /etc/systemd/resolved.conf, set DNSStubListener=no, then run:"
    print_warn "  sudo rm /etc/resolv.conf && sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf && sudo systemctl restart systemd-resolved"
    read -rp "Continue deploying anyway? (y/N): " continue_anyway
    [[ "${continue_anyway,,}" == "y" ]] || print_error "Aborted — free up port 53 first (see above), then rerun deploy.sh."
fi

mkdir -p "$INSTALL_DIR"

ensure_main_net

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    WEBPASSWORD=$(generate_secret)
    prompt_mem_limit "pihole-app" "512m"
    # Suggested default is deliberately NOT 80 — NGINX Proxy Manager already
    # owns host port 80 on this server (see install_dockhub.sh).
    prompt_host_port "8081"

    cat > "$INSTALL_DIR/.env" <<EOF
PIHOLE_VERSION=latest
TZ=UTC
WEBPASSWORD=$WEBPASSWORD
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Pi-hole secrets - DO NOT SHARE"
        echo "$(date '+%F %T')"
        echo "  WEBPASSWORD=$WEBPASSWORD"
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
# Note: unlike other services, HOST_PORT here maps to the WEB UI (80), not
# DNS — port 53 is unconditional and already in the base compose file.
ENV_MEM_LIMIT=""
ENV_HOST_PORT=""
grep -qa '^MEM_LIMIT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_MEM_LIMIT=$(grep -a '^MEM_LIMIT=' "$INSTALL_DIR/.env" | cut -d= -f2)
grep -qa '^HOST_PORT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_HOST_PORT=$(grep -a '^HOST_PORT=' "$INSTALL_DIR/.env" | cut -d= -f2)

if [[ -n "$ENV_MEM_LIMIT" || -n "$ENV_HOST_PORT" ]]; then
    {
        echo "services:"
        echo "  pihole:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:80\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'pihole-app' container."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct web-UI access."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Pi-hole..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Pi-hole. Check log: $LOGFILE"

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"

print_info "Pi-hole is starting."
echo
echo "──────────────────────────────────────────────"
echo "🌐 DNS:          $SERVER_IP:53  (always on — point your router/devices here)"
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "🌐 Web UI:       http://$SERVER_IP:$ENV_HOST_PORT/admin"
fi
echo "🔗 Proxy target: pihole-app:80 on 'main-net'"
echo "👤 Web login:    password only (no username) — see secrets file below"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
echo "👉 NEXT STEP: Pi-hole blocks nothing until devices actually use it as"
echo "   their DNS server. Set your router's DNS (or each device's, for a"
echo "   partial rollout) to $SERVER_IP — check your router's admin panel"
echo "   for where to change this (usually under WAN/LAN or DHCP settings)."
echo
echo "Set up NGINX Proxy Manager for the web UI: forward to pihole-app,"
echo "port 80, enable SSL."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

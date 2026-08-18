#!/bin/bash
# deploy.sh (services/Home-Automation/home-assistant)
# Purpose: Deploy Home Assistant Container — see docker-compose.yml for why
# it uses host networking + privileged mode, unlike every other service in
# this repo.
#
# This is a single-instance service: one Home Assistant deployment per
# host, under ~/docker/home-assistant/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Home Assistant Container (host networking, privileged)."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/home-assistant"
LOGFILE="$INSTALL_DIR/deploy.log"

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

# No ensure_main_net here — host networking means this container never
# joins main-net (see docker-compose.yml's header comment), so it would be
# dead code for this specific service.

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    print_warn "Home Assistant runs with --privileged and host networking (official requirement, not a shortcut — see README.md's 'Why Host Networking' section). This grants it broader host access than any other service in this repo."

    prompt_mem_limit "homeassistant" "1g"

    cat > "$INSTALL_DIR/.env" <<EOF
HA_VERSION=stable
TZ=UTC
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    print_info "Generated .env at $INSTALL_DIR/.env."
fi

mkdir -p "$INSTALL_DIR/config"

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from whatever .env currently has.
# Only a memory cap can go here — there's no host-port toggle for this
# service (see docker-compose.yml's header comment).
ENV_MEM_LIMIT=""
grep -qa '^MEM_LIMIT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_MEM_LIMIT=$(grep -a '^MEM_LIMIT=' "$INSTALL_DIR/.env" | cut -d= -f2)

if [[ -n "$ENV_MEM_LIMIT" ]]; then
    {
        echo "services:"
        echo "  homeassistant:"
        echo "    mem_limit: $ENV_MEM_LIMIT"
    } > "$INSTALL_DIR/docker-compose.override.yml"
    print_info "Memory limit $ENV_MEM_LIMIT applied to the 'homeassistant' container."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Home Assistant (first run can take a minute or two)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Home Assistant. Check log: $LOGFILE"

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"

print_info "Home Assistant is starting."
echo
echo "──────────────────────────────────────────────"
echo "🌐 URL:          http://$SERVER_IP:8123"
echo "👤 First visit:  follow the setup wizard — create your own admin account"
echo "📁 Config:       $INSTALL_DIR/config"
echo "📜 Log:          $LOGFILE"
echo "──────────────────────────────────────────────"
echo
echo "Port 8123 is always bound directly to the host (host networking, no"
echo "'optional host port' choice like other services here)."
echo
echo "Set up NGINX Proxy Manager: forward to $SERVER_IP, port 8123 — NOT a"
echo "container name, since this container doesn't join 'main-net'. You"
echo "must ALSO add these lines to $INSTALL_DIR/config/configuration.yaml"
echo "(Home Assistant rejects requests from unlisted reverse proxies):"
echo
echo "  http:"
echo "    use_x_forwarded_for: true"
echo "    trusted_proxies:"
echo "      - <main-net's subnet — see README.md's Reverse Proxy section>"
echo
echo "Then restart: cd $INSTALL_DIR && $COMPOSE_CMD restart"
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

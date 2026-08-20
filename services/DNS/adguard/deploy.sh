#!/bin/bash
# deploy.sh (services/DNS/adguard)
# Purpose: Deploy AdGuard Home — see docker-compose.yml for the deliberate
# deviations from upstream's typical example.
#
# This is a single-instance service: one AdGuard Home deployment per host,
# under ~/docker/adguard/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy AdGuard Home behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/adguard"
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

# Unlike every other service's optional host-port prompt, DNS port 53 is
# never optional — AdGuard Home is useless without it. Check it up front
# with a specific, actionable fix instead of letting the container fail to
# start with a generic "port is already allocated" error. Same gotcha as
# this repo's Pi-hole: systemd-resolved binds port 53 by default on almost
# every fresh Ubuntu install.
if port_in_use 53; then
    print_warn "Port 53 (DNS) looks already in use — most likely systemd-resolved, which binds it by default on Ubuntu. AdGuard Home cannot start without this port."
    print_warn "Fix: edit /etc/systemd/resolved.conf, set DNSStubListener=no, then run:"
    print_warn "  sudo rm /etc/resolv.conf && sudo ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf && sudo systemctl restart systemd-resolved"
    read -rp "Continue deploying anyway? (y/N): " continue_anyway
    [[ "${continue_anyway,,}" == "y" ]] || print_error "Aborted — free up port 53 first (see above), then rerun deploy.sh."
fi

# AdGuard Home has no unattended/env-var setup — the setup-wizard port
# (3000) and the admin UI port you choose during that wizard both need
# direct browser access at least once, unless you bootstrap through NPM by
# pointing a Proxy Host at the container by name first (see README.md).
# This asks once whether to publish both host ports together for the
# simpler direct-access path. Sets SETUP_PORT/ADMIN_PORT in the caller's
# shell (empty if declined).
SETUP_PORT=""
ADMIN_PORT=""
prompt_adguard_ports() {
    local answer
    read -rp "Also publish host ports for direct access to the setup wizard and admin UI without NPM? (y/N): " answer
    [[ "${answer,,}" == "y" ]] || return 0

    local cont
    while true; do
        read -rp "Setup wizard port (default 3000): " SETUP_PORT
        SETUP_PORT="${SETUP_PORT:-3000}"
        if ! valid_port "$SETUP_PORT"; then
            echo "Invalid port — must be a number between 1024 and 65535." >&2
            continue
        fi
        if port_in_use "$SETUP_PORT"; then
            read -rp "Port $SETUP_PORT looks already in use — continue anyway? (y/N): " cont
            [[ "${cont,,}" == "y" ]] || continue
        fi
        break
    done

    # This next prompt is for the HOST (your server) — a completely
    # separate thing from the container's own internal Admin Web Interface
    # port, which you'll pick as 80 inside the wizard itself later (see the
    # final instructions after deploy). Printed as its own line, not
    # crammed into the prompt text, specifically to avoid the two numbers
    # being misread as one question.
    echo "The next port is on the HOST (your server) — separate from the port" >&2
    echo "you'll choose inside AdGuard Home's own setup wizard later (see the" >&2
    echo "instructions printed after this finishes deploying)." >&2
    while true; do
        read -rp "Admin UI port on the host (default 8080): " ADMIN_PORT
        ADMIN_PORT="${ADMIN_PORT:-8080}"
        if ! valid_port "$ADMIN_PORT"; then
            echo "Invalid port — must be a number between 1024 and 65535." >&2
            continue
        fi
        if [[ "$ADMIN_PORT" == "$SETUP_PORT" ]]; then
            echo "Must be different from the setup wizard port ($SETUP_PORT)." >&2
            continue
        fi
        if port_in_use "$ADMIN_PORT"; then
            read -rp "Port $ADMIN_PORT looks already in use — continue anyway? (y/N): " cont
            [[ "${cont,,}" == "y" ]] || continue
        fi
        break
    done
}

mkdir -p "$INSTALL_DIR"

ensure_main_net

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    prompt_mem_limit "adguard-app" "256m"
    prompt_adguard_ports

    cat > "$INSTALL_DIR/.env" <<EOF
ADGUARD_VERSION=latest
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$SETUP_PORT" ]] && echo "SETUP_PORT=$SETUP_PORT" >> "$INSTALL_DIR/.env"
    [[ -n "$ADMIN_PORT" ]] && echo "ADMIN_PORT=$ADMIN_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    print_info "Generated .env at $INSTALL_DIR/.env."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from whatever .env currently has.
ENV_MEM_LIMIT=""
ENV_SETUP_PORT=""
ENV_ADMIN_PORT=""
grep -qa '^MEM_LIMIT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_MEM_LIMIT=$(grep -a '^MEM_LIMIT=' "$INSTALL_DIR/.env" | cut -d= -f2)
grep -qa '^SETUP_PORT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_SETUP_PORT=$(grep -a '^SETUP_PORT=' "$INSTALL_DIR/.env" | cut -d= -f2)
grep -qa '^ADMIN_PORT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_ADMIN_PORT=$(grep -a '^ADMIN_PORT=' "$INSTALL_DIR/.env" | cut -d= -f2)

if [[ -n "$ENV_MEM_LIMIT" || -n "$ENV_SETUP_PORT" ]]; then
    {
        echo "services:"
        echo "  adguardhome:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_SETUP_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_SETUP_PORT:3000/tcp\""
            echo "      - \"$ENV_ADMIN_PORT:80/tcp\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'adguard-app' container."
    [[ -n "$ENV_SETUP_PORT" ]] && print_info "Host ports $ENV_SETUP_PORT (setup) and $ENV_ADMIN_PORT (admin UI) published for direct access."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting AdGuard Home..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start AdGuard Home. Check log: $LOGFILE"

SERVER_IP=$(host_lan_ip)
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"

print_info "AdGuard Home is starting."
echo
echo "──────────────────────────────────────────────"
echo "🌐 DNS:          $SERVER_IP:53  (always on — point your router/devices here after setup)"
if [[ -n "$ENV_SETUP_PORT" ]]; then
    echo "🧙 Setup wizard: http://$SERVER_IP:$ENV_SETUP_PORT"
    echo "🌐 Admin UI:     http://$SERVER_IP:$ENV_ADMIN_PORT  (after setup)"
else
    echo "🧙 Setup wizard: via NPM — see README.md's Reverse Proxy section for the"
    echo "   two-step Proxy Host bootstrap this requires (no direct host port)."
fi
echo "🔗 Proxy target: adguard-app on 'main-net' (port 3000 for setup, then"
echo "   whichever admin port you choose in the wizard)"
echo "📜 Log:          $LOGFILE"
echo "──────────────────────────────────────────────"
echo
echo "👉 In the setup wizard: pick port 80 for the 'Admin Web Interface' —"
echo "   this matches every other service here's NPM-forwards-to-port-80"
echo "   convention. Create your own admin username/password there too;"
echo "   AdGuard Home has no default account and no env-var-based setup."
echo
echo "👉 NEXT STEP after setup: point your router's DNS (or each device's,"
echo "   for a partial rollout) to $SERVER_IP — AdGuard Home blocks nothing"
echo "   until devices actually use it as their DNS server."
echo
echo "Set up NGINX Proxy Manager for the admin UI: forward to adguard-app,"
echo "port 80, enable SSL."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

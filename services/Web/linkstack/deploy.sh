#!/bin/bash
# deploy.sh (services/Web/linkstack)
# Purpose: Deploy LinkStack (single container, SQLite embedded — see
# docker-compose.yml for the deliberate deviations from upstream's own
# docker-compose example).
#
# LinkStack is multi-instance (like this repo's Odoo): each instance gets
# its own directory under ~/docker/linkstack/<instance>/, so you can run
# more than one LinkStack site on the same host. Unlike this repo's other
# services, deploy.sh always asks for an instance name and always creates
# a fresh one — it does not have a "rerun to manage an existing instance"
# flow (same as Odoo); rerunning just lets you add another instance.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy a LinkStack instance behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/linkstack"

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

read -rp "Enter instance name (e.g., linkstack-prod): " INSTANCE_NAME
validate_identifier "$INSTANCE_NAME" "instance name"
INSTANCE_DIR="$INSTALL_DIR/$INSTANCE_NAME"
[[ -d "$INSTANCE_DIR" ]] && print_error "Instance '$INSTANCE_NAME' already exists."

prompt_mem_limit "linkstack-$INSTANCE_NAME" "512m"
prompt_host_port "8095"

# HTTP_SERVER_NAME/HTTPS_SERVER_NAME are Apache's ServerName for each
# vhost — not security-critical here (LinkStack has no CORS/host-header
# check like Vikunja/Plane), but should still match how you access it so
# any auto-generated links are correct. Derive from the host port when
# chosen, otherwise ask for the real domain — same pattern as this repo's
# other services.
if [[ -n "$HOST_PORT" ]]; then
    SERVER_IP_FOR_NAME=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${SERVER_IP_FOR_NAME:-}" ]] && SERVER_IP_FOR_NAME="localhost"
    SERVER_NAME_VALUE="$SERVER_IP_FOR_NAME"
    print_info "Using '$SERVER_NAME_VALUE' as the server name. Once you switch to NPM, edit SERVER_NAME in .env to your real domain."
else
    # Format-checked too, not just non-empty: an invisible character tagging
    # along from a paste silently corrupts every URL built from this.
    # prompt_domain re-asks instead of aborting the whole deploy — see
    # lib/common.sh.
    prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. links.example.com): " "domain"
    LINKSTACK_DOMAIN="$PROMPTED_DOMAIN"
    SERVER_NAME_VALUE="$LINKSTACK_DOMAIN"
fi

ensure_main_net

mkdir -p "$INSTANCE_DIR"
LOGFILE="$INSTANCE_DIR/deploy.log"

cat > "$INSTANCE_DIR/.env" <<EOF
INSTANCE_NAME=$INSTANCE_NAME
LINKSTACK_VERSION=latest
TZ=UTC
SERVER_ADMIN=admin@localhost
SERVER_NAME=$SERVER_NAME_VALUE
EOF
[[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTANCE_DIR/.env"
[[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTANCE_DIR/.env"
chmod 600 "$INSTANCE_DIR/.env"
print_info "Generated .env at $INSTANCE_DIR/.env."

cp "$SOURCE_DIR/docker-compose.yml" "$INSTANCE_DIR/docker-compose.yml"

# docker-compose.override.yml adds the optional host port / memory cap on
# top of the static template above. Like Odoo, deploy.sh only ever runs
# once per instance (it refuses to touch an existing one), so this file is
# generated here and then never regenerated automatically — to change it
# later, hand-edit this file directly, then
# cd $INSTANCE_DIR && $COMPOSE_CMD up -d
if [[ -n "$MEM_LIMIT" || -n "$HOST_PORT" ]]; then
    {
        echo "services:"
        echo "  linkstack:"
        [[ -n "$MEM_LIMIT" ]] && echo "    mem_limit: $MEM_LIMIT"
        if [[ -n "$HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$HOST_PORT:80\""
        fi
    } > "$INSTANCE_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTANCE_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting LinkStack instance '$INSTANCE_NAME'..."
(cd "$INSTANCE_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start LinkStack. Check log: $LOGFILE"

print_info "LinkStack instance '$INSTANCE_NAME' is starting."
echo
echo "──────────────────────────────────────────────"
if [[ -n "$HOST_PORT" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 URL:          http://$SERVER_IP:$HOST_PORT"
fi
echo "🔗 Proxy target: linkstack-$INSTANCE_NAME:443 (HTTPS, self-signed) on 'main-net'"
echo "👤 First visit:  follow the setup wizard — create your own admin account"
echo "📜 Log:          $LOGFILE"
echo "──────────────────────────────────────────────"
echo
echo "Set up NGINX Proxy Manager: forward to linkstack-$INSTANCE_NAME, port 443,"
echo "forward scheme HTTPS (not HTTP — LinkStack's container terminates its"
echo "own self-signed TLS on 443; proxying plain HTTP to port 80 causes"
echo "mixed-content errors per upstream's own docs). Enable SSL on the NPM"
echo "side too. See the README's Reverse Proxy section."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTANCE_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

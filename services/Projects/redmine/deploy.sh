#!/bin/bash
# deploy.sh (services/Projects/redmine)
# Purpose: Deploy the Redmine stack (app, db) — see docker-compose.yml for
# the full stack and the deliberate deviations from the official redmine
# Docker Hub image's own docker-compose example.
#
# This is a single-instance service: one Redmine deployment per host, under
# ~/docker/redmine/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy the Redmine stack behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/redmine"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.redmine-docker-secrets.txt"

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
    POSTGRES_PASSWORD=$(generate_secret)
    SECRET_KEY_BASE=$(generate_secret)
    prompt_mem_limit "redmine" "512m"
    prompt_host_port "3000"

    cat > "$INSTALL_DIR/.env" <<EOF
REDMINE_VERSION=6-alpine
POSTGRES_USER=redmine
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=redmine
SECRET_KEY_BASE=$SECRET_KEY_BASE
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Redmine secrets - DO NOT SHARE"
        echo "$(date '+%F %T')"
        echo "  POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
        echo "  SECRET_KEY_BASE=$SECRET_KEY_BASE"
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved a copy of the secrets to $SECRETS_FILE."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

# Bind-mount targets for plugins/themes — created explicitly (and owned by
# the invoking user) so Docker doesn't create them as root on first 'up -d'.
mkdir -p "$INSTALL_DIR/plugins" "$INSTALL_DIR/themes"

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from whatever .env currently has.
ENV_MEM_LIMIT=""
ENV_HOST_PORT=""
grep -qa '^MEM_LIMIT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_MEM_LIMIT=$(grep -a '^MEM_LIMIT=' "$INSTALL_DIR/.env" | cut -d= -f2)
grep -qa '^HOST_PORT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_HOST_PORT=$(grep -a '^HOST_PORT=' "$INSTALL_DIR/.env" | cut -d= -f2)

if [[ -n "$ENV_MEM_LIMIT" || -n "$ENV_HOST_PORT" ]]; then
    {
        echo "services:"
        echo "  redmine:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:3000\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'redmine' container (db stays unbounded)."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Redmine..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Redmine. Check log: $LOGFILE"

print_info "Redmine is starting."
echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(host_lan_ip)
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 URL:          http://$SERVER_IP:$ENV_HOST_PORT"
fi
echo "🔗 Proxy target: redmine-app:3000 on 'main-net'"
echo "👤 First login:  admin / admin — change this immediately (My account → Change password)"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
echo "Set up NGINX Proxy Manager: forward to redmine-app:3000, enable SSL."
echo "Then set your real URL from inside Redmine itself: Administration ->"
echo "Settings -> General -> \"Host name and path\" (used for links in emails) —"
echo "unlike this repo's other services, Redmine has no deploy-time domain"
echo "setting; it's entirely configured from its own admin UI after login."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

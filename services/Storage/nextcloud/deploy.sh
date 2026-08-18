#!/bin/bash
# deploy.sh (services/Storage/nextcloud)
# Purpose: Deploy the Nextcloud stack (app, db, redis, cron) — see
# docker-compose.yml for the full stack and the deliberate deviations from
# the official nextcloud/docker reference compose.
#
# This is a single-instance service: one Nextcloud deployment per host,
# under ~/docker/nextcloud/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy the Nextcloud stack behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/nextcloud"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.nextcloud-docker-secrets.txt"

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
    read -rp "Enter the admin username (default: admin): " ADMIN_USER
    ADMIN_USER="${ADMIN_USER:-admin}"

    POSTGRES_PASSWORD=$(generate_secret)
    ADMIN_PASSWORD=$(generate_secret)
    prompt_mem_limit "app" "1g"
    prompt_host_port "8080"

    # NEXTCLOUD_TRUSTED_DOMAINS must match the browser's actual Host header
    # exactly, or Nextcloud rejects every request with "Access through
    # untrusted domain" — so it can't just be an arbitrary placeholder domain
    # when accessed directly by IP:port. OVERWRITEPROTOCOL=https also makes
    # Nextcloud force-redirect to https://, which makes a bare-HTTP direct
    # host port completely inaccessible. Both are only asked/derived here
    # when NOT using a host port; flip them back once NPM/SSL is set up
    # (edit .env and rerun deploy.sh).
    if [[ -n "$HOST_PORT" ]]; then
        OVERWRITEPROTOCOL_VALUE="http"
        SERVER_IP_FOR_DOMAIN=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "${SERVER_IP_FOR_DOMAIN:-}" ]] && SERVER_IP_FOR_DOMAIN="localhost"
        TRUSTED_DOMAIN="$SERVER_IP_FOR_DOMAIN:$HOST_PORT"
        print_info "Using '$TRUSTED_DOMAIN' as NEXTCLOUD_TRUSTED_DOMAINS (must match how you access it). Once you switch to NPM, edit this to your real domain in .env."
    else
        OVERWRITEPROTOCOL_VALUE="https"
        # Format-checked too, not just non-empty: an invisible character
        # tagging along from a paste silently corrupts every URL built from
        # this. prompt_domain re-asks instead of aborting the whole deploy —
        # see lib/common.sh.
        prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. cloud.example.com): " "domain"
        TRUSTED_DOMAIN="$PROMPTED_DOMAIN"
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
POSTGRES_DB=nextcloud
POSTGRES_USER=nextcloud
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
NEXTCLOUD_TRUSTED_DOMAINS=$TRUSTED_DOMAIN
NEXTCLOUD_ADMIN_USER=$ADMIN_USER
NEXTCLOUD_ADMIN_PASSWORD=$ADMIN_PASSWORD
OVERWRITEPROTOCOL=$OVERWRITEPROTOCOL_VALUE
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Nextcloud secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): domain=$TRUSTED_DOMAIN"
        echo "  Admin user:     $ADMIN_USER"
        echo "  Admin password: $ADMIN_PASSWORD"
        echo "  POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved a copy of the secrets to $SECRETS_FILE."
    print_warn "Admin password: $ADMIN_PASSWORD — also saved to $SECRETS_FILE."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from whatever .env currently has.
ENV_MEM_LIMIT=""
ENV_HOST_PORT=""
grep -qa '^MEM_LIMIT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_MEM_LIMIT=$(grep -a '^MEM_LIMIT=' "$INSTALL_DIR/.env" | cut -d= -f2)
grep -qa '^HOST_PORT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_HOST_PORT=$(grep -a '^HOST_PORT=' "$INSTALL_DIR/.env" | cut -d= -f2)

if [[ -n "$ENV_MEM_LIMIT" || -n "$ENV_HOST_PORT" ]]; then
    {
        echo "services:"
        echo "  app:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:80\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'app' container (db/redis/cron stay unbounded)."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Nextcloud..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Nextcloud. Check log: $LOGFILE"

print_info "Nextcloud is starting."
echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 URL:          http://$SERVER_IP:$ENV_HOST_PORT"
fi
echo "🔗 Proxy target: nextcloud-app:80 on 'main-net'"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
echo "Set up NGINX Proxy Manager: forward to nextcloud-app:80, enable Websockets"
echo "Support, enable SSL (see README.md 'Reverse Proxy' section)."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

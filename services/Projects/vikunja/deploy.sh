#!/bin/bash
# deploy.sh (services/Projects/vikunja)
# Purpose: Deploy the Vikunja stack (app, db) — see docker-compose.yml for
# the full stack and the deliberate deviations from the official Vikunja
# Docker Hub image's own docker-compose example.
#
# This is a single-instance service: one Vikunja deployment per host, under
# ~/docker/vikunja/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy the Vikunja stack behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/vikunja"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.vikunja-docker-secrets.txt"

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
    SECRET_KEY=$(generate_secret)
    prompt_mem_limit "vikunja" "512m"
    prompt_host_port "3456"

    # VIKUNJA_SERVICE_PUBLICURL must match the browser's actual access URL
    # exactly (scheme + host + trailing slash) — Vikunja's CORS check
    # rejects requests otherwise ("The default configuration has CORS
    # enabled, which requires a public URL to be set", per upstream docs).
    # Same reasoning as OpenProject/Nextcloud/n8n's domain handling: derive
    # it from the host port when chosen, otherwise ask for the real domain.
    if [[ -n "$HOST_PORT" ]]; then
        SERVER_IP_FOR_URL=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "${SERVER_IP_FOR_URL:-}" ]] && SERVER_IP_FOR_URL="localhost"
        PUBLIC_URL_VALUE="http://$SERVER_IP_FOR_URL:$HOST_PORT/"
        print_info "Using '$PUBLIC_URL_VALUE' as VIKUNJA_SERVICE_PUBLICURL (must match how you access it). Once you switch to NPM, edit this to your real domain in .env."
    else
        # Format-checked too, not just non-empty: an invisible character
        # tagging along from a paste silently corrupts every URL built from
        # this. prompt_domain re-asks instead of aborting the whole deploy —
        # see lib/common.sh.
        prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. vikunja.example.com): " "domain"
        VIKUNJA_DOMAIN="$PROMPTED_DOMAIN"
        PUBLIC_URL_VALUE="https://$VIKUNJA_DOMAIN/"
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
VIKUNJA_VERSION=latest
POSTGRES_USER=vikunja
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=vikunja
SECRET_KEY=$SECRET_KEY
PUBLIC_URL=$PUBLIC_URL_VALUE
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Vikunja secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): public_url=$PUBLIC_URL_VALUE"
        echo "  POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
        echo "  SECRET_KEY=$SECRET_KEY"
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved a copy of the secrets to $SECRETS_FILE."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

# Vikunja runs as UID 1000 with no group and needs write access to the
# files/ bind mount (uploaded attachments) — per upstream's own docs. Try
# direct chown first, then passwordless sudo, then warn (matches odoo's
# config/addons chown pattern in this repo).
mkdir -p "$INSTALL_DIR/files"
if chown 1000 "$INSTALL_DIR/files" 2>/dev/null; then
    print_info "Set ownership of files/ to uid 1000."
elif sudo -n chown 1000 "$INSTALL_DIR/files" 2>/dev/null; then
    print_info "Set ownership of files/ to uid 1000 (via sudo)."
else
    print_warn "Could not chown files/ to uid 1000 automatically. Vikunja needs write access to it for attachments — run: sudo chown 1000 $INSTALL_DIR/files"
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
        echo "  vikunja:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:3456\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'vikunja' container (db stays unbounded)."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Vikunja..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Vikunja. Check log: $LOGFILE"

print_info "Vikunja is starting."
echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 URL:          http://$SERVER_IP:$ENV_HOST_PORT"
fi
echo "🔗 Proxy target: vikunja-app:3456 on 'main-net'"
echo "👤 First visit:  register your own account — Vikunja has no default admin"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "⚠️  VIKUNJA_SERVICE_PUBLICURL was set to your bare IP:port for this direct"
    echo "   port to work at all (Vikunja rejects requests otherwise — CORS check)."
    echo "   Once you switch to NPM+SSL, edit PUBLIC_URL=https://<domain>/ in .env"
    echo "   and rerun deploy.sh."
    echo
fi
echo "Set up NGINX Proxy Manager: forward to vikunja-app:3456, enable SSL."
echo "After creating your account, consider disabling public registration:"
echo "see the README's 'Disabling Registration' section."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

#!/bin/bash
# deploy.sh (services/ERP/dolibarr)
# Purpose: Deploy Dolibarr (app + MariaDB) — see docker-compose.yml for the
# stack and the deliberate deviations from Dolibarr's own docker-compose
# example.
#
# This is a single-instance service (unlike services/ERP/odoo, which supports
# multiple named instances): one Dolibarr deployment per host, under
# ~/docker/dolibarr/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Dolibarr behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/dolibarr"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.dolibarr-docker-secrets.txt"

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
    DB_ROOT_PASSWORD=$(generate_secret 24)
    DB_PASSWORD=$(generate_secret 24)
    ADMIN_PASSWORD=$(generate_secret 20)
    # Encryption salt for stored passwords and API keys. Generated once and
    # kept in .env forever: if this ever changes, everything Dolibarr
    # encrypted with the old value becomes unreadable.
    INSTANCE_UNIQUE_ID=$(generate_secret_hex 32)
    CRON_KEY=$(generate_secret_hex 16)

    prompt_mem_limit "dolibarr-app" "1g"
    prompt_host_port "8086"

    # DOLI_URL_ROOT is the base URL Dolibarr builds links from, so it has to
    # match how the site is actually reached — same class of setting as
    # OpenProject's OPENPROJECT_HOST__NAME. Only one of the two paths is
    # asked for, matching the host-port choice just made.
    if [[ -n "$HOST_PORT" ]]; then
        SERVER_IP_FOR_URL=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
        [[ -z "${SERVER_IP_FOR_URL:-}" ]] && SERVER_IP_FOR_URL="localhost"
        URL_ROOT_VALUE="http://$SERVER_IP_FOR_URL:$HOST_PORT"
        print_info "Using '$URL_ROOT_VALUE' as DOLI_URL_ROOT. Once you switch to NPM, edit it in .env to your https:// domain and rerun."
    else
        prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. erp.example.com): " "domain"
        URL_ROOT_VALUE="https://$PROMPTED_DOMAIN"
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
DOLIBARR_VERSION=23
TZ=UTC
DOLI_DB_NAME=dolidb
DOLI_DB_USER=dolidbuser
DOLI_DB_PASSWORD=$DB_PASSWORD
DOLI_DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD
DOLI_INSTANCE_UNIQUE_ID=$INSTANCE_UNIQUE_ID
DOLI_URL_ROOT=$URL_ROOT_VALUE
DOLI_ADMIN_LOGIN=admin
DOLI_ADMIN_PASSWORD=$ADMIN_PASSWORD
DOLI_CRON_KEY=$CRON_KEY
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Dolibarr secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): url=$URL_ROOT_VALUE"
        echo "  Dolibarr login:     admin"
        echo "  Dolibarr password:  $ADMIN_PASSWORD"
        echo "  MariaDB user pass:  $DB_PASSWORD"
        echo "  MariaDB root pass:  $DB_ROOT_PASSWORD"
        echo "  Encryption salt:    $INSTANCE_UNIQUE_ID"
        echo "  (the salt decrypts stored passwords/API keys — keep it with your backups)"
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
ENV_URL_ROOT=$(read_env_value "DOLI_URL_ROOT" "$INSTALL_DIR/.env")

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from whatever .env currently has.
if [[ -n "$ENV_MEM_LIMIT" || -n "$ENV_HOST_PORT" ]]; then
    {
        echo "services:"
        echo "  dolibarr-app:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:80\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'dolibarr-app' container (the database stays unbounded)."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

# The NPM upload-size block, written to a file instead of only living in the
# README — so it can be copied straight off the server with `cat` rather than
# out of a browser. Quoted heredoc: nothing here needs expanding.
cat > "$INSTALL_DIR/npm-custom-nginx.conf" <<'NGINXEOF'
# Paste this whole file into NGINX Proxy Manager:
#   Edit Proxy Host → ⚙️ gear icon → "Custom Nginx Configuration" → Save
# (not the "Custom Locations" tab — that's a different feature)
#
# Dolibarr's PHP accepts 32 MB uploads, but NGINX Proxy Manager applies its
# own limit first and rejects the request before PHP ever sees it. Without
# this, attaching a scanned invoice fails with "413 Request Entity Too Large"
# and nothing appears in Dolibarr's own logs to explain why.

client_max_body_size 40M;
NGINXEOF

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Dolibarr (first run installs the database — this takes a minute or two)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Dolibarr. Check log: $LOGFILE"

print_info "Dolibarr is starting."
echo
echo "──────────────────────────────────────────────"
echo "🌐 URL:          $ENV_URL_ROOT"
echo "🔗 Proxy target: dolibarr-app:80 on 'main-net'"
echo "👤 Login:        admin / the generated password below"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "⚠️  DOLI_URL_ROOT is set to the direct host-port URL above. When you"
    echo "   switch to NPM+SSL, edit it in .env to your https:// domain and"
    echo "   rerun deploy.sh — Dolibarr builds its links from that value."
    echo
fi
echo "Set up NGINX Proxy Manager:"
echo "   1. Forward to  dolibarr-app : 80"
echo "   2. ⚙️ gear icon → 'Custom Nginx Configuration' → paste this file:"
echo "        cat $INSTALL_DIR/npm-custom-nginx.conf"
echo "      (raises the upload limit — without it, attachments fail with 413)"
echo "   3. Enable SSL with Let's Encrypt"
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

#!/bin/bash
# deploy.sh (services/Photos/immich)
# Purpose: Deploy Immich (server, machine-learning, redis, postgres) — see
# docker-compose.yml for the full stack and the deliberate deviations from
# the official release-attached docker-compose.yml this was verified
# against.
#
# This is a single-instance service: one Immich deployment per host, under
# ~/docker/immich/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Immich behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/immich"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.immich-docker-secrets.txt"

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
    print_warn "Immich's machine-learning container (face recognition, smart search) runs CPU-only by default and can be memory-hungry on first indexing — 2 GB+ free RAM recommended beyond whatever you cap 'immich-app' at below."

    DB_PASSWORD=$(generate_secret)
    prompt_mem_limit "immich-app" "2g"
    prompt_host_port "2283"

    cat > "$INSTALL_DIR/.env" <<EOF
IMMICH_VERSION=release
DB_USERNAME=immich
DB_PASSWORD=$DB_PASSWORD
DB_DATABASE_NAME=immich
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Immich secrets - DO NOT SHARE"
        echo "$(date '+%F %T')"
        echo "  DB_PASSWORD=$DB_PASSWORD"
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved a copy of the secrets to $SECRETS_FILE."
fi

mkdir -p "$INSTALL_DIR/library" "$INSTALL_DIR/postgres"

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
        echo "  immich-server:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:2283\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'immich-app' container (machine-learning/redis/db stay unbounded)."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

# The NPM upload-tuning block, written to a file instead of only living in
# the README — so it can be copied straight off the server with `cat` rather
# than out of a browser.
cat > "$INSTALL_DIR/npm-custom-nginx.conf" <<'NGINXEOF'
# Paste this whole file into NGINX Proxy Manager:
#   Edit Proxy Host → ⚙️ gear icon → "Custom Nginx Configuration" → Save
# (not the "Custom Locations" tab — that's a different feature)
#
# Immich's own recommended settings for large photo/video uploads. Without
# them NPM's 1 MB default body limit rejects anything but small photos.

client_max_body_size 50000M;
proxy_request_buffering off;
proxy_read_timeout 600s;
proxy_send_timeout 600s;
send_timeout 600s;
NGINXEOF

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Immich (first run pulls 4 images and can take a few minutes)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Immich. Check log: $LOGFILE"

print_info "Immich is starting."
echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(host_lan_ip)
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 URL:          http://$SERVER_IP:$ENV_HOST_PORT"
fi
echo "🔗 Proxy target: immich-app:2283 on 'main-net'"
echo "📁 Photo library: $INSTALL_DIR/library"
echo "👤 First visit:  follow the setup wizard — create your own admin account"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
echo "Set up NGINX Proxy Manager:"
echo "   1. Forward to  immich-app : 2283  + enable 'Websockets Support'"
echo "   2. ⚙️ gear icon → 'Custom Nginx Configuration' → paste this file:"
echo "        cat $INSTALL_DIR/npm-custom-nginx.conf"
echo "      (raises the upload limit — without it, big videos fail to upload)"
echo "   3. Enable SSL with Let's Encrypt"
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

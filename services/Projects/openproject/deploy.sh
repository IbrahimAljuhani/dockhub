#!/bin/bash
# deploy.sh (services/Projects/openproject)
# Purpose: Deploy the OpenProject stack (web, worker, cron, seeder, db, cache,
# hocuspocus) — see docker-compose.yml for the full stack and the deliberate
# deviations from the official opf/openproject-docker-compose repo.
#
# This is a single-instance service (unlike services/ERP/odoo, which supports
# multiple named instances): one OpenProject deployment per host, under
# ~/docker/openproject/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy the OpenProject stack behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/openproject"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.openproject-docker-secrets.txt"

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
    print_warn "OpenProject needs at least 4 GB RAM / 2 CPU cores / 20 GB disk for a small team — more for heavier use."

    POSTGRES_PASSWORD=$(generate_secret_hex 16)
    SECRET_KEY_BASE=$(generate_secret_hex 64)
    COLLABORATIVE_SERVER_SECRET=$(generate_secret_hex 32)
    prompt_mem_limit "web" "2g"
    prompt_host_port "8080"

    # OPENPROJECT_HOST__NAME must match the browser's actual Host header
    # exactly, or OpenProject rejects every request with "Invalid host_name
    # configuration" — so it can't just be an arbitrary placeholder domain
    # when accessed directly by IP:port. OPENPROJECT_HTTPS=true also makes
    # the app force-redirect to https:// and mark cookies secure-only, which
    # makes a bare-HTTP direct host port completely inaccessible. Both are
    # only asked/derived here when NOT using a host port; flip them back
    # once NPM/SSL is set up (edit .env and rerun deploy.sh).
    if [[ -n "$HOST_PORT" ]]; then
        OPENPROJECT_HTTPS_VALUE="false"
        SERVER_IP_FOR_HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "${SERVER_IP_FOR_HOST:-}" ]] && SERVER_IP_FOR_HOST="localhost"
        HOST_NAME="$SERVER_IP_FOR_HOST:$HOST_PORT"
        print_info "Using '$HOST_NAME' as OPENPROJECT_HOST__NAME (must match how you access it). Once you switch to NPM, edit this to your real domain in .env."
    else
        OPENPROJECT_HTTPS_VALUE="true"
        # Format-checked too, not just non-empty: an invisible character
        # tagging along from a paste silently corrupts every URL built from
        # this. prompt_domain re-asks instead of aborting the whole deploy —
        # see lib/common.sh.
        prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. openproject.example.com): " "host domain"
        HOST_NAME="$PROMPTED_DOMAIN"
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
OPENPROJECT_HOST__NAME=$HOST_NAME
OPENPROJECT_HTTPS=$OPENPROJECT_HTTPS_VALUE
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
SECRET_KEY_BASE=$SECRET_KEY_BASE
COLLABORATIVE_SERVER_SECRET=$COLLABORATIVE_SERVER_SECRET
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated OpenProject secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): host=$HOST_NAME"
        echo "  POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
        echo "  SECRET_KEY_BASE=$SECRET_KEY_BASE"
        echo "  COLLABORATIVE_SERVER_SECRET=$COLLABORATIVE_SERVER_SECRET"
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
ENV_MEM_LIMIT=""
ENV_HOST_PORT=""
grep -qa '^MEM_LIMIT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_MEM_LIMIT=$(grep -a '^MEM_LIMIT=' "$INSTALL_DIR/.env" | cut -d= -f2)
grep -qa '^HOST_PORT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_HOST_PORT=$(grep -a '^HOST_PORT=' "$INSTALL_DIR/.env" | cut -d= -f2)

if [[ -n "$ENV_MEM_LIMIT" || -n "$ENV_HOST_PORT" ]]; then
    {
        echo "services:"
        echo "  web:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:8080\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'web' container (db/worker/cron/seeder/hocuspocus stay unbounded)."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access (web only — /hocuspocus real-time editing still needs NPM)."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

# The NPM routing block, written to a file instead of only living in the
# README — so it can be copied straight off the server with `cat` rather
# than out of a browser. Quoted heredoc: the $ below are nginx's own
# variables, not ours.
cat > "$INSTALL_DIR/npm-custom-nginx.conf" <<'NGINXEOF'
# Paste this whole file into NGINX Proxy Manager:
#   Edit Proxy Host → ⚙️ gear icon → "Custom Nginx Configuration" → Save
# (not the "Custom Locations" tab — that's a different feature)
#
# Routes real-time collaborative editing to the hocuspocus container.
# Without it OpenProject works, but simultaneous editing of the same work
# package silently won't sync.

location /hocuspocus {
    proxy_pass http://openproject-hocuspocus:1234;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
NGINXEOF

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting OpenProject (first run seeds the database and can take a few minutes)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start OpenProject. Check log: $LOGFILE"

print_info "OpenProject is starting."
echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 URL:                     http://$SERVER_IP:$ENV_HOST_PORT"
fi
echo "🔗 Proxy target (main):     openproject-app:8080 on 'main-net'"
echo "🔗 Proxy target (realtime): openproject-hocuspocus:1234 at path /hocuspocus on 'main-net'"
echo "👤 First login:             admin / admin — you'll be forced to change it immediately"
echo "📜 Log:                     $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:                 $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "⚠️  OPENPROJECT_HTTPS was set to false for this plain-http:// direct port"
    echo "   to work at all. Real-time collaborative editing still needs NPM's"
    echo "   /hocuspocus routing regardless. Once you switch to NPM+SSL, edit"
    echo "   OPENPROJECT_HTTPS=true in .env and rerun deploy.sh."
    echo
fi
echo "Set up NGINX Proxy Manager:"
echo "   1. Forward to  openproject-app : 8080"
echo "   2. ⚙️ gear icon → 'Custom Nginx Configuration' → paste this file:"
echo "        cat $INSTALL_DIR/npm-custom-nginx.conf"
echo "      (routes /hocuspocus — without it, real-time co-editing won't sync)"
echo "   3. Enable SSL with Let's Encrypt"
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

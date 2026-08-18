#!/bin/bash
# deploy.sh (services/Web/ghost)
# Purpose: Deploy Ghost (Node.js app + MySQL) — see docker-compose.yml for
# why this service uses MySQL and not MariaDB, and the deliberate deviations
# from the official example.
#
# This is a single-instance service: one Ghost deployment per host, under
# ~/docker/ghost/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Ghost behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/ghost"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.ghost-docker-secrets.txt"

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

    prompt_mem_limit "ghost-app" "1g"
    prompt_host_port "2368"

    # Ghost builds every absolute link from `url` — canonical URLs, RSS,
    # newsletter links, and the redirect after admin login. It has to match
    # how the site is actually reached, so only one of the two paths is
    # asked for, matching the host-port choice just made.
    if [[ -n "$HOST_PORT" ]]; then
        SERVER_IP_FOR_URL=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
        [[ -z "${SERVER_IP_FOR_URL:-}" ]] && SERVER_IP_FOR_URL="localhost"
        GHOST_URL_VALUE="http://$SERVER_IP_FOR_URL:$HOST_PORT"
        print_info "Using '$GHOST_URL_VALUE' as Ghost's url. Once you switch to NPM, edit GHOST_URL in .env to your https:// domain and rerun."
    else
        prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. blog.example.com): " "domain"
        GHOST_URL_VALUE="https://$PROMPTED_DOMAIN"
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
GHOST_VERSION=6
GHOST_URL=$GHOST_URL_VALUE
GHOST_DB_NAME=ghost
GHOST_DB_USER=ghost
GHOST_DB_PASSWORD=$DB_PASSWORD
GHOST_DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Ghost secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): url=$GHOST_URL_VALUE"
        echo "  Ghost admin:       create it yourself at <url>/ghost on first visit"
        echo "  MySQL user pass:   $DB_PASSWORD"
        echo "  MySQL root pass:   $DB_ROOT_PASSWORD"
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
ENV_GHOST_URL=$(read_env_value "GHOST_URL" "$INSTALL_DIR/.env")

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from whatever .env currently has.
if [[ -n "$ENV_MEM_LIMIT" || -n "$ENV_HOST_PORT" ]]; then
    {
        echo "services:"
        echo "  ghost-app:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:2368\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'ghost-app' container (the database stays unbounded)."
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
# Ghost accepts image and media uploads well past NGINX Proxy Manager's own
# default request limit, and the proxy rejects the request before Ghost ever
# sees it. Without this, dragging a photo into the editor fails with
# "413 Request Entity Too Large" and nothing appears in Ghost's logs.

client_max_body_size 50M;
NGINXEOF

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Ghost (first run initialises the database — this takes a minute)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Ghost. Check log: $LOGFILE"

print_info "Ghost is starting."
echo
echo "──────────────────────────────────────────────"
echo "🌐 Site:         $ENV_GHOST_URL"
echo "🔑 Admin panel:  $ENV_GHOST_URL/ghost"
echo "🔗 Proxy target: ghost-app:2368 on 'main-net'"
echo "👤 First visit:  create the owner account at /ghost — there is no default login"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "⚠️  Ghost's 'url' is set to the direct host-port URL above. When you"
    echo "   switch to NPM+SSL, edit GHOST_URL in .env to your https:// domain"
    echo "   and rerun deploy.sh — every link Ghost generates comes from it."
    echo
fi
echo "Set up NGINX Proxy Manager:"
echo "   1. Forward to  ghost-app : 2368"
echo "   2. ⚙️ gear icon → 'Custom Nginx Configuration' → paste this file:"
echo "        cat $INSTALL_DIR/npm-custom-nginx.conf"
echo "      (raises the upload limit — without it, image uploads fail with 413)"
echo "   3. Enable SSL with Let's Encrypt"
echo
echo "📧 Email is not configured. Ghost works fine without it for publishing,"
echo "   but staff invites, password resets and newsletters all need SMTP."
echo "   See the README's Email section to add it."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

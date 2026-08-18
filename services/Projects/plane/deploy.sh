#!/bin/bash
# deploy.sh (services/Projects/plane)
# Purpose: Deploy the Plane stack (web, space, admin, live, api, worker,
# beat-worker, migrator, db, redis, mq, minio, proxy) — see docker-compose.yml
# for the full 13-container stack and the deliberate deviations from the
# official release-attached docker-compose.yml this was verified against.
#
# This is a single-instance service: one Plane deployment per host, under
# ~/docker/plane/. Plane needs noticeably more resources than this repo's
# other project-management services (OpenProject/Redmine/Taiga/Vikunja) —
# official docs recommend 4 GB RAM minimum, 8 GB for comfortable use.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy the Plane stack behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/plane"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.plane-docker-secrets.txt"

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
    print_warn "Plane needs roughly 4 GB RAM minimum (8 GB recommended) — it's a 13-container stack (Postgres, Redis, RabbitMQ, MinIO, and 8 app containers behind a proxy)."

    POSTGRES_PASSWORD=$(generate_secret)
    RABBITMQ_PASSWORD=$(generate_secret)
    AWS_ACCESS_KEY_ID=$(generate_secret)
    AWS_SECRET_ACCESS_KEY=$(generate_secret)
    SECRET_KEY=$(generate_secret)
    LIVE_SERVER_SECRET_KEY=$(generate_secret)
    prompt_mem_limit "plane-app" "256m"
    prompt_host_port "8090"

    # WEB_URL/CORS_ALLOWED_ORIGINS must match the browser's actual access URL
    # exactly, or Plane's CORS check rejects every request (verified against
    # the release-attached variables.env: CORS_ALLOWED_ORIGINS derives from
    # APP_DOMAIN). Same reasoning as OpenProject/Nextcloud/n8n/Vikunja's
    # domain handling: derive it from the host port when chosen, otherwise
    # ask for the real domain.
    if [[ -n "$HOST_PORT" ]]; then
        SERVER_IP_FOR_DOMAIN=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "${SERVER_IP_FOR_DOMAIN:-}" ]] && SERVER_IP_FOR_DOMAIN="localhost"
        APP_DOMAIN_VALUE="$SERVER_IP_FOR_DOMAIN:$HOST_PORT"
        WEB_URL_VALUE="http://$APP_DOMAIN_VALUE"
        print_info "Using '$APP_DOMAIN_VALUE' as APP_DOMAIN (must match how you access it). Once you switch to NPM, edit this to your real domain in .env."
    else
        # Format-checked too, not just non-empty: an invisible character
        # tagging along from a paste silently corrupts every URL built from
        # this. prompt_domain re-asks instead of aborting the whole deploy —
        # see lib/common.sh.
        prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. plane.example.com): " "domain"
        APP_DOMAIN_VALUE="$PROMPTED_DOMAIN"
        WEB_URL_VALUE="https://$APP_DOMAIN_VALUE"
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
APP_RELEASE=stable
POSTGRES_USER=plane
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=plane
RABBITMQ_USER=plane
RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
SECRET_KEY=$SECRET_KEY
LIVE_SERVER_SECRET_KEY=$LIVE_SERVER_SECRET_KEY
APP_DOMAIN=$APP_DOMAIN_VALUE
WEB_URL=$WEB_URL_VALUE
CORS_ALLOWED_ORIGINS=$WEB_URL_VALUE
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Plane secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): domain=$APP_DOMAIN_VALUE"
        echo "  POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
        echo "  RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD"
        echo "  AWS_ACCESS_KEY_ID (MinIO)=$AWS_ACCESS_KEY_ID"
        echo "  AWS_SECRET_ACCESS_KEY (MinIO)=$AWS_SECRET_ACCESS_KEY"
        echo "  SECRET_KEY=$SECRET_KEY"
        echo "  LIVE_SERVER_SECRET_KEY=$LIVE_SERVER_SECRET_KEY"
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
        echo "  proxy:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:80\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'plane-app' container (all 12 other containers stay unbounded)."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Plane (first run can take several minutes to pull 13 images and run migrations)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Plane. Check log: $LOGFILE"

print_info "Plane is starting."
echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 URL:          http://$SERVER_IP:$ENV_HOST_PORT"
fi
echo "🔗 Proxy target: plane-app:80 on 'main-net'"
echo "👤 First visit:  register your own account — Plane has no default admin"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "⚠️  APP_DOMAIN/WEB_URL/CORS_ALLOWED_ORIGINS were set to your bare IP:port"
    echo "   for this direct port to work at all (Plane rejects requests otherwise —"
    echo "   CORS check). Once you switch to NPM+SSL, edit these three to your real"
    echo "   https://domain in .env and rerun deploy.sh."
    echo
fi
echo "Set up NGINX Proxy Manager: forward to plane-app:80, enable Websockets"
echo "Support (needed for the 'live' realtime-collaboration service), enable SSL."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"
echo "First run can take a few extra minutes after containers start while"
echo "'plane-migrator' finishes database migrations — if the site errors out"
echo "immediately, wait a bit and refresh."

#!/bin/bash
# deploy.sh (services/Automation/n8n)
# Purpose: Deploy the n8n stack (app, db, external task-runner) — see
# docker-compose.yml for the full stack and the deliberate deviations from
# the official n8n-io/n8n-hosting reference compose.
#
# This is a single-instance service: one n8n deployment per host, under
# ~/docker/n8n/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy the n8n stack behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/n8n"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.n8n-docker-secrets.txt"

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
    POSTGRES_ROOT_PASSWORD=$(generate_secret)
    POSTGRES_APP_PASSWORD=$(generate_secret)
    RUNNERS_AUTH_TOKEN=$(generate_secret)
    prompt_mem_limit "app" "512m"
    prompt_host_port "5678"

    # N8N_HOST feeds URL generation/display — using the placeholder domain
    # you'd type here instead of the real IP:port would show wrong/misleading
    # URLs while testing via the direct port. N8N_PROTOCOL=https +
    # N8N_SECURE_COOKIE=true (the default) also make n8n reject login
    # entirely over a bare-http:// direct host port — browsers won't send a
    # secure-flagged cookie back over plain HTTP. All three are only
    # asked/derived here when NOT using a host port; flip them back once
    # NPM/SSL is set up (edit .env and rerun deploy.sh).
    if [[ -n "$HOST_PORT" ]]; then
        N8N_PROTOCOL_VALUE="http"
        N8N_SECURE_COOKIE_VALUE="false"
        SERVER_IP_FOR_WEBHOOK=$(host_lan_ip)
        [[ -z "${SERVER_IP_FOR_WEBHOOK:-}" ]] && SERVER_IP_FOR_WEBHOOK="localhost"
        N8N_HOST_NAME="$SERVER_IP_FOR_WEBHOOK:$HOST_PORT"
        N8N_WEBHOOK_URL_VALUE="http://$SERVER_IP_FOR_WEBHOOK:$HOST_PORT/"
        print_info "Using '$N8N_HOST_NAME' as N8N_HOST (must match how you access it). Once you switch to NPM, edit this to your real domain in .env."
    else
        N8N_PROTOCOL_VALUE="https"
        N8N_SECURE_COOKIE_VALUE="true"
        # Format-checked too, not just non-empty: an invisible character
        # tagging along from a paste silently corrupts every URL built from
        # this. prompt_domain re-asks instead of aborting the whole deploy —
        # see lib/common.sh.
        prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. n8n.example.com): " "domain"
        N8N_HOST_NAME="$PROMPTED_DOMAIN"
        N8N_WEBHOOK_URL_VALUE="https://$N8N_HOST_NAME/"
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
N8N_VERSION=stable
POSTGRES_USER=n8n_root
POSTGRES_PASSWORD=$POSTGRES_ROOT_PASSWORD
POSTGRES_DB=n8n
POSTGRES_NON_ROOT_USER=n8n
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_APP_PASSWORD
RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN
N8N_HOST=$N8N_HOST_NAME
N8N_PROTOCOL=$N8N_PROTOCOL_VALUE
N8N_WEBHOOK_URL=$N8N_WEBHOOK_URL_VALUE
N8N_SECURE_COOKIE=$N8N_SECURE_COOKIE_VALUE
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated n8n secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): host=$N8N_HOST_NAME"
        echo "  POSTGRES_PASSWORD (root)=$POSTGRES_ROOT_PASSWORD"
        echo "  POSTGRES_NON_ROOT_PASSWORD (app)=$POSTGRES_APP_PASSWORD"
        echo "  RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN"
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved a copy of the secrets to $SECRETS_FILE."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi
if [[ -f "$INSTALL_DIR/init-data.sh" ]]; then
    print_info "Existing init-data.sh found at $INSTALL_DIR — keeping it (not overwritten)."
else
    cp "$SOURCE_DIR/init-data.sh" "$INSTALL_DIR/init-data.sh"
    chmod +x "$INSTALL_DIR/init-data.sh"
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
            echo "      - \"$ENV_HOST_PORT:5678\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'app' container (db/runner stay unbounded)."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting n8n..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start n8n. Check log: $LOGFILE"

print_info "n8n is starting."
echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(host_lan_ip)
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 URL:          http://$SERVER_IP:$ENV_HOST_PORT"
fi
echo "🔗 Proxy target: n8n-app:5678 on 'main-net'"
echo "👤 First visit:  create the owner account yourself (n8n has no default admin)"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "⚠️  N8N_PROTOCOL/N8N_SECURE_COOKIE were set to http/false for this"
    echo "   plain-http:// direct port to work at all (login fails otherwise —"
    echo "   browsers won't send a secure cookie over plain HTTP). Once you"
    echo "   switch to NPM+SSL, edit N8N_PROTOCOL=https, N8N_SECURE_COOKIE=true,"
    echo "   and N8N_WEBHOOK_URL=https://<domain>/ in .env and rerun deploy.sh."
    echo
fi
echo "Set up NGINX Proxy Manager: forward to n8n-app:5678, enable Websockets"
echo "Support (needed for workflow editor live updates), enable SSL."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

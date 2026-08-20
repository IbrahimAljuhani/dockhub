#!/bin/bash
# deploy.sh (services/Storage/seafile)
# Purpose: Deploy Seafile Community Edition — see docker-compose.yml for the
# stack, why Caddy and SeaDoc are dropped, and the other deliberate
# deviations from Seafile's own 13.0 templates.
#
# This is a single-instance service: one Seafile deployment per host, under
# ~/docker/seafile/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Seafile CE behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/seafile"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.seafile-docker-secrets.txt"

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
    REDIS_PASSWORD_VALUE=$(generate_secret 24)
    ADMIN_PASSWORD=$(generate_secret 20)
    # Signs tokens between Seafile's internal services. Upstream requires at
    # least 32 characters and refuses to start without it.
    JWT_KEY=$(generate_secret_hex 32)

    prompt_mem_limit "seafile-app" "2g"
    prompt_host_port "8087"

    # Seafile splits this into hostname (no scheme) plus protocol, and uses
    # both for generated links AND for its CSRF trusted origins. A mismatch
    # doesn't fail at deploy time — it shows up later as "CSRF verification
    # failed" the moment you try to log in.
    if [[ -n "$HOST_PORT" ]]; then
        SERVER_IP_FOR_URL=$(host_lan_ip || true)
        [[ -z "${SERVER_IP_FOR_URL:-}" ]] && SERVER_IP_FOR_URL="localhost"
        # Seafile wants host:port here when the port isn't the default —
        # the value is used to build absolute URLs, so the port has to
        # travel with it.
        SEAFILE_HOSTNAME_VALUE="$SERVER_IP_FOR_URL:$HOST_PORT"
        SEAFILE_PROTOCOL_VALUE="http"
        print_info "Using '$SEAFILE_HOSTNAME_VALUE' over http as the server hostname. Switching to NPM later means editing both SEAFILE_SERVER_HOSTNAME and SEAFILE_SERVER_PROTOCOL in .env."
    else
        prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. files.example.com): " "domain"
        SEAFILE_HOSTNAME_VALUE="$PROMPTED_DOMAIN"
        SEAFILE_PROTOCOL_VALUE="https"
    fi

    read -rp "Admin email address for the first Seafile account (e.g. you@example.com): " ADMIN_EMAIL
    # Seafile uses this as the login identity, so an empty value produces an
    # account nobody can sign in to. Loop rather than abort, same reasoning
    # as prompt_domain in lib/common.sh.
    while [[ ! "$ADMIN_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; do
        print_warn "That doesn't look like an email address — Seafile uses it as the admin login."
        read -rp "Admin email address (e.g. you@example.com): " ADMIN_EMAIL
    done

    cat > "$INSTALL_DIR/.env" <<EOF
SEAFILE_VERSION=13.0-latest
TIME_ZONE=Etc/UTC
SEAFILE_SERVER_HOSTNAME=$SEAFILE_HOSTNAME_VALUE
SEAFILE_SERVER_PROTOCOL=$SEAFILE_PROTOCOL_VALUE
SEAFILE_MYSQL_DB_USER=seafile
SEAFILE_MYSQL_DB_PASSWORD=$DB_PASSWORD
INIT_SEAFILE_MYSQL_ROOT_PASSWORD=$DB_ROOT_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD_VALUE
JWT_PRIVATE_KEY=$JWT_KEY
INIT_SEAFILE_ADMIN_EMAIL=$ADMIN_EMAIL
INIT_SEAFILE_ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Seafile secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): host=$SEAFILE_PROTOCOL_VALUE://$SEAFILE_HOSTNAME_VALUE"
        echo "  Seafile login:      $ADMIN_EMAIL"
        echo "  Seafile password:   $ADMIN_PASSWORD"
        echo "  MariaDB root pass:  $DB_ROOT_PASSWORD"
        echo "  MariaDB seafile pw: $DB_PASSWORD"
        echo "  Redis password:     $REDIS_PASSWORD_VALUE"
        echo "  JWT_PRIVATE_KEY:    $JWT_KEY"
        echo "  (the JWT key signs Seafile's internal service tokens — keep it with backups)"
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
ENV_HOSTNAME=$(read_env_value "SEAFILE_SERVER_HOSTNAME" "$INSTALL_DIR/.env")
ENV_PROTOCOL=$(read_env_value "SEAFILE_SERVER_PROTOCOL" "$INSTALL_DIR/.env")
ENV_ADMIN_EMAIL=$(read_env_value "INIT_SEAFILE_ADMIN_EMAIL" "$INSTALL_DIR/.env")

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from whatever .env currently has.
if [[ -n "$ENV_MEM_LIMIT" || -n "$ENV_HOST_PORT" ]]; then
    {
        echo "services:"
        echo "  seafile-app:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:80\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'seafile-app' container (db/redis stay unbounded)."
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
# Seafile is a file-sync product, so the proxy's own request limit is the
# thing that decides your real maximum upload size. NGINX Proxy Manager's
# default rejects large files before Seafile ever sees them, and the desktop
# client reports it as a sync failure with no useful detail.
#
# 0 disables the limit entirely and lets Seafile's own settings govern.
client_max_body_size 0;

# Long uploads over a slow link otherwise hit the proxy's read timeout
# mid-transfer and restart from zero.
proxy_request_buffering off;
proxy_read_timeout 1200s;
proxy_send_timeout 1200s;
send_timeout 1200s;
NGINXEOF

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Seafile (first run initialises three databases — this takes a few minutes)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Seafile. Check log: $LOGFILE"

print_info "Seafile is starting."
echo
echo "──────────────────────────────────────────────"
echo "🌐 URL:          $ENV_PROTOCOL://$ENV_HOSTNAME"
echo "🔗 Proxy target: seafile-app:80 on 'main-net'"
echo "👤 Login:        $ENV_ADMIN_EMAIL / the generated password below"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
echo "⏳ First start is slow: Seafile creates ccnet_db, seafile_db and"
echo "   seahub_db and runs its migrations before serving anything. A 502"
echo "   for the first couple of minutes is normal. Watch it finish with:"
echo "     cd $INSTALL_DIR && $COMPOSE_CMD logs -f seafile-app"
echo
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "⚠️  SEAFILE_SERVER_HOSTNAME is set to '$ENV_HOSTNAME' over http."
    echo "   Moving to NPM later means editing BOTH that and"
    echo "   SEAFILE_SERVER_PROTOCOL=https in .env, then rerunning deploy.sh."
    echo "   Getting them out of step shows up as 'CSRF verification failed'"
    echo "   at login, not as an obvious configuration error."
    echo
fi
echo "Set up NGINX Proxy Manager:"
echo "   1. Forward to  seafile-app : 80  + enable 'Websockets Support'"
echo "   2. ⚙️ gear icon → 'Custom Nginx Configuration' → paste this file:"
echo "        cat $INSTALL_DIR/npm-custom-nginx.conf"
echo "      (lifts the upload limit — without it, large file syncs fail)"
echo "   3. Enable SSL with Let's Encrypt"
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

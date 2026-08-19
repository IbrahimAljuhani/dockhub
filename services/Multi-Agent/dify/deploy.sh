#!/bin/bash
# Dify — deploy/manage. Run with: bash deploy.sh
#
# See docker-compose.override.yml in this folder for why Dify is the one
# service in this catalogue that does not ship a compose file of our own.

set -euo pipefail

SERVICE_NAME="dify"
# Pinned. Upstream's compose hardcodes this same version in its image tags,
# so the tree and the images move together. Bumping this is a deliberate act:
# read their release notes first, then delete ~/docker/dify/docker-compose.yaml
# and rerun to pull the new tree.
DIFY_VERSION="1.16.1"

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$HOME/docker/$SERVICE_NAME"
LOGFILE="$RUNTIME_DIR/deploy.log"

LIB_COMMON="$SOURCE_DIR/../../../lib/common.sh"
if [[ ! -f "$LIB_COMMON" ]]; then
    LIB_COMMON="$(mktemp -d)/common.sh"
    curl -fsSL -o "$LIB_COMMON" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_COMMON"

if [[ $EUID -eq 0 ]]; then
    print_error "This script must NOT be run as root. Please run as a regular user in the docker group."
fi

check_prerequisites
ensure_main_net

# ── Compose 2.24+ is required, and the reason is specific ───────────────
# docker-compose.override.yml uses the `!override` tag to REPLACE upstream's
# published ports rather than merge with them. Compose merges list values by
# default, so on an older version our empty list would append nothing and
# Dify would still bind host ports 80 and 443 — taking down NGINX Proxy
# Manager and, on a VPS, the host's HTTP with it. Better to refuse than to
# collide.
_cv="$($COMPOSE_CMD version --short 2>/dev/null | tr -d 'v')"
if [[ -n "$_cv" ]]; then
    _maj="${_cv%%.*}"; _rest="${_cv#*.}"; _min="${_rest%%.*}"
    if (( _maj < 2 || (_maj == 2 && _min < 24) )); then
        print_error "Docker Compose $_cv is too old for Dify (needs 2.24+ for the \`!override\` tag).
    Without it this deployment would publish host ports 80 and 443 and collide with NGINX Proxy Manager.
    Update Docker Compose, then rerun."
    fi
fi

mkdir -p "$RUNTIME_DIR"

# ── Upstream's docker/ tree, at the pinned tag ──────────────────────────
# The whole directory, not just the compose file: it mounts ./nginx/*.template,
# ./nginx/conf.d, ./ssrf_proxy/ and ./startupscripts/ by relative path, so the
# compose file on its own does not run.
if [[ -f "$RUNTIME_DIR/docker-compose.yaml" ]]; then
    print_info "Existing deployment found at $RUNTIME_DIR — its .env and data are kept."
else
    print_info "Fetching Dify $DIFY_VERSION from upstream (compose tree, ~1.3 MB)..."
    _tmp="$(mktemp -d)"
    if ! curl -fsSL "https://github.com/langgenius/dify/archive/refs/tags/${DIFY_VERSION}.tar.gz" \
         | tar xz -C "$_tmp" --strip-components=2 "dify-${DIFY_VERSION}/docker" 2>/dev/null; then
        rm -rf "$_tmp"
        print_error "Could not fetch Dify $DIFY_VERSION. Check the tag exists and this host has internet access."
    fi
    [[ -f "$_tmp/docker-compose.yaml" && -f "$_tmp/.env.example" ]] \
        || { rm -rf "$_tmp"; print_error "The fetched tree is missing docker-compose.yaml or .env.example — refusing to continue."; }
    cp -a "$_tmp/." "$RUNTIME_DIR/"
    rm -rf "$_tmp"
    print_info "Fetched into $RUNTIME_DIR."

    # ── The .env, built from THEIR example with OUR secrets ─────────────
    # Their .env.example ships working defaults for every credential:
    #   DB_PASSWORD=difyai123456   REDIS_PASSWORD=difyai123456
    #   SANDBOX_API_KEY=dify-sandbox
    #   PLUGIN_DAEMON_KEY=lYkiYYT6owG+...   (a real key, published on GitHub)
    #   PLUGIN_DIFY_INNER_API_KEY=QaHbTe77Ctu...
    # Anyone who copied the example and moved on is running a deployment whose
    # every secret is in a public repository. Generating them is the single
    # most valuable thing this script does.
    cp "$RUNTIME_DIR/.env.example" "$RUNTIME_DIR/.env"

    umask 077
    # Dify's own docs specify base64 for SECRET_KEY; the rest are ours.
    set_env_value SECRET_KEY                "$(openssl rand -base64 42)" "$RUNTIME_DIR/.env"
    set_env_value INIT_PASSWORD             "$(generate_secret 24)"      "$RUNTIME_DIR/.env"
    set_env_value DB_PASSWORD               "$(generate_secret 32)"      "$RUNTIME_DIR/.env"
    set_env_value REDIS_PASSWORD            "$(generate_secret 32)"      "$RUNTIME_DIR/.env"
    set_env_value SANDBOX_API_KEY           "$(generate_secret_hex 32)"  "$RUNTIME_DIR/.env"
    set_env_value PLUGIN_DAEMON_KEY         "$(generate_secret_hex 32)"  "$RUNTIME_DIR/.env"
    set_env_value PLUGIN_DIFY_INNER_API_KEY "$(generate_secret_hex 32)"  "$RUNTIME_DIR/.env"
    chmod 600 "$RUNTIME_DIR/.env"
    umask 022
    print_info "Generated every credential — none of upstream's published defaults survive."
fi

# Our layer, refreshed every run so an edit here reaches existing deployments.
cp "$SOURCE_DIR/docker-compose.override.yml" "$RUNTIME_DIR/"

# ── Optional host port ──────────────────────────────────────────────────
# The override removes upstream's 80/443 outright. This adds one back only if
# asked, and never 80 — that belongs to NGINX Proxy Manager.
ENV_HOST_PORT="$(read_env_value DOCKHUB_HOST_PORT "$RUNTIME_DIR/.env" || true)"
if [[ -z "$ENV_HOST_PORT" ]] && [[ ! -f "$RUNTIME_DIR/.dockhub-asked" ]]; then
    prompt_host_port 8088
    set_env_value DOCKHUB_HOST_PORT "${HOST_PORT:-}" "$RUNTIME_DIR/.env"
    touch "$RUNTIME_DIR/.dockhub-asked"
    ENV_HOST_PORT="${HOST_PORT:-}"
fi
if [[ -n "$ENV_HOST_PORT" ]]; then
    # Appended to our override rather than written into .env, because the
    # override is the file that owns the ports list.
    printf '\n# Added by deploy.sh — direct access without NPM.\nservices:\n  nginx:\n    ports: !override\n      - "%s:80"\n' \
        "$ENV_HOST_PORT" >> "$RUNTIME_DIR/docker-compose.override.yml"
fi

pull_with_progress "$RUNTIME_DIR"

print_info "Starting $SERVICE_NAME (this brings up ~15 containers)..."
(cd "$RUNTIME_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start $SERVICE_NAME. Check log: $LOGFILE"

# ── Self-test ───────────────────────────────────────────────────────────
# Probed from inside dify-nginx against its own port, so this tests Dify
# rather than the host's networking. A 200 or a redirect both mean the stack
# answered; anything else is reported as it is rather than interpreted.
print_info "Waiting for Dify to answer (first boot runs database migrations)..."
if wait_for_container_ready "dify-nginx" \
     "wget -q -O /dev/null -T 3 http://localhost:80/ || wget -q -S -O /dev/null -T 3 http://localhost:80/ 2>&1 | grep -q 'HTTP/'" \
     40 5; then
    print_info "Dify is answering."
else
    print_warn "Dify did not answer within 200s. First boot migrates the database and can be slow."
    print_warn "Watch it with:  docker logs -f dify-api"
fi

echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "🌐 URL:        http://$(hostname -I 2>/dev/null | awk '{print $1}'):$ENV_HOST_PORT"
else
    echo "🔗 Proxy:      dify-nginx:80 on 'main-net'  (no host port published)"
fi
echo "👤 First run:  open the URL and set up the admin account"
echo "🔑 Setup pass: INIT_PASSWORD in $RUNTIME_DIR/.env"
echo "📁 Data:       $RUNTIME_DIR/volumes"
echo "🔒 Secrets:    $RUNTIME_DIR/.env   (all generated, none of upstream's defaults)"
echo "📜 Log:        $LOGFILE"
echo "──────────────────────────────────────────────"
echo
echo "Upstream tree pinned at $DIFY_VERSION. Everything DockHub changed is in"
echo "   $RUNTIME_DIR/docker-compose.override.yml   (readable, ~40 lines)"
echo "To manage: cd $RUNTIME_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"
print_tunnel_reminder_if_relevant

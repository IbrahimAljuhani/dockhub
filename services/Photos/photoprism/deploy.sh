#!/bin/bash
# deploy.sh (services/Photos/photoprism)
# Purpose: Deploy PhotoPrism (app + MariaDB) — see docker-compose.yml for
# the full stack and the deliberate deviations from upstream's own example.
#
# This is a single-instance service: one PhotoPrism deployment per host,
# under ~/docker/photoprism/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy PhotoPrism behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/photoprism"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.photoprism-docker-secrets.txt"

# Shared helpers — sourced from a git checkout if present, self-fetched
# otherwise so standalone curl usage still works with no extra steps.
LIB_COMMON="$SOURCE_DIR/../../../lib/common.sh"
if [[ ! -f "$LIB_COMMON" ]]; then
    LIB_COMMON="$(mktemp -d)/common.sh"
    curl -fsSL -o "$LIB_COMMON" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_COMMON"

# Prompts for the photo library path — required. Same two-question pattern
# as this repo's Jellyfin/Plex. Sets ORIGINALS_PATH_VALUE in the caller's
# shell.
#
# Note this folder is mounted READ-WRITE (unlike Jellyfin/Plex's read-only
# media): PhotoPrism organizes files and writes YAML sidecars into it.
ORIGINALS_PATH_VALUE=""
prompt_originals_path() {
    local answer path err
    read -rp "Do you already have a photo folder on this host? (Y/n): " answer
    if [[ "${answer,,}" == "n" ]]; then
        while true; do
            read -rp "Path to create for your photo library (e.g. /mnt/photos, or ~/photos): " path
            if [[ -z "$path" ]]; then
                echo "A path is required." >&2
                continue
            fi
            path=$(normalize_host_path "$path") || continue
            if err=$(mkdir -p "$path" 2>&1); then
                ORIGINALS_PATH_VALUE="$(cd "$path" && pwd)"
                return 0
            fi
            echo "Failed to create '$path': $err" >&2
            echo "Try a path your user can write to (e.g. under \$HOME), or create it yourself first with sudo mkdir -p and sudo chown \$USER on it." >&2
        done
    else
        # Warn only on this branch: pointing at an EXISTING library is the
        # only case where PhotoPrism's read-write mount can touch photos you
        # already care about. Creating a fresh empty folder (the branch
        # above) has nothing at risk, so the warning would just be noise
        # there.
        print_warn "PhotoPrism will MODIFY this folder — it organizes files and writes YAML sidecar metadata alongside them. That's normal for this app, but unlike this repo's Jellyfin/Plex (which mount media read-only). Back up irreplaceable originals first, or see the README on PHOTOPRISM_READONLY."
        while true; do
            read -rp "Path to your existing photo library (e.g. /mnt/photos): " path
            if [[ -z "$path" ]]; then
                echo "A path is required." >&2
                continue
            fi
            path=$(normalize_host_path "$path") || continue
            if [[ -d "$path" ]]; then
                ORIGINALS_PATH_VALUE="$(cd "$path" && pwd)"
                return 0
            fi
            echo "'$path' doesn't exist." >&2
        done
    fi
}

check_prerequisites

mkdir -p "$INSTALL_DIR"

ensure_main_net

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."

    # A reused .env can point at a directory that has since moved or been
    # deleted. Docker would not complain: a bind mount to a missing path is
    # silently created as an empty root-owned folder, and the library simply
    # appears empty. Found the hard way after a bad path was cleaned up and
    # the redeploy happily bound the hole it left behind.
    _mp=$(read_env_value "MEDIA_PATH" "$INSTALL_DIR/.env")
    if [[ -n "$_mp" && ! -d "$_mp" ]]; then
        print_warn "The MEDIA_PATH in the existing .env no longer exists:"
        print_warn "  $_mp"
        print_warn "Docker will bind-mount it anyway and create it empty, so the"
        print_warn "library will look wiped. Fix the path, then rerun:"
        print_warn "  sed -i 's|^MEDIA_PATH=.*|MEDIA_PATH=/your/real/path|' $INSTALL_DIR/.env"
    fi
else
    # The read-write / "PhotoPrism modifies your files" warning lives inside
    # prompt_originals_path, on the existing-folder branch only — see there.
    prompt_originals_path

    # Upstream explicitly warns against memory limits here, so this differs
    # from every other service's plain prompt_mem_limit call: the warning
    # comes first, and the default stays "no".
    print_warn "Upstream advises AGAINST capping memory for PhotoPrism: the indexer temporarily needs a lot of RAM for large files, and a limit can cause restart loops. Saying no here is recommended."
    prompt_mem_limit "photoprism" "4g"
    prompt_host_port "2342"

    ADMIN_PASSWORD=$(generate_secret)
    DB_PASSWORD=$(generate_secret)
    DB_ROOT_PASSWORD=$(generate_secret)

    # PHOTOPRISM_SITE_URL must match how you actually reach it (scheme, host,
    # and trailing slash all matter) — same pattern as this repo's Vikunja.
    if [[ -n "$HOST_PORT" ]]; then
        SERVER_IP_FOR_URL=$(host_lan_ip)
        [[ -z "${SERVER_IP_FOR_URL:-}" ]] && SERVER_IP_FOR_URL="localhost"
        SITE_URL_VALUE="http://$SERVER_IP_FOR_URL:$HOST_PORT/"
        print_info "Using '$SITE_URL_VALUE' as PHOTOPRISM_SITE_URL. Once you switch to NPM, edit this to your real https:// domain in .env and rerun deploy.sh."
    else
        # Format-checked too, not just non-empty: an invisible character
        # tagging along from a paste silently corrupts every URL built from
        # this. prompt_domain re-asks instead of aborting the whole deploy —
        # see lib/common.sh.
        prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. photos.example.com): " "domain"
        PHOTOPRISM_DOMAIN="$PROMPTED_DOMAIN"
        SITE_URL_VALUE="https://$PHOTOPRISM_DOMAIN/"
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
PHOTOPRISM_VERSION=latest
ORIGINALS_PATH=$ORIGINALS_PATH_VALUE
PHOTOPRISM_ADMIN_PASSWORD=$ADMIN_PASSWORD
PHOTOPRISM_DATABASE_PASSWORD=$DB_PASSWORD
MARIADB_ROOT_PASSWORD=$DB_ROOT_PASSWORD
PHOTOPRISM_SITE_URL=$SITE_URL_VALUE
PHOTOPRISM_UID=$(id -u)
PHOTOPRISM_GID=$(id -g)
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated PhotoPrism secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): site_url=$SITE_URL_VALUE"
        echo "  Web UI username: admin"
        echo "  Web UI password: $ADMIN_PASSWORD"
        echo "  PHOTOPRISM_DATABASE_PASSWORD=$DB_PASSWORD"
        echo "  MARIADB_ROOT_PASSWORD=$DB_ROOT_PASSWORD"
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
        echo "  photoprism:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:2342\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'photoprism' container (mariadb stays unbounded)."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting PhotoPrism (first run downloads TensorFlow models and can take several minutes)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start PhotoPrism. Check log: $LOGFILE"

print_info "PhotoPrism is starting."
echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(host_lan_ip)
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 URL:           http://$SERVER_IP:$ENV_HOST_PORT"
fi
echo "🔗 Proxy target:  photoprism-app:2342 on 'main-net'"
echo "📁 Photo library: $(grep -a '^ORIGINALS_PATH=' "$INSTALL_DIR/.env" | cut -d= -f2-)  (read-write)"
echo "👤 Web login:     username 'admin' + the generated password — see secrets file below"
echo "📜 Log:           $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:       $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
echo "👉 NEXT STEP: photos aren't visible until they're indexed. Log in, then"
echo "   go to Library → Index to scan your photo folder for the first time."
echo
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "⚠️  PHOTOPRISM_SITE_URL was set to your bare IP:port. Once you switch to"
    echo "   NPM+SSL, edit it to https://<your-domain>/ in .env (keep the trailing"
    echo "   slash) and rerun deploy.sh — links and redirects are built from it."
    echo
fi
echo "Set up NGINX Proxy Manager: forward to photoprism-app, port 2342,"
echo "enable Websockets Support, enable SSL. PhotoPrism's own TLS is disabled"
echo "on purpose so NPM handles certificates — that's upstream's own"
echo "recommendation for reverse-proxy setups."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

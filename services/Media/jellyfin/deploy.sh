#!/bin/bash
# deploy.sh (services/Media/jellyfin)
# Purpose: Deploy Jellyfin (single container, config/cache in Docker
# volumes, your media bind-mounted read-only from the host) — see
# docker-compose.yml for the deliberate deviations from upstream's own
# guidance.
#
# This is a single-instance service: one Jellyfin deployment per host,
# under ~/docker/jellyfin/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Jellyfin behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/jellyfin"
LOGFILE="$INSTALL_DIR/deploy.log"

# Shared helpers — sourced from a git checkout if present, self-fetched
# otherwise so standalone curl usage still works with no extra steps.
LIB_COMMON="$SOURCE_DIR/../../../lib/common.sh"
if [[ ! -f "$LIB_COMMON" ]]; then
    LIB_COMMON="$(mktemp -d)/common.sh"
    curl -fsSL -o "$LIB_COMMON" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_COMMON"

# Prompts once for hardware transcoding (passes /dev/dri through to the
# container) — optional, off by default, since most servers don't have a
# compatible GPU. Sets HW_ACCEL ("1" or "") in the caller's shell.
HW_ACCEL=""
prompt_hw_accel() {
    local answer
    if [[ ! -e /dev/dri ]]; then
        return 0
    fi
    read -rp "Detected /dev/dri — enable hardware transcoding passthrough? (y/N): " answer
    [[ "${answer,,}" == "y" ]] && HW_ACCEL="1"
    # Explicit `return 0`: without it, answering anything but "y" makes the
    # `[[ ]] && ...` above the function's last command AND a failing one, so
    # the function returns 1 — which under `set -e` silently kills the whole
    # script at the call site. (A bare `A && B` at top level is exempt from
    # set -e; the same line as a function's final statement is not.)
    return 0
}

# Prompts for the media library path — required (Jellyfin has nothing to
# serve without it). Two clearly separate questions instead of one nested
# prompt: first whether to create a fresh empty folder or point at an
# existing one, then the path itself — so "yes, create it" always means the
# very next path you type gets created, no ambiguity about which question
# you're answering. Sets MEDIA_PATH_VALUE in the caller's shell.
MEDIA_PATH_VALUE=""
prompt_media_path() {
    local answer path err
    read -rp "Do you already have a media folder on this host? (Y/n): " answer
    if [[ "${answer,,}" == "n" ]]; then
        while true; do
            read -rp "Path to create for your media library (e.g. /mnt/media, or ~/media): " path
            if [[ -z "$path" ]]; then
                echo "A path is required." >&2
                continue
            fi
            path=$(normalize_host_path "$path") || continue
            if err=$(mkdir -p "$path" 2>&1); then
                MEDIA_PATH_VALUE="$(cd "$path" && pwd)"
                return 0
            fi
            echo "Failed to create '$path': $err" >&2
            echo "Try a path your user can write to (e.g. under \$HOME), or create it yourself first with sudo mkdir -p and sudo chown \$USER on it." >&2
        done
    else
        while true; do
            read -rp "Path to your existing media library (e.g. /mnt/media): " path
            if [[ -z "$path" ]]; then
                echo "A path is required." >&2
                continue
            fi
            path=$(normalize_host_path "$path") || continue
            if [[ -d "$path" ]]; then
                MEDIA_PATH_VALUE="$(cd "$path" && pwd)"
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
    prompt_media_path
    prompt_mem_limit "jellyfin" "2g"
    prompt_host_port "8096"
    prompt_hw_accel

    # PUBLISHED_URL is only used for Jellyfin's LAN autodiscovery feature —
    # unlike Vikunja/Plane, Jellyfin has no CORS/host-header check, so this
    # is optional, not required for NPM access to work.
    if [[ -n "$HOST_PORT" ]]; then
        SERVER_IP_FOR_URL=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "${SERVER_IP_FOR_URL:-}" ]] && SERVER_IP_FOR_URL="localhost"
        PUBLISHED_URL_VALUE="http://$SERVER_IP_FOR_URL:$HOST_PORT"
    else
        # Optional — Enter skips it. But a non-empty answer is format-checked
        # (prompt_optional_domain, lib/common.sh): a typo here doesn't fail
        # loudly, it just bakes a broken URL into Jellyfin's autodiscovery
        # and clients quietly fail to find the server.
        prompt_optional_domain "Public domain you'll point NGINX Proxy Manager at, for autodiscovery (optional, e.g. jellyfin.example.com): " "domain"
        JELLYFIN_DOMAIN="$PROMPTED_DOMAIN"
        [[ -n "$JELLYFIN_DOMAIN" ]] && PUBLISHED_URL_VALUE="https://$JELLYFIN_DOMAIN" || PUBLISHED_URL_VALUE=""
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
JELLYFIN_VERSION=latest
TZ=UTC
MEDIA_PATH=$MEDIA_PATH_VALUE
PUBLISHED_URL=$PUBLISHED_URL_VALUE
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    [[ -n "$HW_ACCEL" ]] && echo "HW_ACCEL=$HW_ACCEL" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    print_info "Generated .env at $INSTALL_DIR/.env (media path: $MEDIA_PATH_VALUE)."
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
ENV_HW_ACCEL=""
grep -qa '^MEM_LIMIT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_MEM_LIMIT=$(grep -a '^MEM_LIMIT=' "$INSTALL_DIR/.env" | cut -d= -f2)
grep -qa '^HOST_PORT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_HOST_PORT=$(grep -a '^HOST_PORT=' "$INSTALL_DIR/.env" | cut -d= -f2)
grep -qa '^HW_ACCEL=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_HW_ACCEL=$(grep -a '^HW_ACCEL=' "$INSTALL_DIR/.env" | cut -d= -f2)

if [[ -n "$ENV_MEM_LIMIT" || -n "$ENV_HOST_PORT" || -n "$ENV_HW_ACCEL" ]]; then
    {
        echo "services:"
        echo "  jellyfin:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:8096\""
        fi
        if [[ -n "$ENV_HW_ACCEL" ]]; then
            echo "    devices:"
            echo "      - /dev/dri:/dev/dri"
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'jellyfin' container."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
    [[ -n "$ENV_HW_ACCEL" ]] && print_info "Hardware transcoding passthrough (/dev/dri) enabled."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Jellyfin..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Jellyfin. Check log: $LOGFILE"

print_info "Jellyfin is starting."
echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 URL:          http://$SERVER_IP:$ENV_HOST_PORT"
fi
echo "🔗 Proxy target: jellyfin-app:8096 on 'main-net'"
echo "📁 Media path:   $(grep -a '^MEDIA_PATH=' "$INSTALL_DIR/.env" | cut -d= -f2-)"
echo "👤 First visit:  follow the setup wizard — create your own admin account"
echo "📜 Log:          $LOGFILE"
echo "──────────────────────────────────────────────"
echo
echo "⚠️  IMPORTANT — after setup, go to Admin Dashboard → Networking →"
echo "   'Known proxies' and add NPM's subnet, or Jellyfin will discard"
echo "   X-Forwarded-For and log every visitor as the proxy's own IP."
echo "   Find the subnet with:"
echo "     docker network inspect main-net --format '{{ (index .IPAM.Config 0).Subnet }}'"
echo
echo "Set up NGINX Proxy Manager: forward to jellyfin-app, port 8096,"
echo "enable Websockets Support (Jellyfin uses them for sync/notifications)."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

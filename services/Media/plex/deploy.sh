#!/bin/bash
# deploy.sh (services/Media/plex)
# Purpose: Deploy Plex Media Server (single container, config/transcode in
# Docker volumes, your media bind-mounted read-only from the host) — see
# docker-compose.yml for the deliberate deviations from upstream's own
# examples, especially the bridge-vs-host networking tradeoff.
#
# ⚠️ Plex is proprietary freemium software and needs a free Plex account —
# unlike every other service in this repo. See README.md.
#
# This is a single-instance service: one Plex deployment per host, under
# ~/docker/plex/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Plex Media Server behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/plex"
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

# Prompts for the media library path — required (Plex has nothing to serve
# without it). Same two-question pattern as this repo's Jellyfin: first
# whether to create a fresh empty folder or point at an existing one, then
# the path itself. Sets MEDIA_PATH_VALUE in the caller's shell.
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

# Prompts once for hardware transcoding (passes /dev/dri through to the
# container). Same as this repo's Jellyfin, with one Plex-specific caveat
# noted in the prompt: Plex gates hardware transcoding behind a paid Plex
# Pass subscription, so passing the device through does nothing on a free
# account. Sets HW_ACCEL ("1" or "") in the caller's shell.
HW_ACCEL=""
prompt_hw_accel() {
    local answer
    if [[ ! -e /dev/dri ]]; then
        return 0
    fi
    read -rp "Detected /dev/dri — enable hardware transcoding passthrough? (needs a paid Plex Pass to actually be used) (y/N): " answer
    [[ "${answer,,}" == "y" ]] && HW_ACCEL="1"
    # Explicit `return 0`: without it, answering anything but "y" makes the
    # `[[ ]] && ...` above the function's last command AND a failing one, so
    # the function returns 1 — which under `set -e` silently kills the whole
    # script at the call site. (A bare `A && B` at top level is exempt from
    # set -e; the same line as a function's final statement is not.)
    return 0
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
    print_warn "Plex is proprietary freemium software and requires a free Plex account (unlike every other service here). If you'd rather run a fully open-source media server, this repo also ships Jellyfin."

    prompt_media_path
    prompt_mem_limit "plex" "2g"
    prompt_host_port "32400"
    prompt_hw_accel

    # ADVERTISE_IP is required in bridge networking (see docker-compose.yml's
    # header comment) so Plex advertises an address clients can reach. Plex
    # clients talk to the server directly on its own port rather than through
    # NPM, so this is derived from the direct host port when you publish one.
    if [[ -n "$HOST_PORT" ]]; then
        SERVER_IP_FOR_URL=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "${SERVER_IP_FOR_URL:-}" ]] && SERVER_IP_FOR_URL="localhost"
        ADVERTISE_IP_VALUE="http://$SERVER_IP_FOR_URL:$HOST_PORT/"
    else
        # Optional — Enter skips it. But a non-empty answer is format-checked
        # (prompt_optional_domain, lib/common.sh): a typo here doesn't fail
        # loudly, it just puts a broken URL in ADVERTISE_IP and clients
        # quietly fail to reach the server.
        prompt_optional_domain "Public domain you'll point NGINX Proxy Manager at (optional, e.g. plex.example.com): " "domain"
        PLEX_DOMAIN="$PROMPTED_DOMAIN"
        [[ -n "$PLEX_DOMAIN" ]] && ADVERTISE_IP_VALUE="https://$PLEX_DOMAIN:443/" || ADVERTISE_IP_VALUE=""
    fi

    # Asked LAST, deliberately: the claim token expires roughly 4 minutes
    # after you generate it, so every other question is out of the way
    # before the clock starts. Optional — an unclaimed server can still be
    # claimed afterward from a browser on the same LAN.
    echo
    echo "── Claim token (last step) ──────────────────────────────────" >&2
    echo "Open https://www.plex.tv/claim while signed in to your Plex account" >&2
    echo "and copy the token it shows. ⚠️ It EXPIRES ABOUT 4 MINUTES after it's" >&2
    echo "generated, which is why this is asked last." >&2
    echo "Leave blank to skip — you can claim the server later from a browser" >&2
    echo "on the same local network (see README.md)." >&2
    read -rp "Claim token (claim-xxxxxxxxxxxx), or blank to skip: " PLEX_CLAIM_VALUE

    cat > "$INSTALL_DIR/.env" <<EOF
PLEX_VERSION=latest
TZ=UTC
PLEX_HOSTNAME=PlexServer
MEDIA_PATH=$MEDIA_PATH_VALUE
ADVERTISE_IP=$ADVERTISE_IP_VALUE
PLEX_CLAIM=$PLEX_CLAIM_VALUE
PLEX_UID=$(id -u)
PLEX_GID=$(id -g)
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
        echo "  plex:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" ]]; then
            echo "    ports:"
            echo "      - \"$ENV_HOST_PORT:32400\""
        fi
        if [[ -n "$ENV_HW_ACCEL" ]]; then
            echo "    devices:"
            echo "      - /dev/dri:/dev/dri"
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'plex' container."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
    [[ -n "$ENV_HW_ACCEL" ]] && print_info "Hardware transcoding passthrough (/dev/dri) enabled — needs a paid Plex Pass to actually be used."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Plex..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Plex. Check log: $LOGFILE"

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
CLAIMED=$(grep -a '^PLEX_CLAIM=' "$INSTALL_DIR/.env" | cut -d= -f2-)

print_info "Plex is starting."
echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "🌐 URL:          http://$SERVER_IP:$ENV_HOST_PORT/web"
fi
echo "🔗 Proxy target: plex-app:32400 on 'main-net'"
echo "📁 Media path:   $(grep -a '^MEDIA_PATH=' "$INSTALL_DIR/.env" | cut -d= -f2-)"
if [[ -n "$CLAIMED" ]]; then
    echo "👤 First visit:  server was claim-linked to your Plex account — sign in and it should appear"
else
    echo "👤 First visit:  server NOT claimed — see the note below"
fi
echo "📜 Log:          $LOGFILE"
echo "──────────────────────────────────────────────"
echo
if [[ -z "$CLAIMED" ]]; then
    echo "⚠️  No claim token was provided, so this server isn't linked to a Plex"
    echo "   account yet. To claim it, open Plex from a browser on the SAME local"
    echo "   network as this server (Plex only allows unclaimed setup from the"
    echo "   local network). Alternatively, put a fresh token from"
    echo "   https://www.plex.tv/claim into PLEX_CLAIM in .env and rerun"
    echo "   deploy.sh within ~4 minutes of generating it."
    echo
fi
echo "⚠️  IMPORTANT — Plex behind a reverse proxy needs its own settings, in"
echo "   Settings → Network:"
echo "     • Custom server access URLs: https://<your-domain>:443"
echo "     • Secure connections: 'Preferred' (not 'Required' — some clients"
echo "       like Roku/PlayStation/older TVs can't do HTTPS)"
echo "   Also turn Remote Access OFF when NPM is fronting it, so Plex doesn't"
echo "   also try to punch its own hole through your router."
echo
echo "Set up NGINX Proxy Manager: forward to plex-app, port 32400, enable"
echo "Websockets Support, enable SSL. See README.md's Reverse Proxy section."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

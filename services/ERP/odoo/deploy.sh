#!/bin/bash
# deploy.sh (services/ERP/odoo)
# Author: Ibrahim Aljuhani (Fixed Version - Official Images)
# Purpose: Install Odoo in Docker using OFFICIAL Docker Hub images
# Fixed: 2026-07-11
#
# CHANGELOG vs original:
#   1. POSTGRES_DB is now "postgres" (not the instance DB name) so Odoo
#      creates & initializes the actual database itself via
#      /web/database/manager instead of finding an empty, uninitialized
#      DB and throwing "ir_module_module does not exist".
#   2. /var/lib/odoo is now a named Docker volume instead of a bind mount,
#      so Docker preserves the correct ownership from the image instead of
#      inheriting the host user's UID/GID (fixes "Permission denied:
#      /var/lib/odoo/sessions").
#   3. ./config and ./addons (which must stay as bind mounts, since users
#      edit them from the host) are chown'ed to the odoo container's real
#      UID/GID, detected dynamically instead of hardcoded 100:101.
#   4. Healthcheck no longer assumes curl exists inside the image; uses
#      python3 (bundled with Odoo) instead.
#   5. postgres:15 -> postgres:17.
#   6. DB_USER / DB_NAME are now validated like the instance name.
#   7. mem_limit/mem_reservation added alongside "deploy:" so memory
#      limits also apply under plain `docker-compose` (non-swarm), where
#      "deploy:" is silently ignored.
#   8. chown warning for config/addons now tries direct chown, then
#      passwordless sudo, then explains it's usually harmless instead of
#      sounding like a blocking error.
#   9. New option 4 in the version menu: use a custom image (your own
#      build, Docker Hub, or private registry), validated for format and
#      existence (locally or via `docker manifest inspect`) before use.
#  10. WebSocket/longpolling (port 8072) is now exposed and enabled.
#      Odoo's gevent worker only starts when "workers" >= 1, so the
#      config now sets workers=2 / max_cron_threads=1 / gevent_port=8072
#      — without this, live chat, POS sync, and bus notifications
#      silently fall back to polling or don't work at all.
#  11. FIX: config/odoo.conf permissions. An earlier revision set this to
#      chmod 600, which broke the container (it's owned by the host user,
#      not the container's odoo uid, so the odoo process couldn't read
#      its own config -> crash loop). Now it's chowned to the odoo
#      user/group first, then locked to 640 (falls back to 644, with a
#      warning, if chown isn't possible without sudo).
#  12. Host ports are now OPTIONAL (default: no) instead of always asked and
#      always published, matching the convention every other service in
#      this repo follows — reach the container by name over 'main-net'
#      (for NPM) unless you explicitly opt into direct access. Also added
#      an optional memory cap on the 'odoo' container (was previously
#      hardcoded to 2g with no way to change it without hand-editing the
#      generated compose file).
#  13. docker-compose.yml is now a tracked template file (services/ERP/odoo/
#      docker-compose.yml) that deploy.sh copies per-instance, instead of
#      being generated inline via heredoc — matches every other service in
#      this repo, and makes the compose file reviewable/diffable on its own.

set -euo pipefail

# Handle --help/-h before anything else (including the root check below) so
# it works no matter who invokes the script.
if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Install Odoo in Docker using official images."
            exit 0
            ;;
    esac
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/odoo"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.odoo-docker-secrets.txt"

# Shared helpers — sourced from a git checkout if present, self-fetched
# otherwise so standalone curl usage still works with no extra steps.
LIB_COMMON="$SOURCE_DIR/../../../lib/common.sh"
if [[ ! -f "$LIB_COMMON" ]]; then
    LIB_COMMON="$(mktemp -d)/common.sh"
    curl -fsSL -o "$LIB_COMMON" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_COMMON"

# -----------------------------
# 🎨 Terminal Colors — Odoo's deploy.sh keeps its own colored print_*
# (overriding lib/common.sh's plain versions) since this predates and goes
# beyond the shared convention; not worth flattening a deliberate,
# already-working flourish just for uniformity.
# -----------------------------
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
BLUE="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

print_info()  { echo -e "${GREEN}[✓]${RESET} $1" >&2; }
print_warn()  { echo -e "${YELLOW}[!]${RESET} $1" >&2; }
print_error() { echo -e "${RED}[✗]${RESET} $1" >&2; exit 1; }
print_step()  { echo -e "\n${BLUE}${BOLD}==> $1${RESET}" >&2; }

# -----------------------------
# 🚫 Prevent root execution
# -----------------------------
if [[ $EUID -eq 0 ]]; then
  print_error "This script must NOT be run as root. Please run as a regular user in the docker group."
fi

# check_prerequisites (COMPOSE_CMD, docker, openssl) comes from lib/common.sh
# — Odoo also specifically needs curl (for the custom-image registry check
# in choose_custom_image), which the shared check doesn't cover.
command -v curl &>/dev/null || print_error "Missing required component: curl. Please install it first."

# validate_identifier() (instance name / db user / db name) comes from
# lib/common.sh.

# -----------------------------
# 🏷️ Choose Odoo version
# -----------------------------
choose_odoo_version() {
    echo -e "${BOLD}Choose Odoo version:${RESET}" >&2
    echo "1) 19.0 (Development - Use at your own risk)"
    echo "2) 18.0 (Stable - Recommended)"
    echo "3) 17.0 (LTS)"
    echo "4) Custom image (your own Odoo image, e.g. myrepo/odoo:custom)"
    local choice
    while true; do
        read -rp "Enter choice (1-4): " choice
        case "$choice" in
            1)
                ODOO_VERSION="19.0"
                print_warn "⚠️  Odoo 19.0 is still in development. May not have official Docker image yet."
                break
                ;;
            2) ODOO_VERSION="18.0"; break ;;
            3) ODOO_VERSION="17.0"; break ;;
            4) choose_custom_image; break ;;
            *) echo "Invalid choice. Try again." ;;
        esac
    done
}

# -----------------------------
# 🖼️  Choose a custom Odoo image (own build / Docker Hub / private registry)
# -----------------------------
choose_custom_image() {
    local image confirm
    while true; do
        read -rp "Enter full image name (e.g. myrepo/odoo:18-custom): " image

        if [[ -z "$image" ]]; then
            echo "Image name cannot be empty."
            continue
        fi
        # repo[/repo...][:tag] — require an explicit tag (avoid implicit 'latest')
        if [[ ! "$image" =~ ^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)*:[a-zA-Z0-9._-]+$ ]]; then
            echo "Invalid format, or missing tag. Expected something like: repo/image:tag"
            continue
        fi

        print_info "Checking if '$image' exists locally or on the registry..."
        if docker image inspect "$image" &>/dev/null; then
            print_info "Found locally."
        elif docker manifest inspect "$image" &>/dev/null; then
            print_info "Found on the registry."
        else
            print_warn "Could not verify '$image' — it may not exist, or it's in a private registry that needs 'docker login' first."
            read -rp "Continue anyway? (y/N): " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || continue
        fi
        break
    done
    CUSTOM_IMAGE_OVERRIDE="$image"
    ODOO_VERSION="custom"
}

# -----------------------------
# 📁 Prepare install directory
# -----------------------------
prepare_install_dir() {
    mkdir -p "$INSTALL_DIR" || print_error "Failed to create $INSTALL_DIR"
    [[ -w "$INSTALL_DIR" ]] || print_error "No write permission for $INSTALL_DIR"
}

# generate_secret() (used below in place of the old local generate_password())
# and port_in_use() both come from lib/common.sh.

# -----------------------------
# ⚓ Check port availability — wraps lib/common.sh's port_in_use() with
#    Odoo's own "continue anyway?" confirm flow.
# -----------------------------
check_port() {
    local port="$1" confirm
    if port_in_use "$port"; then
        print_warn "Port $port is already in use."
        read -rp "Continue anyway? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || print_error "Aborted due to port conflict on $port."
    fi
}

# -----------------------------
# 🔌 Optional host ports (default: no — reach the container by name over
#    'main-net' for NPM, same convention every other service here follows).
#    Sets ODOO_PORT/LONGPOLLING_PORT (empty if declined).
# -----------------------------
ODOO_PORT=""
LONGPOLLING_PORT=""
prompt_odoo_ports() {
    local answer
    read -rp "Also publish host ports for direct access without NPM (e.g. http://<server-ip>:<port>)? (y/N): " answer
    [[ "${answer,,}" == "y" ]] || return 0

    read -rp "Enter HTTP port (default 8069): " ODOO_PORT
    ODOO_PORT="${ODOO_PORT:-8069}"
    if ! [[ "$ODOO_PORT" =~ ^[0-9]+$ ]] || [ "$ODOO_PORT" -lt 1024 ] || [ "$ODOO_PORT" -gt 65535 ]; then
        print_error "Port must be between 1024 and 65535."
    fi
    check_port "$ODOO_PORT"

    local longpolling_default=$((ODOO_PORT + 3))
    read -rp "Enter WebSocket/longpolling port (default $longpolling_default): " LONGPOLLING_PORT
    LONGPOLLING_PORT="${LONGPOLLING_PORT:-$longpolling_default}"
    if ! [[ "$LONGPOLLING_PORT" =~ ^[0-9]+$ ]] || [ "$LONGPOLLING_PORT" -lt 1024 ] || [ "$LONGPOLLING_PORT" -gt 65535 ]; then
        print_error "Port must be between 1024 and 65535."
    fi
    if [ "$LONGPOLLING_PORT" -eq "$ODOO_PORT" ]; then
        print_error "WebSocket/longpolling port must be different from the HTTP port."
    fi
    check_port "$LONGPOLLING_PORT"
}

# prompt_mem_limit() (container name + default) comes from lib/common.sh —
# 'db' stays unbounded, same "main container only" convention every other
# service here follows.

# -----------------------------
# 🆔 Detect the real UID/GID of the "odoo" user inside the image
#     (avoids hardcoding 100:101, which can differ between image builds
#     and may collide with reserved system UIDs like _apt/systemd-journal)
# -----------------------------
detect_odoo_ids() {
    local image="$1"
    print_info "Detecting odoo user UID/GID inside $image (pulling image if needed)..."
    local id_output
    id_output=$(docker run --rm --entrypoint id "$image" odoo 2>/dev/null || true)

    if [[ -n "$id_output" ]]; then
        ODOO_UID=$(echo "$id_output" | grep -oP 'uid=\K[0-9]+' || true)
        ODOO_GID=$(echo "$id_output" | grep -oP 'gid=\K[0-9]+' || true)
    fi

    if [[ -z "${ODOO_UID:-}" || -z "${ODOO_GID:-}" ]]; then
        print_warn "Could not detect odoo UID/GID automatically, falling back to 100:101."
        ODOO_UID=100
        ODOO_GID=101
    else
        print_info "Detected odoo user as UID=$ODOO_UID GID=$ODOO_GID"
    fi
}

# -----------------------------
# 🚀 Main installation process
# -----------------------------
main() {
    print_step "Checking prerequisites..."
    check_prerequisites

    prepare_install_dir

    read -rp "Enter instance name (e.g., odoo-prod): " INSTANCE_NAME
    validate_identifier "$INSTANCE_NAME" "instance name"
    INSTANCE_DIR="$INSTALL_DIR/$INSTANCE_NAME"
    [[ -d "$INSTANCE_DIR" ]] && print_error "Instance '$INSTANCE_NAME' already exists."

    choose_odoo_version
    if [[ "$ODOO_VERSION" == "custom" ]]; then
        CUSTOM_IMAGE="$CUSTOM_IMAGE_OVERRIDE"
    else
        CUSTOM_IMAGE="odoo:$ODOO_VERSION"
    fi

    prompt_odoo_ports
    prompt_mem_limit "odoo" "2g"

    echo
    echo "Database Configuration:"
    read -rp "Enter PostgreSQL username (default: odoo): " DB_USER
    DB_USER="${DB_USER:-odoo}"
    validate_identifier "$DB_USER" "database username"

    read -rsp "Enter PostgreSQL password (leave blank to auto-generate): " DB_PASS
    echo
    if [ -z "$DB_PASS" ]; then
        DB_PASS=$(generate_secret)
        print_warn "Auto-generated DB password: $DB_PASS"
    fi

    read -rp "Enter Database name (default: odoo) — this is just the name you'll type in Odoo's database manager on first login, it is NOT pre-created: " DB_NAME
    DB_NAME="${DB_NAME:-odoo}"
    validate_identifier "$DB_NAME" "database name"

    # Detect the odoo container's UID/GID so bind-mounted config/addons
    # folders are owned correctly. This also pre-pulls the image.
    detect_odoo_ids "$CUSTOM_IMAGE"

    ensure_main_net

    mkdir -p "$INSTANCE_DIR"/{config,addons,db-data}

    # Give the odoo container user write access to the bind-mounted folders
    # Try direct chown first (works if you already own the files), then fall
    # back to non-interactive sudo (only succeeds if you have passwordless
    # sudo cached — this never blocks the script waiting for a password).
    if chown -R "$ODOO_UID:$ODOO_GID" "$INSTANCE_DIR/config" "$INSTANCE_DIR/addons" 2>/dev/null; then
        print_info "Set ownership of config/addons to $ODOO_UID:$ODOO_GID."
    elif sudo -n chown -R "$ODOO_UID:$ODOO_GID" "$INSTANCE_DIR/config" "$INSTANCE_DIR/addons" 2>/dev/null; then
        print_info "Set ownership of config/addons to $ODOO_UID:$ODOO_GID (via sudo)."
    else
        print_warn "Could not chown config/addons automatically. This is usually harmless — Odoo only reads from these two folders in normal operation and doesn't need write access to them. You'd only need this if you plan to let Odoo itself write into config/addons (uncommon). If you hit permission errors later, run:"
        print_warn "  sudo chown -R $ODOO_UID:$ODOO_GID $INSTANCE_DIR/{config,addons}"
    fi

    ADMIN_PASS=$(generate_secret)

    # Save secrets securely
    if [[ ! -f "$SECRETS_FILE" ]]; then
        echo "# Auto-generated Odoo secrets - DO NOT SHARE" > "$SECRETS_FILE"
        chmod 600 "$SECRETS_FILE"
    fi
    {
        echo "$(date '+%F %T'): Instance '$INSTANCE_NAME' admin password: $ADMIN_PASS"
        echo "$(date '+%F %T'): DB '$DB_NAME' credentials: $DB_USER / $DB_PASS"
    } >> "$SECRETS_FILE"
    print_info "Credentials saved to $SECRETS_FILE."
    print_warn "⚠️  Keep this file secure. Never share it!"

    # Create .env file for docker-compose
    # NOTE: POSTGRES_DB is intentionally "postgres" (the default maintenance
    # DB), NOT $DB_NAME. Odoo creates/initializes the real database itself
    # the first time you visit /web/database/manager. Pre-creating an empty
    # DB_NAME database here would make Odoo think it's already initialized
    # and fail with "ir_module_module does not exist". ODOO_DB_NAME below is
    # purely informational (read by backup.sh to know what to pg_dump) —
    # Odoo itself never reads this key.
    cat >"$INSTANCE_DIR/.env" <<EOF
ODOO_IMAGE=$CUSTOM_IMAGE
INSTANCE_NAME=$INSTANCE_NAME
POSTGRES_DB=postgres
POSTGRES_USER=$DB_USER
POSTGRES_PASSWORD=$DB_PASS
ADMIN_PASS=$ADMIN_PASS
ODOO_DB_NAME=$DB_NAME
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTANCE_DIR/.env"
    [[ -n "$ODOO_PORT" ]] && echo "ODOO_PORT=$ODOO_PORT" >> "$INSTANCE_DIR/.env"
    [[ -n "$LONGPOLLING_PORT" ]] && echo "LONGPOLLING_PORT=$LONGPOLLING_PORT" >> "$INSTANCE_DIR/.env"
    chmod 600 "$INSTANCE_DIR/.env"

    # -----------------------------
    # 🧱 docker-compose.yml: copied from the tracked template (never
    # overwritten if it somehow already exists — matches every other
    # service's convention, even though the duplicate-instance check above
    # makes that unreachable today).
    # -----------------------------
    if [[ -f "$INSTANCE_DIR/docker-compose.yml" ]]; then
        print_info "Existing docker-compose.yml found at $INSTANCE_DIR — keeping it (not overwritten)."
    else
        cp "$SOURCE_DIR/docker-compose.yml" "$INSTANCE_DIR/docker-compose.yml"
    fi

    # docker-compose.override.yml adds the optional host ports / memory cap
    # on top of the static template above. Unlike this repo's other
    # services, deploy.sh only ever runs once per instance (it refuses to
    # touch an existing one), so this file is generated here and then never
    # regenerated automatically — to change it later, hand-edit this file
    # directly (or delete it to go back to unbounded/main-net-only), then
    # cd $INSTANCE_DIR && $COMPOSE_CMD up -d
    if [[ -n "$MEM_LIMIT" || -n "$ODOO_PORT" ]]; then
        {
            echo "services:"
            echo "  odoo:"
            [[ -n "$MEM_LIMIT" ]] && echo "    mem_limit: $MEM_LIMIT"
            if [[ -n "$ODOO_PORT" ]]; then
                echo "    ports:"
                echo "      - \"$ODOO_PORT:8069\""
                echo "      - \"$LONGPOLLING_PORT:8072\""
            fi
        } > "$INSTANCE_DIR/docker-compose.override.yml"
    fi

    # Odoo config — explicit DB connection settings avoid reliance on entrypoint defaults.
    # db_name is intentionally left unset so Odoo shows the database
    # selector/manager on first visit instead of assuming a DB already exists.
    cat >"$INSTANCE_DIR/config/odoo.conf" <<EOF
[options]
admin_passwd = ${ADMIN_PASS}
addons_path   = /mnt/extra-addons
data_dir      = /var/lib/odoo
db_host       = db
db_port       = 5432
db_user       = ${DB_USER}
db_password   = ${DB_PASS}
list_db       = True
workers       = 2
max_cron_threads = 1
gevent_port   = 8072
EOF
    # odoo.conf is bind-mounted and read directly by the odoo user (uid
    # $ODOO_UID) inside the container. It must stay readable by that user.
    # chmod 600 alone would lock the container OUT of its own config file
    # (since the file is owned by the host user, not uid $ODOO_UID) and
    # cause a permission-denied crash loop. So: try to hand ownership to
    # the container's odoo user first, then lock it down to 640 (owner +
    # group read/write only). If we can't chown (no sudo), fall back to
    # 644 so the container can still read it — world-readable beats
    # "secure but broken" on a single-user dev/test box.
    if chown "$ODOO_UID:$ODOO_GID" "$INSTANCE_DIR/config/odoo.conf" 2>/dev/null; then
        chmod 640 "$INSTANCE_DIR/config/odoo.conf"
    elif sudo -n chown "$ODOO_UID:$ODOO_GID" "$INSTANCE_DIR/config/odoo.conf" 2>/dev/null; then
        # We just handed ownership to $ODOO_UID via sudo, so a plain
        # (non-sudo) chmod would now fail with "Operation not permitted"
        # -- only the file's owner (or root) may change its mode. Use
        # sudo here too, consistently.
        sudo -n chmod 640 "$INSTANCE_DIR/config/odoo.conf" 2>/dev/null \
            || print_warn "chown via sudo succeeded but chmod did not; file may be left at default permissions."
    else
        chmod 644 "$INSTANCE_DIR/config/odoo.conf"
        print_warn "Could not chown odoo.conf to the container's odoo user; left it world-readable (644) so the container can still read it. Run 'sudo chown $ODOO_UID:$ODOO_GID $INSTANCE_DIR/config/odoo.conf && sudo chmod 640 $INSTANCE_DIR/config/odoo.conf' to tighten this."
    fi

    # NPM routing block, written per instance. Note this one is NOT a quoted
    # heredoc: the container name has to be interpolated, so the instance's
    # real name lands in the file. The README can only show a
    # 'odoo-<instance>' placeholder the reader has to substitute by hand —
    # this removes that step, and the mistake that comes with it.
    # nginx's own variables are escaped (\$) to survive the interpolation.
    cat > "$INSTANCE_DIR/npm-custom-nginx.conf" <<NGINXEOF
# Paste this whole file into NGINX Proxy Manager:
#   Edit Proxy Host → ⚙️ gear icon → "Custom Nginx Configuration" → Save
# (not the "Custom Locations" tab — that's a different feature)
#
# Routes Odoo's WebSocket/longpolling traffic to the gevent worker.
# Without it Odoo works, but live chat, POS sync and bus notifications
# silently fall back to polling or don't work at all.
#
# Generated for instance '$INSTANCE_NAME' — container names already filled in.

location /websocket {
    proxy_pass http://odoo-$INSTANCE_NAME:8072;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
}
NGINXEOF

    pull_with_progress "$INSTANCE_DIR" \
        || print_warn "Pull failed — the start below will report the real error."
    print_step "Starting Odoo instance..."
    (cd "$INSTANCE_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
        || print_error "Failed to start Odoo containers. Check log: $LOGFILE"
    print_info "Containers started successfully."

    # Detect server IP (more compatible)
    SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || ip addr show scope global | grep inet | grep -v docker | awk '{print $2}' | cut -d'/' -f1 | head -n1)
    [[ -z "$SERVER_IP" ]] && SERVER_IP="127.0.0.1"

    if [[ "$SERVER_IP" == "127.0.0.1" ]]; then
        print_warn "Could not detect public IP. Use localhost or configure network."
    fi

    print_info "Odoo instance '$INSTANCE_NAME' is running!"
    echo
    echo "──────────────────────────────────────────────"
    if [[ -n "$ODOO_PORT" ]]; then
        echo "🌐 URL:          http://$SERVER_IP:$ODOO_PORT"
        echo "🔌 WebSocket:    http://$SERVER_IP:$LONGPOLLING_PORT  (live chat / POS / bus notifications)"
    fi
    echo "🔗 Proxy target: odoo-$INSTANCE_NAME:8069 (and :8072 for WS) on the 'main-net' network — use this in NGINX Proxy Manager"
    echo "📦 Odoo Version: $ODOO_VERSION"
    echo "🖼️  Image:        $CUSTOM_IMAGE"
    echo "🗄️  Database:     $DB_NAME  (not yet created — see next step below)"
    echo "👤 DB User:      $DB_USER"
    echo "🔑 DB Password:  $DB_PASS"
    echo "🔐 Admin Pass:   $ADMIN_PASS"
    echo "⚙️  Config:       $INSTANCE_DIR/config/odoo.conf"
    echo "🧩 Addons:       $INSTANCE_DIR/addons"
    echo "💾 DB Data:      $INSTANCE_DIR/db-data"
    echo "📁 Data Volume:  odoo-data (named Docker volume, not a host folder)"
    echo "📜 Log:          $LOGFILE"
    echo "🔒 Secrets:      $SECRETS_FILE"
    echo "──────────────────────────────────────────────"
    echo
    echo "👉 NEXT STEP (first run only):"
    if [[ -n "$ODOO_PORT" ]]; then
        echo "   Open http://$SERVER_IP:$ODOO_PORT/web/database/manager"
    else
        echo "   Set up NGINX Proxy Manager first (see above), then open"
        echo "   https://<your-domain>/web/database/manager"
    fi
    echo "   and click 'Create Database' using:"
    echo "     - Master Password: $ADMIN_PASS"
    echo "     - Database Name:   $DB_NAME"
    echo "   Odoo will create and initialize the DB tables itself."
    echo
    echo "🌐 NGINX Proxy Manager:"
    echo "   1. Forward to  odoo-$INSTANCE_NAME : 8069"
    echo "   2. ⚙️ gear icon → 'Custom Nginx Configuration' → paste this file:"
    echo "        cat $INSTANCE_DIR/npm-custom-nginx.conf"
    echo "      (routes /websocket — without it live chat / POS sync won't work)"
    echo "   3. Enable SSL with Let's Encrypt"
    echo
    echo "To manage containers:"
    echo "  cd $INSTANCE_DIR && $COMPOSE_CMD [ps|logs|stop|rm]"
    print_tunnel_reminder_if_relevant
    echo
    echo "💡 Tip: Add your custom addons to $INSTANCE_DIR/addons"
    echo
    echo "┌─────────────────────────────────────────────┐"
    echo "│  🔒  SECURITY REMINDER — ACTION REQUIRED    │"
    echo "├─────────────────────────────────────────────┤"
    echo "│  Passwords above are shown in plain text.   │"
    echo "│  Before leaving this terminal:              │"
    echo "│    1. Save credentials from: $SECRETS_FILE"
    echo "│    2. Clear terminal history:               │"
    echo "│         history -c && history -w            │"
    echo "└─────────────────────────────────────────────┘"
}

main "$@"

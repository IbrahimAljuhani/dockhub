#!/bin/bash
# lib/common.sh — shared helpers sourced by install_dockhub.sh and every
# service's deploy.sh. Not meant to be run directly.
#
# Two ways scripts pick this up:
#   1) Git clone: sourced directly via a relative path from SOURCE_DIR.
#   2) Standalone curl (single deploy.sh, no sibling files): the caller
#      self-fetches this file first (see _template/deploy.sh.template for
#      the exact snippet), then sources it the same way.
#
# Consolidates functions that used to be copy-pasted with small, silent drift
# across every deploy.sh (some called it generate_secret(), some
# generate_password(); openproject's took a byte-length argument, others
# didn't) — see services/README.md's "Convention Every Service Follows" for
# the story.

print_info()  { echo -e "[✓] $1" >&2; }
print_warn()  { echo -e "[!] $1" >&2; }
print_error() { echo -e "[✗] $1" >&2; exit 1; }

# Sets COMPOSE_CMD in the caller's shell. Exits via print_error if anything
# required is missing.
check_prerequisites() {
    local missing=()
    command -v docker &>/dev/null || missing+=("Docker CE")
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif docker-compose version &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        missing+=("Docker Compose")
    fi
    command -v openssl &>/dev/null || missing+=("openssl")
    if (( ${#missing[@]} != 0 )); then
        print_error "Missing required components: ${missing[*]}. Run install_dockhub.sh first."
    fi
}

# Random alphanumeric string, $1 = length (default 20). This is the canonical
# replacement for every service's old generate_secret()/generate_password().
generate_secret() {
    local raw
    raw=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9')
    echo "${raw:0:${1:-20}}"
}

# Random hex string, $1 = byte count (default 16, so 32 hex chars). Kept
# separate from generate_secret() rather than unifying the format — some
# services (e.g. Rails-based ones expecting SECRET_KEY_BASE) were set up
# against a hex value and there's no reason to churn already-working .env
# generation logic during the lib/common.sh migration.
generate_secret_hex() {
    openssl rand -hex "${1:-16}"
}

# Validates an instance name / db user / db name for multi-instance services
# (odoo, linkstack, ...). $1 = value, $2 = label for the error message.
validate_identifier() {
    local value="$1" label="$2"
    if [[ ! "$value" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        print_error "Invalid $label. Must start with a lowercase letter and contain only letters, digits, hyphens, or underscores."
    fi
}

# Reads one KEY=value out of a .env file. Always use this instead of a bare
# `grep ... | cut`: without -a, GNU grep prints "Binary file X matches"
# instead of the line the moment the file contains one byte it considers
# binary, and `cut` then happily hands that sentence back as the value. That
# produced a NetBird deploy whose domain silently became the literal string
# "Binary file ... matches", generating OAuth URLs that failed with
# "Unauthenticated" — a broken-but-running install with no error anywhere.
# $1 = key name, $2 = path to the .env file. Prints nothing if unset.
# The trailing `|| true` is load-bearing, not defensive clutter. Every
# deploy.sh runs under `set -euo pipefail`, and grep exits 1 when the key
# simply isn't there — a normal, expected outcome for any optional key
# (MEM_LIMIT, HOST_PORT, ...). Under pipefail that 1 becomes the whole
# pipeline's status, so the function would return 1, so `VAR=$(read_env_value
# ...)` would fail, so `set -e` would kill the script dead — with no error
# message at all, right after a successful-looking step. Absent must read as
# "empty", never as "failure".
read_env_value() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    grep -a "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

# Validates a public domain/hostname. Rejects anything that isn't a plain
# ASCII hostname — including a scheme, a path, a port, or an invisible
# non-ASCII character pasted in by accident (a real hazard when typing a
# Latin domain inside an Arabic or other RTL context, where directional
# marks travel along with the text unseen). $1 = value, $2 = label.
validate_domain() {
    local value="$1" label="${2:-domain}"
    [[ -n "$value" ]] || print_error "A $label is required."
    case "$value" in
        *://*)  print_error "Enter the $label only, without the http:// or https:// prefix." ;;
        */*)    print_error "Enter the $label only, without a path." ;;
        *:*)    print_error "Enter the $label only, without a port number." ;;
    esac
    if [[ ! "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
        print_error "Invalid $label: '$value'. Expected something like sub.example.com (letters, digits, hyphens and dots only). If you pasted it, an invisible character may have come along — retype it by hand."
    fi
}

# Asks for a domain and keeps asking until it's valid, instead of exiting the
# whole script on the first typo. validate_domain() below exits by design —
# it's also used to check values already sitting in a .env, where aborting is
# the right response — so this runs it inside a subshell: the subshell dies,
# the caller lives, and its message is captured and shown. That means one
# stray pasted character or an accidental Enter costs a retry, not a rerun of
# the whole deploy (menus, warnings and all).
#
# Note an IPv4 address passes validate_domain, and that's deliberate: several
# services here name something after this value and are perfectly happy with
# an IP for a LAN-only deployment.
#
# $1 = prompt text, $2 = label for error messages. Sets PROMPTED_DOMAIN in the
# caller's shell (same no-command-substitution reasoning as prompt_mem_limit).
#
# Named PROMPTED_DOMAIN, not the more obvious DOMAIN_VALUE: vaultwarden's
# deploy.sh already owns a variable by that name for something different (the
# full https:// URL), and a helper in a shared library must not quietly
# reach into a caller's namespace and overwrite it.
PROMPTED_DOMAIN=""
prompt_domain() {
    local prompt="$1" label="${2:-domain}" value msg
    PROMPTED_DOMAIN=""
    while true; do
        read -rp "$prompt" value
        if msg=$( (validate_domain "$value" "$label") 2>&1 ); then
            PROMPTED_DOMAIN="$value"
            return 0
        fi
        echo "$msg" >&2
    done
}

# Same as prompt_domain, but an empty answer is a legitimate one meaning
# "skip this". Used where the domain is genuinely optional (Jellyfin and Plex
# ask for one only to fill in an autodiscovery URL). A non-empty answer still
# has to be a valid domain, so a typo or a pasted invisible character gets
# caught and re-asked rather than silently baked into a broken URL — the
# whole point, since a wrong value here fails quietly rather than loudly.
#
# $1 = prompt text, $2 = label. Sets PROMPTED_DOMAIN, empty if skipped.
prompt_optional_domain() {
    local prompt="$1" label="${2:-domain}" value msg
    PROMPTED_DOMAIN=""
    while true; do
        read -rp "$prompt" value
        if [[ -z "$value" ]]; then
            return 0
        fi
        if msg=$( (validate_domain "$value" "$label") 2>&1 ); then
            PROMPTED_DOMAIN="$value"
            return 0
        fi
        echo "$msg" >&2
        echo "(or press Enter to skip)" >&2
    done
}

# Idempotent main-net creation — identical block used to be copy-pasted in
# every deploy.sh. Safe to call even if install_dockhub.sh already created it
# (this script can also be run standalone, out of order).
ensure_main_net() {
    if ! docker network ls --format '{{.Name}}' | grep -qx "main-net"; then
        # >/dev/null: `docker network create` echoes the new network's ID,
        # which lands in the middle of a deploy as an unexplained 64-character
        # hex string. The print_info below is the message we actually want.
        docker network create main-net >/dev/null || true
        if docker network ls --format '{{.Name}}' | grep -qx "main-net"; then
            print_info "Created docker network 'main-net'."
        else
            print_error "Failed to create docker network 'main-net'."
        fi
    fi
}

# ── AI cluster helpers ──────────────────────────────────────────────────

# The AI services talk to each other over their own shared network, exactly
# as the web services do over main-net. Keeping them separate means a model
# provider needs no published port at all: consumers reach it by container
# name. That matters because Ollama's API has NO AUTHENTICATION — anything
# that can reach the port can use your models and read your conversations.
ensure_ai_net() {
    if ! docker network ls --format '{{.Name}}' | grep -qx "ai-net"; then
        docker network create ai-net >/dev/null || true
        if docker network ls --format '{{.Name}}' | grep -qx "ai-net"; then
            print_info "Created docker network 'ai-net'."
        else
            print_error "Failed to create docker network 'ai-net'."
        fi
    fi
}

# Every model provider in DockHub, by container name. Used to keep exactly
# one of them running at a time.
AI_PROVIDER_CONTAINERS=(ollama llama-cpp localai)

# Providers are alternatives, not companions: they all load models into the
# same GPU memory, so two at once means either an out-of-memory failure or
# constant swapping that destroys performance — and the model files are many
# gigabytes each on disk.
#
# Deliberately checks whether another provider is RUNNING, not whether it is
# installed. Contention is a runtime problem: having llama.cpp installed but
# stopped costs nothing, and someone may reasonably keep LocalAI around for
# image generation while using Ollama for chat. Same shape as the Vulhub
# launcher's one-environment-at-a-time rule.
#
# $1 = the container name of the provider being deployed (excluded from the
# check). Offers to stop whatever else is running; returns non-zero only if
# the user declines.
ensure_single_provider() {
    local self="$1" other running=()
    for other in "${AI_PROVIDER_CONTAINERS[@]}"; do
        [[ "$other" == "$self" ]] && continue
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$other" && running+=("$other")
    done
    (( ${#running[@]} )) || return 0

    echo >&2
    print_warn "Another model provider is already running: ${running[*]}"
    print_warn "Providers share the same GPU memory, so running two at once means"
    print_warn "either an out-of-memory failure or constant model swapping."
    echo >&2
    local answer
    read -rp "Stop ${running[*]} and continue? (Y/n): " answer
    if [[ "${answer,,}" == "n" ]]; then
        print_info "Leaving ${running[*]} running. Nothing was deployed."
        return 1
    fi
    for other in "${running[@]}"; do
        docker stop "$other" >/dev/null 2>&1 && print_info "Stopped $other." \
            || print_warn "Could not stop $other — check 'docker ps'."
    done
    return 0
}

# Warns when there isn't room for what's about to be downloaded. Language
# models are the only thing in DockHub measured in tens of gigabytes, so a
# generic "enough disk?" check isn't enough — the caller passes what the
# specific model needs. $1 = GB required, $2 = path to check.
# Returns non-zero if short; the caller decides whether that's fatal.
check_free_disk_gb() {
    local need="$1" path="${2:-$HOME}" free
    free=$(df -BG --output=avail "$path" 2>/dev/null | tail -n1 | tr -dc '0-9') || return 0
    [[ -n "$free" ]] || return 0
    if (( free < need )); then
        print_warn "Only ${free} GB free on $path, and this needs about ${need} GB."
        return 1
    fi
    print_info "Disk check: ${free} GB free, ${need} GB needed. ✅"
    return 0
}

valid_mem_limit() { [[ "$1" =~ ^[0-9]+[bkmgBKMG]?$ ]]; }

# Prompts once for an optional memory cap. $1 = container name (for the
# prompt text), $2 = suggested default. Sets MEM_LIMIT in the caller's shell
# (no command substitution — keeps the prompt on a real terminal instead of
# risking it being swallowed into a captured value).
MEM_LIMIT=""
prompt_mem_limit() {
    local container="$1" default="$2" answer value
    MEM_LIMIT=""
    read -rp "Set a memory limit for the '$container' container? (y/N): " answer
    [[ "${answer,,}" == "y" ]] || return 0
    while true; do
        read -rp "Memory limit (default: $default, e.g. 512m, 2g): " value
        value="${value:-$default}"
        if valid_mem_limit "$value"; then
            MEM_LIMIT="$value"
            return 0
        fi
        echo "Invalid format — use a number followed by b/k/m/g (e.g. 2g)." >&2
    done
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 )); }

port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | grep -q ":$port\b"
    elif command -v netstat &>/dev/null; then
        netstat -tuln 2>/dev/null | grep -q ":$port\b"
    else
        return 1
    fi
}

# Prompts once for an optional host port (direct access without NPM). $1 =
# suggested default port. Sets HOST_PORT in the caller's shell (same
# no-command-substitution reasoning as prompt_mem_limit above).
HOST_PORT=""
prompt_host_port() {
    local default="$1" answer port cont
    HOST_PORT=""
    read -rp "Also publish a host port for direct access without NPM (e.g. http://<server-ip>:<port>)? (y/N): " answer
    [[ "${answer,,}" == "y" ]] || return 0
    while true; do
        read -rp "Host port (default: $default): " port
        port="${port:-$default}"
        if ! valid_port "$port"; then
            echo "Invalid port — must be a number between 1024 and 65535." >&2
            continue
        fi
        if port_in_use "$port"; then
            read -rp "Port $port looks already in use — continue anyway? (y/N): " cont
            [[ "${cont,,}" == "y" ]] || continue
        fi
        HOST_PORT="$port"
        return 0
    done
}

# ── Security-Lab helpers ────────────────────────────────────────────────
# Used ONLY by services/Security-Lab/*, which deploy software that is
# deliberately vulnerable. Nothing else in this repo should call these.

# A typed-confirmation gate. Not theatre: services.sh presents Security-Lab
# in the same menu as everything else, so a user tabbing through and pressing
# Enter could otherwise stand up an exploitable app without registering what
# they did. A y/N prompt is exactly what muscle memory defeats; typing a
# phrase is not. $1 = service name shown in the warning.
confirm_vulnerable_deploy() {
    local name="$1" answer
    echo >&2
    print_warn "$name is DELIBERATELY VULNERABLE software. That is its purpose."
    print_warn "Anything that can reach it can compromise it — and from there reach"
    print_warn "this host and everything else on your network. Never expose it to the"
    print_warn "internet, and stop it when you are done practising."
    echo >&2
    read -rp "Type I-UNDERSTAND to continue (anything else aborts): " answer
    [[ "$answer" == "I-UNDERSTAND" ]] || print_error "Aborted — nothing was deployed."
}

# Security-Lab services bind to a specific address rather than 0.0.0.0, so a
# deliberately vulnerable app isn't silently offered to every interface the
# host has. Sets SECLAB_BIND in the caller's shell to the primary LAN address
# (the agreed default: attack tooling on a laptop needs to reach it, and SSH
# tunnels make that painful). Falls back to 127.0.0.1 when no address can be
# determined — failing closed is the right direction here.
SECLAB_BIND=""
detect_seclab_bind() {
    SECLAB_BIND=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    if [[ -z "${SECLAB_BIND:-}" ]]; then
        SECLAB_BIND="127.0.0.1"
        print_warn "Could not determine this host's LAN address — binding to 127.0.0.1."
        print_warn "Reach it with: ssh -L <port>:localhost:<port> <user>@<this-host>"
    fi
    return 0
}

# ── Environment detection (home vs VPS) ─────────────────────────────────
# Reads ~/docker/.dockhub-env, written once by install_dockhub.sh on first
# core-infra install. Sets DOCKHUB_ENVIRONMENT ("home"/"vps") and
# DOCKHUB_ACCESS_METHOD ("tunnel"/"port_forward") in the caller's shell —
# both empty if the file doesn't exist (standalone curl users who never ran
# install_dockhub.sh). Callers must treat "empty" as "unknown", never assume
# "vps" as a default — this only ever adds an extra reminder, it must never
# gate whether a deploy works.
DOCKHUB_ENVIRONMENT=""
DOCKHUB_ACCESS_METHOD=""
read_dockhub_env() {
    local env_file="$HOME/docker/.dockhub-env"
    DOCKHUB_ENVIRONMENT=""
    DOCKHUB_ACCESS_METHOD=""
    [[ -f "$env_file" ]] || return 0
    DOCKHUB_ENVIRONMENT=$(grep -a '^ENVIRONMENT=' "$env_file" 2>/dev/null | cut -d= -f2)
    DOCKHUB_ACCESS_METHOD=$(grep -a '^ACCESS_METHOD=' "$env_file" 2>/dev/null | cut -d= -f2)
}

# Call at the end of a service's post-deploy summary, after printing the
# normal "Set up NGINX Proxy Manager..." line. No-op unless the saved
# environment is specifically Cloudflare Tunnel.
print_tunnel_reminder_if_relevant() {
    read_dockhub_env
    if [[ "$DOCKHUB_ACCESS_METHOD" == "tunnel" ]]; then
        echo
        echo "💻 Cloudflare Tunnel detected (from your core-infra setup): route this"
        echo "   domain to NPM itself — not directly to this service — and leave Force"
        echo "   SSL OFF on its Proxy Host. See docs/cloudflare-tunnel.md."
    fi
}

# ── Generic backup / restore ────────────────────────────────────────────
# Tars the ENTIRE install_dir tree (.env, compose files, and any
# bind-mounted directories a service keeps user data in — Vikunja's files/,
# Redmine's plugins/themes/, Taiga's i18n-overrides/, Odoo's config/addons/,
# etc.) PLUS every named volume belonging to this service's compose project
# (data that lives in Docker's own volume storage, not under install_dir at
# all), into ~/docker/backups/<service>/[<instance>/]<timestamp>.tar.gz.
#
# Deliberately backs up the whole directory rather than cherry-picking known
# filenames — a service can bind-mount arbitrary extra folders (this
# repo already has several), and enumerating each one per-service here
# would silently miss the next one added later. Only true Docker volumes
# need separate handling, since those aren't visible as plain files.
#
# Does NOT stop containers first — fine for config-only/SQLite-embedded
# services (jellyfin, linkstack, etc). Services with a separate database
# container (postgres/mysql) should NOT rely on this for the db volume —
# define a backup_<service>() override using pg_dump/mysqldump instead
# (raw-copying a live database's data files can produce a corrupted/
# inconsistent backup). See _template/backup.sh.template.
#
# $1 = service slug, $2 = instance name (empty for single-instance services),
# $3 = install dir (e.g. ~/docker/jellyfin or ~/docker/odoo/<instance>).
backup_service_generic() {
    local service="$1" instance="${2:-}" install_dir="$3"
    local backup_root="$HOME/docker/backups/$service"
    [[ -n "$instance" ]] && backup_root="$backup_root/$instance"
    mkdir -p "$backup_root"

    local ts staging
    ts="$(date '+%Y-%m-%d_%H%M')"
    staging="$(mktemp -d)"

    # Copied via a throwaway root-context container, not a plain host-user
    # `cp` — several services bind-mount directories owned by a container's
    # own internal uid (Vikunja's 1000, Odoo's dynamically-detected uid),
    # which the invoking host user often can't read directly. Running as
    # root here (same trick used for volumes below) avoids silently
    # skipping files a `2>/dev/null`-guarded host copy would swallow with
    # no indication anything was missed.
    mkdir -p "$staging/install_dir"
    docker run --rm -v "$install_dir":/data:ro -v "$staging/install_dir":/backup alpine \
        sh -c "cp -a /data/. /backup/" \
        || print_warn "Some files under $install_dir may not have been backed up — check permissions."

    local project_name volumes vol
    project_name="$(basename "$install_dir")"
    volumes=$(docker volume ls --format '{{.Name}}' | grep -E "^${project_name}_" || true)
    if [[ -n "$volumes" ]]; then
        mkdir -p "$staging/volumes"
        local vol_ok=1
        for vol in $volumes; do
            if ! docker run --rm -v "$vol":/data -v "$staging/volumes":/backup alpine \
                tar czf "/backup/${vol}.tar.gz" -C /data . 2>/dev/null; then
                print_warn "Failed to back up volume '$vol'."
                vol_ok=0
            fi
        done
        (( vol_ok )) || print_warn "Backup completed with at least one volume failure — check above."
    fi

    tar czf "$backup_root/${ts}.tar.gz" -C "$staging" .
    rm -rf "$staging"
    print_info "Backup saved: $backup_root/${ts}.tar.gz"
}

# $1 = service slug, $2 = instance name (empty for single-instance), $3 =
# install dir, $4 = path to the .tar.gz to restore. Overwrites everything
# currently under install_dir plus named volumes — callers must confirm
# with the user before calling this (see services.sh).
restore_service_generic() {
    local service="$1" instance="${2:-}" install_dir="$3" archive="$4"
    local staging
    staging="$(mktemp -d)"
    tar xzf "$archive" -C "$staging"

    if [[ -d "$staging/install_dir" ]]; then
        mkdir -p "$install_dir"
        # Root-context container copy, same reasoning as backup_service_generic
        # above — preserves the original container-uid ownership captured at
        # backup time instead of everything landing owned by the host user.
        docker run --rm -v "$staging/install_dir":/backup:ro -v "$install_dir":/data alpine \
            sh -c "cp -a /backup/. /data/" \
            || print_warn "Some files may not have restored correctly — check $install_dir."
    fi

    if [[ -d "$staging/volumes" ]]; then
        local vol_archive vol_name
        for vol_archive in "$staging/volumes"/*.tar.gz; do
            [[ -f "$vol_archive" ]] || continue
            vol_name="$(basename "$vol_archive" .tar.gz)"
            docker volume create "$vol_name" >/dev/null
            docker run --rm -v "$vol_name":/data -v "$staging/volumes":/backup alpine \
                sh -c "find /data -mindepth 1 -delete; tar xzf /backup/$(basename "$vol_archive") -C /data" \
                || print_warn "Failed to restore volume '$vol_name'."
        done
    fi
    rm -rf "$staging"
    print_info "Restored from: $archive"
}

# Lists available backups for a service (newest first) as plain paths, one
# per line — empty output if none exist. $1 = service slug, $2 = instance
# name (empty for single-instance).
list_backups() {
    local service="$1" instance="${2:-}"
    local backup_root="$HOME/docker/backups/$service"
    [[ -n "$instance" ]] && backup_root="$backup_root/$instance"
    [[ -d "$backup_root" ]] || return 0
    find "$backup_root" -maxdepth 1 -name '*.tar.gz' | sort -r
}

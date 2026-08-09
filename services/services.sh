#!/bin/bash
# services.sh — lists services and lets you deploy, remove, or reinstall one.
#
# Two modes for finding service files:
#   1) Local checkout: if this file sits inside a real services/ folder with
#      sibling <name>/deploy.sh directories (full repo clone), those are
#      used directly.
#   2) Standalone (curl'd on its own, matching how every other script in this
#      repo is normally fetched — see the root README): no sibling folders
#      exist, so deploying downloads the chosen service's files fresh into
#      ./<name>/ from GitHub.
#
# Usage: bash services.sh
# (not './services.sh' — a fresh git clone/pull doesn't reliably preserve the
# executable bit, and 'bash <file>' works regardless of it)

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root — each service's own deploy.sh checks that too." >&2
    exit 1
fi

REPO_RAW_BASE="https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helpers (generate_secret, backup/restore, env detection, etc.) —
# sourced from a git checkout if present, self-fetched otherwise so
# `curl -O services.sh && bash services.sh` alone still works standalone.
LIB_COMMON="$SCRIPT_DIR/../lib/common.sh"
if [[ ! -f "$LIB_COMMON" ]]; then
    LIB_COMMON="$(mktemp -d)/common.sh"
    curl -fsSL -o "$LIB_COMMON" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_COMMON"

# Extra files (besides deploy.sh) each service needs — keep this in sync with
# that service's own README.md "Installation" curl commands.
declare -A SERVICE_FILES=(
    [odoo]="docker-compose.yml backup.sh"
    [erpnext]="docker-compose.yml backup.sh"
    [dolibarr]="docker-compose.yml backup.sh"
    [openproject]="docker-compose.yml backup.sh"
    [redmine]="docker-compose.yml backup.sh"
    [plane]="docker-compose.yml backup.sh"
    [vikunja]="docker-compose.yml backup.sh"
    [linkstack]="docker-compose.yml"
    [jellyfin]="docker-compose.yml"
    [home-assistant]="docker-compose.yml"
    # No backup.sh: no database, so the generic volume backup covers it.
    [mosquitto]="docker-compose.yml"
    # AI: no backup.sh. Ollama's volume is downloaded models — re-pullable,
    # and not yours. Open WebUI's volume DOES hold your chats and accounts,
    # but it has no separate database container, so the generic backup
    # already captures it correctly.
    [ollama]="docker-compose.yml"
    [open-webui]="docker-compose.yml"
    # Security-Lab: no backup.sh by design — these hold no data of yours.
    [juice-shop]="docker-compose.yml"
    [webgoat]="docker-compose.yml"
    # Vulhub ships NO compose file of ours — it clones upstream's library of
    # ~330 of them. Empty on purpose; the key still has to exist so
    # is_available() offers it in standalone (curl) mode.
    [vulhub]=""
    [immich]="docker-compose.yml backup.sh"
    [pi-hole]="docker-compose.yml"
    [adguard]="docker-compose.yml"
    [plex]="docker-compose.yml"
    [vaultwarden]="docker-compose.yml"
    [netbird]="docker-compose.yml"
    [openvpn]="docker-compose.yml"
    [photoprism]="docker-compose.yml backup.sh"
    [wireguard]="docker-compose.yml"
    [wordpress]="docker-compose.yml backup.sh"
    [ghost]="docker-compose.yml backup.sh"
    [nextcloud]="docker-compose.yml backup.sh"
    # No backup.sh: oCIS has no separate database container, so the generic
    # volume backup already captures everything (both named volumes).
    [owncloud]="docker-compose.yml"
    [seafile]="docker-compose.yml backup.sh"
    [n8n]="docker-compose.yml init-data.sh backup.sh"
    [taiga]="docker-compose.yml docker-compose-inits.yml backup.sh taiga-gateway/taiga.conf i18n-overrides/django-ar.po i18n-overrides/locale-ar.json i18n-overrides/apply-front-locale.sh"
)

# Full target catalog, grouped by category: CATEGORY|slug|Display Name.
# 'slug' is the folder name a service will eventually live under (matches
# SERVICE_FILES keys once built). This list is the project roadmap, not just
# what's built today — see is_available() below. Add a new category by just
# adding its first entry here; the category menu picks it up automatically
# in the order entries first appear.
CATALOG=(
    # Three categories split what people loosely call "AI", along one line:
    # do you USE a model, use an AGENT, or BUILD agent systems?
    #
    # AI            — the model layer: providers that serve models, and the
    #                 chat interface you talk to them through.
    "AI|ollama|Ollama"
    "AI|open-webui|Open WebUI"
    "AI|llama-cpp|llama.cpp"
    "AI|localai|LocalAI"
    # AI-Agents     — a running agent that does work FOR you. You talk to it
    #                 and it acts, with tools. You don't design anything.
    "AI-Agents|openclaw|OpenClaw"
    "AI-Agents|hermes|Hermes"
    "AI-Agents|openhands|OpenHands"
    # Multi-Agent   — platforms where you BUILD and orchestrate systems of
    #                 agents. Dify moved here from AI: it is an LLM app
    #                 platform with agent management, far closer to Langflow
    #                 and Flowise than to Ollama. Paperclip moved here from
    #                 AI-Agents once its own description settled it — "the
    #                 app everyone uses to manage agents at work".
    #
    # LangGraph and CrewAI are deliberately ABSENT. They are libraries, not
    # services: LangGraph's server image builds YOUR code from a
    # langgraph.json, and CrewAI publishes no image at all. Listing them
    # would put entries in the menu with nothing to deploy. See this
    # category's README — Langflow sits on LangGraph and Flowise on
    # LangChain, so the capability is here, as a service.
    "Multi-Agent|dify|Dify"
    "Multi-Agent|langflow|Langflow"
    "Multi-Agent|flowise|Flowise"
    "Multi-Agent|paperclip|Paperclip"
    "Automation|n8n|n8n"
    "DNS|pi-hole|Pi-hole"
    "DNS|adguard|AdGuard"
    "ERP|erpnext|ERPNext"
    "ERP|dolibarr|Dolibarr"
    "ERP|odoo|Odoo"
    "Home-Automation|home-assistant|Home Assistant"
    "Home-Automation|mosquitto|Eclipse Mosquitto"
    "Media|jellyfin|Jellyfin"
    "Media|plex|Plex"
    "Photos|immich|Immich"
    "Photos|photoprism|PhotoPrism"
    "Projects|openproject|OpenProject"
    "Projects|plane|Plane"
    "Projects|vikunja|Vikunja"
    "Projects|redmine|Redmine"
    "Projects|taiga|Taiga"
    "Security|vaultwarden|Vaultwarden"
    # Security-Lab is deliberately its OWN category, not part of Security.
    # Everything below is software that is vulnerable ON PURPOSE — training
    # targets with real, working flaws. Listing them next to Vaultwarden, a
    # password manager holding real secrets, would invite exactly the wrong
    # mental grouping. These are also the only services in this repo that must
    # NOT join main-net or get a public domain; see their READMEs.
    "Security-Lab|juice-shop|OWASP Juice Shop"
    "Security-Lab|webgoat|WebGoat"
    "Security-Lab|vulhub|Vulhub"
    "Storage|nextcloud|Nextcloud"
    "Storage|seafile|Seafile"
    "Storage|owncloud|ownCloud"
    "VPN|wireguard|WireGuard"
    "VPN|netbird|NetBird"
    "VPN|openvpn|OpenVPN"
    "Web|wordpress|WordPress"
    "Web|ghost|Ghost"
    "Web|linkstack|LinkStack"
)

# A catalog entry is deployable now if either its local <category>/<slug>/
# deploy.sh folder exists (repo checkout mode — services/ is organized into
# one subfolder per category, matching CATALOG) or it's a registered
# SERVICE_FILES key (standalone/curl mode) — either signal alone is enough,
# so this works identically in both of deploy_service's two modes. Anything
# in CATALOG that matches neither is a roadmap placeholder: shown, but not
# deployable.
is_available() {
    local category="$1" slug="$2"
    [[ -f "$SCRIPT_DIR/$category/$slug/deploy.sh" ]] && return 0
    [[ -n "${SERVICE_FILES[$slug]+set}" ]] && return 0
    return 1
}

compose_cmd() {
    if docker compose version &>/dev/null; then
        echo "docker compose"
    elif docker-compose version &>/dev/null; then
        echo "docker-compose"
    fi
}

# Prints one instance directory per line for a service's runtime root
# ($HOME/docker/<name>). Single-instance services (openproject, nextcloud,
# n8n) have their compose file directly in that folder; multi-instance ones
# (odoo) have it one level down, in named subfolders — detected generically,
# not hardcoded to odoo specifically.
find_instances() {
    local svc_dir="$1"
    [[ -d "$svc_dir" ]] || return 0
    if [[ -f "$svc_dir/docker-compose.yml" ]]; then
        echo "$svc_dir"
        return 0
    fi
    local d
    for d in "$svc_dir"/*/; do
        [[ -f "${d}docker-compose.yml" ]] && echo "${d%/}"
    done
}

prompt_choice() {
    # $1 = number of items (the menu also gets an implicit "Exit"/"Back" at
    # 0). Echoes the chosen index (1-based, or "0" for exit/back) via a
    # global, not command substitution (same reasoning as the mem-limit
    # prompts in the service deploy.sh files: keeps the prompt on the real
    # terminal instead of a captured subshell).
    local count="$1" label="${2:-Exit}" choice
    echo "  0) $label"
    read -rp "Choice (0-$count): " choice || { CHOSEN_INDEX="0"; return 0; }
    if [[ "$choice" == "0" ]]; then
        CHOSEN_INDEX="0"
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > count )); then
        echo "Invalid choice." >&2
        CHOSEN_INDEX=""
        return 1
    fi
    CHOSEN_INDEX="$choice"
}

# Stops (and optionally wipes) one deployed instance directory.
# Soft removal (default): stops containers, deletes the cached
# docker-compose.yml/override.yml so a future deploy.sh re-copies the latest
# version — .env/secrets/logs are kept so a reinstall can reuse them.
# Full wipe: also removes named volumes and deletes the whole directory.
remove_instance() {
    local instance_dir="$1" cc wipe
    cc="$(compose_cmd)"
    if [[ -z "$cc" ]]; then
        echo "Docker Compose not found." >&2
        return 1
    fi
    read -rp "Also permanently delete this instance's data (database, uploaded files, secrets)? (y/N): " wipe || wipe="n"
    if [[ "${wipe,,}" == "y" ]]; then
        (cd "$instance_dir" && $cc down -v) || true
        rm -rf "$instance_dir"
        print_info "Removed $instance_dir completely (data wiped)."
    else
        (cd "$instance_dir" && $cc down) || true
        rm -f "$instance_dir/docker-compose.yml" "$instance_dir/docker-compose.override.yml"
        print_info "Stopped and removed containers for $instance_dir. Data/.env kept — deploying again will reuse them."
    fi
}

# Sources $category/$name/backup.sh if the service ships one (DB-aware
# services define backup_<name>()/restore_<name>() there instead of
# relying on the generic volume-tar fallback — see
# _template/backup.sh.template). This file is deliberately SEPARATE from
# deploy.sh: deploy.sh is only ever exec'd as its own process (never
# sourced, since it has top-level side-effecting code), so a function
# defined inside it would be invisible here. backup.sh has no top-level
# code at all — just function definitions — so it's safe to source.
# Silently no-ops if the service doesn't ship one (falls back to generic).
load_service_backup_hooks() {
    local category="$1" name="$2" hooks="$SCRIPT_DIR/$category/$name/backup.sh"
    if [[ -f "$hooks" ]]; then
        # shellcheck source=/dev/null
        source "$hooks"
        return 0
    fi
    # Standalone mode: try fetching it, but don't fail the whole operation
    # if this particular service just doesn't have one (curl 404).
    local tmp
    tmp="$(mktemp -d)/backup.sh"
    if curl -fsSL -o "$tmp" "$REPO_RAW_BASE/$category/$name/backup.sh" 2>/dev/null; then
        # shellcheck source=/dev/null
        source "$tmp"
    fi
}

# Backs up one instance of $1 (picks which one if multiple exist, e.g.
# odoo). Uses a per-service backup_<name>() override if that service ships
# a backup.sh defining one (DB-aware services should — see
# _template/backup.sh.template) — otherwise falls back to
# backup_service_generic() from lib/common.sh (compose files + volumes,
# fine for config-only/SQLite-embedded services).
backup_menu() {
    local name="$1" category="$2"
    load_service_backup_hooks "$category" "$name"
    local svc_runtime_dir="$HOME/docker/$name"
    local -a instances=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && instances+=("$line")
    done < <(find_instances "$svc_runtime_dir")

    if (( ${#instances[@]} == 0 )); then
        print_warn "Nothing to back up — '$name' isn't deployed."
        return
    fi

    pick_instance "${instances[@]}" || return
    [[ -z "$INSTANCE_PATH" ]] && return

    local instance=""
    [[ "$INSTANCE_PATH" != "$svc_runtime_dir" ]] && instance="$(basename "$INSTANCE_PATH")"

    if declare -F "backup_$name" &>/dev/null; then
        "backup_$name" "$instance" "$INSTANCE_PATH"
    else
        backup_service_generic "$name" "$instance" "$INSTANCE_PATH"
    fi
}

# Lists available backups for $1 (browsing per-instance sub-folders first
# for multi-instance services), confirms before overwriting current data,
# restores, then brings the service back up. You manage retention/pruning
# of old backups yourself — nothing here deletes them automatically.
restore_menu() {
    local name="$1" category="$2"
    load_service_backup_hooks "$category" "$name"
    local backups_root="$HOME/docker/backups/$name"

    if [[ ! -d "$backups_root" ]]; then
        print_warn "No backups found for '$name'."
        return
    fi

    local instance=""
    # Multi-instance layout: backups/<name>/<instance>/*.tar.gz — detected by
    # the *absence* of .tar.gz files directly under backups/<name>/ itself.
    if ! find "$backups_root" -maxdepth 1 -name '*.tar.gz' 2>/dev/null | grep -q .; then
        local -a scope_dirs=()
        while IFS= read -r d; do scope_dirs+=("$d"); done < <(find "$backups_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
        if (( ${#scope_dirs[@]} == 0 )); then
            print_warn "No backups found for '$name'."
            return
        fi
        echo "Instances with backups:"
        local i=1 d
        for d in "${scope_dirs[@]}"; do
            echo "  $i) $(basename "$d")"
            i=$((i + 1))
        done
        prompt_choice "${#scope_dirs[@]}" "Back" || return
        [[ "$CHOSEN_INDEX" == "0" ]] && return
        instance="$(basename "${scope_dirs[$((CHOSEN_INDEX - 1))]}")"
    fi

    local -a archives=()
    while IFS= read -r f; do archives+=("$f"); done < <(list_backups "$name" "$instance")
    if (( ${#archives[@]} == 0 )); then
        print_warn "No backups found for '$name'."
        return
    fi

    echo "Available backups (newest first):"
    local i=1 f
    for f in "${archives[@]}"; do
        echo "  $i) $(basename "$f" .tar.gz)"
        i=$((i + 1))
    done
    prompt_choice "${#archives[@]}" "Back" || return
    [[ "$CHOSEN_INDEX" == "0" ]] && return
    local chosen_archive="${archives[$((CHOSEN_INDEX - 1))]}"

    local install_dir="$HOME/docker/$name"
    [[ -n "$instance" ]] && install_dir="$install_dir/$instance"
    mkdir -p "$install_dir"

    local confirm
    read -rp "This overwrites current data at $install_dir with the chosen backup. Continue? (y/N): " confirm || confirm="n"
    [[ "${confirm,,}" == "y" ]] || { print_warn "Restore cancelled."; return; }

    local cc
    cc="$(compose_cmd)"
    if [[ -n "$cc" && -f "$install_dir/docker-compose.yml" ]]; then
        (cd "$install_dir" && $cc down) || true
    fi

    if declare -F "restore_$name" &>/dev/null; then
        "restore_$name" "$instance" "$install_dir" "$chosen_archive"
    else
        restore_service_generic "$name" "$instance" "$install_dir" "$chosen_archive"
    fi

    if [[ -n "$cc" && -f "$install_dir/docker-compose.yml" ]]; then
        (cd "$install_dir" && $cc up -d) && print_info "Service restarted after restore." \
            || print_warn "Restore finished, but failed to start containers — check manually."
    else
        print_warn "Restore finished, but no docker-compose.yml found to start — run 'Deploy / manage' next."
    fi
}

# Deploys $1 (in category $2) — local checkout if available, otherwise
# downloads it fresh. Terminal action: always ends the script (exec).
# Downloads always land in a flat ./<slug>/ locally regardless of the
# source repo's category/<slug>/ layout — no reason to make the user's own
# working directory as deep as the repo's.
deploy_service() {
    local name="$1" category="$2"
    if [[ -f "$SCRIPT_DIR/$category/$name/deploy.sh" ]]; then
        echo "Launching $name..."
        exec bash "$SCRIPT_DIR/$category/$name/deploy.sh"
    fi

    local target_dir="./$name"
    mkdir -p "$target_dir"
    echo "Downloading $name into $target_dir/ ..."
    curl -fsSL -o "$target_dir/deploy.sh" "$REPO_RAW_BASE/$category/$name/deploy.sh"
    local f
    for f in ${SERVICE_FILES[$name]:-}; do
        # mkdir first: some services ship files nested in a subfolder (e.g.
        # taiga/taiga-gateway/taiga.conf) — curl -o doesn't create parents.
        mkdir -p "$(dirname "$target_dir/$f")"
        curl -fsSL -o "$target_dir/$f" "$REPO_RAW_BASE/$category/$name/$f"
    done
    chmod +x "$target_dir/deploy.sh"

    echo "Launching $name..."
    cd "$target_dir"
    exec bash ./deploy.sh
}

# Lets the user pick which instance to act on when a service has more than
# one (odoo). Returns the chosen path in INSTANCE_PATH, or empty if the user
# backs out.
pick_instance() {
    local -a instances=("$@")
    if (( ${#instances[@]} == 1 )); then
        INSTANCE_PATH="${instances[0]}"
        return 0
    fi
    echo "Multiple instances found:"
    local i=1 inst
    for inst in "${instances[@]}"; do
        echo "  $i) $(basename "$inst")"
        i=$((i + 1))
    done
    if ! prompt_choice "${#instances[@]}" "Back"; then
        INSTANCE_PATH=""
        return 1
    fi
    if [[ "$CHOSEN_INDEX" == "0" ]]; then
        INSTANCE_PATH=""
        return 1
    fi
    INSTANCE_PATH="${instances[$((CHOSEN_INDEX - 1))]}"
}

service_menu() {
    # Two separate 'local' statements on purpose: 'local a=1 b=$a' does NOT
    # let the second assignment see the first's new value within the same
    # statement — it evaluates using whatever '$a' was before this line ran
    # (e.g. a stale value from a previous call to this function).
    local name="$1" category="$2"
    local svc_runtime_dir="$HOME/docker/$name"
    while true; do
        local -a instances=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && instances+=("$line")
        done < <(find_instances "$svc_runtime_dir")

        echo
        if (( ${#instances[@]} > 1 )); then
            echo "'$name' is already deployed (${#instances[@]} instances under $svc_runtime_dir)."
        elif (( ${#instances[@]} == 1 )); then
            echo "'$name' is already deployed under $svc_runtime_dir."
        else
            echo "'$name' is not deployed yet."
        fi
        echo "1) Deploy / manage (runs deploy.sh — safe for new or existing deployments)"
        echo "2) Remove"
        echo "3) Reinstall (remove, then deploy fresh)"
        echo "4) Backup"
        echo "5) Restore from backup"
        local choice
        if ! prompt_choice 5 "Back"; then
            continue
        fi
        choice="$CHOSEN_INDEX"
        case "$choice" in
            1) deploy_service "$name" "$category" ;;
            2)
                if (( ${#instances[@]} == 0 )); then
                    print_warn "Nothing to remove — '$name' isn't deployed."
                    continue
                fi
                pick_instance "${instances[@]}" || continue
                # '|| true': a failure here (e.g. Docker Compose missing)
                # should return to the menu, not kill the whole session.
                [[ -n "$INSTANCE_PATH" ]] && { remove_instance "$INSTANCE_PATH" || true; }
                ;;
            3)
                if (( ${#instances[@]} > 0 )); then
                    pick_instance "${instances[@]}" || continue
                    [[ -n "$INSTANCE_PATH" ]] && { remove_instance "$INSTANCE_PATH" || true; }
                fi
                print_info "Deploying $name fresh..."
                deploy_service "$name" "$category"
                ;;
            4) backup_menu "$name" "$category" || true ;;
            5) restore_menu "$name" "$category" || true ;;
            0) return ;;
        esac
    done
}

# Lists the services within one category, marking not-yet-built ones. Picking
# an available one hands off to the existing service_menu (deploy/remove/
# reinstall); picking a roadmap placeholder just prints a notice and stays
# in this same category list.
category_menu() {
    local category="$1"
    while true; do
        local -a slugs=() names=() marks=()
        local entry cat slug name
        for entry in "${CATALOG[@]}"; do
            IFS='|' read -r cat slug name <<< "$entry"
            [[ "$cat" == "$category" ]] || continue
            slugs+=("$slug")
            names+=("$name")
            if is_available "$category" "$slug"; then
                marks+=("")
            else
                marks+=("  (coming soon)")
            fi
        done

        echo
        echo "$category:"
        local i
        for ((i = 1; i <= ${#names[@]}; i++)); do
            echo "  $i) ${names[$((i - 1))]}${marks[$((i - 1))]}"
        done
        prompt_choice "${#names[@]}" "Back" || continue
        [[ "$CHOSEN_INDEX" == "0" ]] && return

        local picked_slug="${slugs[$((CHOSEN_INDEX - 1))]}"
        local picked_name="${names[$((CHOSEN_INDEX - 1))]}"
        if is_available "$category" "$picked_slug"; then
            service_menu "$picked_slug" "$category"
        else
            echo
            print_warn "$picked_name isn't available yet — coming soon!"
        fi
    done
}

main_menu() {
    # Category list, in first-appearance order from CATALOG — add a new
    # category by adding its first CATALOG entry, nothing else to update here.
    local -a categories=()
    local entry cat slug name c already_listed
    for entry in "${CATALOG[@]}"; do
        IFS='|' read -r cat slug name <<< "$entry"
        already_listed=false
        for c in "${categories[@]}"; do
            [[ "$c" == "$cat" ]] && { already_listed=true; break; }
        done
        [[ "$already_listed" == false ]] && categories+=("$cat")
    done

    while true; do
        echo
        echo "Categories:"
        local i
        for ((i = 1; i <= ${#categories[@]}; i++)); do
            echo "  $i) ${categories[$((i - 1))]}"
        done
        prompt_choice "${#categories[@]}" "Exit" || continue
        [[ "$CHOSEN_INDEX" == "0" ]] && exit 0
        category_menu "${categories[$((CHOSEN_INDEX - 1))]}"
    done
}

main_menu

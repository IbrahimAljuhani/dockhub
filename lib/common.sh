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

# The counterpart: write a key into an existing .env, replacing the line if
# it's there and appending it if it isn't.
#
# The appending half is what matters. A deployment created before a setting
# existed has no line to replace, and a bare `sed s|^KEY=.*|` silently does
# nothing on that file — the script reports success while the setting never
# lands. That is how an "existing deployments keep working" upgrade path
# turns into "existing deployments quietly ignore the new option".
#
# $1 = key, $2 = value, $3 = path to the .env file.
set_env_value() {
    local key="$1" value="$2" file="$3" escaped
    [[ -f "$file" ]] || return 0
    if grep -aq "^${key}=" "$file"; then
        # The replacement text is NOT literal to sed. Three characters have
        # to be neutralised before it goes in:
        #   &   expands to the whole matched line
        #   |   ends the s|||  expression (the delimiter chosen below)
        #   \   starts an escape
        # Caught by a test, not by reading: an API base URL of
        # 'https://h/v1?a=1&b=2' wrote the OLD line into the middle of the
        # new value. Values reaching here include user-typed URLs and API
        # keys, so this is not hypothetical.
        escaped=$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')
        # '|' as the delimiter: values here are URLs and paths often enough
        # that '/' would collide. See the Vulhub sed that failed silently on
        # a '#' in the replacement.
        sed -i "s|^${key}=.*|${key}=${escaped}|" "$file"
    else
        # Appending is plain text, so it needs no escaping — and it is why a
        # .env written before a setting existed gains it instead of silently
        # ignoring it.
        echo "${key}=${value}" >> "$file"
    fi
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
AI_AGENT_CONTAINERS=(openclaw hermes openhands)

# Container names this call actually stopped. Callers read it to decide
# whether a follow-up message applies at all — "your consumers now point at
# a stopped container" is noise when nothing was stopped.
SINGLE_GROUP_STOPPED=()

# One-of-a-group enforcement, shared by providers and agents.
#
# Deliberately checks whether another member is RUNNING, not whether it is
# installed: contention is a runtime problem, and having llama.cpp installed
# but stopped costs nothing. Same shape as the Vulhub launcher's
# one-environment-at-a-time rule.
#
# Generic on purpose. Providers and agents both allow only one, but for
# DIFFERENT reasons, so each caller supplies its own — copying the VRAM
# wording onto agents would be a false statement in a warning, since agents
# never load a model at all.
#
#   $1    container being deployed (excluded from the check)
#   $2    what to call the group in the message
#   $3    why only one, as a newline-separated block
#   $4..  the group's container names
#
# Returns non-zero only if the user declines to stop the others.
ensure_single_in_group() {
    local self="$1" label="$2" why="$3"; shift 3
    local other running=() line
    SINGLE_GROUP_STOPPED=()
    for other in "$@"; do
        [[ "$other" == "$self" ]] && continue
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$other" && running+=("$other")
    done
    (( ${#running[@]} )) || return 0

    echo >&2
    print_warn "Another $label is already running: ${running[*]}"
    while IFS= read -r line; do
        [[ -n "$line" ]] && print_warn "$line"
    done <<< "$why"
    echo >&2
    local answer
    read -rp "Stop ${running[*]} and continue? (Y/n): " answer
    if [[ "${answer,,}" == "n" ]]; then
        print_info "Leaving ${running[*]} running. Nothing was deployed."
        return 1
    fi
    for other in "${running[@]}"; do
        if docker stop "$other" >/dev/null 2>&1; then
            print_info "Stopped $other."
            SINGLE_GROUP_STOPPED+=("$other")
        else
            print_warn "Could not stop $other — check 'docker ps'."
        fi
    done
    return 0
}

# ── An agent's network posture ──────────────────────────────────────────
# Open WebUI sits on main-net and that is fine: it displays a conversation
# and executes nothing. An agent executes. THE ABILITY TO RUN COMMANDS is
# what changes the posture, and it is the line services/AI-Agents draws.
#
# On main-net an agent reaches every other service by container name —
# including Portainer, which mounts the Docker socket. The chain from "a web
# page it read said so" to "root on the host" is one step long.
#
# So: ai-net always (the provider is all it needs), main-net only when asked
# for, with the reason named rather than implied. Sets AGENT_ON_MAIN_NET.
#
# $1 = service name, used in the messages.
AGENT_ON_MAIN_NET=0
prompt_agent_network() {
    local name="$1" answer
    AGENT_ON_MAIN_NET=0
    echo >&2
    print_info "$name will run on 'ai-net', where it can reach the model provider."
    print_info "That is all it needs to work."
    echo >&2
    print_warn "Joining 'main-net' as well would let NGINX Proxy Manager serve it on"
    print_warn "a public domain — but it also lets $name reach every other DockHub"
    print_warn "service by name, including Portainer and its Docker socket."
    print_warn "An agent acts on text it did not write. Keep that in mind here."
    echo >&2
    read -rp "Also join 'main-net', so NPM can serve it on a domain? (y/N): " answer
    if [[ "${answer,,}" == "y" ]]; then
        AGENT_ON_MAIN_NET=1
        ensure_main_net
        print_warn "On 'main-net'. Give it its own credentials, never your primary ones."
    else
        print_info "'ai-net' only. Reach it on a host port from your LAN — no domain."
    fi
    return 0
}

# Agents are alternatives too, but NOT for the providers' reason: an agent is
# a consumer and never loads a model, so there is no VRAM contention to cite.
# You pick one assistant.
ensure_single_agent() {
    ensure_single_in_group "$1" "AI agent" \
"Agents are alternatives, not companions — you pick one assistant.
Several at once means several memories acting on the same workspace,
all queueing against the one model provider." \
        "${AI_AGENT_CONTAINERS[@]}"
}

# Providers are alternatives for a HARD technical reason: they all load
# models into the same GPU memory, so two at once means either an
# out-of-memory failure or constant swapping.
#
# $1 = the container name of the provider being deployed (excluded from the
# check). Returns non-zero only if the user declines to stop the others.
ensure_single_provider() {
    ensure_single_in_group "$1" "model provider" \
"Providers share the same GPU memory, so running two at once means
either an out-of-memory failure or constant model swapping." \
        "${AI_PROVIDER_CONTAINERS[@]}" || return 1
    (( ${#SINGLE_GROUP_STOPPED[@]} )) || return 0
    # Consumers keep their old endpoint in .env, so they now point at a
    # container that isn't running. The visible symptom is an empty model
    # list with nothing explaining it; rerunning a consumer's deploy.sh
    # detects the change and offers to re-point it.
    print_warn "Anything already using ${SINGLE_GROUP_STOPPED[*]} (Open WebUI, agents) still"
    print_warn "points at it. Rerun that service's deploy.sh to switch it over."
    return 0
}

# Waits for a container to become ready, and — the part that matters — knows
# the difference between "still starting" and "already dead".
#
# Extracted after writing it twice: llama.cpp's first version polled a
# readiness command in a loop, and because `docker exec` fails identically
# whether a container is loading or has exited, a container crash-looping on
# a bad setting looked exactly like a slow multi-gigabyte download. Twenty
# minutes of silence, then a timeout blaming the wrong thing.
#
# $1 = container, $2 = shell command run INSIDE it to test readiness,
# $3 = max rounds (default 120), $4 = seconds per round (default 10).
# Returns: 0 ready · 1 container died · 2 timed out.
# On death it prints the container's own last lines — the only place the real
# reason ever appears.
wait_for_container_ready() {
    local name="$1" probe="$2" rounds="${3:-120}" gap="${4:-10}"
    local i state line last=""
    for (( i = 1; i <= rounds; i++ )); do
        state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)
        # Checked first, every round. "restarting" counts as dead: a crash
        # loop never becomes ready, and waiting it out helps nobody.
        if [[ "$state" != "running" ]]; then
            echo >&2
            print_warn "The container stopped (state: $state). Its last output:"
            echo "──────────────────────────────────────────────" >&2
            docker logs --tail 25 "$name" 2>&1 | sed 's/^/  /' >&2
            echo "──────────────────────────────────────────────" >&2
            return 1
        fi
        if docker exec "$name" sh -c "$probe" >/dev/null 2>&1; then
            return 0
        fi
        # Echo the newest log line periodically. A long download behind a
        # silent prompt is indistinguishable from a hang.
        if (( i % 3 == 0 )); then
            line=$(docker logs --tail 1 "$name" 2>&1 | tr -d '\r' | tail -n1)
            if [[ -n "$line" && "$line" != "$last" ]]; then
                echo "   … $line"
                last="$line"
            fi
        fi
        sleep "$gap"
    done
    return 2
}

# Finds whichever model provider is currently running and where to reach it.
# Sets AI_PROVIDER_NAME and AI_PROVIDER_BASE_URL in the caller's shell, both
# empty when nothing is running.
#
# Consumers call this instead of hardcoding "ollama", so the same deploy.sh
# keeps working when the user later switches to llama.cpp or LocalAI — the
# only thing that changes is which container answers.
#
# Note the caller still decides which environment variable to put the URL in:
# Ollama has a native API that most consumers support directly, while
# llama.cpp and LocalAI are reached through their OpenAI-compatible /v1
# path. That mapping is consumer-specific, so it doesn't belong here.
AI_PROVIDER_NAME=""
AI_PROVIDER_BASE_URL=""
detect_ai_provider() {
    AI_PROVIDER_NAME=""
    AI_PROVIDER_BASE_URL=""
    local name
    for name in "${AI_PROVIDER_CONTAINERS[@]}"; do
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name" || continue
        AI_PROVIDER_NAME="$name"
        case "$name" in
            ollama)    AI_PROVIDER_BASE_URL="http://ollama:11434" ;;
            llama-cpp) AI_PROVIDER_BASE_URL="http://llama-cpp:8080" ;;
            localai)   AI_PROVIDER_BASE_URL="http://localai:8080" ;;
        esac
        return 0
    done
    return 0
}

# ── Where model weights live ────────────────────────────────────────────
# One directory for every AI service, asked once and remembered in
# ~/docker/.dockhub-env beside the environment answers.
#
# Bind mount rather than named volumes, deliberately. Named volumes are
# easier (Docker fixes their ownership for you), but they hide the single
# largest thing this project downloads inside /var/lib/docker/volumes, where
# you cannot see what is using the space and cannot move it to a bigger disk
# without relocating all of Docker. Models are 25+ GB for a LocalAI AIO set.
#
# What this does NOT buy you: sharing weights between providers. Ollama
# repacks into a content-addressed blob store (blobs/sha256-… + manifests),
# and llama.cpp and LocalAI both use GGUF but with different layouts and
# names. They coexist under one budget; they do not reuse each other's
# downloads. The win is visibility and relocation, not deduplication.
AI_MODELS_DIR=""
resolve_ai_models_dir() {
    local env_file="$HOME/docker/.dockhub-env" stored answer default
    default="$HOME/docker/ai-models"
    mkdir -p "$HOME/docker"

    stored=$(grep -a '^AI_MODELS_DIR=' "$env_file" 2>/dev/null | cut -d= -f2- || true)
    if [[ -n "$stored" ]]; then
        AI_MODELS_DIR="$stored"
        mkdir -p "$AI_MODELS_DIR" 2>/dev/null || true
        return 0
    fi

    echo
    print_info "Where should AI model weights be stored?"
    print_info "This is the largest thing DockHub downloads — a full LocalAI set"
    print_info "is 25+ GB. Keeping it in one folder lets you see the space with"
    print_info "'du -sh', and point it at a second disk instead of moving Docker."
    print_info "Asked once; every AI service reuses the answer."
    echo
    while true; do
        read -rp "Directory (default: $default): " answer
        AI_MODELS_DIR="${answer:-$default}"
        # Absolute only: a relative path resolves against whatever directory
        # deploy.sh happened to be run from, which is not the same place twice.
        [[ "$AI_MODELS_DIR" == /* ]] && break
        echo "Please give an absolute path, starting with '/'." >&2
    done

    if ! mkdir -p "$AI_MODELS_DIR" 2>/dev/null; then
        print_error "Could not create $AI_MODELS_DIR. Check the path and permissions."
    fi
    [[ -f "$env_file" ]] || : > "$env_file"
    set_env_value "AI_MODELS_DIR" "$AI_MODELS_DIR" "$env_file"
    print_info "Saved to $env_file — change it there to relocate future deployments."
    return 0
}

# Creates a service's model directory and PROVES the container can write to
# it. $1 = host directory, $2 = the image that will mount it.
#
# This is the price of bind mounts. A named volume is chowned by Docker to
# whatever the image needs; a host directory is not, so an image running as a
# non-root user gets permission denied — and it surfaces mid-download, as an
# error that reads like a network failure rather than a permissions one.
#
# Returns non-zero only when the container genuinely cannot write. A probe
# that could not run at all is reported and passed, because failing a deploy
# on a broken test is worse than not testing.
prepare_model_dir() {
    local dir="$1" image="$2" user rc=0
    mkdir -p "$dir" || { print_warn "Could not create $dir."; return 1; }

    user=$(docker image inspect --format '{{.Config.User}}' "$image" 2>/dev/null || true)
    if [[ -n "$user" && "$user" != "root" && "$user" != "0" && "$user" != "0:0" ]]; then
        # chown from INSIDE the image, so a user NAME resolves against that
        # image's own /etc/passwd — alpine has never heard of 'node'.
        docker run --rm --user 0 --entrypoint sh -v "$dir":/d "$image" \
            -c "chown -R $user /d" >/dev/null 2>&1 \
            || print_warn "Could not hand $dir to the image's '$user' user."
    fi

    docker run --rm --entrypoint sh -v "$dir":/d "$image" \
        -c 'touch /d/.dockhub-write-test && rm -f /d/.dockhub-write-test' >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) return 0 ;;
        125|126|127)
            # Docker refused, or there is no shell to run the probe with.
            print_info "Could not run a write test inside $image — continuing."
            return 0
            ;;
        *)
            print_warn "$image cannot write to $dir — the bind-mount permission trap."
            print_warn "Fix the ownership and rerun:"
            print_warn "  sudo chown -R \$(id -u):\$(id -g) $dir"
            return 1
            ;;
    esac
}

# Where Docker actually stores volumes and images. NOT $HOME: models live in
# named volumes under Docker's root directory, and on a host with a separate
# /home partition those are different filesystems. Checking $HOME there can
# report 400 GB free while the partition the download lands on has 5 GB —
# a check that passes and then fails is worse than no check.
docker_data_dir() {
    local dir
    dir=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)
    [[ -n "$dir" && -d "$dir" ]] && { printf '%s' "$dir"; return 0; }
    printf '%s' "${HOME}"
}

# Warns when there isn't room for what's about to be downloaded. Language
# models are the only thing in DockHub measured in tens of gigabytes, so a
# generic "enough disk?" check isn't enough — the caller passes what the
# specific model needs. $1 = GB required, $2 = path to check (defaults to
# Docker's storage, which is where a pulled model actually lands).
# Returns non-zero if short; the caller decides whether that's fatal.
check_free_disk_gb() {
    local need="$1" path="${2:-$(docker_data_dir)}" free probe
    # df fails on a path that does not exist yet — and the caller's path
    # usually does NOT, because the whole point is to check before creating
    # and downloading. Returning "fine" there is the worst possible outcome:
    # observed live, LocalAI's first deploy printed no disk check at all,
    # while its second (where the directory survived a removal) printed one.
    # Walk up to the nearest existing ancestor; it is on the same filesystem.
    probe="$path"
    while [[ -n "$probe" && ! -e "$probe" ]]; do
        probe="${probe%/*}"
    done
    [[ -n "$probe" ]] || probe="/"
    free=$(df -BG --output=avail "$probe" 2>/dev/null | tail -n1 | tr -dc '0-9') || return 0
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
    # 600, not the umask default. Every service's install_dir holds its .env,
    # and many hold a generated secrets file too — database passwords, API
    # keys, an agent's messaging tokens. Those are created 600 at the source;
    # leaving the archive that contains them world-readable would undo that
    # for anyone with an account on this host.
    chmod 600 "$backup_root/${ts}.tar.gz"
    rm -rf "$staging"
    print_info "Backup saved: $backup_root/${ts}.tar.gz"
}

# $1 = service slug, $2 = instance name (empty for single-instance), $3 =
# install dir, $4 = path to the .tar.gz to restore. Overwrites everything
# currently under install_dir plus named volumes — callers must confirm
# with the user before calling this (see services.sh).
# Backs up a service's CONFIGURATION only, leaving its volumes alone.
#
# For a model provider the generic backup is actively harmful, not merely
# wasteful. A LocalAI All-In-One volume is 25+ GB of GGUF and safetensors —
# already-quantised binary that gzip cannot compress — and the generic path
# gzips it into a staging directory and then gzips that again. So it burns
# a long single-threaded compression pass, needs roughly double the space
# free (staging under $TMPDIR plus the final archive), and what it preserves
# is a file set that `ollama pull` or a container restart re-fetches for
# free. Nothing in it is yours.
#
# What IS worth keeping is small and irreplaceable-by-download: .env holds
# the model choice, the acceleration decision, the port and the memory
# limit, and the compose files hold how it was wired up.
#
# NOT for Open WebUI: its volume holds accounts, chat history and uploaded
# documents. That is real user data and belongs in the generic backup.
backup_service_config_only() {
    local service="$1" instance="${2:-}" install_dir="$3"
    local backup_root="$HOME/docker/backups/$service"
    [[ -n "$instance" ]] && backup_root="$backup_root/$instance"
    mkdir -p "$backup_root"

    local ts staging
    ts="$(date '+%Y-%m-%d_%H%M')"
    staging="$(mktemp -d)"

    mkdir -p "$staging/install_dir"
    docker run --rm -v "$install_dir":/data:ro -v "$staging/install_dir":/backup alpine \
        sh -c "cp -a /data/. /backup/" \
        || print_warn "Some files under $install_dir may not have been backed up — check permissions."

    # Say plainly what was left out and how big it was. A backup that is
    # silently a hundredth of the size you expected looks like a failure.
    local project_name volumes vol size
    project_name="$(basename "$install_dir")"
    volumes=$(docker volume ls --format '{{.Name}}' | grep -E "^${project_name}_" || true)
    if [[ -n "$volumes" ]]; then
        print_info "Skipping the model volume(s) — downloaded weights, not your data:"
        for vol in $volumes; do
            size=$(docker run --rm -v "$vol":/data:ro alpine du -sh /data 2>/dev/null | awk '{print $1}' || true)
            print_info "   $vol${size:+  ($size)}"
        done
        print_info "Re-downloaded on the next start. Config and .env ARE in the backup."
    fi

    tar czf "$backup_root/${ts}.tar.gz" -C "$staging" .
    # 600, not the umask default. Every service's install_dir holds its .env,
    # and many hold a generated secrets file too — database passwords, API
    # keys, an agent's messaging tokens. Those are created 600 at the source;
    # leaving the archive that contains them world-readable would undo that
    # for anyone with an account on this host.
    chmod 600 "$backup_root/${ts}.tar.gz"
    rm -rf "$staging"
    print_info "Backup saved: $backup_root/${ts}.tar.gz"
}

# Restores an archive made by either backup function — the volumes block is
# skipped when the archive has none, so config-only archives need no special
# restore of their own.
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

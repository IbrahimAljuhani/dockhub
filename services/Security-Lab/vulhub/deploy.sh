#!/bin/bash
# deploy.sh (services/Security-Lab/vulhub)
# Purpose: A LAUNCHER for Vulhub, not a deployment.
#
# Vulhub is not a service. It is a library of ~330 separate docker-compose
# environments, each reproducing a real CVE — Log4Shell, Struts RCE, and so
# on. Every other service in DockHub ships a compose file we wrote and can
# reason about. Here the compose files belong to upstream, and some of them
# run privileged, use host networking, or publish on 0.0.0.0. None of the
# Security-Lab hardening applied to Juice Shop and WebGoat can be applied to
# them, because that would mean forking hundreds of files that change with
# every update to the repo.
#
# That is why this script REFUSES to run on a host where main-net exists.
# main-net is created by install_dockhub.sh for NGINX Proxy Manager, so its
# presence means this is the machine carrying your real services. Vulhub
# belongs on a separate, throwaway machine — a requirement here, not advice.
#
# See services/Security-Lab/README.md for the threat model.

set -euo pipefail

ALLOW_PRODUCTION_HOST=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0 [--allow-production-host]"
            echo
            echo "Launch one Vulhub CVE environment at a time on a throwaway machine."
            echo
            echo "  --allow-production-host   Skip the refusal to run on a host that has"
            echo "                            main-net (i.e. one running your real services)."
            echo "                            You are accepting that a working, unauthenticated"
            echo "                            RCE will be running beside them."
            exit 0
            ;;
        --allow-production-host)
            ALLOW_PRODUCTION_HOST=1
            shift
            ;;
        *)
            echo "Unknown option: $1 (try --help)" >&2
            exit 1
            ;;
    esac
done

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/vulhub"
REPO_DIR="$INSTALL_DIR/vulhub"
STATE_FILE="$INSTALL_DIR/.current-environment"

LIB_COMMON="$SOURCE_DIR/../../../lib/common.sh"
if [[ ! -f "$LIB_COMMON" ]]; then
    LIB_COMMON="$(mktemp -d)/common.sh"
    curl -fsSL -o "$LIB_COMMON" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_COMMON"

check_prerequisites
command -v git >/dev/null 2>&1 || print_error "git is required to fetch Vulhub. Install it with: sudo apt install -y git"

# ── The host check ──────────────────────────────────────────────────────
# Deliberately before the confirmation prompt: on the wrong machine there is
# nothing to confirm.
if docker network ls --format '{{.Name}}' | grep -qx "main-net"; then
    if (( ! ALLOW_PRODUCTION_HOST )); then
        echo >&2
        print_warn "This host has the 'main-net' network, which means install_dockhub.sh"
        print_warn "set up NGINX Proxy Manager here and you are very likely running your"
        print_warn "real services on this machine."
        echo >&2
        print_warn "Vulhub environments are working, unauthenticated remote code execution"
        print_warn "exploits. Unlike Juice Shop and WebGoat, whose flaws live in the"
        print_warn "application and are attacked through a browser, a Vulhub exploit puts"
        print_warn "an attacker INSIDE the container immediately. Their compose files are"
        print_warn "upstream's — some run privileged or on host networking — so none of"
        print_warn "this repo's Security-Lab hardening can be applied to them."
        echo >&2
        print_warn "Run this on a separate, disposable machine or VM."
        echo >&2
        print_warn "If you have genuinely accepted this risk, the override is NOT available"
        print_warn "through the install_dockhub.sh / services.sh menus — deliberately. Those"
        print_warn "hand off without forwarding arguments, and a flag whose only purpose is"
        print_warn "to switch off a safety check should not be reachable from the friendliest"
        print_warn "entry point. Invoke this script directly instead:"
        echo >&2
        echo "    bash $SOURCE_DIR/deploy.sh --allow-production-host" >&2
        echo >&2
        print_error "Refusing to continue."
    fi
    print_warn "--allow-production-host given: continuing on a host that runs your real services."
fi

confirm_vulnerable_deploy "Vulhub"

mkdir -p "$INSTALL_DIR"

# ── Fetch or update the library ─────────────────────────────────────────
# --depth 1: the repo is ~180 MB of history and none of it is useful here.
# --recurse-submodules: base/oracle-java is a submodule a few Java
# environments build from, and without it those fail with a confusing
# "no such file or directory" at build time rather than a missing-submodule
# message.
if [[ -d "$REPO_DIR/.git" ]]; then
    print_info "Updating the Vulhub library..."
    (cd "$REPO_DIR" && git pull --quiet --recurse-submodules) \
        || print_warn "Could not update — continuing with the copy already on disk."
else
    print_info "Fetching the Vulhub library (a shallow clone, roughly 100 MB)..."
    git clone --depth 1 --recurse-submodules --quiet \
        https://github.com/vulhub/vulhub.git "$REPO_DIR" \
        || print_error "Failed to clone Vulhub."
fi

# Every directory holding a docker-compose.yml is one environment.
mapfile -t ENVIRONMENTS < <(cd "$REPO_DIR" && find . -name docker-compose.yml -printf '%h\n' 2>/dev/null | sed 's|^\./||' | sort)
(( ${#ENVIRONMENTS[@]} > 0 )) || print_error "No environments found under $REPO_DIR — the clone may be incomplete."
print_info "${#ENVIRONMENTS[@]} environments available."

# ── Stop whatever is already running ────────────────────────────────────
# Only one environment at a time: Vulhub's compose files reuse the obvious
# ports (8080, 8983, 3306...) constantly, so a second one usually collides
# with the first in ways that look like the exploit failing.
stop_current() {
    local current
    current=$(cat "$STATE_FILE" 2>/dev/null || true)
    [[ -n "$current" && -d "$REPO_DIR/$current" ]] || return 0
    print_info "Stopping the currently running environment: $current"
    (cd "$REPO_DIR/$current" && $COMPOSE_CMD down --remove-orphans) \
        || print_warn "Could not stop $current cleanly — check 'docker ps'."
    rm -f "$STATE_FILE"
    return 0
}

CURRENT=$(cat "$STATE_FILE" 2>/dev/null || true)
if [[ -n "$CURRENT" ]]; then
    echo
    print_warn "Environment currently running: $CURRENT"
    read -rp "Stop it now? (Y/n): " stop_answer
    if [[ "${stop_answer,,}" != "n" ]]; then
        stop_current
    else
        echo "Leaving it running. Nothing else to do."
        exit 0
    fi
fi

# ── Pick an environment ─────────────────────────────────────────────────
# A search rather than a menu: 330 entries is not a list anyone reads.
SELECTED=""
while [[ -z "$SELECTED" ]]; do
    echo
    read -rp "Search for an environment (e.g. log4j, struts2, tomcat) or 'q' to quit: " query
    [[ "$query" == "q" ]] && { echo "Nothing started."; exit 0; }
    [[ -n "$query" ]] || continue

    mapfile -t MATCHES < <(printf '%s\n' "${ENVIRONMENTS[@]}" | grep -i -- "$query" || true)
    if (( ${#MATCHES[@]} == 0 )); then
        echo "No environment matches '$query'." >&2
        continue
    fi
    if (( ${#MATCHES[@]} > 30 )); then
        echo "${#MATCHES[@]} matches — too many to show. Try something more specific." >&2
        continue
    fi

    echo
    idx=1
    for m in "${MATCHES[@]}"; do
        printf "  %2d) %s\n" "$idx" "$m"
        idx=$(( idx + 1 ))
    done
    echo "   0) Search again"
    read -rp "Choice (0-${#MATCHES[@]}): " pick
    if [[ "$pick" == "0" ]] || [[ ! "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#MATCHES[@]} )); then
        continue
    fi
    SELECTED="${MATCHES[$(( pick - 1 ))]}"
done

ENV_DIR="$REPO_DIR/$SELECTED"

# Each environment ships a README explaining the vulnerability and how to
# exploit it. That README is the actual learning material — the container is
# just the target — so it gets shown rather than merely mentioned.
echo
echo "══════════════════════════════════════════════"
if [[ -f "$ENV_DIR/README.md" ]]; then
    # Skip the Chinese-version link line every Vulhub README carries as its
    # second line — it's noise here — and take enough lines that the
    # "References:" heading arrives with its links rather than dangling.
    grep -v '中文版本' "$ENV_DIR/README.md" | head -n 12
else
    echo "$SELECTED"
fi
echo "══════════════════════════════════════════════"
echo
read -rp "Start this environment? (y/N): " start_answer
[[ "${start_answer,,}" == "y" ]] || { echo "Nothing started."; exit 0; }

print_info "Starting $SELECTED (first run may build or pull images)..."
(cd "$ENV_DIR" && $COMPOSE_CMD up -d) \
    || print_error "Failed to start $SELECTED. Its own README may list extra steps: $ENV_DIR/README.md"

echo "$SELECTED" > "$STATE_FILE"

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<this-host>"

echo
echo "──────────────────────────────────────────────"
echo "🧪 Environment:  $SELECTED"
echo "📖 Write-up:     $ENV_DIR/README.md"
echo "🖥️  Host:         $SERVER_IP"
echo "──────────────────────────────────────────────"
echo
echo "📡 Published ports:"
(cd "$ENV_DIR" && $COMPOSE_CMD ps --format '   {{.Service}}  {{.Ports}}' 2>/dev/null) \
    || echo "   (check with: cd $ENV_DIR && $COMPOSE_CMD ps)"
echo
echo "⚠️  These ports are published by UPSTREAM's compose file, on all"
echo "   interfaces. This script does not control that — which is exactly why"
echo "   this belongs on a disposable machine."
echo
echo "🛑 Stop it when you're done:"
echo "     cd $ENV_DIR && $COMPOSE_CMD down"
echo "   Or rerun this script — it offers to stop the running environment first."
echo
echo "📌 Read the write-up above before attacking it. Vulhub's value is the"
echo "   explanation of WHY the CVE works; the container is just the target."

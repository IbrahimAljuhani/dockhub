#!/bin/bash
# deploy.sh (services/Security-Lab/juice-shop)
# Purpose: Deploy OWASP Juice Shop — DELIBERATELY VULNERABLE software, for
# practising application security on a target you are allowed to attack.
#
# See services/Security-Lab/README.md for the threat model, and this
# service's docker-compose.yml for why its settings are stricter than the
# rest of DockHub rather than looser.
#
# This is a single-instance service, under ~/docker/juice-shop/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy OWASP Juice Shop (deliberately vulnerable) on an isolated network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/juice-shop"
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

check_prerequisites

# Before anything else, including creating directories. Aborting has to mean
# nothing happened.
confirm_vulnerable_deploy "OWASP Juice Shop"

mkdir -p "$INSTALL_DIR"

# Deliberately NOT ensure_main_net. This service must never join it.
# The lab's own shared network instead — see lib/common.sh.
ensure_seclab_net

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    detect_seclab_bind

    JUICE_PORT="3000"
    while true; do
        read -rp "Port to serve Juice Shop on (default: 3000): " port_input
        port_input="${port_input:-3000}"
        if ! valid_port "$port_input"; then
            echo "Invalid port — must be a number between 1024 and 65535." >&2
            continue
        fi
        if port_in_use "$port_input"; then
            read -rp "Port $port_input looks already in use — continue anyway? (y/N): " cont
            [[ "${cont,,}" == "y" ]] || continue
        fi
        JUICE_PORT="$port_input"
        break
    done

    # Juice Shop ships some challenges disabled: the ones that reach the
    # filesystem rather than staying inside the app. 'unsafe' enables them.
    # Asked rather than assumed — it genuinely widens what a successful
    # exploit can touch, and the honest answer depends on what you're here
    # to learn.
    JUICE_MODE="production"
    echo
    read -rp "Enable ALL challenges, including the filesystem ones Juice Shop disables by default? (y/N): " unsafe_answer
    if [[ "${unsafe_answer,,}" == "y" ]]; then
        JUICE_MODE="unsafe"
        print_warn "Unsafe mode: every challenge is enabled, including ones that write outside the app."
    fi

    prompt_mem_limit "juice-shop" "512m"

    cat > "$INSTALL_DIR/.env" <<EOF
JUICE_SHOP_VERSION=v20.1.1
SECLAB_BIND=$SECLAB_BIND
JUICE_SHOP_PORT=$JUICE_PORT
JUICE_SHOP_MODE=$JUICE_MODE
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    print_info "Generated .env at $INSTALL_DIR."
    # No secrets file: Juice Shop has no admin credentials to generate. Its
    # accounts are part of the exercise — finding them IS a challenge.
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    # OFFERED, not merely announced. A kept compose from before 2026-08-20
    # still declares a PER-SERVICE network and carries no cpus limit, so a
    # deployment left on it silently misses both the shared seclab-net and a
    # containment measure the category README promises. The operator still
    # decides; they just have to decide.
    offer_compose_update "$INSTALL_DIR/docker-compose.yml" "$SOURCE_DIR/docker-compose.yml" \
        "rm $INSTALL_DIR/docker-compose.yml && bash $0"
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

ENV_MEM_LIMIT=$(read_env_value "MEM_LIMIT" "$INSTALL_DIR/.env")
ENV_BIND=$(read_env_value "SECLAB_BIND" "$INSTALL_DIR/.env")
ENV_PORT=$(read_env_value "JUICE_SHOP_PORT" "$INSTALL_DIR/.env")
ENV_MODE=$(read_env_value "JUICE_SHOP_MODE" "$INSTALL_DIR/.env")

# ── Checked here, every run, not only on a first install ─────────────────
# An empty SECLAB_BIND turns the compose file's "${SECLAB_BIND}:3000:3000"
# into ":3000:3000" — every interface, for deliberately vulnerable software.
# This is the one value in the file with no default, on purpose, so it is the
# one value that has to be asserted. Fails closed.
assert_seclab_bind "$ENV_BIND" "Juice Shop"

# The compose file now carries a memory limit that always applies; this only
# RAISES it when you asked for something else. `cpus` is set there too.
if [[ -n "$ENV_MEM_LIMIT" ]]; then
    set_env_value SECLAB_MEM "$ENV_MEM_LIMIT" "$INSTALL_DIR/.env"
fi
rm -f "$INSTALL_DIR/docker-compose.override.yml"

# NOT fatal, deliberately: a redeploy whose image is already on disk must
# still work on a host with no internet. pull_with_progress prints the real
# failure; `up -d` below gives the verdict.
pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Juice Shop..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Juice Shop. Check log: $LOGFILE"

# Juice Shop rebuilds its database on every start, so "container running"
# genuinely precedes "app answering". Wait for a real HTTP response rather
# than reporting success and leaving you to discover it wasn't ready.
print_info "Waiting for Juice Shop to finish starting..."
READY=0
for _ in $(seq 1 40); do
    if curl -fsS -o /dev/null --max-time 3 "http://$ENV_BIND:$ENV_PORT/" 2>/dev/null; then
        READY=1
        break
    fi
    sleep 3
done

echo
echo "──────────────────────────────────────────────"
echo "🧪 URL:          http://$ENV_BIND:$ENV_PORT"
echo "🏆 Scoreboard:   http://$ENV_BIND:$ENV_PORT/#/score-board"
echo "⚙️  Mode:         $ENV_MODE$( [[ "$ENV_MODE" == "unsafe" ]] && echo "  (all challenges enabled)" )"
echo "📜 Log:          $LOGFILE"
echo "──────────────────────────────────────────────"
echo
if (( READY )); then
    print_info "Self-test passed — the app answered an HTTP request."
else
    print_warn "The app did not answer within two minutes. It may still be starting:"
    print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f juice-shop"
fi
echo
echo "⚠️  This is DELIBERATELY VULNERABLE software, reachable from your LAN."
echo "   Stop it when you finish practising:"
echo "     cd $INSTALL_DIR && $COMPOSE_CMD stop"
echo "   Nothing here restarts on boot, so stopped stays stopped."
echo
echo "🔎 Left something running? Check every lab container at once:"
echo "     docker ps --filter \"label=dockhub.security-lab=true\""
echo
echo "📌 No login is provided — finding accounts is part of the exercise."
echo "   Start at the scoreboard above; it lists every challenge by difficulty."
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|start]"

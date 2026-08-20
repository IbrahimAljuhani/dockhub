#!/bin/bash
# deploy.sh (services/Security-Lab/webgoat)
# Purpose: Deploy OWASP WebGoat + WebWolf — DELIBERATELY VULNERABLE software,
# for practising application security on a target you are allowed to attack.
#
# See services/Security-Lab/README.md for the threat model, and this
# service's docker-compose.yml for why WebWolf matters and why
# WEBGOAT_HOST/WEBWOLF_HOST are not bind addresses.
#
# This is a single-instance service, under ~/docker/webgoat/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy OWASP WebGoat + WebWolf (deliberately vulnerable) on an isolated network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/webgoat"
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
confirm_vulnerable_deploy "OWASP WebGoat"

mkdir -p "$INSTALL_DIR"

# Deliberately NOT ensure_main_net. This service must never join it.
# The lab's own shared network instead — see lib/common.sh.
ensure_seclab_net

# Asks for one of the two ports. $1 = label, $2 = default. Sets SEC_PORT.
SEC_PORT=""
prompt_lab_port() {
    local label="$1" default="$2" port_input cont
    while true; do
        read -rp "Port for $label (default: $default): " port_input
        port_input="${port_input:-$default}"
        if ! valid_port "$port_input"; then
            echo "Invalid port — must be a number between 1024 and 65535." >&2
            continue
        fi
        if port_in_use "$port_input"; then
            read -rp "Port $port_input looks already in use — continue anyway? (y/N): " cont
            [[ "${cont,,}" == "y" ]] || continue
        fi
        SEC_PORT="$port_input"
        return 0
    done
}

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    detect_seclab_bind

    print_info "WebGoat and WebWolf run in one container but need a port each."
    prompt_lab_port "WebGoat (the lessons)" "8080"
    WEBGOAT_PORT_VALUE="$SEC_PORT"
    prompt_lab_port "WebWolf (the attacker-side companion)" "9090"
    WEBWOLF_PORT_VALUE="$SEC_PORT"

    # Several lessons compare timestamps. The image defaults to
    # Europe/Amsterdam, and a mismatch with your own clock makes those
    # lessons look broken rather than misconfigured.
    HOST_TZ="UTC"
    if [[ -f /etc/timezone ]]; then
        HOST_TZ=$(cat /etc/timezone 2>/dev/null || echo UTC)
    elif command -v timedatectl >/dev/null 2>&1; then
        HOST_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)
    fi
    [[ -n "$HOST_TZ" ]] || HOST_TZ="UTC"
    read -rp "Timezone for the lessons (default: $HOST_TZ, matching this host): " tz_input
    WEBGOAT_TZ_VALUE="${tz_input:-$HOST_TZ}"

    # 1g, not Juice Shop's 512m: this is a JDK image and some lessons compile
    # Java at runtime.
    prompt_mem_limit "webgoat" "1g"

    cat > "$INSTALL_DIR/.env" <<EOF
WEBGOAT_VERSION=v2025.3
SECLAB_BIND=$SECLAB_BIND
WEBGOAT_PORT=$WEBGOAT_PORT_VALUE
WEBWOLF_PORT=$WEBWOLF_PORT_VALUE
WEBGOAT_TZ=$WEBGOAT_TZ_VALUE
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    print_info "Generated .env at $INSTALL_DIR."
    # No secrets file: WebGoat has no admin account. You register your own
    # user on first visit, and that account is per-deployment throwaway.
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
ENV_WEBGOAT_PORT=$(read_env_value "WEBGOAT_PORT" "$INSTALL_DIR/.env")
ENV_WEBWOLF_PORT=$(read_env_value "WEBWOLF_PORT" "$INSTALL_DIR/.env")
ENV_TZ=$(read_env_value "WEBGOAT_TZ" "$INSTALL_DIR/.env")

# Checked every run, not only on a first install. An empty SECLAB_BIND turns
# the compose file's bindings into ":8080:8080" — every interface, for
# deliberately vulnerable software — AND leaves WEBGOAT_HOST/WEBWOLF_HOST
# empty, so the links between the two apps break too. Fails closed.
assert_seclab_bind "$ENV_BIND" "WebGoat"

# The compose file now carries a memory limit that always applies; this only
# RAISES it when you asked for something else. `cpus` is set there too.
if [[ -n "$ENV_MEM_LIMIT" ]]; then
    set_env_value SECLAB_MEM "$ENV_MEM_LIMIT" "$INSTALL_DIR/.env"
fi
rm -f "$INSTALL_DIR/docker-compose.override.yml"

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting WebGoat (a JVM starting up — give it a minute)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start WebGoat. Check log: $LOGFILE"

# Both apps are checked, not just WebGoat. Publishing 8080 and forgetting
# 9090 is the single most common way this deployment goes wrong, and the
# symptom — a handful of lessons that quietly never complete — is very hard
# to trace back to a missing port.
print_info "Waiting for WebGoat and WebWolf to answer..."
GOAT_READY=0
WOLF_READY=0
lab_url_answers() { curl -fsS -o /dev/null --max-time 3 "$1" 2>/dev/null; }

for _ in $(seq 1 40); do
    if (( ! GOAT_READY )) && lab_url_answers "http://$ENV_BIND:$ENV_WEBGOAT_PORT/WebGoat/"; then
        GOAT_READY=1
    fi
    if (( ! WOLF_READY )) && lab_url_answers "http://$ENV_BIND:$ENV_WEBWOLF_PORT/WebWolf/"; then
        WOLF_READY=1
    fi
    if (( GOAT_READY && WOLF_READY )); then
        break
    fi
    sleep 3
done

echo
echo "──────────────────────────────────────────────"
echo "🐐 WebGoat:      http://$ENV_BIND:$ENV_WEBGOAT_PORT/WebGoat/"
echo "🐺 WebWolf:      http://$ENV_BIND:$ENV_WEBWOLF_PORT/WebWolf/"
echo "🕐 Timezone:     $ENV_TZ"
echo "📜 Log:          $LOGFILE"
echo "──────────────────────────────────────────────"
echo
if (( GOAT_READY && WOLF_READY )); then
    print_info "Self-test passed — both WebGoat and WebWolf answered."
else
    (( GOAT_READY )) || print_warn "WebGoat did not answer on port $ENV_WEBGOAT_PORT."
    (( WOLF_READY )) || print_warn "WebWolf did not answer on port $ENV_WEBWOLF_PORT."
    print_warn "A JVM can take longer than two minutes on a slow disk. Check:"
    print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f webgoat"
fi
echo
echo "📌 Note the /WebGoat/ and /WebWolf/ paths — neither app serves the root URL."
echo "   Register your own account on first visit; there is no default login."
echo
echo "🐺 What WebWolf is for: it's the attacker-side half. Lessons that ask you"
echo "   to receive a request, catch exfiltrated data, or read a mail land there."
echo "   Sign in to it with the SAME username you register in WebGoat."
echo
echo "⚠️  This is DELIBERATELY VULNERABLE software, reachable from your LAN."
echo "   Stop it when you finish practising:"
echo "     cd $INSTALL_DIR && $COMPOSE_CMD stop"
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|start]"

#!/bin/bash
# deploy.sh (services/Home-Automation/mosquitto)
# Purpose: Deploy Eclipse Mosquitto (MQTT broker) — see docker-compose.yml for
# why the generated config file and password file are not optional.
#
# This is a single-instance service: one broker per host, under
# ~/docker/mosquitto/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Eclipse Mosquitto, an MQTT broker, with authentication enabled."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/mosquitto"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.mosquitto-docker-secrets.txt"
MQTT_USER="mqtt"
# Single source of truth for the image tag: it is written into .env AND used
# for the throwaway password-file container below. Those were two separate
# literals once, which is exactly how they drifted apart.
#
# `2.1-alpine`, not `2.1`: the 2.1 line ships ONLY -alpine and -ubuntu
# variants — a bare `2.1` tag does not exist and never did. (Bare tags stop
# at 2.0.22.) `latest`, `2` and `2.1-alpine` currently share one digest, so
# this is mainline, not a side variant.
MOSQUITTO_TAG="2.1-alpine"

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

mkdir -p "$INSTALL_DIR/config"

ensure_main_net

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    MQTT_PASSWORD=$(generate_secret 24)

    # MQTT's own port, not an HTTP one, so this uses its own prompt rather
    # than prompt_host_port: it is never optional (a broker nothing can
    # connect to is pointless) and 1883 is the protocol's registered port,
    # which every client defaults to.
    MQTT_PORT_VALUE=1883
    if port_in_use 1883; then
        print_warn "Port 1883 already looks busy — another MQTT broker may be running."
        while true; do
            read -rp "MQTT port to publish (default: 1883): " port_input
            port_input="${port_input:-1883}"
            if [[ "$port_input" =~ ^[0-9]+$ ]] && (( 10#$port_input >= 1 && 10#$port_input <= 65535 )); then
                MQTT_PORT_VALUE="$port_input"
                break
            fi
            echo "Invalid port — must be a number between 1 and 65535." >&2
        done
    fi

    # Off by default: websockets only matter for MQTT clients running in a
    # browser. Everything else — Home Assistant, ESP devices, mosquitto_sub —
    # speaks plain MQTT on 1883.
    ENABLE_WS="false"
    read -rp "Also enable the WebSocket listener on 9001, for browser-based MQTT clients? (y/N): " ws_answer
    [[ "${ws_answer,,}" == "y" ]] && ENABLE_WS="true"

    prompt_mem_limit "mosquitto" "128m"

    cat > "$INSTALL_DIR/.env" <<EOF
MOSQUITTO_VERSION=$MOSQUITTO_TAG
MQTT_PORT=$MQTT_PORT_VALUE
MQTT_USER=$MQTT_USER
ENABLE_WEBSOCKETS=$ENABLE_WS
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Mosquitto secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): port=$MQTT_PORT_VALUE"
        echo "  MQTT username: $MQTT_USER"
        echo "  MQTT password: $MQTT_PASSWORD"
        echo
        echo "  The broker stores only a hash of this password, so it cannot be"
        echo "  recovered from the container — this file is the only copy."
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"

    # Written by a throwaway container running as root, then chowned to 1883
    # — the uid mosquitto drops to. Generated as the host user instead, the
    # broker cannot read it; made world-readable to work around that,
    # Mosquitto logs a deprecation warning and future versions will refuse
    # to load it outright.
    print_info "Generating the MQTT password file..."
    docker run --rm -v "$INSTALL_DIR/config":/mosquitto/config \
        "eclipse-mosquitto:$MOSQUITTO_TAG" \
        sh -c "mosquitto_passwd -b -c /mosquitto/config/passwd '$MQTT_USER' '$MQTT_PASSWORD' \
               && chown 1883:1883 /mosquitto/config/passwd \
               && chmod 0600 /mosquitto/config/passwd" \
        || print_error "Failed to create the password file. Check that Docker can pull eclipse-mosquitto:$MOSQUITTO_TAG."

    print_info "Generated .env and saved a copy of the secrets to $SECRETS_FILE."
fi

ENV_ENABLE_WS=$(read_env_value "ENABLE_WEBSOCKETS" "$INSTALL_DIR/.env")
ENV_MQTT_PORT=$(read_env_value "MQTT_PORT" "$INSTALL_DIR/.env")
ENV_MQTT_USER=$(read_env_value "MQTT_USER" "$INSTALL_DIR/.env")
ENV_MEM_LIMIT=$(read_env_value "MEM_LIMIT" "$INSTALL_DIR/.env")

# mosquitto.conf is fully owned by this script — it is regenerated on every
# run from whatever .env currently says, so hand edits here are lost. Add a
# second config file to the config directory instead; Mosquitto reads them
# all (see the README).
{
    echo "# Generated by DockHub's deploy.sh — regenerated on every run."
    echo "# Do NOT hand-edit. Put your own directives in a separate .conf file"
    echo "# in this same directory; Mosquitto loads every .conf it finds here."
    echo
    echo "# Without an explicit listener, Mosquitto 2.x binds to localhost only"
    echo "# and every remote client gets 'connection refused'."
    echo "listener 1883"
    echo "protocol mqtt"
    echo
    if [[ "$ENV_ENABLE_WS" == "true" ]]; then
        echo "listener 9001"
        echo "protocol websockets"
        echo
    fi
    echo "# No anonymous access. MQTT has no per-topic permissions by default,"
    echo "# so an anonymous broker lets anyone who reaches the port read every"
    echo "# topic and publish to every topic."
    echo "allow_anonymous false"
    echo "password_file /mosquitto/config/passwd"
    echo
    echo "# Survive a restart with retained messages and subscriptions intact."
    echo "persistence true"
    echo "persistence_location /mosquitto/data/"
    echo
    echo "# To stdout, so 'docker compose logs' works instead of the log"
    echo "# living in a volume nobody looks at."
    echo "log_dest stdout"
} > "$INSTALL_DIR/config/mosquitto.conf"

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from whatever .env currently has.
if [[ -n "$ENV_MEM_LIMIT" || "$ENV_ENABLE_WS" == "true" ]]; then
    {
        echo "services:"
        echo "  mosquitto:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ "$ENV_ENABLE_WS" == "true" ]]; then
            # The base compose file's 1883 mapping is repeated here: an
            # override's `ports` list replaces the base one wholesale for
            # this service rather than merging into it, so leaving it out
            # would silently unpublish MQTT itself.
            echo "    ports:"
            echo "      - \"$ENV_MQTT_PORT:1883\""
            echo "      - \"9001:9001\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'mosquitto' container."
    [[ "$ENV_ENABLE_WS" == "true" ]] && print_info "WebSocket listener enabled on port 9001."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Mosquitto..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Mosquitto. Check log: $LOGFILE"

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"

# ── Self-test ───────────────────────────────────────────────────────────
# "Container Started" says nothing about whether the broker accepts
# connections: a bad passwd file, a listener bound to the wrong interface or
# a config typo all leave a running container that refuses every client.
# MQTT has no web page to open, so there's no casual way to notice — hence
# an actual publish/subscribe round trip here.
#
# Uses a RETAINED message (-r) rather than a backgrounded subscriber: the
# broker holds the last retained message per topic and hands it to any new
# subscriber immediately, which turns this into two sequential commands with
# no race and no background job to clean up. The final publish with -n sends
# an empty payload, which is how MQTT clears retention — without it the test
# message would sit in the broker forever.
mqtt_selftest() {
    local pass topic="dockhub/selftest" out
    pass=$(awk -F': ' '/MQTT password:/{print $2; exit}' "$SECRETS_FILE" 2>/dev/null || true)
    [[ -n "$pass" ]] || return 1

    # The container is up but mosquitto may still be binding its listener.
    local waited=0
    while (( waited < 15 )); do
        docker exec mosquitto mosquitto_pub -h localhost -u "$ENV_MQTT_USER" -P "$pass" \
            -t "$topic" -m "dockhub-ok" -r >/dev/null 2>&1 && break
        sleep 1
        waited=$(( waited + 1 ))
    done
    (( waited < 15 )) || return 1

    out=$(docker exec mosquitto mosquitto_sub -h localhost -u "$ENV_MQTT_USER" -P "$pass" \
        -t "$topic" -C 1 -W 5 2>/dev/null || true)
    docker exec mosquitto mosquitto_pub -h localhost -u "$ENV_MQTT_USER" -P "$pass" \
        -t "$topic" -n -r >/dev/null 2>&1 || true

    [[ "$out" == "dockhub-ok" ]]
}

if mqtt_selftest; then
    SELFTEST_RESULT="✅ Self-test passed — published and received a message over MQTT."
else
    SELFTEST_RESULT="⚠️  Self-test did NOT pass. The container is running, but a publish/subscribe round trip failed — see below."
fi

print_info "Mosquitto is running."
echo
echo "──────────────────────────────────────────────"
echo "🔌 MQTT:         $SERVER_IP:$ENV_MQTT_PORT  (from other containers: mosquitto:1883)"
[[ "$ENV_ENABLE_WS" == "true" ]] && echo "🔌 WebSockets:   $SERVER_IP:9001"
echo "👤 Username:     $ENV_MQTT_USER  (password in the secrets file below)"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
echo "$SELFTEST_RESULT"
echo
if [[ "$SELFTEST_RESULT" != ✅* ]]; then
    echo "   Check the broker's own log first — it names the reason:"
    echo "     cd $INSTALL_DIR && $COMPOSE_CMD logs --tail=30 mosquitto"
    echo "   To repeat the test by hand:"
    echo "     P=\$(awk -F': ' '/MQTT password:/{print \$2; exit}' $SECRETS_FILE)"
    echo "     docker exec mosquitto mosquitto_pub -h localhost -u $ENV_MQTT_USER -P \"\$P\" -t t -m hi -r"
    echo "     docker exec mosquitto mosquitto_sub -h localhost -u $ENV_MQTT_USER -P \"\$P\" -t t -C 1 -W 5"
    echo
fi
echo "📌 There is no web interface — MQTT is a protocol, not a website, so"
echo "   there's nothing to point NGINX Proxy Manager at. Point your clients"
echo "   (Home Assistant, ESP devices, sensors) straight at the port above."
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

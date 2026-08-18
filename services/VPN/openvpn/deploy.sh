#!/bin/bash
# deploy.sh (services/VPN/openvpn)
# Purpose: Deploy OpenVPN Access Server — see docker-compose.yml for why this
# repo builds "OpenVPN" as Access Server specifically, the 2-concurrent-
# connection limit that comes with it, and the deliberate deviations from
# upstream's own docker-compose example.
#
# This is a single-instance service: one Access Server deployment per host,
# under ~/docker/openvpn/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy OpenVPN Access Server behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/openvpn"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.openvpn-docker-secrets.txt"

# Shared helpers — sourced from a git checkout if present, self-fetched
# otherwise so standalone curl usage still works with no extra steps.
LIB_COMMON="$SOURCE_DIR/../../../lib/common.sh"
if [[ ! -f "$LIB_COMMON" ]]; then
    LIB_COMMON="$(mktemp -d)/common.sh"
    curl -fsSL -o "$LIB_COMMON" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_COMMON"

# sacli is Access Server's configuration CLI, and the only way to set most of
# what this script needs — the image exposes no environment variables for the
# admin password, the client-facing hostname, or the daemon ports.
SACLI="/usr/local/openvpn_as/scripts/sacli"

check_prerequisites

# /dev/net/tun must exist on the host — the container gets the device passed
# through, it can't conjure one. Missing on some minimal/virtualised kernels.
if [[ ! -e /dev/net/tun ]]; then
    print_warn "/dev/net/tun does not exist on this host. Trying to load the 'tun' module..."
    sudo modprobe tun 2>/dev/null || true
    [[ -e /dev/net/tun ]] || print_error "/dev/net/tun is still missing. OpenVPN cannot run without it — on most systems 'sudo modprobe tun' fixes this; on some VPS types (OpenVZ, some LXC) the provider must enable TUN/TAP for your container."
fi

mkdir -p "$INSTALL_DIR"

ensure_main_net

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    # Stated before any question is asked — this is the one thing about
    # Access Server that most surprises people, and it's better to find out
    # now than after wiring up DNS and a port-forward.
    print_warn "OpenVPN Access Server allows 2 CONCURRENT connections without a license."
    print_warn "That's 2 simultaneous tunnels, not 2 accounts — you can create as many"
    print_warn "users as you like, but the 3rd device connecting at once is refused."
    print_warn "It never expires. Need more? WireGuard and NetBird in this repo are"
    print_warn "unlimited, or buy an Access Server license."
    echo

    # The address VPN clients actually dial over UDP. Like WireGuard's
    # INIT_HOST and unlike every other service's domain question, this is
    # never optional — VPN traffic can't go through NPM (raw UDP, not
    # HTTP), so there is always a real endpoint to name. It's also baked
    # into every client profile Access Server generates.
    # Re-asks rather than aborting the whole deploy on a stray Enter. Note
    # this deliberately does NOT use prompt_domain: that runs validate_domain,
    # which rejects colons (it reads them as a port), and a bare IPv6 endpoint
    # is a legitimate answer here. Emptiness is the only thing checked.
    while true; do
        read -rp "Enter the public IP or domain your VPN clients will connect to (e.g. vpn.example.com or your server's public IP): " VPN_HOST_VALUE
        [[ -n "$VPN_HOST_VALUE" ]] && break
        print_warn "A public IP or domain is required — this is the actual VPN endpoint clients connect to, and it's written into every client profile."
    done

    ADMIN_PASSWORD=$(generate_secret)
    prompt_mem_limit "openvpn-as" "1g"
    # 9443, not Access Server's own 943: valid_port() in lib/common.sh only
    # accepts 1024-65535, so suggesting 943 would offer a default it then
    # rejects, looping forever. Only the HOST side moves — the container
    # still serves on 943, and nothing but a human ever types this port
    # (client profiles carry the VPN port, never the web UI's).
    prompt_host_port "9443"

    # Access Server's default OpenVPN-over-TCP port is 443, which NGINX
    # Proxy Manager already owns in this repo. So TCP is off unless asked
    # for, and then never on 443. Its purpose is clients on networks that
    # block UDP — TCP-over-TCP is slower, so it's a fallback, not a default.
    TCP_PORT=""
    read -rp "Also enable an OpenVPN-over-TCP fallback, for clients on networks that block UDP? (y/N): " tcp_answer
    if [[ "${tcp_answer,,}" == "y" ]]; then
        while true; do
            read -rp "TCP port (default: 8443 — NOT 443, NGINX Proxy Manager uses that): " tcp_port_input
            tcp_port_input="${tcp_port_input:-8443}"
            if ! valid_port "$tcp_port_input"; then
                echo "Invalid port — must be a number between 1024 and 65535." >&2
                continue
            fi
            if [[ "$tcp_port_input" == "443" ]]; then
                echo "Port 443 belongs to NGINX Proxy Manager — pick another." >&2
                continue
            fi
            if port_in_use "$tcp_port_input"; then
                read -rp "Port $tcp_port_input looks already in use — continue anyway? (y/N): " cont
                [[ "${cont,,}" == "y" ]] || continue
            fi
            TCP_PORT="$tcp_port_input"
            break
        done
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
OPENVPN_AS_VERSION=latest
VPN_HOST=$VPN_HOST_VALUE
ADMIN_USERNAME=openvpn
ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    [[ -n "$TCP_PORT" ]] && echo "TCP_PORT=$TCP_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated OpenVPN Access Server secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): vpn endpoint=$VPN_HOST_VALUE"
        echo "  Admin UI username: openvpn"
        echo "  Admin UI password: $ADMIN_PASSWORD"
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved a copy of the secrets to $SECRETS_FILE."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from whatever .env currently has.
# Note: HOST_PORT here maps to the web UI (943) — the VPN data port
# (1194/udp) is unconditional and already in the base compose file.
ENV_MEM_LIMIT=$(read_env_value "MEM_LIMIT" "$INSTALL_DIR/.env")
ENV_HOST_PORT=$(read_env_value "HOST_PORT" "$INSTALL_DIR/.env")
ENV_TCP_PORT=$(read_env_value "TCP_PORT" "$INSTALL_DIR/.env")
ENV_VPN_HOST=$(read_env_value "VPN_HOST" "$INSTALL_DIR/.env")
ENV_ADMIN_PASSWORD=$(read_env_value "ADMIN_PASSWORD" "$INSTALL_DIR/.env")

if [[ -n "$ENV_MEM_LIMIT" || -n "$ENV_HOST_PORT" || -n "$ENV_TCP_PORT" ]]; then
    {
        echo "services:"
        echo "  openvpn-as:"
        [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
        if [[ -n "$ENV_HOST_PORT" || -n "$ENV_TCP_PORT" ]]; then
            echo "    ports:"
            # The base compose file's 1194/udp is repeated here: an override's
            # 'ports' list replaces the base one wholesale for this service
            # rather than merging into it, so leaving it out would silently
            # unpublish the VPN itself.
            echo "      - \"1194:1194/udp\""
            [[ -n "$ENV_HOST_PORT" ]] && echo "      - \"$ENV_HOST_PORT:943/tcp\""
            # Published 1:1 on purpose — the port number is written into every
            # client profile Access Server generates, so a remapped host port
            # would hand clients an address that doesn't answer.
            [[ -n "$ENV_TCP_PORT" ]] && echo "      - \"$ENV_TCP_PORT:$ENV_TCP_PORT/tcp\""
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
    [[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'openvpn-as' container."
    [[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct web-UI access."
    [[ -n "$ENV_TCP_PORT" ]] && print_info "TCP fallback port $ENV_TCP_PORT published."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting OpenVPN Access Server (first run generates a PKI and can take a couple of minutes)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start OpenVPN Access Server. Check log: $LOGFILE"

# Access Server isn't configurable until its own service is up — on a first
# run that means waiting for the PKI to be generated. Poll sacli rather than
# sleeping a fixed amount, which would be either too short or wasteful.
print_info "Waiting for Access Server to finish initialising..."
AS_READY=0
for _ in $(seq 1 60); do
    if docker exec openvpn-as "$SACLI" ConfigQuery >/dev/null 2>&1; then
        AS_READY=1
        break
    fi
    sleep 3
done

if (( ! AS_READY )); then
    print_warn "Access Server did not become ready within 3 minutes."
    print_warn "The container is running but hasn't been configured yet. Check:"
    print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f openvpn-as"
    print_warn "Then rerun this script to finish configuration."
    exit 1
fi

# ── Post-start configuration ────────────────────────────────────────────
# Everything below is idempotent: rerunning deploy.sh re-applies the same
# values, which is also how you change them (edit .env, rerun).
# Warns rather than aborting on failure: `set -e` would otherwise kill the
# script on a bare `docker exec` failure with no explanation at all, and a
# key Access Server renames in some future version shouldn't leave a
# half-configured deployment behind with no message.
as_config() {
    docker exec openvpn-as "$SACLI" --key "$1" --value "$2" ConfigPut >/dev/null \
        || print_warn "Failed to set Access Server option '$1' = '$2'."
}

# The address written into every client profile. Without this, Access Server
# guesses from the container's own IP — which is a private docker-network
# address, so every downloaded profile would point at something unreachable.
as_config "host.name" "$ENV_VPN_HOST"

# Pin to exactly one UDP daemon on 1194. Access Server defaults to one daemon
# per CPU core, and multi-daemon mode puts each on a CONSECUTIVE port —
# 1194, 1195, 1196... on a 4-core box. Only 1194 is published, so the extra
# daemons would be unreachable, and profiles handed to clients could name a
# port that never answers. One daemon keeps what's published and what's
# advertised identical.
as_config "vpn.server.daemon.udp.n_daemons" "1"
as_config "vpn.server.daemon.udp.port" "1194"

if [[ -n "$ENV_TCP_PORT" ]]; then
    as_config "vpn.server.daemon.tcp.n_daemons" "1"
    as_config "vpn.server.daemon.tcp.port" "$ENV_TCP_PORT"
else
    # No TCP daemon at all: its default port is 443, which NGINX Proxy
    # Manager owns.
    as_config "vpn.server.daemon.tcp.n_daemons" "0"
fi

# Off in BOTH cases, deliberately. Port sharing makes the OpenVPN TCP port
# serve the web UI too, for any connection that isn't the OpenVPN protocol.
# That's a sensible default upstream, where the TCP port IS 443 and there is
# no separate reverse proxy — but here it republishes the admin panel on the
# TCP fallback port, straight to the host, bypassing NPM and its Let's
# Encrypt certificate. Visiting that port then shows a browser security
# warning (Access Server's own self-signed cert), which reads as a broken
# deployment and isn't: it's a second, unintended door to the admin panel.
# The web UI has exactly one route here — NPM to port 943.
as_config "vpn.server.port_share.enable" "false"

# Replaces the password Access Server auto-generates and prints to its log on
# first boot. Setting it here instead keeps this service consistent with
# every other one in this repo: credentials come from deploy.sh and land in
# the secrets file, rather than the user having to grep container logs.
docker exec openvpn-as "$SACLI" --user "openvpn" --new_pass "$ENV_ADMIN_PASSWORD" SetLocalPassword >/dev/null \
    || print_warn "Could not set the admin password automatically. Find the auto-generated one with: docker logs openvpn-as | grep -i 'auto-generated pass'"

# Applies every ConfigPut above — they only take effect on a service restart.
docker exec openvpn-as "$SACLI" start >/dev/null \
    || print_warn "Access Server did not reload cleanly — check: $COMPOSE_CMD logs openvpn-as"

print_info "Access Server configured."
echo
echo "──────────────────────────────────────────────"
echo "🔌 VPN endpoint:  $ENV_VPN_HOST:1194/udp  ← for the OpenVPN client app"
[[ -n "$ENV_TCP_PORT" ]] && echo "🔌 TCP fallback:  $ENV_VPN_HOST:$ENV_TCP_PORT/tcp   ← also the client app, NOT a web address"
echo "🌐 Web UI:        https://<your-NPM-domain>/       (admin panel: /admin)"
if [[ -n "$ENV_HOST_PORT" ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
    echo "🌐 Web UI direct: https://$SERVER_IP:$ENV_HOST_PORT/  (self-signed cert — browser warning is expected here)"
fi
echo "🔗 Proxy target:  openvpn-as:943 on 'main-net' — scheme MUST be https"
echo "👤 Admin login:   username 'openvpn' + the generated password below"
echo "📜 Log:           $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:       $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
echo "⚠️  2 concurrent connections without a license — see the README."
echo
echo "Set up NGINX Proxy Manager for the web UI:"
echo "   1. Forward to  openvpn-as : 943"
echo "   2. Set 'Scheme' to https  ← not http; Access Server serves TLS itself"
echo "   3. Enable SSL with Let's Encrypt"
echo
echo "🔥 Forward $ENV_VPN_HOST:1194/udp to this server at your router."
echo "   The VPN tunnel bypasses NPM entirely — a Proxy Host does not carry it,"
echo "   and neither does Cloudflare Tunnel (raw UDP)."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

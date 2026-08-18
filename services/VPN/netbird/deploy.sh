#!/bin/bash
# deploy.sh (services/VPN/netbird)
# Purpose: Deploy NetBird (dashboard + combined server) — see
# docker-compose.yml for why this reproduces upstream's "Nginx Proxy
# Manager" setup path statically instead of running their interactive
# getting-started.sh.
#
# Unlike most services here, this generates THREE files into the install
# dir: .env (for Compose), config.yaml (server settings), and dashboard.env
# (web UI settings). The latter two are rewritten from .env on every run, so
# changing the domain means editing .env and rerunning this script.
#
# This is a single-instance service: one NetBird deployment per host, under
# ~/docker/netbird/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy NetBird behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/netbird"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.netbird-docker-secrets.txt"

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

# STUN is never optional and can't be proxied — check it up front with a
# specific message rather than letting Compose fail with a generic "port is
# already allocated". Same treatment as Pi-hole's port 53.
if port_in_use 3478; then
    print_warn "Port 3478/udp (STUN) looks already in use. NetBird needs it for NAT traversal and cannot start without it."
    read -rp "Continue deploying anyway? (y/N): " continue_anyway
    [[ "${continue_anyway,,}" == "y" ]] || print_error "Aborted — free up port 3478 first, then rerun deploy.sh."
fi

mkdir -p "$INSTALL_DIR"

ensure_main_net

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    # NOTE: no host-port option here, deliberately — same reasoning as this
    # repo's Vaultwarden. NetBird builds OAuth redirect URIs, the gRPC
    # endpoint peers dial, and the dashboard's API endpoint from the domain,
    # so reaching it at http://<ip>:<port> would break the login flow
    # outright. The domain is always required.
    # Validated, not just checked for emptiness: this value ends up in OAuth
    # redirect URIs and the gRPC endpoint, where a stray character produces a
    # deployment that starts fine and then fails login with "Unauthenticated".
    # prompt_domain re-asks instead of aborting the whole deploy — see
    # lib/common.sh.
    prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. netbird.example.com): " "domain"
    NETBIRD_DOMAIN_VALUE="$PROMPTED_DOMAIN"

    prompt_mem_limit "netbird-server" "1g"

    RELAY_AUTH_SECRET=$(openssl rand -base64 32 | tr -d '=')
    DATASTORE_KEY=$(openssl rand -base64 32)
    SESSION_KEY=$(openssl rand -base64 32)

    # NetBird only honours X-Forwarded-* from proxies it trusts. NPM sits on
    # main-net, so trust that subnet — discovered rather than hardcoded,
    # since Docker assigns it. Same class of setting as Jellyfin's "Known
    # proxies" and AdGuard's trusted_proxies.
    TRUSTED_CIDR=$(docker network inspect main-net --format '{{ (index .IPAM.Config 0).Subnet }}' 2>/dev/null || true)
    if [[ -z "$TRUSTED_CIDR" ]]; then
        TRUSTED_CIDR="172.16.0.0/12"
        print_warn "Couldn't read main-net's subnet; defaulting TRUSTED_PROXY_CIDR to $TRUSTED_CIDR. If the dashboard later shows every visitor as the proxy's own IP, set it correctly in .env and rerun."
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
NETBIRD_DASHBOARD_VERSION=latest
NETBIRD_SERVER_VERSION=latest
NETBIRD_DOMAIN=$NETBIRD_DOMAIN_VALUE
NETBIRD_RELAY_AUTH_SECRET=$RELAY_AUTH_SECRET
DATASTORE_ENCRYPTION_KEY=$DATASTORE_KEY
SESSION_COOKIE_ENCRYPTION_KEY=$SESSION_KEY
TRUSTED_PROXY_CIDR=$TRUSTED_CIDR
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated NetBird secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): domain=$NETBIRD_DOMAIN_VALUE"
        echo "  NETBIRD_RELAY_AUTH_SECRET=$RELAY_AUTH_SECRET"
        echo "  DATASTORE_ENCRYPTION_KEY=$DATASTORE_KEY"
        echo "  SESSION_COOKIE_ENCRYPTION_KEY=$SESSION_KEY"
        echo
        echo "# NetBird has no admin password: the first person to sign up on"
        echo "# the dashboard becomes the admin, via its built-in Dex identity"
        echo "# provider. These are server-side keys, not login credentials."
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved a copy of the secrets to $SECRETS_FILE."
fi

# Read back from .env so a rerun after hand-editing the domain regenerates
# config.yaml/dashboard.env to match. read_env_value (lib/common.sh) is
# binary-safe — a plain `grep | cut` here once handed back the literal string
# "Binary file ... matches" as the domain, producing OAuth URLs that failed
# with "Unauthenticated" on a deploy that otherwise looked successful.
ENV_DOMAIN=$(read_env_value NETBIRD_DOMAIN "$INSTALL_DIR/.env")
ENV_RELAY_SECRET=$(read_env_value NETBIRD_RELAY_AUTH_SECRET "$INSTALL_DIR/.env")
ENV_DATASTORE_KEY=$(read_env_value DATASTORE_ENCRYPTION_KEY "$INSTALL_DIR/.env")
ENV_SESSION_KEY=$(read_env_value SESSION_COOKIE_ENCRYPTION_KEY "$INSTALL_DIR/.env")
ENV_TRUSTED_CIDR=$(read_env_value TRUSTED_PROXY_CIDR "$INSTALL_DIR/.env")

# Belt and braces: if the domain still came back empty or malformed for any
# reason, stop here rather than writing config files that would deploy
# cleanly and then fail authentication with no obvious cause.
validate_domain "$ENV_DOMAIN" "NETBIRD_DOMAIN in $INSTALL_DIR/.env"

# config.yaml + dashboard.env are fully owned by this script (never
# hand-edit them — edit .env and rerun). Reproduced from upstream's
# render_combined_yaml() / render_dashboard_env().
cat > "$INSTALL_DIR/config.yaml" <<EOF
# Generated by DockHub's deploy.sh — do not hand-edit.
# Change values in .env and rerun deploy.sh instead.

server:
  listenAddress: ":80"
  exposedAddress: "https://$ENV_DOMAIN:443"
  stunPorts:
    - 3478
  metricsPort: 9090
  healthcheckAddress: ":9000"
  logLevel: "info"
  logFile: "console"

  authSecret: "$ENV_RELAY_SECRET"
  dataDir: "/var/lib/netbird"

  auth:
    issuer: "https://$ENV_DOMAIN/oauth2"
    signKeyRefreshEnabled: true
    sessionCookieEncryptionKey: "$ENV_SESSION_KEY"
    dashboardRedirectURIs:
      - "https://$ENV_DOMAIN/nb-auth"
      - "https://$ENV_DOMAIN/nb-silent-auth"
    cliRedirectURIs:
      - "http://localhost:53000/"

  reverseProxy:
    trustedHTTPProxies:
      - "$ENV_TRUSTED_CIDR"

  store:
    engine: "sqlite"
    encryptionKey: "$ENV_DATASTORE_KEY"
EOF
chmod 600 "$INSTALL_DIR/config.yaml"

cat > "$INSTALL_DIR/dashboard.env" <<EOF
# Generated by DockHub's deploy.sh — do not hand-edit.
# Change values in .env and rerun deploy.sh instead.
NETBIRD_MGMT_API_ENDPOINT=https://$ENV_DOMAIN
NETBIRD_MGMT_GRPC_API_ENDPOINT=https://$ENV_DOMAIN
AUTH_AUDIENCE=netbird-dashboard
AUTH_CLIENT_ID=netbird-dashboard
AUTH_CLIENT_SECRET=
AUTH_AUTHORITY=https://$ENV_DOMAIN/oauth2
USE_AUTH0=false
AUTH_SUPPORTED_SCOPES=openid profile email groups
AUTH_REDIRECT_URI=/nb-auth
AUTH_SILENT_REDIRECT_URI=/nb-silent-auth
NGINX_SSL_PORT=443
LETSENCRYPT_DOMAIN=none
EOF
chmod 600 "$INSTALL_DIR/dashboard.env"
print_info "Wrote config.yaml and dashboard.env for domain '$ENV_DOMAIN'."

# The NPM routing block, written to a file rather than printed. It's ~30
# lines that have to be copied verbatim into NPM's UI, and dumping that into
# the terminal buried the handful of things the user actually has to DO.
# From a file they can `cat` it, or scp it, and it's still there tomorrow.
# Quoted heredoc: every $ below is nginx's own variable, not ours.
cat > "$INSTALL_DIR/npm-custom-nginx.conf" <<'NGINXEOF'
# Paste this whole file into NGINX Proxy Manager:
#   Edit Proxy Host → ⚙️ gear icon → "Custom Nginx Configuration" → Save
# (not the "Custom Locations" tab — that's a different feature)
#
# Also required, on the SSL tab: enable "HTTP/2 Support" (gRPC needs it).

client_header_timeout 1d;
client_body_timeout 1d;

# WebSocket (relay, signal, management)
location ~ ^/(relay|ws-proxy/) {
    proxy_pass http://netbird-server:80;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 1d;
}

# Native gRPC (signal + management)
location ~ ^/(signalexchange\.SignalExchange|management\.ManagementService)/ {
    grpc_pass grpc://netbird-server:80;
    grpc_read_timeout 1d;
    grpc_send_timeout 1d;
    grpc_socket_keepalive on;
}

# REST API + OAuth2
location ~ ^/(api|oauth2)/ {
    proxy_pass http://netbird-server:80;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
NGINXEOF

# A one-command check, so verifying doesn't mean retyping a long curl.
cat > "$INSTALL_DIR/verify-npm.sh" <<VERIFYEOF
#!/bin/bash
# Checks whether NPM is routing NetBird's paths correctly.
d="$ENV_DOMAIN"
code=\$(curl -sk -o /dev/null -w '%{http_code} %{content_type}' "https://\$d/oauth2/.well-known/openid-configuration")
echo "GET https://\$d/oauth2/.well-known/openid-configuration"
echo "  -> \$code"
echo
case "\$code" in
  200*json*)
    echo "✅ Routing is correct."
    echo "   If the page still shows 'Unauthenticated', that's stale browser"
    echo "   state — open the site in a PRIVATE window to confirm."
    ;;
  404*)
    echo "❌ /oauth2 is still hitting the dashboard container."
    echo "   The routing block isn't saved in NPM. Paste this file:"
    echo "     $INSTALL_DIR/npm-custom-nginx.conf"
    echo "   into Edit Proxy Host → ⚙️ gear icon → Custom Nginx Configuration."
    ;;
  *)
    echo "⚠️  Unexpected response — check DNS, the tunnel/port-forward, and TLS."
    echo "   See docs/troubleshooting.md."
    ;;
esac
VERIFYEOF
chmod +x "$INSTALL_DIR/verify-npm.sh"

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it). Only a memory cap can land here — there's no host-port option for
# this service (see the comment above the domain prompt).
ENV_MEM_LIMIT=""
grep -qa '^MEM_LIMIT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_MEM_LIMIT=$(grep -a '^MEM_LIMIT=' "$INSTALL_DIR/.env" | cut -d= -f2)

if [[ -n "$ENV_MEM_LIMIT" ]]; then
    {
        echo "services:"
        echo "  netbird-server:"
        echo "    mem_limit: $ENV_MEM_LIMIT"
    } > "$INSTALL_DIR/docker-compose.override.yml"
    print_info "Memory limit $ENV_MEM_LIMIT applied to the 'netbird-server' container (dashboard stays unbounded)."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting NetBird..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start NetBird. Check log: $LOGFILE"

print_info "NetBird is starting."
echo
echo "──────────────────────────────────────────────"
echo "🌐 URL:          https://$ENV_DOMAIN  (once NPM is set up — see below)"
echo "🔗 Proxy target: netbird-dashboard:80 on 'main-net'"
echo "🔌 STUN:         3478/udp  (published on the host — must reach the internet)"
echo "👤 First visit:  sign up on the dashboard — the first account becomes admin"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
echo "⚠️  A plain Proxy Host is NOT enough for NetBird. Three steps in NPM:"
echo "   1. Forward to  netbird-dashboard : 80"
echo "   2. SSL tab   → enable 'HTTP/2 Support'   (gRPC needs it)"
echo "   3. ⚙️ gear icon → 'Custom Nginx Configuration' → paste this file:"
echo "        cat $INSTALL_DIR/npm-custom-nginx.conf"
echo
echo "   Then check it worked:   bash $INSTALL_DIR/verify-npm.sh"
echo
echo "🔌 Port-forward 3478/udp on your router — NAT traversal needs it, and it"
echo "   can't go through NPM or Cloudflare Tunnel."
echo
echo "📖 Why, and what to do if it misbehaves: services/VPN/netbird/README.md"
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

#!/bin/bash
# deploy.sh (services/Storage/owncloud)
# Purpose: Deploy ownCloud Infinite Scale (oCIS) — see docker-compose.yml for
# why this builds Infinite Scale rather than ownCloud Server (Classic), and
# for the self-URL lookup that makes the extra_hosts entry below necessary.
#
# This is a single-instance service: one oCIS deployment per host, under
# ~/docker/owncloud/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy ownCloud Infinite Scale behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/owncloud"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.owncloud-docker-secrets.txt"

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

mkdir -p "$INSTALL_DIR"

ensure_main_net

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    print_info "This deploys ownCloud Infinite Scale (oCIS) — one container, no database."
    print_info "It is not ownCloud Server (Classic); see the README if you expected the PHP one."
    echo

    ADMIN_PASSWORD=$(generate_secret 20)

    prompt_mem_limit "owncloud-ocis" "1g"
    prompt_host_port "9200"

    # OCIS_URL is baked into OIDC issuer discovery, so it must match how the
    # browser reaches oCIS exactly. The two paths also differ in who
    # terminates TLS, which is what PROXY_TLS switches.
    if [[ -n "$HOST_PORT" ]]; then
        SERVER_IP_FOR_URL=$(host_lan_ip || true)
        [[ -z "${SERVER_IP_FOR_URL:-}" ]] && SERVER_IP_FOR_URL="localhost"
        # https, not http, even for a direct port: oCIS's web UI is an OIDC
        # client, and browsers only expose the crypto APIs it needs in a
        # secure context. oCIS serves its own self-signed certificate here,
        # so expect a browser warning — same situation as this repo's
        # OpenVPN admin UI on a direct port.
        OCIS_URL_VALUE="https://$SERVER_IP_FOR_URL:$HOST_PORT"
        PROXY_TLS_VALUE="true"
        OCIS_INSECURE_VALUE="true"
        OCIS_DOMAIN_VALUE=""
        print_info "Using '$OCIS_URL_VALUE' as OCIS_URL, with oCIS's own self-signed certificate."
    else
        prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. cloud.example.com): " "domain"
        OCIS_DOMAIN_VALUE="$PROMPTED_DOMAIN"
        OCIS_URL_VALUE="https://$PROMPTED_DOMAIN"
        PROXY_TLS_VALUE="false"
        OCIS_INSECURE_VALUE="false"
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
OCIS_VERSION=8.1
OCIS_URL=$OCIS_URL_VALUE
OCIS_DOMAIN=$OCIS_DOMAIN_VALUE
PROXY_TLS=$PROXY_TLS_VALUE
OCIS_INSECURE=$OCIS_INSECURE_VALUE
OCIS_LOG_LEVEL=info
OCIS_ADMIN_PASSWORD=$ADMIN_PASSWORD
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated ownCloud Infinite Scale secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): url=$OCIS_URL_VALUE"
        echo "  Login:     admin"
        echo "  Password:  $ADMIN_PASSWORD"
        echo
        echo "  oCIS also generates its own secrets (JWT signing key, machine auth key)"
        echo "  into the ocis-config volume on first start. Those are NOT in this file,"
        echo "  and the data volume is unreadable without them — back up both volumes."
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved a copy of the secrets to $SECRETS_FILE."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

ENV_MEM_LIMIT=$(read_env_value "MEM_LIMIT" "$INSTALL_DIR/.env")
ENV_HOST_PORT=$(read_env_value "HOST_PORT" "$INSTALL_DIR/.env")
ENV_OCIS_URL=$(read_env_value "OCIS_URL" "$INSTALL_DIR/.env")
ENV_OCIS_DOMAIN=$(read_env_value "OCIS_DOMAIN" "$INSTALL_DIR/.env")

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it's always safe to regenerate from whatever .env currently has.
# Guarded rather than written unconditionally: `services:\n  ocis:` with no
# keys under it is `ocis: null`, which Compose rejects outright. In practice
# one of the three is always set (the domain and the host port are mutually
# exclusive but one of them always exists), so this only protects against a
# hand-edited .env — but a deploy that fails on malformed YAML it generated
# itself is a bad way to find that out.
OVERRIDE_BODY=$(
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    if [[ -n "$ENV_HOST_PORT" ]]; then
        echo "    ports:"
        echo "      - \"$ENV_HOST_PORT:9200\""
    fi
    if [[ -n "$ENV_OCIS_DOMAIN" ]]; then
        # THE ONE THAT MATTERS. oCIS verifies every access token by fetching
        # https://<domain>/.well-known/openid-configuration from inside the
        # container. Left to normal DNS that resolves to your PUBLIC address,
        # which a home server behind a router usually cannot reach from the
        # inside — so login fails with "failed to verify access token" while
        # the site itself loads perfectly. Pointing the domain at
        # host-gateway sends that lookup to the Docker host, where NGINX
        # Proxy Manager is listening on 443 and answers with the right
        # certificate for this domain.
        echo "    extra_hosts:"
        echo "      - \"$ENV_OCIS_DOMAIN:host-gateway\""
    fi
    true
)
if [[ -n "$OVERRIDE_BODY" ]]; then
    { echo "services:"; echo "  ocis:"; printf '%s\n' "$OVERRIDE_BODY"; } \
        > "$INSTALL_DIR/docker-compose.override.yml"
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

[[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'owncloud-ocis' container."
[[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
[[ -n "$ENV_OCIS_DOMAIN" ]] && print_info "Mapped $ENV_OCIS_DOMAIN to host-gateway inside the container, so oCIS can reach its own OIDC endpoint."

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting ownCloud Infinite Scale (first run generates its config and secrets)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start oCIS. Check log: $LOGFILE"

print_info "oCIS is starting."
echo
echo "──────────────────────────────────────────────"
echo "🌐 URL:          $ENV_OCIS_URL"
echo "🔗 Proxy target: owncloud-ocis:9200 on 'main-net'"
echo "👤 Login:        admin / the generated password below"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "⚠️  oCIS is serving its OWN self-signed certificate on this port, so"
    echo "   your browser will warn on first visit. That's expected — the web"
    echo "   UI needs https to work at all, so plain http isn't an option."
    echo "   Moving to NPM later: edit .env (OCIS_URL, PROXY_TLS=false,"
    echo "   OCIS_INSECURE=false, OCIS_DOMAIN=...) and rerun deploy.sh."
    echo
fi
echo "Set up NGINX Proxy Manager:"
echo "   1. Forward to  owncloud-ocis : 9200  + enable 'Websockets Support'"
echo "   2. Enable SSL with Let's Encrypt"
echo
echo "🩺 If the page loads but login fails, check this first:"
echo "     cd $INSTALL_DIR && $COMPOSE_CMD logs ocis | grep -i 'verify access token'"
echo "   A hit there means oCIS can't reach its own OIDC endpoint from inside"
echo "   the container — see the README's 'site loads but login fails' section."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

#!/bin/bash
# deploy.sh (services/Security/vaultwarden)
# Purpose: Deploy Vaultwarden (Bitwarden-compatible password manager) — see
# docker-compose.yml for the deliberate deviations from upstream's own
# example, especially why env_file is used instead of ${VAR} substitution.
#
# This is a single-instance service: one Vaultwarden deployment per host,
# under ~/docker/vaultwarden/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Vaultwarden behind the shared 'main-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/vaultwarden"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.vaultwarden-docker-secrets.txt"
VAULTWARDEN_IMAGE="vaultwarden/server:latest"

# Shared helpers — sourced from a git checkout if present, self-fetched
# otherwise so standalone curl usage still works with no extra steps.
LIB_COMMON="$SOURCE_DIR/../../../lib/common.sh"
if [[ ! -f "$LIB_COMMON" ]]; then
    LIB_COMMON="$(mktemp -d)/common.sh"
    curl -fsSL -o "$LIB_COMMON" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_COMMON"

# Turns a plaintext admin password into the Argon2 PHC hash Vaultwarden
# recommends storing instead of the raw token, using the binary's own
# `hash` subcommand inside a throwaway container.
#
# Expect this to fall back on current versions. Upstream's hash subcommand
# reads the password with rpassword::prompt_password(), which opens the
# controlling terminal (/dev/tty) directly rather than reading stdin — so
# piping a password into it cannot work by design, no matter the shell
# plumbing. Automating it would need a pseudo-terminal (expect/script),
# which is fragile enough that a documented manual upgrade path beats it.
# The attempt is kept anyway: it costs one command, and it starts working
# for free if upstream ever adds a non-interactive input path.
#
# The fallback stores the plaintext token, which Vaultwarden still accepts
# — see this service's README for the one-command upgrade to a hash. A
# working deploy with a weaker-at-rest token beats a deploy that dies on an
# upstream CLI quirk (see this repo's WireGuard service, where exactly that
# happened with wg-easy's `wgpw`).
#
# Sets ADMIN_TOKEN_STORED (what goes in .env) and TOKEN_IS_HASHED (1/0).
ADMIN_TOKEN_STORED=""
TOKEN_IS_HASHED=0
hash_admin_token() {
    local plain="$1" out=""
    print_info "Hashing the admin token (pulls the Vaultwarden image if needed)..."
    out=$(printf '%s\n%s\n' "$plain" "$plain" \
        | docker run --rm -i "$VAULTWARDEN_IMAGE" /vaultwarden hash --preset owasp 2>/dev/null \
        | grep -oE '\$argon2id\$[^[:space:]'"'"'"]+' | head -1) || true

    if [[ -n "$out" ]]; then
        ADMIN_TOKEN_STORED="$out"
        TOKEN_IS_HASHED=1
        return 0
    fi

    ADMIN_TOKEN_STORED="$plain"
    TOKEN_IS_HASHED=0
    print_warn "Couldn't produce an Argon2 hash (upstream's 'hash' subcommand may need a TTY in this version). Falling back to a plaintext admin token — still valid, just less protected at rest. To upgrade it later, see this service's README."
    return 0
}

check_prerequisites

mkdir -p "$INSTALL_DIR"

ensure_main_net

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    prompt_mem_limit "vaultwarden" "512m"

    # NOTE: this service deliberately does NOT offer the optional direct
    # host port that every other service here does. Two reasons, both
    # dead ends rather than trade-offs:
    #   1. The Bitwarden web vault encrypts in the browser via the Web
    #      Crypto API (crypto.subtle), which browsers expose only in a
    #      *secure context* — HTTPS, or a localhost/127.0.0.1 address. On
    #      http://<lan-ip>:<port> the vault refuses to load at all, showing
    #      "You are not using a secure context". No server-side setting can
    #      change that; it's the browser's rule.
    #   2. Worse, taking that path would set DOMAIN to http://<ip>:<port>,
    #      and DOMAIN must match the real access URL — so it would then
    #      quietly break the NPM+HTTPS path too, until someone noticed and
    #      edited DOMAIN by hand.
    # So the domain is always asked for, and NPM+SSL is the only supported
    # route. See README.md.
    # Format-checked too, not just non-empty: an invisible character tagging
    # along from a paste silently corrupts every URL built from this.
    # prompt_domain re-asks instead of aborting the whole deploy — see
    # lib/common.sh. (It sets PROMPTED_DOMAIN, deliberately not DOMAIN_VALUE,
    # which this script already uses below for the full https:// URL.)
    prompt_domain "Enter the public domain you'll point NGINX Proxy Manager at (e.g. vault.example.com): " "domain"
    VAULTWARDEN_DOMAIN="$PROMPTED_DOMAIN"
    DOMAIN_VALUE="https://$VAULTWARDEN_DOMAIN"

    ADMIN_PASSWORD=$(generate_secret)
    hash_admin_token "$ADMIN_PASSWORD"

    # Single-quoted on purpose: the Argon2 hash is full of '$' and this file
    # is consumed via env_file (not ${...} substitution) — see
    # docker-compose.yml's header comment.
    cat > "$INSTALL_DIR/.env" <<EOF
VAULTWARDEN_VERSION=latest
DOMAIN=$DOMAIN_VALUE
ADMIN_TOKEN='$ADMIN_TOKEN_STORED'
SIGNUPS_ALLOWED=true
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Vaultwarden secrets - DO NOT SHARE"
        echo "$(date '+%F %T'): domain=$DOMAIN_VALUE"
        echo "  Admin page password: $ADMIN_PASSWORD"
        if (( TOKEN_IS_HASHED )); then
            echo "  (stored in .env as an Argon2 hash — this plaintext is the one you type)"
        else
            echo "  (stored in .env as PLAINTEXT — hashing was unavailable; see README to upgrade)"
        fi
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
# Only a memory cap can land here — there is no host-port option for this
# service (see the comment above the domain prompt for why).
ENV_MEM_LIMIT=""
grep -qa '^MEM_LIMIT=' "$INSTALL_DIR/.env" 2>/dev/null && ENV_MEM_LIMIT=$(grep -a '^MEM_LIMIT=' "$INSTALL_DIR/.env" | cut -d= -f2)

if [[ -n "$ENV_MEM_LIMIT" ]]; then
    {
        echo "services:"
        echo "  vaultwarden:"
        echo "    mem_limit: $ENV_MEM_LIMIT"
    } > "$INSTALL_DIR/docker-compose.override.yml"
    print_info "Memory limit $ENV_MEM_LIMIT applied to the 'vaultwarden' container."
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."
print_info "Starting Vaultwarden..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Vaultwarden. Check log: $LOGFILE"

print_info "Vaultwarden is starting."
echo
echo "──────────────────────────────────────────────"
echo "🌐 URL:          $(grep -a '^DOMAIN=' "$INSTALL_DIR/.env" | cut -d= -f2-)  (once NPM is set up below)"
echo "🔗 Proxy target: vaultwarden-app:80 on 'main-net'"
echo "👤 First visit:  create your own account — Vaultwarden has no default user"
echo "🔐 Admin page:   /admin  (password in the secrets file below)"
echo "📜 Log:          $LOGFILE"
[[ -f "$SECRETS_FILE" ]] && echo "🔒 Secrets:      $SECRETS_FILE"
echo "──────────────────────────────────────────────"
echo
echo "🚨 REQUIRED NEXT STEP — open registration is currently ON so you can"
echo "   create your own account. As soon as you have, close it:"
echo "     sed -i 's/^SIGNUPS_ALLOWED=true/SIGNUPS_ALLOWED=false/' $INSTALL_DIR/.env"
echo "     cd $INSTALL_DIR && $COMPOSE_CMD up -d"
echo "   Leaving it open means anyone who can reach this instance can sign"
echo "   up on your password manager."
echo
echo "Set up NGINX Proxy Manager: forward to vaultwarden-app, port 80,"
echo "enable Websockets Support, enable SSL. HTTPS isn't optional here —"
echo "browser password managers and 2FA/WebAuthn refuse to work without it."
print_tunnel_reminder_if_relevant
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

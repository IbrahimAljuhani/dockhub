#!/bin/bash
# Flowise — deploy/manage. Run with: bash deploy.sh
#
# See docker-compose.yml in this folder for every way this deployment differs
# from upstream's own, and why.

set -euo pipefail

SERVICE_NAME="flowise"
# ── PINNED, and not to `latest` ─────────────────────────────────────────
# The first live deploy used `latest` and crash-looped on startup:
#
#   TypeError: this.db.exec is not a function
#     at new SQLiteStore (connect-sqlite3/lib/connect-sqlite3.js:56)
#     at initializeDBClientAndStore (enterprise/.../SessionPersistance.js:96)
#
# alongside two module-resolution failures (@smithy/eventstream-codec, and
# @langchain/core not exporting ./utils/uuid). Three broken package
# resolutions in one image is a bad build, not a misconfiguration.
#
# Checked against the registry rather than assumed: `3.1.4` and `latest` have
# DIFFERENT digests, and 3.1.4 was pushed FIFTEEN MINUTES AFTER latest — so
# `latest` here is an earlier build than the newest tagged release, not a
# pointer to it. That is exactly the failure mode pinning exists to prevent.
FLOWISE_VERSION_PIN="3.1.4"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$HOME/docker/$SERVICE_NAME"
LOGFILE="$RUNTIME_DIR/deploy.log"
CONTAINER_PORT=3000

LIB_COMMON="$SOURCE_DIR/../../../lib/common.sh"
if [[ ! -f "$LIB_COMMON" ]]; then
    LIB_COMMON="$(mktemp -d)/common.sh"
    curl -fsSL -o "$LIB_COMMON" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_COMMON"

if [[ $EUID -eq 0 ]]; then
    print_error "This script must NOT be run as root. Please run as a regular user in the docker group."
fi

check_prerequisites
ensure_main_net

[[ -f "$SOURCE_DIR/docker-compose.yml" ]] || print_error "docker-compose.yml not found in $SOURCE_DIR."

mkdir -p "$RUNTIME_DIR"

if [[ -f "$RUNTIME_DIR/docker-compose.yml" ]]; then
    print_info "Existing deployment found at $RUNTIME_DIR — its secrets and data are kept."
    # Correct the one value THIS SCRIPT got wrong, and only that one. An
    # existing .env saying `latest` was written by an earlier version of this
    # file, not chosen by the operator, and that image does not start. A
    # version the user pinned themselves is left alone.
    if [[ "$(read_env_value FLOWISE_VERSION "$RUNTIME_DIR/.env")" == "latest" ]]; then
        set_env_value FLOWISE_VERSION "$FLOWISE_VERSION_PIN" "$RUNTIME_DIR/.env"
        print_warn "Moved FLOWISE_VERSION from 'latest' to $FLOWISE_VERSION_PIN — the 'latest'"
        print_warn "tag is an earlier build than the release and crash-loops on startup."
    fi

    # ── SQLite → Postgres, and this one DOES replace the compose file ────
    # Everywhere else in this catalogue an existing docker-compose.yml is
    # left alone, because it may carry edits the operator made. The exception
    # is earned here: a flowise compose with no `flowise-db` service is the
    # SQLite layout, and that layout does not start at all — it dies in
    # SessionPersistance before serving a request. There is no running
    # deployment to protect and no data to migrate, because it never ran.
    #
    # The old file is kept beside the new one rather than deleted, so a
    # deviation made by hand is still recoverable.
    if ! grep -q 'flowise-db' "$RUNTIME_DIR/docker-compose.yml"; then
        cp "$RUNTIME_DIR/docker-compose.yml" "$RUNTIME_DIR/docker-compose.yml.pre-postgres"
        cp "$SOURCE_DIR/docker-compose.yml" "$RUNTIME_DIR/docker-compose.yml"
        print_warn "This deployment used the SQLite layout, which crash-loops in this image"
        print_warn "(connect-sqlite3 has no working sqlite3 under it). Replaced the compose"
        print_warn "file with the Postgres layout; the old one is kept as"
        print_warn "    docker-compose.yml.pre-postgres"
        print_warn "Your .env and data/ are untouched — and nothing is lost, because the"
        print_warn "SQLite deployment never reached the point of storing anything."
    fi

    # An .env written before that change has no database credentials, and an
    # unset POSTGRES_PASSWORD makes Compose substitute an empty string —
    # postgres then refuses to initialise, with an error about the app.
    if [[ -z "$(read_env_value POSTGRES_PASSWORD "$RUNTIME_DIR/.env" || true)" ]]; then
        set_env_value POSTGRES_USER     "flowise"                 "$RUNTIME_DIR/.env"
        set_env_value POSTGRES_PASSWORD "$(generate_secret 32)"   "$RUNTIME_DIR/.env"
        set_env_value POSTGRES_DB       "flowise"                 "$RUNTIME_DIR/.env"
        print_info "Generated database credentials into the existing .env."
    fi
else
    cp "$SOURCE_DIR/docker-compose.yml" "$RUNTIME_DIR/"

    # ── Secrets ──────────────────────────────────────────────────────────
    # FLOWISE_SECRETKEY_OVERWRITE is the important one. It encrypts the
    # credential store — every model-provider API key you paste into a flow.
    # Upstream's .env.example ships it as the literal `myencryptionkey`, so
    # any deployment that copied the example encrypts its secrets with a
    # string published on GitHub.
    #
    # The JWT/session/token secrets are ABSENT from that example entirely.
    # An unset signing secret is not "no auth" — it is auth signed with
    # whatever the application falls back to, which is the same on every
    # install that also left it unset. Set explicitly, they are yours.
    umask 077
    {
        echo "# Generated by deploy.sh — do not commit. Secrets live here only."
        echo "FLOWISE_VERSION=$FLOWISE_VERSION_PIN"
        echo "FLOWISE_SECRETKEY_OVERWRITE=$(generate_secret_hex 32)"
        echo "JWT_AUTH_TOKEN_SECRET=$(generate_secret_hex 32)"
        echo "JWT_REFRESH_TOKEN_SECRET=$(generate_secret_hex 32)"
        echo "EXPRESS_SESSION_SECRET=$(generate_secret_hex 32)"
        echo "TOKEN_HASH_SECRET=$(generate_secret_hex 32)"
        # Postgres, because Flowise's sqlite SESSION store does not start in
        # this image — see docker-compose.yml, note 3. Upstream's example
        # ships DATABASE_PASSWORD=mypassword; this one is generated.
        echo "POSTGRES_USER=flowise"
        echo "POSTGRES_PASSWORD=$(generate_secret 32)"
        echo "POSTGRES_DB=flowise"
    } > "$RUNTIME_DIR/.env"
    chmod 600 "$RUNTIME_DIR/.env"
    umask 022

    # Assert rather than announce: this script must not claim a published
    # default is gone while its own output file still contains one.
    if grep -qE 'myencryptionkey|mypassword' "$RUNTIME_DIR/.env"; then
        print_error "A published upstream default survived generation — bug in deploy.sh."
    fi
    print_info "Generated the credential-store key and all four auth secrets."
fi

# ── The data directory, created before Docker can ────────────────────────
# The image runs as `node`, uid 1000. A bind-mount target that does not exist
# is created by the daemon as ROOT, and Flowise then cannot write its own
# encryption key, uploads or logs — it fails with a permission error that
# names a path inside the container, which is a poor clue to a problem out
# here. (The tables live in Postgres now; these files still do not.)
#
# Outside the first-install branch on purpose, so a deployment made before
# this existed gets corrected on its next run rather than staying broken.
mkdir -p "$RUNTIME_DIR/data"
chmod 700 "$RUNTIME_DIR/data"
if [[ "$(id -u)" != "1000" ]]; then
    print_warn "This image runs as uid 1000 and you are uid $(id -u), so it cannot"
    print_warn "write to $RUNTIME_DIR/data. Fix it once with:"
    print_warn "    sudo chown -R 1000:1000 $RUNTIME_DIR/data"
fi

# ── How it is reached ────────────────────────────────────────────────────
# Flowise builds and runs agent flows whose Custom Tool nodes execute
# JavaScript with filesystem access, so it belongs to the Multi-Agent threat
# model and gets that category's question — asked, not assumed.
ENV_HOST_PORT="$(read_env_value DOCKHUB_HOST_PORT "$RUNTIME_DIR/.env" || true)"
ENV_ON_MAIN_NET="$(read_env_value DOCKHUB_ON_MAIN_NET "$RUNTIME_DIR/.env" || true)"

if [[ ! -f "$RUNTIME_DIR/.dockhub-asked" ]]; then
    prompt_agent_network "Flowise"
    ENV_ON_MAIN_NET="$AGENT_ON_MAIN_NET"
    if (( ENV_ON_MAIN_NET )); then
        prompt_host_port 3200
    else
        print_info "Not on 'main-net', so a host port is the only way to reach it."
        HOST_PORT=""
        while [[ -z "$HOST_PORT" ]]; do
            prompt_host_port 3200
            [[ -n "$HOST_PORT" ]] || print_warn "A port is required in this mode — otherwise nothing can reach Flowise."
        done
    fi
    ENV_HOST_PORT="${HOST_PORT:-}"
    set_env_value DOCKHUB_HOST_PORT   "$ENV_HOST_PORT"   "$RUNTIME_DIR/.env"
    set_env_value DOCKHUB_ON_MAIN_NET "$ENV_ON_MAIN_NET" "$RUNTIME_DIR/.env"
    prompt_mem_limit "flowise" "1g"
    [[ -n "$MEM_LIMIT" ]] && set_env_value DOCKHUB_MEM_LIMIT "$MEM_LIMIT" "$RUNTIME_DIR/.env"
    touch "$RUNTIME_DIR/.dockhub-asked"
fi
[[ -z "$ENV_ON_MAIN_NET" ]] && ENV_ON_MAIN_NET=1
ENV_MEM_LIMIT="$(read_env_value DOCKHUB_MEM_LIMIT "$RUNTIME_DIR/.env" || true)"

# ── Regenerated every run, never hand-edited ─────────────────────────────
# Written whole rather than appended to, and its shape is checked below: the
# equivalent file for Dify was once built by appending a second `services:`
# block, which is a duplicate top-level key that Compose cannot read.
{
    echo "# Generated by deploy.sh on every run — never hand-edit."
    echo "services:"
    echo "  flowise:"
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    if [[ -n "$ENV_HOST_PORT" ]]; then
        echo "    ports:"
        echo "      - \"$ENV_HOST_PORT:$CONTAINER_PORT\""
    fi
    # This file owns the APP's network membership outright — the base compose
    # gives the flowise service no `networks:` key at all, precisely so that
    # these lines REPLACE rather than merge with it.
    echo "    networks:"
    # Always, regardless of the answer: this is the link to its database, not
    # a reachability choice. The base file declares the network; only
    # membership is written here, because membership is what merges.
    echo "      - flowise-db-net"
    if (( ENV_ON_MAIN_NET )); then
        echo "      - main-net"
    else
        # Its own private network, so the container still has one. A service
        # with no network at all lands on the default bridge, back among
        # every other unattached container on the host.
        echo "      - flowise-net"
    fi
    echo "networks:"
    if (( ENV_ON_MAIN_NET )); then
        echo "  main-net:"
        echo "    external: true"
    else
        echo "  flowise-net:"
    fi
} > "$RUNTIME_DIR/docker-compose.override.yml"

_dupes="$(grep -oE '^[a-z_]+:' "$RUNTIME_DIR/docker-compose.override.yml" | sort | uniq -d)"
[[ -z "$_dupes" ]] || print_error "Generated an invalid override (duplicate top-level key: $_dupes). Bug in deploy.sh."
if ! (cd "$RUNTIME_DIR" && $COMPOSE_CMD config -q 2>/tmp/flowise-cfg.err); then
    print_warn "Compose rejected the merged configuration:"
    sed 's/^/    /' /tmp/flowise-cfg.err >&2
    rm -f /tmp/flowise-cfg.err
    print_error "Refusing to continue with a configuration Compose cannot read."
fi
rm -f /tmp/flowise-cfg.err

pull_with_progress "$RUNTIME_DIR"

print_info "Starting $SERVICE_NAME..."
(cd "$RUNTIME_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start $SERVICE_NAME. Check log: $LOGFILE"

# Upstream's own health endpoint, and wget is present because the image is
# Node on Alpine — not assumed: the same probe is in their compose file.
print_info "Waiting for Flowise to answer..."
if wait_for_container_ready "flowise" \
     "wget -q -O /dev/null http://localhost:$CONTAINER_PORT/api/v1/ping" 30 5; then
    print_info "Flowise is answering."
else
    print_warn "Flowise did not answer within 150s. Check:  docker logs -f flowise"
fi

echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "🌐 URL:        http://$(host_lan_ip):$ENV_HOST_PORT"
fi
if (( ENV_ON_MAIN_NET )); then
    echo "🔗 Proxy:      flowise:$CONTAINER_PORT on 'main-net'"
else
    echo "🔒 Networks:   flowise-net only — deliberately NOT on 'main-net'"
fi
echo "👤 First run:  create your own account — Flowise has no default login"
echo "🗄️  Database:   postgres in 'flowise-db' — not reachable from main-net"
echo "📁 Files:      $RUNTIME_DIR/data   (encryption key, uploads, logs)"
echo "🔑 Secrets:    $RUNTIME_DIR/.env   (chmod 600)"
echo "📜 Log:        $LOGFILE"
echo "──────────────────────────────────────────────"
echo
print_warn "Custom Tool nodes run JavaScript, and upstream allows those tools to"
print_warn "require('fs'). Treat a flow you did not write like a script you did"
print_warn "not write. See services/Multi-Agent/README.md."
echo
echo "To manage: cd $RUNTIME_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"
print_tunnel_reminder_if_relevant

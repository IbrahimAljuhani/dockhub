#!/bin/bash
# Dify — deploy/manage. Run with: bash deploy.sh
#
# See docker-compose.override.yml in this folder for why Dify is the one
# service in this catalogue that does not ship a compose file of our own.

set -euo pipefail

SERVICE_NAME="dify"
# Pinned. Upstream's compose hardcodes this same version in its image tags,
# so the tree and the images move together. Bumping this is a deliberate act:
# read their release notes first, then delete ~/docker/dify/docker-compose.yaml
# and rerun to pull the new tree.
DIFY_VERSION="1.16.1"

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$HOME/docker/$SERVICE_NAME"
LOGFILE="$RUNTIME_DIR/deploy.log"

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
# api, worker and plugin_daemon join this unconditionally, so it must exist
# even on a host that has never deployed anything from the AI category.
ensure_models_net

# ── Compose 2.24+ is required, and the reason is specific ───────────────
# docker-compose.override.yml uses the `!override` tag to REPLACE upstream's
# published ports rather than merge with them. Compose merges list values by
# default, so on an older version our empty list would append nothing and
# Dify would still bind host ports 80 and 443 — taking down NGINX Proxy
# Manager and, on a VPS, the host's HTTP with it. Better to refuse than to
# collide.
_cv="$($COMPOSE_CMD version --short 2>/dev/null | tr -d 'v')"
if [[ -n "$_cv" ]]; then
    _maj="${_cv%%.*}"; _rest="${_cv#*.}"; _min="${_rest%%.*}"
    if (( _maj < 2 || (_maj == 2 && _min < 24) )); then
        print_error "Docker Compose $_cv is too old for Dify (needs 2.24+ for the \`!override\` tag).
    Without it this deployment would publish host ports 80 and 443 and collide with NGINX Proxy Manager.
    Update Docker Compose, then rerun."
    fi
fi

mkdir -p "$RUNTIME_DIR"

# ── Upstream's docker/ tree, at the pinned tag ──────────────────────────
# The whole directory, not just the compose file: it mounts ./nginx/*.template,
# ./nginx/conf.d, ./ssrf_proxy/ and ./startupscripts/ by relative path, so the
# compose file on its own does not run.
if [[ -f "$RUNTIME_DIR/docker-compose.yaml" ]]; then
    print_info "Existing deployment found at $RUNTIME_DIR — its .env and data are kept."
else
    print_info "Fetching Dify $DIFY_VERSION from upstream (compose tree, ~1.3 MB)..."
    _tmp="$(mktemp -d)"
    if ! curl -fsSL "https://github.com/langgenius/dify/archive/refs/tags/${DIFY_VERSION}.tar.gz" \
         | tar xz -C "$_tmp" --strip-components=2 "dify-${DIFY_VERSION}/docker" 2>/dev/null; then
        rm -rf "$_tmp"
        print_error "Could not fetch Dify $DIFY_VERSION. Check the tag exists and this host has internet access."
    fi
    [[ -f "$_tmp/docker-compose.yaml" && -f "$_tmp/.env.example" ]] \
        || { rm -rf "$_tmp"; print_error "The fetched tree is missing docker-compose.yaml or .env.example — refusing to continue."; }
    cp -a "$_tmp/." "$RUNTIME_DIR/"
    rm -rf "$_tmp"
    print_info "Fetched into $RUNTIME_DIR."

    # ── The .env, built from THEIR example with OUR secrets ─────────────
    # Their .env.example ships working defaults for every credential:
    #   DB_PASSWORD=difyai123456   REDIS_PASSWORD=difyai123456
    #   SANDBOX_API_KEY=dify-sandbox
    #   PLUGIN_DAEMON_KEY=lYkiYYT6owG+...   (a real key, published on GitHub)
    #   PLUGIN_DIFY_INNER_API_KEY=QaHbTe77Ctu...
    # Anyone who copied the example and moved on is running a deployment whose
    # every secret is in a public repository. Generating them is the single
    # most valuable thing this script does.
    cp "$RUNTIME_DIR/.env.example" "$RUNTIME_DIR/.env"

    # ── Secrets that are USED IN PAIRS ───────────────────────────────────
    # Generated into variables first, because several of these appear in more
    # than one key and both ends must match. The first version of this set
    # each key independently and shipped a deployment where:
    #
    #   REDIS_PASSWORD    = <generated>
    #   CELERY_BROKER_URL = redis://:difyai123456@redis:6379/1   ← unchanged
    #
    # — two different passwords for one Redis — and where SANDBOX_API_KEY was
    # regenerated while CODE_EXECUTION_API_KEY, the other end of the same
    # handshake, still said `dify-sandbox`. Found by reading the .env a live
    # deploy produced, not by reading this script.
    # NO `local` here. This is top-level script, not a function body, and
    # `local` outside a function is a RUNTIME error — "can only be used in a
    # function". `bash -n` accepts it happily, which is exactly how it
    # reached a live deploy. ShellCheck catches it as SC2168; CI would have
    # too, had this been pushed before it was run.
    _redis_pw="$(generate_secret 32)"
    _sandbox_key="$(generate_secret_hex 32)"
    _weaviate_key="$(generate_secret_hex 32)"

    umask 077
    # Dify's own docs specify base64 for SECRET_KEY; the rest are ours.
    set_env_value SECRET_KEY                "$(openssl rand -base64 42)" "$RUNTIME_DIR/.env"
    set_env_value INIT_PASSWORD             "$(generate_secret 24)"      "$RUNTIME_DIR/.env"
    set_env_value DB_PASSWORD               "$(generate_secret 32)"      "$RUNTIME_DIR/.env"
    set_env_value PLUGIN_DAEMON_KEY         "$(generate_secret_hex 32)"  "$RUNTIME_DIR/.env"
    set_env_value PLUGIN_DIFY_INNER_API_KEY "$(generate_secret_hex 32)"  "$RUNTIME_DIR/.env"

    # Redis — the password and every URL that embeds it.
    set_env_value REDIS_PASSWORD    "$_redis_pw" "$RUNTIME_DIR/.env"
    set_env_value CELERY_BROKER_URL "redis://:${_redis_pw}@redis:6379/1" "$RUNTIME_DIR/.env"

    # The sandbox handshake — one key, two names, both ends.
    set_env_value SANDBOX_API_KEY        "$_sandbox_key" "$RUNTIME_DIR/.env"
    set_env_value CODE_EXECUTION_API_KEY "$_sandbox_key" "$RUNTIME_DIR/.env"

    # Weaviate ships a published key in three places at once: the client's
    # key, the server's allow-list, and nothing checks they agree except
    # reality. All three get the same generated value.
    set_env_value WEAVIATE_API_KEY                        "$_weaviate_key" "$RUNTIME_DIR/.env"
    set_env_value WEAVIATE_AUTHENTICATION_APIKEY_ALLOWED_KEYS "$_weaviate_key" "$RUNTIME_DIR/.env"

    # Two that upstream's own .env.example tells you to replace, in writing:
    #   "Replace this development default in production."
    # A default that documents its own unsuitability is still a default.
    set_env_value DIFY_AGENT_API_TOKEN        "$(generate_secret_hex 32)" "$RUNTIME_DIR/.env"
    set_env_value DIFY_AGENT_SERVER_SECRET_KEY "$(openssl rand -base64 32)" "$RUNTIME_DIR/.env"

    # ── Two non-secret defaults worth changing, using upstream's own knobs ──
    #
    # Anonymous access to Weaviate. We generate WEAVIATE_API_KEY and write it
    # to both the client and the server's allow-list — and .env.example then
    # sets ANONYMOUS_ACCESS_ENABLED=true, which accepts unauthenticated
    # requests alongside the key, so the key gated nothing. Note upstream's
    # COMPOSE default for this is already `false`; only .env.example flips it.
    # Weaviate holds the knowledge-base index — your documents, embedded.
    #
    # ⚠️ If the knowledge base stops working, Dify's client is not sending the
    # key and this is the cause. Set it back to true and rerun.
    set_env_value WEAVIATE_AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED "false" "$RUNTIME_DIR/.env"
    # Telemetry off, the same call made for Paperclip. Delete the line to
    # restore upstream's behaviour.
    set_env_value WEAVIATE_DISABLE_TELEMETRY "true" "$RUNTIME_DIR/.env"

    chmod 600 "$RUNTIME_DIR/.env"
    umask 022

    # ── Verified, not asserted ───────────────────────────────────────────
    # An earlier version printed "none of upstream's published defaults
    # survive" and it was FALSE — five did. A script must not claim something
    # its own output file contradicts, so the claim is now a check.
    _left=""
    _left="$(grep -nE 'difyai123456|dify-sandbox|WVF5YThaHlkYwhGUSmCRgsX3tD5ngdN8pkih|dify-agent-run-token-for-dev-only|MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY' \
        "$RUNTIME_DIR/.env" || true)"
    if [[ -n "$_left" ]]; then
        print_warn "Upstream default credentials still present in .env — this is a bug in deploy.sh:"
        echo "$_left" | sed 's/^/    /' >&2
        print_error "Refusing to start with published credentials in place."
    fi
    print_info "Generated every credential, and verified no published default survived."
fi

# Our layer, refreshed every run so an edit here reaches existing deployments.
cp "$SOURCE_DIR/docker-compose.override.yml" "$RUNTIME_DIR/"

# ── How Dify is reached, asked the same way its category-mates are ──────
# Dify was originally deployed asking ONE question — the host port — while
# Paperclip, in the same category, asks the main-net security question first.
# That inconsistency was wrong in the more dangerous direction: Dify runs a
# CODE SANDBOX. It executes code a model wrote, on behalf of text the model
# read. The Multi-Agent threat model applies to it more than to Paperclip,
# not less, so it gets the same question with the same reasons named.
ENV_HOST_PORT="$(read_env_value DOCKHUB_HOST_PORT "$RUNTIME_DIR/.env" || true)"
ENV_ON_MAIN_NET="$(read_env_value DOCKHUB_ON_MAIN_NET "$RUNTIME_DIR/.env" || true)"

if [[ ! -f "$RUNTIME_DIR/.dockhub-asked" ]]; then
    # ── One correction to the shared warning, because it does not fit ────
    # prompt_agent_network says "…lets <name> reach every other DockHub
    # service by name, including Portainer and its Docker socket." That is
    # exactly true for Paperclip, whose single container runs the agents AND
    # joins main-net.
    #
    # It is NOT true for Dify, and saying it anyway would be scaring you with
    # someone else's topology. Verified against upstream's compose:
    #
    #   nginx          default + main-net   ← the only one that joins, and it
    #                                         is a reverse proxy, not an agent
    #   api / worker   default + ssrf_proxy_network
    #   sandbox        ssrf_proxy_network ONLY  ← cannot reach `default` at
    #                                             all: no database, no redis,
    #                                             no weaviate, no main-net
    #   local_sandbox  agent_sandbox_network + local_sandbox_proxy_network
    #
    # Nothing that executes model-written code is on main-net, and the code
    # executor cannot even reach Dify's own datastores. Upstream's isolation
    # here is genuinely good and deserves to be said plainly rather than
    # buried under a borrowed warning.
    print_info "Note for Dify specifically: only its nginx joins 'main-net', and"
    print_info "nginx runs no agent code. Its sandbox — the container that actually"
    print_info "executes generated code — is on an isolated network with no route to"
    print_info "'main-net', to Dify's database, or to Redis. The warning below is the"
    print_info "shared one; for Dify the exposure is the web front end, not the sandbox."
    prompt_agent_network "Dify" "models-net"
    ENV_ON_MAIN_NET="$AGENT_ON_MAIN_NET"

    if (( ENV_ON_MAIN_NET )); then
        prompt_host_port 8088
    else
        # No proxy in the path, so a host port is the only way in. Offering
        # to skip it would be offering a deployment nobody can reach.
        print_info "Not on 'main-net', so a host port is the only way to reach it."
        prompt_host_port 8088 required
    fi
    ENV_HOST_PORT="${HOST_PORT:-}"
    set_env_value DOCKHUB_HOST_PORT   "$ENV_HOST_PORT"   "$RUNTIME_DIR/.env"
    set_env_value DOCKHUB_ON_MAIN_NET "$ENV_ON_MAIN_NET" "$RUNTIME_DIR/.env"
    touch "$RUNTIME_DIR/.dockhub-asked"
fi
# Deployments made before this setting existed were always on main-net.
[[ -z "$ENV_ON_MAIN_NET" ]] && ENV_ON_MAIN_NET=1

if (( ! ENV_ON_MAIN_NET )); then
    # Both halves, by marker — the attachment and the external declaration.
    sed -i '/# DOCKHUB:MAINNET$/d' "$RUNTIME_DIR/docker-compose.override.yml"
    sed -i '/# DOCKHUB:MAINNET-BLOCK-START/,/# DOCKHUB:MAINNET-BLOCK-END/d' \
        "$RUNTIME_DIR/docker-compose.override.yml"
fi
if [[ -n "$ENV_HOST_PORT" ]]; then
    # Substituted INTO the existing nginx block, not appended as a new one.
    #
    # The first version of this appended a second `services:` section to the
    # end of the file. That is a DUPLICATE TOP-LEVEL KEY, which YAML does not
    # allow — Compose could not parse the project at all, so `pull` reported
    # nothing to do and the deploy died without ever starting a container.
    # Caught on the first live run. Generating a file is not the same as
    # generating a valid one; the check below is why this cannot recur.
    # Aimed at the DOCKHUB:HOSTPORT marker, not at the bare pattern. There are
    # now two `ports: !override []` lines — nginx's and plugin_daemon's — and
    # an untargeted substitution rewrote BOTH, publishing the plugin debugging
    # daemon on the web port and undoing the fix that had just closed it.
    sed -i "s|ports: !override \[\]   # DOCKHUB:HOSTPORT|ports: !override\n      - \"${ENV_HOST_PORT}:80\"|" \
        "$RUNTIME_DIR/docker-compose.override.yml"
fi

# Whatever happened above, the plugin debugging port stays closed. Asserted
# rather than assumed, because this is a security property that a future edit
# to the substitution above could silently take away.
if grep -qE '^\s+- "[0-9]+:5003"' "$RUNTIME_DIR/docker-compose.override.yml"; then
    print_error "The plugin debugging port would be published — refusing to start.
    This is a bug in deploy.sh: see docker-compose.override.yml, plugin_daemon."
fi

# The override is generated, so it gets verified before anything depends on
# it — one top-level `services:` and one `networks:`, or stop here.
_dupes="$(grep -oE '^[a-z_]+:' "$RUNTIME_DIR/docker-compose.override.yml" | sort | uniq -d)"
[[ -z "$_dupes" ]] || print_error "Generated an invalid override (duplicate top-level key: $_dupes).
    This is a bug in deploy.sh — please report it. Nothing was started."
if ! (cd "$RUNTIME_DIR" && $COMPOSE_CMD config -q 2>/tmp/dify-cfg.err); then
    print_warn "Compose rejected the merged configuration:"
    sed 's/^/    /' /tmp/dify-cfg.err >&2
    rm -f /tmp/dify-cfg.err
    print_error "Refusing to continue with a configuration Compose cannot read."
fi
rm -f /tmp/dify-cfg.err

pull_with_progress "$RUNTIME_DIR"

print_info "Starting $SERVICE_NAME (this brings up ~15 containers)..."
(cd "$RUNTIME_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start $SERVICE_NAME. Check log: $LOGFILE"

# ── Self-test ───────────────────────────────────────────────────────────
# Probed from inside dify-nginx against its own port, so this tests Dify
# rather than the host's networking. A 200 or a redirect both mean the stack
# answered; anything else is reported as it is rather than interpreted.
# Probed from dify-api, not dify-nginx. The first version ran `wget` inside
# nginx:latest — which ships neither wget nor curl, so the probe could never
# succeed and every deployment waited the full 200s before warning about a
# stack that was already up. dify-api is a Python image, so python is there
# by construction. It connects to nginx by service name across the compose
# network, which is the path a browser's request actually takes.
print_info "Waiting for Dify to answer (first boot runs database migrations)..."
if wait_for_container_ready "dify-api" \
     "python -c \"import socket,sys; socket.create_connection(('nginx',80),3); sys.exit(0)\"" \
     40 5; then
    print_info "Dify is answering."
else
    print_warn "Dify did not answer within 200s. First boot migrates the database and can be slow."
    print_warn "Watch it with:  docker logs -f dify-api"
fi

echo
echo "──────────────────────────────────────────────"
if [[ -n "$ENV_HOST_PORT" ]]; then
    echo "🌐 URL:        http://$(host_lan_ip):$ENV_HOST_PORT"
else
    echo "🔗 Proxy:      dify-nginx:80 on 'main-net'  (no host port published)"
fi
echo "👤 First run:  open the URL and set up the admin account"
# Printed in full, unlike every other secret this script generates, and the
# distinction is real: INIT_PASSWORD is spent the moment you use it. It only
# unlocks Dify's /install page to create the first admin, and once that
# account exists the value is worthless — Dify closes the endpoint. You need
# it in a browser within the next minute, so making you `cat` a second file
# for it is friction with no security bought.
#
# The DB password, the Redis password, the plugin keys and the Weaviate key
# are NOT printed, and must not be: those stay live for the deployment's
# whole life.
echo "🔑 Setup pass: $(read_env_value INIT_PASSWORD "$RUNTIME_DIR/.env")"
echo "               one-time — it only unlocks first admin setup, then is spent"
echo "📁 Data:       $RUNTIME_DIR/volumes"
echo "🔒 Secrets:    $RUNTIME_DIR/.env   (all generated, none of upstream's defaults)"
echo "📜 Log:        $LOGFILE"
echo "──────────────────────────────────────────────"
echo
echo "Upstream tree pinned at $DIFY_VERSION. Everything DockHub changed is in"
echo "   $RUNTIME_DIR/docker-compose.override.yml   (readable, ~40 lines)"
echo "To manage: cd $RUNTIME_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"
print_tunnel_reminder_if_relevant

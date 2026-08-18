#!/bin/bash
# Paperclip — deploy/manage. Run with: bash deploy.sh
#
# See docker-compose.yml in this folder for why this service exists now (a
# condition written into services/Multi-Agent/README.md was met on
# 2026-08-18) and why it pulls rather than builds.

set -euo pipefail

SERVICE_NAME="paperclip"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$HOME/docker/$SERVICE_NAME"
LOGFILE="$RUNTIME_DIR/deploy.log"
CONTAINER_PORT=3100

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
# Both are created if missing. main-net is needed even in direct-port mode,
# because the compose file declares it as external — Compose resolves every
# declared network at `up`, whether or not a service attaches to it.
ensure_main_net
ensure_ai_net

[[ -f "$SOURCE_DIR/docker-compose.yml" ]] || print_error "docker-compose.yml not found in $SOURCE_DIR."

mkdir -p "$RUNTIME_DIR"

# ── How Paperclip is reached, asked in exactly one place ────────────────
# Defined as a function because it is needed on TWO paths — first install and
# reconfigure — and two copies of a question drift apart. Sets PUBLIC_URL and
# HOST_PORT.
#
# PAPERCLIP_PUBLIC_URL is not cosmetic. Paperclip builds its login and
# session-cookie redirects from it, so a value that does not match the address
# you actually type produces a login page that bounces you back to itself —
# the failure this repo hit on OpenProject, Nextcloud and n8n independently
# before it became a fixed convention.
ask_reachability() {
    # ── The security question first, and asked OUT LOUD ──────────────────
    # An earlier version of this script inferred main-net from the host-port
    # answer: no port meant NPM, which meant main-net. It produced the right
    # topology and was still wrong, because "do you want a direct port?" is a
    # CONVENIENCE question, and its answer was quietly deciding how far the
    # agents in this container can reach. The operator answered about ports
    # and received a security posture they were never shown.
    #
    # prompt_agent_network is the same question the three AI-Agents services
    # ask, with the same reasons named — Portainer, the socket, an agent
    # acting on text it did not write. Those reasons are identical here
    # because the situation is identical: Paperclip runs its harnesses as
    # processes in this container. Reused rather than re-implemented, so the
    # two categories cannot drift apart.
    prompt_agent_network "Paperclip"
    ON_MAIN_NET="$AGENT_ON_MAIN_NET"

    if (( ON_MAIN_NET )); then
        # NPM can serve it, so a domain is the expected route — but a host
        # port alongside is still allowed for LAN access while DNS settles.
        prompt_domain "Public domain for Paperclip (e.g. agents.example.com): " "domain"
        PUBLIC_URL="https://$PROMPTED_DOMAIN"
        print_info "Public URL set to $PUBLIC_URL — point NGINX Proxy Manager at paperclip-app:$CONTAINER_PORT."
        prompt_host_port "$CONTAINER_PORT"
    else
        # Off main-net there is no proxy, so a host port is the ONLY way in.
        # Asking "do you want one?" here would be offering a deployment
        # nobody can reach.
        print_info "Not on 'main-net', so a host port is the only way to reach it."
        HOST_PORT=""
        while [[ -z "$HOST_PORT" ]]; do
            prompt_host_port "$CONTAINER_PORT"
            [[ -n "$HOST_PORT" ]] || print_warn "A port is required in this mode — otherwise nothing can reach Paperclip."
        done
        local server_ip
        server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
        [[ -n "$server_ip" ]] || server_ip="localhost"
        PUBLIC_URL="http://${server_ip}:${HOST_PORT}"
        print_info "Public URL set to $PUBLIC_URL (direct host port)."
    fi
}

if [[ -f "$RUNTIME_DIR/docker-compose.yml" ]]; then
    print_info "Existing deployment found at $RUNTIME_DIR — its secrets and data are kept."

    # ── Reconfigure, so the first answer is not the permanent one ────────
    # Without this, moving from a direct host port to a domain behind NGINX
    # Proxy Manager means hand-editing .env — and getting PUBLIC_URL wrong
    # does not produce an error, it produces a login page that loops. That is
    # a bad thing to leave to memory and a text editor. Same lesson as the
    # "Reconfigure" option added to install_dockhub.sh, which existed because
    # the only route back to a question was a reset that destroyed the data.
    echo
    echo "  Currently reached at : $(read_env_value PUBLIC_URL "$RUNTIME_DIR/.env")"
    _cur_port="$(read_env_value HOST_PORT "$RUNTIME_DIR/.env")"
    echo "  Direct host port     : ${_cur_port:-none (via NGINX Proxy Manager)}"
    echo
    read -rp "Change how Paperclip is reached? (y/N): " _recfg || _recfg="n"
    if [[ "${_recfg,,}" == "y" ]]; then
        ask_reachability
        # Secrets are deliberately NOT regenerated here. Rewriting
        # BETTER_AUTH_SECRET would log every user out, and rewriting
        # POSTGRES_PASSWORD would lock the app out of its own database —
        # the .env would no longer match the password baked into the volume
        # when Postgres first initialised.
        set_env_value PUBLIC_URL "$PUBLIC_URL" "$RUNTIME_DIR/.env"
        # Emptied rather than deleted: read_env_value returns "" either way,
        # and the override generator below treats empty as "no port", so an
        # empty line switches direct access off without needing a delete.
        set_env_value HOST_PORT "${HOST_PORT:-}" "$RUNTIME_DIR/.env"
        set_env_value ON_MAIN_NET "${ON_MAIN_NET:-0}" "$RUNTIME_DIR/.env"
        print_info "Reconfigured. Secrets and data untouched."
    fi
else
    cp "$SOURCE_DIR/docker-compose.yml" "$RUNTIME_DIR/"

    ask_reachability
    prompt_mem_limit "paperclip" "2g"

    # ── Secrets ──────────────────────────────────────────────────────────
    # BETTER_AUTH_SECRET is marked required upstream with `:?`, i.e. their own
    # compose refuses to start without it. Generated here so it is never a
    # weak default and never the same on two hosts.
    umask 077
    {
        echo "# Generated by deploy.sh — do not commit. Secrets live here only."
        echo "PAPERCLIP_VERSION=latest"
        echo "POSTGRES_USER=paperclip"
        echo "POSTGRES_PASSWORD=$(generate_secret)"
        echo "POSTGRES_DB=paperclip"
        echo "BETTER_AUTH_SECRET=$(generate_secret_hex 32)"
        echo "PUBLIC_URL=$PUBLIC_URL"
        [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT"
        [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT"
        echo "ON_MAIN_NET=${ON_MAIN_NET:-0}"
    } > "$RUNTIME_DIR/.env"
    chmod 600 "$RUNTIME_DIR/.env"
    umask 022

    print_info "Copied service files to $RUNTIME_DIR."
fi

# ── The state directory: ownership first, then mode ─────────────────────
# Outside the install/reconfigure branches, so an EXISTING deployment gets
# corrected on the next run too. The first version of this fix lived in the
# first-install branch and left every deployment already on disk unchanged —
# a fix that reaches nobody who already has the problem.
#
# Why it matters more than it looks: the image sets HOME=/paperclip. So this
# directory is not just Paperclip's own state, it is HOME for every agent CLI
# — /paperclip/.claude, /paperclip/.config/opencode, /paperclip/.codex — which
# means OAuth tokens and API keys. The .env next to it is 600; this holds the
# same class of secret and was being created 0755.
#
# Ownership is checked BEFORE tightening the mode, and that order is the whole
# point. The container runs as uid 1000. If the invoking user is not uid 1000,
# then 0700 owned by someone else locks the container out entirely — turning a
# readable-secrets problem into a service that cannot start. And 0755 does not
# save it either: "other" has no write bit, so a non-1000 host user has ALWAYS
# been broken here. That has simply never been hit, because the first user on
# a Debian/Ubuntu box is uid 1000.
mkdir -p "$RUNTIME_DIR/state"
_HOST_UID="$(id -u)"
if [[ "$_HOST_UID" == "1000" ]]; then
    chmod 700 "$RUNTIME_DIR/state"
else
    print_warn "You are uid $_HOST_UID, but the Paperclip image runs as uid 1000."
    print_warn "The container cannot write to $RUNTIME_DIR/state, and Paperclip will"
    print_warn "fail to save its configuration. Fix it with:"
    print_warn "    sudo chown -R 1000:1000 $RUNTIME_DIR/state && sudo chmod 700 $RUNTIME_DIR/state"
    print_warn "Leaving the mode alone for now — tightening it would only lock you out too."
fi

# ── Regenerated every run, never hand-edited ────────────────────────────
# To change these later: edit MEM_LIMIT=/HOST_PORT= in $RUNTIME_DIR/.env (or
# delete the line), then rerun this script.
ENV_MEM_LIMIT="$(read_env_value MEM_LIMIT "$RUNTIME_DIR/.env" || true)"
ENV_HOST_PORT="$(read_env_value HOST_PORT "$RUNTIME_DIR/.env" || true)"
# Deployments made before this setting existed have no line; they were created
# under the old rule, where "no host port" meant NPM meant main-net. Defaulting
# to that keeps them working exactly as they were until reconfigured.
ENV_ON_MAIN_NET="$(read_env_value ON_MAIN_NET "$RUNTIME_DIR/.env" || true)"
[[ -z "$ENV_ON_MAIN_NET" ]] && { [[ -z "$ENV_HOST_PORT" ]] && ENV_ON_MAIN_NET=1 || ENV_ON_MAIN_NET=0; }

# This file is now always written, because it carries more than the optional
# extras: it decides whether the app joins main-net at all.
{
    echo "# Generated by deploy.sh on every run — never hand-edit."
    echo "services:"
    echo "  paperclip:"
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    if [[ -n "$ENV_HOST_PORT" ]]; then
        echo "    ports:"
        echo "      - \"$ENV_HOST_PORT:$CONTAINER_PORT\""
    fi
    # ── The network decision ────────────────────────────────────────────
    # The full list is written out rather than just the addition, so this is
    # correct whether Compose merges a service's `networks` with the base
    # file's or replaces it. Under merge the duplicates collapse; under
    # replace this list is already complete. Emitting only "main-net" would
    # be right under one rule and would cut the app off from its own database
    # under the other.
    echo "    networks:"
    echo "      - paperclip-net"
    echo "      - ai-net"
    # Keyed off the question that was actually ASKED, not off the port. The
    # two are now independent: a host port is convenience, main-net is reach.
    if (( ENV_ON_MAIN_NET )); then
        echo "      - main-net"
    fi
} > "$RUNTIME_DIR/docker-compose.override.yml"

[[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to paperclip-app (db stays unbounded)."
[[ -n "$ENV_HOST_PORT" ]] && print_info "Host port $ENV_HOST_PORT published for direct access."
if (( ENV_ON_MAIN_NET )); then
    print_warn "On 'main-net' so NGINX Proxy Manager can reach it — which also means the"
    print_warn "agent harnesses in this container can reach everything else on it,"
    print_warn "including portainer:9000 (Docker socket) and NPM's admin interface."
    print_warn "Change both of their default passwords. See services/Multi-Agent/README.md."
else
    print_info "Networks: paperclip-net, ai-net. Deliberately NOT main-net — the agents"
    print_info "in this container cannot reach the other services on it."
fi

pull_with_progress "$RUNTIME_DIR"

print_info "Starting $SERVICE_NAME..."
(cd "$RUNTIME_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start $SERVICE_NAME. Check log: $LOGFILE"

# ── Self-test ───────────────────────────────────────────────────────────
# Probes from INSIDE the container against its own port, so this tests the
# app rather than the host's networking. `wait_for_container_ready` reports a
# crash-loop as a death instead of waiting out the full timeout — the whole
# reason it exists.
#
# The probe is a TCP connect, deliberately not an HTTP path: this deployment
# runs in "authenticated" mode, so every route worth naming answers 401 or
# 302 until you have an account. Treating that as failure would report a
# healthy service as broken, which is the mistake already made once on
# Hermes. What is being asserted here is narrow and true — the server is
# listening. Whether you can log in is the next section's job, and yours.
print_info "Waiting for Paperclip to accept connections..."
if wait_for_container_ready "paperclip-app" \
     "node -e 'require(\"net\").connect($CONTAINER_PORT,\"127.0.0.1\").on(\"connect\",()=>process.exit(0)).on(\"error\",()=>process.exit(1))'" \
     30 5; then
    print_info "Paperclip is listening on $CONTAINER_PORT."
else
    rc=$?
    if (( rc == 1 )); then
        print_warn "paperclip-app stopped while starting up. Its last lines are above."
    else
        print_warn "Paperclip did not answer within 150s. It may still be migrating the database on first boot."
    fi
    print_warn "Check with:  docker logs -f paperclip-app"
fi

# ── The summary ─────────────────────────────────────────────────────────
# Kept short on purpose. An earlier version of this block ran to 92 print
# statements: every finding from every review had added its own paragraph,
# each justified alone, together a wall nobody reads. The same thing was
# fixed once already in NetBird (30 lines to 12).
#
# The rule that decides what stays: THIS SCRIPT REPORTS FACTS ABOUT THIS
# HOST — what is running, what was detected, what was verified. The README
# explains. Anything that would read the same on every machine belongs
# there, not here.
echo
print_info "$SERVICE_NAME is running."
echo
printf '  %-14s %s\n' "Open" "$(read_env_value PUBLIC_URL "$RUNTIME_DIR/.env")   → create the first account"
printf '  %-14s %s\n' "Data" "$RUNTIME_DIR/state"
printf '  %-14s %s\n' "Secrets" "$RUNTIME_DIR/.env"
if (( ENV_ON_MAIN_NET )); then
    printf '  %-14s %s\n' "Networks" "paperclip-net, ai-net, main-net"
    printf '  %-14s %s\n' "NPM target" "paperclip-app:$CONTAINER_PORT"
else
    printf '  %-14s %s\n' "Networks" "paperclip-net, ai-net   (not main-net)"
fi

# ── Connecting an agent: only what is actionable on THIS host ───────────
echo
echo "  Connect an agent — Agent → Configuration → Adapter:"
echo

_HERMES_URL="http://hermes:8642"
_hermes_ok=0
if docker ps --format '{{.Names}}' | grep -qx hermes; then
    # Two separate checks, kept because they answer different questions: is
    # it routable, and is the key accepted. One request proving both cannot
    # say which failed — the lesson from Hermes' own deploy.sh.
    if docker exec paperclip-app node -e "
        const u=new URL('$_HERMES_URL');
        require('net').connect(u.port,u.hostname)
          .on('connect',()=>process.exit(0)).on('error',()=>process.exit(1));
    " >/dev/null 2>&1; then
        _hk="$(read_env_value API_SERVER_KEY "$HOME/docker/hermes/data/.env")"
        [[ -z "$_hk" ]] && _hk="$(read_env_value API_SERVER_KEY "$HOME/docker/hermes/.env")"
        _auth=0
        [[ -n "$_hk" ]] && { docker exec -e HK="$_hk" paperclip-app node -e "
            fetch('$_HERMES_URL/v1/models',{headers:{Authorization:'Bearer '+process.env.HK}})
              .then(r=>process.exit(r.status===200?0:1)).catch(()=>process.exit(1));
        " >/dev/null 2>&1 && _auth=1; }
        _hermes_ok=1
        echo "    Hermes Gateway      $( ((_auth)) && echo 'reachable, key verified' || echo 'reachable — KEY REJECTED, see README' )"
        echo "      API base URL      $_HERMES_URL"
        echo "      API key           $HOME/docker/hermes/data/.env"
        echo "      Paperclip API URL http://paperclip-app:$CONTAINER_PORT"
        echo "      Allow remote HTTP ON"
    else
        print_warn "Hermes is running but unreachable from Paperclip — are both on ai-net?"
    fi
fi

echo "    Cloud key           add to $RUNTIME_DIR/.env, then rerun:"
echo "                        ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY"

detect_ai_provider
[[ -n "$AI_PROVIDER_NAME" ]] && \
    echo "    Local model         $AI_PROVIDER_NAME is on ai-net — use the OpenCode adapter"

if docker ps --format '{{.Names}}' | grep -qx openclaw; then
    echo "    OpenClaw Gateway    running, but the adapter is 'Coming soon' upstream"
fi

echo
echo "  Which adapters work, local models, the plain-HTTP warning:"
echo "      services/Multi-Agent/paperclip/README.md"
print_tunnel_reminder_if_relevant

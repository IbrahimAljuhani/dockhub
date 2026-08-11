#!/bin/bash
# deploy.sh (services/AI-Agents/openclaw)
# Purpose: Deploy OpenClaw — the first AGENT in DockHub. See
# docker-compose.yml for why the Docker socket is absent by default and why
# upstream's setup.sh is not used, and ../README.md for the threat model.
#
# This is a single-instance service, under ~/docker/openclaw/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy OpenClaw on the shared 'ai-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/openclaw"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.openclaw-docker-secrets.txt"

# Shared helpers — sourced from a git checkout if present, self-fetched
# otherwise so standalone curl usage still works with no extra steps.
LIB_DIR="$SOURCE_DIR/../../../lib"
if [[ ! -f "$LIB_DIR/common.sh" ]]; then
    LIB_DIR="$(mktemp -d)"
    curl -fsSL -o "$LIB_DIR/common.sh" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

check_prerequisites

# Agents are alternatives, not companions — and NOT for the providers'
# reason. See ensure_single_agent() in lib/common.sh.
ensure_single_agent "openclaw" || exit 0

mkdir -p "$INSTALL_DIR"

# ai-net always: the model provider is what it actually needs.
ensure_ai_net

# No lib/gpu.sh here, deliberately. An agent never loads a model — the
# provider does. Same reasoning as Open WebUI.

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."

    # Upgrade path. A .env written before the auth gate was known has no
    # token, and reusing it as-is would reproduce the exact failure this
    # release fixes — the deployment would look "already configured" and
    # crash-loop anyway. set_env_value appends when the key is absent.
    if [[ -z "$(read_env_value "OPENCLAW_GATEWAY_TOKEN" "$INSTALL_DIR/.env")" ]]; then
        GATEWAY_TOKEN=$(generate_secret_hex 32)
        set_env_value "OPENCLAW_GATEWAY_TOKEN" "$GATEWAY_TOKEN" "$INSTALL_DIR/.env"
        {
            echo "# Auto-generated OpenClaw secrets - DO NOT SHARE"
            echo "$(date '+%F %T')  (added to an existing deployment)"
            echo
            echo "  Gateway token: $GATEWAY_TOKEN"
        } > "$SECRETS_FILE"
        chmod 600 "$SECRETS_FILE"
        print_info "This deployment had no gateway token — generated one and saved it"
        print_info "to $SECRETS_FILE. The gateway refuses to start without it."
    fi
else
    echo
    print_info "OpenClaw is an AGENT: it acts on what it reads, using tools."
    print_info "That is different from every other service in DockHub, and the"
    print_info "questions below exist because of it. See ../README.md."

    # ── main-net, or not ────────────────────────────────────────────────
    # The one decision with a real security consequence, so it is asked
    # first, before anyone has stopped reading.
    prompt_agent_network "OpenClaw"

    # ── The Docker socket ───────────────────────────────────────────────
    # Optional here, per upstream's own docs: it powers sandbox mode, where
    # agent tools run in their own containers. Off by default. Saying yes
    # trades the category's core rule for isolation of the tools — a real
    # trade, not a free upgrade, so it is spelled out.
    echo
    print_info "OpenClaw can run its tools inside separate containers (sandbox mode)."
    print_warn "That needs the Docker socket. Understand the trade before saying yes:"
    print_warn "  gained — tools run isolated from the gateway itself"
    print_warn "  given  — anything reaching that socket can start a privileged"
    print_warn "           container, which is root-equivalent on this host"
    print_warn "OpenClaw runs fine WITHOUT it. This is not required."
    read -rp "Enable sandbox mode (mounts /var/run/docker.sock)? (y/N): " sandbox_answer
    if [[ "${sandbox_answer,,}" == "y" ]]; then
        OPENCLAW_SANDBOX_VALUE=1
        print_warn "Sandbox enabled. Keep this host behind a firewall."
    else
        OPENCLAW_SANDBOX_VALUE=0
        print_info "No Docker socket. Tools run inside the OpenClaw container."
    fi

    # ── Browser automation ──────────────────────────────────────────────
    # A separate image variant rather than a runtime flag, and a much larger
    # one — Chromium plus Xvfb baked in. Worth asking rather than assuming.
    echo
    print_info "Should OpenClaw be able to drive a browser (page automation)?"
    print_info "That is a different, considerably larger image variant."
    read -rp "Use the browser variant? (y/N): " browser_answer
    if [[ "${browser_answer,,}" == "y" ]]; then
        OPENCLAW_TAG_VALUE="latest-browser"
    else
        OPENCLAW_TAG_VALUE="latest"
    fi

    echo
    prompt_mem_limit "openclaw" "2g"

    # Its own web gateway, on 18789. Unlike the providers this DOES have
    # authentication — a gateway token, which deploy.sh generates because
    # the gateway refuses to listen without one — so a
    # host port is a reasonable default rather than an exposure.
    echo
    print_info "OpenClaw serves its own web interface on 18789, protected by a"
    print_info "gateway token generated below — unlike the AI providers, this one"
    print_info "refuses to listen without authentication."
    prompt_host_port "18789"

    # The gateway refuses to bind 0.0.0.0 without credentials, and inside a
    # container 0.0.0.0 is what it defaults to. So this is not optional
    # hardening — it is what makes the service start at all.
    GATEWAY_TOKEN=$(generate_secret_hex 32)

    cat > "$INSTALL_DIR/.env" <<EOF
OPENCLAW_TAG=$OPENCLAW_TAG_VALUE
OPENCLAW_TZ=$(cat /etc/timezone 2>/dev/null || echo UTC)
OPENCLAW_SANDBOX=$OPENCLAW_SANDBOX_VALUE
AGENT_ON_MAIN_NET=$AGENT_ON_MAIN_NET
OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated OpenClaw secrets - DO NOT SHARE"
        echo "$(date '+%F %T')"
        echo
        echo "  Gateway token: $GATEWAY_TOKEN"
        echo
        echo "  This is what the web interface asks for. It is NOT generated by"
        echo "  onboarding here — the gateway will not start without it, so"
        echo "  deploy.sh sets it up front and hands it to you."
        echo
        echo "  Changing it means changing OPENCLAW_GATEWAY_TOKEN in .env and"
        echo "  restarting; anything already paired must be re-paired."
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved the gateway token to $SECRETS_FILE."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

ENV_MEM_LIMIT=$(read_env_value "MEM_LIMIT" "$INSTALL_DIR/.env")
ENV_HOST_PORT=$(read_env_value "HOST_PORT" "$INSTALL_DIR/.env")
ENV_SANDBOX=$(read_env_value "OPENCLAW_SANDBOX" "$INSTALL_DIR/.env")
ENV_MAIN_NET=$(read_env_value "AGENT_ON_MAIN_NET" "$INSTALL_DIR/.env")
ENV_TAG=$(read_env_value "OPENCLAW_TAG" "$INSTALL_DIR/.env")

# These directories hold messaging tokens and model keys. Created here with
# 700 rather than left to Docker, which would make them root-owned and
# world-readable — for an agent's credential store that is the wrong default.
mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/workspace" "$INSTALL_DIR/auth"
chmod 700 "$INSTALL_DIR/config" "$INSTALL_DIR/auth"

# These are bind mounts, not named volumes, so Docker does NOT fix up their
# ownership — the container writes as whatever uid it runs as. OpenClaw's
# image mounts under /home/node, i.e. the `node` user, which is uid 1000 in
# Node images. On a normal single-user Ubuntu host the first login account is
# also 1000, so the two coincide and mode 700 still lets the container write.
# That coincidence is doing real work, and it is worth saying out loud rather
# than discovering it as an unexplained permission error on a host where the
# deploying account is not 1000.
DEPLOY_UID=$(id -u)
if (( DEPLOY_UID != 1000 )); then
    print_warn "Your user id is $DEPLOY_UID, not 1000. OpenClaw's container runs as"
    print_warn "'node' (uid 1000) and writes into config/ and auth/, which are mode"
    print_warn "700 and owned by you — so it may not be able to write at all."
    print_warn "If the gateway fails with EACCES or a permissions error, widen them:"
    print_warn "  chmod 770 $INSTALL_DIR/config $INSTALL_DIR/auth"
    print_warn "  sudo chgrp 1000 $INSTALL_DIR/config $INSTALL_DIR/auth"
fi

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it is always safe to regenerate from what .env says.
OVERRIDE_BODY=$(
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    if [[ -n "$ENV_HOST_PORT" ]]; then
        echo "    ports:"
        echo "      - \"$ENV_HOST_PORT:18789\""
    fi
    if [[ "$ENV_SANDBOX" == "1" ]]; then
        echo "    environment:"
        echo "      OPENCLAW_SANDBOX: \"1\""
        echo "    volumes:"
        # Compose MERGES volume lists rather than replacing them, unlike
        # ports — so this adds the socket to the three mounts in the base
        # file instead of wiping them out.
        echo "      - /var/run/docker.sock:/var/run/docker.sock"
    fi
    if [[ "$ENV_MAIN_NET" == "1" ]]; then
        echo "    networks:"
        echo "      - ai-net"
        echo "      - main-net"
    fi
    true
)
if [[ -n "$OVERRIDE_BODY" ]]; then
    {
        echo "services:"
        echo "  openclaw:"
        printf '%s\n' "$OVERRIDE_BODY"
        # A network named in a service must also be declared at top level.
        if [[ "$ENV_MAIN_NET" == "1" ]]; then
            echo "networks:"
            echo "  main-net:"
            echo "    external: true"
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

[[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'openclaw' container."
[[ "$ENV_TAG" == "latest-browser" ]] && print_info "Browser variant selected — a larger image, first pull takes longer."
if [[ "$ENV_SANDBOX" == "1" ]]; then
    print_warn "Sandbox mode: /var/run/docker.sock is mounted (root-equivalent on host)."
fi
if [[ "$ENV_MAIN_NET" == "1" ]]; then
    ensure_main_net
    print_warn "On 'main-net' — it can reach every other DockHub service by name."
else
    print_info "On 'ai-net' only — it cannot reach your other services."
fi

# ── Gate 1: write gateway.mode into the config BEFORE first start ───────
# See docker-compose.yml for the full story. Short version: the gateway will
# not start without this setting, there is no environment variable for it
# (OPENCLAW_GATEWAY_MODE is inert — proven twice on a live host), and the
# only thing that writes it is the image's own CLI.
#
# Run unconditionally rather than gated on a config filename: it is
# idempotent ("Updated gateway.mode"), it costs one short container, and it
# does not depend on guessing what the config file is called. `run` neither
# publishes ports nor inherits the restart policy, so it cannot collide with
# the real container.
# Pull explicitly, before the config steps. Those use `compose run`, which
# pulls the image when it is not cached — silently, underneath a message
# about writing a config value. On a fresh host that is the whole download,
# and on the browser variant it is gigabytes: the deploy appears to hang at
# "Setting gateway.mode" with nothing to watch. Every live test so far had
# the image cached from an earlier run, so this never showed.
print_info "Pulling the image (first run downloads it; the browser variant is large)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD pull 2>&1 | tee -a "$LOGFILE") \
    || print_warn "Pull failed here — the steps below will try again."

print_info "Setting gateway.mode=local in the config..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD run --rm --entrypoint openclaw openclaw \
    config set gateway.mode local 2>&1 | tee -a "$LOGFILE") \
    || print_warn "Could not write gateway.mode — the start below will say so."

# ── Gate 3: pin the Control UI origin allow-list ────────────────────────
# The gateway seeds this at startup and says so plainly:
#   "seeded gateway.controlUi.allowedOrigins [...] Applied for this runtime
#    WITHOUT WRITING CONFIG"
# In memory only. A live session proved what that costs: the dashboard
# connected and worked for two and a half minutes, then every request from
# the SAME origin started failing with `origin not allowed` — a config write
# during normal use displaced the un-persisted seed, and no restart brings it
# back, because the file now says otherwise.
#
# So write it rather than inherit it. The origin is whatever the BROWSER
# shows, which for the SSH-tunnel route is localhost on the published port —
# not the container's 18789 and not the server's IP.
if [[ -n "$ENV_HOST_PORT" ]]; then
    UI_ORIGINS="[\"http://localhost:$ENV_HOST_PORT\",\"http://127.0.0.1:$ENV_HOST_PORT\"]"
else
    UI_ORIGINS="[\"http://localhost:18789\",\"http://127.0.0.1:18789\"]"
fi
# No domain is added here: this script never asks for one — main-net is a
# yes/no question, and the domain lives in NGINX Proxy Manager. Anyone
# serving the dashboard over HTTPS has to append their own origin, which the
# README spells out.

# Written ONLY when the config has none — unlike gateway.mode, which is a
# fixed value and safe to reassert every run. This list is something users
# are told to customise: serving the dashboard over HTTPS means adding your
# own domain, and the README says so. Rewriting it on every rerun would
# silently revert that the next time anyone changed a memory limit, and the
# symptom would be `origin not allowed` — the failure that took four rounds
# to diagnose the first time.
OPENCLAW_CONFIG_JSON="$INSTALL_DIR/config/openclaw.json"
if [[ -f "$OPENCLAW_CONFIG_JSON" ]] && grep -q 'allowedOrigins' "$OPENCLAW_CONFIG_JSON"; then
    print_info "Control UI origin allow-list already configured — left untouched."
    print_info "  (see it with: grep -A4 allowedOrigins $OPENCLAW_CONFIG_JSON)"
else
    print_info "Pinning the Control UI origin allow-list..."
    (cd "$INSTALL_DIR" && $COMPOSE_CMD run --rm --entrypoint openclaw openclaw \
        config set gateway.controlUi.allowedOrigins "$UI_ORIGINS" 2>&1 | tee -a "$LOGFILE") \
        || print_warn "Could not write allowedOrigins. If the dashboard later says 'origin not allowed', set it by hand — see the README."
fi

print_info "Starting OpenClaw..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start OpenClaw. Check log: $LOGFILE"

# ── Self-test ───────────────────────────────────────────────────────────
# OpenClaw ships /healthz and /readyz, both unauthenticated — so unlike
# every provider so far, "is it actually up?" has a real answer from the
# first deploy rather than a guess based on the container being 'running'.
print_info "Waiting for the gateway to answer..."
set +e
wait_for_container_ready "openclaw" "curl -fsS http://localhost:18789/readyz" 45 4
WAIT_RC=$?
set -e

if (( WAIT_RC == 1 )); then
    # Match the guidance to what the log actually says. The first live deploy
    # hit exactly one failure, and a generic "check the logs" would have been
    # useless when the container had already printed its own remedy.
    FAILLOG=$(docker logs --tail 30 openclaw 2>&1 || true)
    case "$FAILLOG" in
        *"without auth"*|*"GATEWAY_TOKEN"*|*"GATEWAY_PASSWORD"*)
            echo
            print_warn "The gateway will not bind 0.0.0.0 without credentials — correct of"
            print_warn "it, and deploy.sh generates a token for exactly this reason."
            print_warn "Seeing this means the token did not reach the container. Check that"
            print_warn "OPENCLAW_GATEWAY_TOKEN has a value:"
            echo >&2
            print_warn "  grep OPENCLAW_GATEWAY_TOKEN $INSTALL_DIR/.env"
            print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD config | grep -i token"
            echo >&2
            print_warn "The second command shows what compose actually resolved. If it is"
            print_warn "empty there, .env and docker-compose.yml disagree."
            ;;
        *"Missing config"*|*"gateway.mode"*)
            echo
            print_warn "gateway.mode is still not in the config, so the step above did not"
            print_warn "take effect. Run it by hand and watch what it says:"
            echo >&2
            print_warn "  cd $INSTALL_DIR"
            print_warn "  $COMPOSE_CMD run --rm --entrypoint openclaw openclaw \\"
            print_warn "      config set gateway.mode local"
            print_warn "  $COMPOSE_CMD up -d"
            echo >&2
            print_warn "It should print 'Updated gateway.mode.' — if the entrypoint name is"
            print_warn "wrong for your image the container's own message names two other"
            print_warn "ways out: 'openclaw setup', or the --allow-unconfigured flag."
            ;;
        *"permission denied"*|*"EACCES"*)
            print_warn "A permissions problem on $INSTALL_DIR/config or /auth."
            print_warn "Those are created mode 700 for your user; check ownership."
            ;;
    esac
    print_error "OpenClaw did not start. Full log: cd $INSTALL_DIR && $COMPOSE_CMD logs openclaw"
fi

# ── What to paste into the wizard ───────────────────────────────────────
# The model is configured in OpenClaw's own onboarding, not by environment
# variable, so this prints the address rather than pretending to automate
# it. Upstream's docs say host.docker.internal, which is WRONG here: in
# DockHub the provider is a container on ai-net, reached by name.
detect_ai_provider

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"

echo
echo "──────────────────────────────────────────────"
[[ -n "$ENV_HOST_PORT" ]] && echo "🌐 Gateway:       http://$SERVER_IP:$ENV_HOST_PORT"
echo "🔗 Container:     openclaw:18789"
echo "🕸️  Networks:      $( [[ "$ENV_MAIN_NET" == "1" ]] && echo "ai-net + main-net" || echo "ai-net only" )"
echo "🔌 Docker socket: $( [[ "$ENV_SANDBOX" == "1" ]] && echo "MOUNTED ⚠️" || echo "not mounted ✅" )"
if [[ -n "$AI_PROVIDER_NAME" ]]; then
    echo "🧠 Provider:      $AI_PROVIDER_NAME  ($AI_PROVIDER_BASE_URL)"
else
    echo "🧠 Provider:      none running — deploy one from services/AI/ first"
fi
echo "📁 Workspace:     $INSTALL_DIR/workspace"
echo "🔒 Credentials:   $INSTALL_DIR/config  (mode 700)"
[[ -f "$SECRETS_FILE" ]] && echo "🔑 Gateway token: $SECRETS_FILE"
echo "📜 Log:           $LOGFILE"
echo "──────────────────────────────────────────────"
echo
if (( WAIT_RC == 0 )); then
    print_info "Self-test passed — the gateway answered on /readyz."
else
    print_warn "The gateway did not answer within 3 minutes. Watch it with:"
    print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f openclaw"
fi

# ── The long-form guidance goes to a FILE, not the terminal ─────────────
# OpenClaw needed five separate discoveries to reach a working agent, and
# each one added a paragraph here until the deploy ended in ~60 lines of
# instructions nobody reads to the bottom of. Same fix the rest of DockHub
# already uses for NPM snippets: generate the detail next to the deployment
# and print a short pointer. The terminal gets what you do NEXT; the file
# keeps why, and what to ignore.
NEXT_STEPS="$INSTALL_DIR/NEXT-STEPS.txt"
TUNNEL_PORT="${ENV_HOST_PORT:-18789}"
PROVIDER_URL_HINT="${AI_PROVIDER_BASE_URL:-http://ollama:11434}"

cat > "$NEXT_STEPS" <<EOF
OpenClaw — getting to a working agent
Generated $(date '+%F %T') by deploy.sh

Three things stand between a running gateway and an agent that answers.
None of them are faults; each is a deliberate choice by OpenClaw that a
containerised deployment meets differently from a laptop install.


1. THE DASHBOARD WILL NOT OPEN OVER PLAIN HTTP
------------------------------------------------------------------
The control UI derives a device identity with Web Crypto, and browsers
only expose that API in a "secure context": HTTPS, or localhost. Browsing
to this server's IP over http:// fails however correct your token is:

    control ui requires device identity
    (use HTTPS or localhost secure context)

A browser rule, not an OpenClaw bug. This is the one place DockHub's usual
"publish a port and browse to it" does not work.

  Option A — SSH tunnel. Nothing to configure, and it also satisfies the
  origin allow-list, which contains localhost only:

      ssh -L $TUNNEL_PORT:localhost:$TUNNEL_PORT $(whoami)@$SERVER_IP

  Leave it open, then browse to  http://localhost:$TUNNEL_PORT

  Option B — HTTPS through NGINX Proxy Manager. Needs 'main-net', so
  redeploy and answer yes to that question. Your domain then has to be
  added to the allow-list, which localhost-only does not cover:

      cd $INSTALL_DIR
      $COMPOSE_CMD run --rm --entrypoint openclaw openclaw config set gateway.controlUi.allowedOrigins '["https://your.domain"]'

  deploy.sh writes that list only when it is absent, so a customised one
  survives future reruns.


2. THE TOKEN
------------------------------------------------------------------
    cat $SECRETS_FILE

Paste it into "Gateway Token" and press Connect. The field is labelled
optional because password auth is the alternative; here the token is
required — the gateway refuses to listen on 0.0.0.0 without credentials,
which is why deploy.sh generates one rather than leaving it to onboarding.

Leave the password field EMPTY. A stray value there produces
"token_mismatch" even when the token itself is right.


3. GIVE IT A MODEL
------------------------------------------------------------------
A fresh install points at a cloud model with no key, so the first message
fails with:

    MissingAgentHarnessError: agent harness "codex" is not registered

"codex" is OpenAI's runtime. The error means no auth — not a missing
install. Fix it with the wizard:

    cd $INSTALL_DIR
    $COMPOSE_CMD run --rm -it --entrypoint openclaw openclaw configure

  Answer: Model -> More... -> Ollama -> Ollama -> Local only

  >>> At "Ollama base URL" it offers http://127.0.0.1:11434. WRONG HERE:
  >>> inside this container that address is OpenClaw itself. Use:
  >>>
  >>>     $PROVIDER_URL_HINT
  >>>
  >>> Upstream's docs make the same mistake in a different form and say
  >>> host.docker.internal. Both assume Ollama runs on the host; in
  >>> DockHub it is a container on 'ai-net', reached by name.

Then pick models — only ones you have actually pulled. Check with:

    docker exec ollama ollama list

The wizard configures the provider but does NOT set the default model, so
finish the job and restart:

    $COMPOSE_CMD run --rm --entrypoint openclaw openclaw models set ollama/<model>
    $COMPOSE_CMD restart openclaw

Confirm — the startup line should name your model, not openai/gpt-5.5:

    $COMPOSE_CMD logs openclaw | grep "agent model" | tail -1

(No --tail on the logs: that line is printed at startup, and a connected
dashboard pushes dozens of WebSocket lines above it within seconds. Search
the whole log and take the last match instead.)


WHAT TO IGNORE
------------------------------------------------------------------
* The dashboard's "Update now" button. In a container it refuses with
  "not-git-install" and suggests 'openclaw update'. DO NOT run that — it
  is advice for a host install, and an in-container update either fails or
  drifts from the image and vanishes on the next recreate. Update with:

      cd $INSTALL_DIR && $COMPOSE_CMD pull && $COMPOSE_CMD up -d

  Your config is a bind mount, so token, pairing and settings survive.

* "Realtime voice provider openai is not configured" — the Talk feature
  wants an OpenAI key. Unrelated to chat.


WORTH KNOWING
------------------------------------------------------------------
* 'configure' is not just for models. Channels, credentials, skills and
  gateway settings all live there. It is the main tool for this service.
* Give the agent its OWN credentials — a bot token and an API key created
  for it. An agent holding your primary key can spend it.
EOF
# 644, not 600: this is documentation, and it holds no secret — only the
# path to the file that does. Locking it down would just make it unreadable
# to a second admin on the same box for no gain.
chmod 644 "$NEXT_STEPS"

echo
echo "📌 THREE STEPS to a working agent — detail in NEXT-STEPS.txt:"
echo
echo "   1. Tunnel. The dashboard needs HTTPS or localhost, so the"
echo "      server's IP over http:// will NOT work:"
echo "        ssh -L $TUNNEL_PORT:localhost:$TUNNEL_PORT $(whoami)@$SERVER_IP"
echo "      then open  http://localhost:$TUNNEL_PORT"
echo
echo "   2. Paste the token into 'Gateway Token' (leave password empty):"
echo "        cat $SECRETS_FILE"
echo
echo "   3. Give it a model — the default is a cloud one it cannot run:"
echo "        cd $INSTALL_DIR"
echo "        $COMPOSE_CMD run --rm -it --entrypoint openclaw openclaw configure"
echo "        $COMPOSE_CMD run --rm --entrypoint openclaw openclaw models set ollama/<model>"
echo "        $COMPOSE_CMD restart openclaw"
echo "      ⚠️  The wizard offers http://127.0.0.1:11434 — wrong here."
echo "          Use  $PROVIDER_URL_HINT"
if [[ -z "$AI_PROVIDER_NAME" ]]; then
    echo
    echo "   ⚠️  No provider is running yet, so step 3 has nothing to point at."
    echo "       Deploy Ollama first (services/AI/ollama/) and pull a model."
fi
echo
echo "📄 Why each step exists, and what to ignore:"
echo "     $NEXT_STEPS"
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

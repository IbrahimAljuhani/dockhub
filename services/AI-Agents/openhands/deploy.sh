#!/bin/bash
# deploy.sh (services/AI-Agents/openhands)
# Purpose: Deploy OpenHands — the software-engineering agent, and the only
# service in DockHub that REQUIRES the Docker socket. See docker-compose.yml
# for why, and ../README.md for the category threat model.
#
# This is a single-instance service, under ~/docker/openhands/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy OpenHands on the shared 'ai-net' network."
            echo "Requires /var/run/docker.sock — see the README before running."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/openhands"
LOGFILE="$INSTALL_DIR/deploy.log"
NEXT_STEPS="$INSTALL_DIR/NEXT-STEPS.txt"

LIB_DIR="$SOURCE_DIR/../../../lib"
if [[ ! -f "$LIB_DIR/common.sh" ]]; then
    LIB_DIR="$(mktemp -d)"
    curl -fsSL -o "$LIB_DIR/common.sh" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

check_prerequisites
ensure_single_agent "openhands" || exit 0

mkdir -p "$INSTALL_DIR"
ensure_ai_net

# No lib/gpu.sh: an agent never loads a model, the provider does.

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    echo
    print_info "OpenHands is a SOFTWARE ENGINEERING agent — it writes code, runs it,"
    print_info "and browses. That is a different job from OpenClaw and Hermes, which"
    print_info "are personal assistants you message. See ../README.md."

    # ── The gate ────────────────────────────────────────────────────────
    # A typed word rather than y/n. The point is NOT that typing is harder
    # than pressing a key — it plainly is not, and pretending otherwise
    # would be theatre. The point is that the word cannot be reached by
    # habit: every other prompt in this repo takes y or Enter, so a reflex
    # answer lands nowhere here and the reader has to look up.
    #
    # What earns the gate is the WARNING, not the keystroke. So it names
    # the actual chain, in order, rather than gesturing at "security".
    echo
    print_warn "════════════════════════════════════════════════════════════"
    print_warn "OpenHands REQUIRES the Docker socket. It is not optional here."
    print_warn "════════════════════════════════════════════════════════════"
    echo >&2
    print_info "Why it wants it — and this part is in its favour:"
    print_info "  it starts a fresh container per session, so the code it writes"
    print_info "  runs isolated from OpenHands itself. Isolation is the point."
    echo >&2
    print_warn "What that costs you, stated in full:"
    print_warn "  1. Anything reaching /var/run/docker.sock can start a"
    print_warn "     privileged container — root-equivalent on this host."
    print_warn "  2. OpenHands has NO authentication of its own. The other two"
    print_warn "     agents refuse to start unless you give them credentials;"
    print_warn "     this one boots straight to a usable settings screen."
    print_warn "  3. So anyone who reaches its port gets a privileged agent."
    print_warn "     That is why deploy.sh binds it to 127.0.0.1 on this server"
    print_warn "     and not to your LAN — upstream advises the same."
    print_warn "  4. The agent acts on text it did not write: a repository it"
    print_warn "     clones, a page it reads, an issue someone filed."
    echo >&2
    print_info "DockHub does not refuse this. Core infrastructure already runs"
    print_info "Portainer on the same socket. The difference is who holds the"
    print_info "trigger — you, or a language model."
    echo >&2
    read -rp "Type  i-accept  to continue, or anything else to stop: " ack
    if [[ "$ack" != "i-accept" ]]; then
        echo
        print_info "Nothing was deployed — no files written, no socket mounted."
        print_info "OpenClaw and Hermes do the assistant job without the socket:"
        print_info "  services/AI-Agents/openclaw/  ·  services/AI-Agents/hermes/"
        exit 0
    fi
    print_warn "Acknowledged. Keep this host behind a firewall."

    # ── main-net ────────────────────────────────────────────────────────
    # Offered with the category's standard warning, per the project ruling:
    # consistent with the other two agents rather than a special case. The
    # host port stays loopback-bound either way — that is about the missing
    # authentication, which no network choice fixes.
    prompt_agent_network "OpenHands"

    echo
    prompt_mem_limit "openhands" "4g"

    # ── The port ────────────────────────────────────────────────────────
    # No prompt_host_port here, deliberately: that helper offers a LAN
    # binding, and a LAN binding on an unauthenticated privileged agent is
    # not a choice this repo should present as routine. Ask for the number,
    # bind it to loopback.
    echo
    print_info "OpenHands' web UI is how you use it — but it has no login, so the"
    print_info "port is bound to 127.0.0.1 on the server rather than your LAN."
    print_info "You reach it over an SSH tunnel; deploy.sh prints the command."
    read -rp "Host port to bind on 127.0.0.1 (default: 3001): " oh_port
    OH_PORT_VALUE="${oh_port:-3001}"
    if ! [[ "$OH_PORT_VALUE" =~ ^[0-9]+$ ]] || (( OH_PORT_VALUE < 1 || OH_PORT_VALUE > 65535 )); then
        print_warn "Not a valid port — using 3001."
        OH_PORT_VALUE=3001
    fi
    # 3000 is Open WebUI's default here, and Redmine's, and Juice Shop's.
    if [[ "$OH_PORT_VALUE" == "3000" ]]; then
        print_warn "3000 is Open WebUI's default in this catalogue (and Redmine's,"
        print_warn "and Juice Shop's). Expect a clash if any of them is running."
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
OPENHANDS_TAG=1.8
# Pinned rather than floating: a runtime image that changes silently under
# a working setup is a debugging problem nobody wants. Bump deliberately.
AGENT_SERVER_IMAGE_REPOSITORY=ghcr.io/openhands/agent-server
AGENT_SERVER_IMAGE_TAG=1.26.0-python
OH_PORT=$OH_PORT_VALUE
AGENT_ON_MAIN_NET=$AGENT_ON_MAIN_NET
SOCKET_ACKNOWLEDGED=1
EOF
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    print_info "Generated .env at $INSTALL_DIR."
    # No secrets file: OpenHands generates no credentials, because it has
    # none. That absence is the whole reason for the loopback binding.
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
    # Not-overwriting is the right default — but this particular key is the
    # difference between a working agent and one that queues every message
    # in silence. A deployment made before it existed looks healthy and is
    # not, so say so rather than letting the user rediscover it the hard way.
    if ! grep -q "OH_WEBHOOKS_0_BASE_URL" "$INSTALL_DIR/docker-compose.yml"; then
        echo
        print_warn "That kept file predates the session-callback fix. Without it the"
        print_warn "agent receives your messages and its answers never arrive back —"
        print_warn "no error, just silence. To take the fix:"
        print_warn "    rm $INSTALL_DIR/docker-compose.yml && bash $0"
        print_warn "Your .env, state/ and conversations are untouched by that."
        echo
    fi
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

ENV_MEM_LIMIT=$(read_env_value "MEM_LIMIT" "$INSTALL_DIR/.env")
ENV_PORT=$(read_env_value "OH_PORT" "$INSTALL_DIR/.env")
ENV_MAIN_NET=$(read_env_value "AGENT_ON_MAIN_NET" "$INSTALL_DIR/.env")
ENV_RUNTIME_REPO=$(read_env_value "AGENT_SERVER_IMAGE_REPOSITORY" "$INSTALL_DIR/.env")
ENV_RUNTIME_TAG=$(read_env_value "AGENT_SERVER_IMAGE_TAG" "$INSTALL_DIR/.env")
ENV_ACK=$(read_env_value "SOCKET_ACKNOWLEDGED" "$INSTALL_DIR/.env")

# A rerun must not skip the gate just because .env exists. If the file was
# hand-made, or copied from another host, or predates this key, the socket
# has not been acknowledged on THIS machine by THIS person.
if [[ "$ENV_ACK" != "1" ]]; then
    echo
    print_warn "This deployment's .env has no record of the Docker socket having"
    print_warn "been acknowledged. Delete $INSTALL_DIR/.env and rerun, so the"
    print_warn "warning is read rather than inherited."
    print_error "Refusing to mount the socket on an unacknowledged deployment."
fi

# State lives here: settings, secrets, conversations, working copies.
mkdir -p "$INSTALL_DIR/state"
chmod 700 "$INSTALL_DIR/state"

# ── The gateway address ─────────────────────────────────────────────────
# Asked of Docker rather than assumed. 172.17.0.1 is the common default,
# but a host with a custom default-address-pool, or one where docker0 was
# renumbered, will differ — and a wrong address here fails in the worst
# way available: silently, at the first message, long after deploy said
# everything was fine.
DOCKER0_GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
if [[ ! "$DOCKER0_GW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    DOCKER0_GW="172.17.0.1"
    print_warn "Could not read the docker0 gateway from Docker — assuming $DOCKER0_GW."
    print_warn "If conversations never get a reply, this is the first thing to check."
fi

# ── Is host port 3000 free ON THE GATEWAY? ──────────────────────────────
# The callback binding below is pinned to 3000 and cannot move (see the
# long note beside it). That makes a collision fatal rather than annoying,
# so it is caught here — before deploy declares success and the failure
# surfaces later as an agent that never answers.
#
# Only two kinds of binding actually clash with $DOCKER0_GW:3000 — a
# wildcard listener (0.0.0.0 / [::], which is what a published container
# port looks like by default) and one already on the gateway itself. A
# service bound to 127.0.0.1:3000 does NOT conflict and is left alone.
GW_ESC=${DOCKER0_GW//./\\.}
PORT_3000_OWNER=""
if command -v ss >/dev/null 2>&1; then
    PORT_3000_OWNER=$(ss -ltnH 2>/dev/null | awk '{print $4}' \
        | grep -Ex "(0\.0\.0\.0|\*|\[::\]|${GW_ESC}):3000" | head -1 || true)
fi
if [[ -n "$PORT_3000_OWNER" ]]; then
    echo
    print_warn "Something is already listening on $PORT_3000_OWNER."
    # Name it if Docker owns it — far more useful than a bare port number.
    CLASH=$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null \
        | grep -E ':3000->' | awk '{print $1}' | tr '\n' ' ' || true)
    [[ -n "$CLASH" ]] && print_warn "Docker container(s) publishing 3000: $CLASH"
    echo
    print_warn "OpenHands cannot yield this one. Its session runtimes dial"
    print_warn "host.docker.internal:3000 and that number is fixed by the app."
    print_warn "Your loopback port ($ENV_PORT) is unaffected — only the callback."
    echo
    print_warn "Move the OTHER service instead. In DockHub, Open WebUI is the"
    print_warn "usual occupant: rerun its deploy and give it a different port."
    print_error "Refusing to deploy into a collision that would break every conversation."
fi

OVERRIDE_BODY=$(
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    echo "    ports:"
    # 127.0.0.1 explicitly. Without the prefix Docker binds 0.0.0.0 and
    # publishes an unauthenticated privileged agent to the whole LAN.
    echo "      - \"127.0.0.1:$ENV_PORT:3000\""
    # ── The callback binding, on the gateway, at PORT 3000 EXACTLY ──────
    # Not a convenience, and the port number is not free to choose.
    #
    # Session runtimes start on the default bridge network, where the name
    # `openhands` does not resolve. Their one route back to the app is
    # host.docker.internal — this gateway. With the loopback binding alone
    # the callback finds nothing listening, every agent event is dropped,
    # and messages pile up in pending_messages with no visible error. The
    # UI just never replies, which reads exactly like a dead model.
    #
    # ⚠️ WHY 3000 AND NOT "$ENV_PORT" — found the hard way on a live server.
    # The app listens on 3000 inside its container and tells each runtime
    # to call it back on "host.docker.internal:3000", assuming the host
    # publishes the same number. DockHub does not: it publishes 3001 by
    # default to stay clear of Open WebUI. So a gateway binding on
    # $ENV_PORT is a door the runtime never knocks on.
    #
    # Proven on the box: from inside a runtime, port 3000 answered nothing
    # while 3001 returned the full OpenHands page — with the app's own
    # OH_WEBHOOKS_0_BASE_URL correctly reading 3001. The app simply does
    # not pass that variable down to the sessions it starts.
    #
    # Hence two bindings with DIFFERENT host ports onto the same container
    # port. The human side stays wherever you chose it; the callback side
    # is pinned to the only number the runtime will ever dial.
    #
    # The cost, stated plainly: this gateway is NOT reachable from your
    # LAN, so the loopback-only rule for humans holds. It IS reachable
    # from every container on the default bridge. A real widening, bounded
    # by the socket this service already required — anything that could
    # reach the gateway could already reach the daemon.
    echo "      - \"$DOCKER0_GW:3000:3000\""
    if [[ "$ENV_MAIN_NET" == "1" ]]; then
        echo "    networks:"
        echo "      - ai-net"
        echo "      - main-net"
    fi
    true
)
{
    echo "services:"
    echo "  openhands:"
    printf '%s\n' "$OVERRIDE_BODY"
    if [[ "$ENV_MAIN_NET" == "1" ]]; then
        echo "networks:"
        echo "  main-net:"
        echo "    external: true"
    fi
} > "$INSTALL_DIR/docker-compose.override.yml"

[[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'openhands' container."
print_warn "Docker socket mounted — required by this service, root-equivalent on host."
if [[ "$ENV_MAIN_NET" == "1" ]]; then
    ensure_main_net
    print_warn "On 'main-net' — it can reach every other DockHub service by name."
    print_warn "NPM can proxy it, but OpenHands brings no login of its own: put an"
    print_warn "Access List on the proxy host, or you have published a privileged"
    print_warn "agent to whoever finds the domain."
else
    print_info "On 'ai-net' only — it cannot reach your other services."
fi

# Both images, pulled up front with visible progress. The runtime is fetched
# by OpenHands at first session otherwise, which looks like a hang inside
# the web UI where there is no progress bar to watch.
print_info "Pulling the app image..."
pull_with_progress "$INSTALL_DIR" \
    || print_warn "Pull failed — the start below will report the real error."

print_info "Pulling the session runtime image ($ENV_RUNTIME_TAG)..."
docker pull "$ENV_RUNTIME_REPO:$ENV_RUNTIME_TAG" 2>&1 | tee -a "$LOGFILE" \
    || print_warn "Could not pre-pull the runtime. OpenHands will fetch it at the
first session instead — expect a long silent wait in the web UI."

print_info "Starting OpenHands..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start OpenHands. Check log: $LOGFILE"

# ── Self-test ───────────────────────────────────────────────────────────
# The UI answering is all a deploy can prove here. It cannot prove the agent
# works: the model is set in the web UI and nowhere else, so there is no
# configuration for this script to verify. See the category README on why a
# green self-test is not a working agent — this service is the clearest case
# of it in the whole repo.
print_info "Waiting for the web interface to answer..."
if docker exec openhands sh -c 'command -v curl' >/dev/null 2>&1; then
    OH_PROBE="curl -fsS http://localhost:3000/ -o /dev/null"
elif docker exec openhands sh -c 'command -v wget' >/dev/null 2>&1; then
    OH_PROBE="wget -q --spider http://localhost:3000/"
else
    OH_PROBE="python3 -c \"import urllib.request as u; u.urlopen('http://localhost:3000/', timeout=5)\""
fi

set +e
wait_for_container_ready "openhands" "$OH_PROBE" 60 5
WAIT_RC=$?
set -e

if (( WAIT_RC == 1 )); then
    FAILLOG=$(docker logs --tail 30 openhands 2>&1 || true)
    case "$FAILLOG" in
        *"docker.sock"*|*"Cannot connect to the Docker daemon"*|*"permission denied"*)
            echo
            print_warn "It cannot reach the Docker daemon — which is the one thing it"
            print_warn "cannot work without. Check the socket really is mounted:"
            print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD config | grep docker.sock"
            print_warn "  ls -l /var/run/docker.sock"
            ;;
        *"port is already allocated"*|*"address already in use"*)
            echo
            print_warn "Port $ENV_PORT is taken. Change OH_PORT in $INSTALL_DIR/.env"
            print_warn "and rerun. Note 3000 is Open WebUI's default here."
            ;;
        *"pull"*|*"manifest"*|*"not found"*)
            echo
            print_warn "An image could not be fetched. The runtime tag is pinned in"
            print_warn ".env and may have aged out — check what exists upstream:"
            print_warn "  grep AGENT_SERVER $INSTALL_DIR/.env"
            ;;
    esac
    print_error "OpenHands did not start. Full log: cd $INSTALL_DIR && $COMPOSE_CMD logs openhands"
fi

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
detect_ai_provider

# ── The model URL the SESSION RUNTIME can actually reach ────────────────
# Every other service in this catalogue reaches a provider by container
# name over ai-net. OpenHands cannot, and this is the one place it must
# not be treated like the others.
#
# The agent — and therefore the LLM call — runs inside the session runtime,
# which Docker starts on the DEFAULT bridge. The name `ollama` does not
# resolve there. Proven live:
#     docker exec <runtime> getent hosts ollama   → nothing
#     docker exec <runtime> wget host.docker.internal:11434/api/tags → models
#
# So the runtime needs the provider's PUBLISHED HOST PORT, via the same
# host.docker.internal route its callback already uses. That port is
# optional in services/AI/*/deploy.sh, so it may simply not exist — in
# which case saying nothing would leave the user with a Base URL that
# cannot work and no error explaining why.
OH_MODEL_URL=""
if [[ -n "$AI_PROVIDER_NAME" ]]; then
    # Container port from the provider's own ai-net URL (…:11434 → 11434).
    PROV_PORT="${AI_PROVIDER_BASE_URL##*:}"; PROV_PORT="${PROV_PORT%%/*}"
    if [[ "$PROV_PORT" =~ ^[0-9]+$ ]]; then
        PROV_PUB=$(docker port "$AI_PROVIDER_NAME" "$PROV_PORT/tcp" 2>/dev/null | head -1 || true)
        PROV_BIND="${PROV_PUB%:*}"
        PROV_HPORT="${PROV_PUB##*:}"
        # Only a wildcard or gateway binding is reachable from the runtime.
        # A 127.0.0.1 binding is NOT — the runtime's loopback is its own.
        if [[ "$PROV_HPORT" =~ ^[0-9]+$ ]] && \
           [[ "$PROV_BIND" == "0.0.0.0" || "$PROV_BIND" == "[::]" || "$PROV_BIND" == "$DOCKER0_GW" ]]; then
            OH_MODEL_URL="http://host.docker.internal:$PROV_HPORT/v1"
        fi
    fi
fi

echo
echo "──────────────────────────────────────────────"
echo "🌐 Web UI:        127.0.0.1:$ENV_PORT on the server — tunnel to reach it"
echo "🕸️  Networks:      $( [[ "$ENV_MAIN_NET" == "1" ]] && echo "ai-net + main-net" || echo "ai-net only" )"
echo "🔌 Docker socket: MOUNTED ⚠️  (required by this service)"
echo "↩️  Callback:      $DOCKER0_GW:3000 — fixed; session runtimes dial only this"
echo "🔓 Login:         none — OpenHands has no authentication of its own"
echo "📦 Session image: $ENV_RUNTIME_REPO:$ENV_RUNTIME_TAG"
if [[ -n "$AI_PROVIDER_NAME" ]] && [[ -n "$OH_MODEL_URL" ]]; then
    echo "🧠 Provider:      $AI_PROVIDER_NAME — use $OH_MODEL_URL"
elif [[ -n "$AI_PROVIDER_NAME" ]]; then
    echo "🧠 Provider:      $AI_PROVIDER_NAME — ⚠️ NOT reachable from sessions"
else
    echo "🧠 Provider:      none running — deploy one from services/AI/ first"
fi
echo "📁 State:         $INSTALL_DIR/state  (settings, conversations, work)"
echo "📜 Log:           $LOGFILE"
echo "──────────────────────────────────────────────"
echo
if (( WAIT_RC == 0 )); then
    print_info "Self-test passed — the web interface answered."
    print_warn "That proves the server runs, NOT that the agent works. The model is"
    print_warn "set in the UI and nowhere else, so nothing here can check it."
else
    print_warn "The interface did not answer within 5 minutes. Watch it with:"
    print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f openhands"
fi

cat > "$NEXT_STEPS" <<EOF
OpenHands — what to do next
Generated $(date '+%F %T') by deploy.sh


1. REACH IT — A SOCKS PROXY, NOT A PORT TUNNEL
------------------------------------------------------------------
The port is bound to 127.0.0.1 ON THE SERVER, because OpenHands has NO
login: anyone who reaches it gets an agent holding the Docker socket.
Upstream advises the same loopback binding.

A plain  ssh -L $ENV_PORT:...  is NOT enough here, and this was learned
the hard way. It loads the page, then the UI sits on "Disconnected"
and every panel reads "Network Error".

The reason: each conversation's runtime container publishes its OWN
ports, with RANDOM host numbers that change every session:

    8000/tcp -> 0.0.0.0:36137     <- the session API the browser needs
    8001/tcp -> 0.0.0.0:57443     <- VS Code
    8011, 8012 -> ...

Your browser talks to those directly. You cannot forward numbers you
cannot know in advance, so forward nothing and proxy everything:

    ssh -D 1080 $(whoami)@$SERVER_IP

Leave it open, then point the browser at that SOCKS proxy:

  Firefox: Settings -> Network Settings -> Manual proxy configuration
           SOCKS Host  127.0.0.1     Port  1080     SOCKS v5
           tick "Proxy DNS when using SOCKS v5"
           (SOCKS Host — NOT the HTTP Proxy field above it)

  Then, in about:config, set:
           network.proxy.allow_hijacking_localhost = true

  That last one is required. Firefox refuses to proxy localhost by
  default — its own dialog says so — and without it the browser looks
  on YOUR machine instead of the server's.

  Chrome: start it with
           --proxy-server="socks5://127.0.0.1:1080"

Then browse to  http://localhost:$ENV_PORT

Every address the page asks for is now opened from the server's side,
including those random runtime ports.

  >>> SECURITY, STATED PRECISELY: those runtime ports are published on
  >>> 0.0.0.0 — your whole LAN — and DockHub cannot prevent it. We bind
  >>> the app to 127.0.0.1, but the runtimes are created by OpenHands
  >>> through the Docker socket, not by this compose file, so their
  >>> binding is not ours to choose.
  >>>
  >>> It is not wide open, and the measured result matters more than
  >>> the alarm: tested from the server's own LAN address, /alive
  >>> answers 200 while POST /api/bash/start_bash_command returns 401.
  >>> The machine-to-machine API authenticates. So the exposure is
  >>> "a reachable, token-guarded API" — not a free shell.
  >>>
  >>> The unauthenticated door is the UI on $ENV_PORT, and that is the
  >>> one on loopback. Keep the host firewalled anyway: random ports
  >>> cannot be pinned by a rule, and an agent is a large attack
  >>> surface to leave on a shared network.


2. GIVE IT A MODEL — IN THE UI, THERE IS NO OTHER WAY
------------------------------------------------------------------
No environment variable configures this. Hermes could be scripted
because its model lives in a config file; OpenHands cannot.

Open  Settings -> LLM -> Advanced.  THREE fields must all be right,
and the first is the one that catches people:

    Custom Model   openai/<model>     <- the openai/ prefix is required
    Base URL       (below)
    API Key        anything, e.g.  ollama

There is NO dropdown of your models here. "Custom Model" is free text,
and OpenHands never asks your provider what it serves. The list on the
Basic tab is OpenHands' own cloud catalogue — your local models will
never appear in it. Get the exact names yourself:

    docker exec -it ${AI_PROVIDER_NAME:-ollama} ollama list

then type, for example:   openai/qwen3.5:9b   — colons included.

  >>> The openai/ prefix does not name OpenAI the company. It tells
  >>> LiteLLM, inside OpenHands, to speak the OpenAI protocol to the
  >>> Base URL below. A leftover  openhands/...  value from the Basic
  >>> tab silently ignores your Base URL and calls the cloud instead.

  >>> API Key must NOT be left empty, even for a local provider. The
  >>> protocol requires the field; your provider ignores its value.

Base URL — paste exactly:

$( if [[ -n "$OH_MODEL_URL" ]]; then
echo "    $OH_MODEL_URL"
echo
echo "  (provider found: $AI_PROVIDER_NAME, published on the host)"
elif [[ -n "$AI_PROVIDER_NAME" ]]; then
echo "    ⚠️  $AI_PROVIDER_NAME is running, but publishes NO host port that"
echo "        a session can reach — so no Base URL here can work yet."
echo
echo "        Rerun its deploy and accept the host-port question:"
echo "            services/AI/$AI_PROVIDER_NAME/"
echo "        then reread this file."
else
echo "    No provider is running yet — deploy one first:"
echo "        services/AI/ollama/"
fi )

  >>> DO NOT use the container name here. This is the one place where
  >>> OpenHands differs from every other DockHub service, and an earlier
  >>> version of this file got it backwards.
  >>>
  >>> http://ollama:11434/v1 resolves from the OpenHands container — but
  >>> that is not where the model is called. The agent runs inside the
  >>> SESSION RUNTIME, which Docker starts on the default bridge, where
  >>> no DockHub container name resolves at all. Verified live:
  >>>
  >>>     getent hosts ollama                      -> nothing
  >>>     wget host.docker.internal:11434/api/tags -> your model list
  >>>
  >>> So the runtime reaches your provider the same way it reaches
  >>> OpenHands itself: through host.docker.internal and a published
  >>> host port. A container name here fails silently — the message is
  >>> accepted, no reply ever arrives, and nothing in the UI says why.


3. THE FIRST SESSION STARTS A SECOND CONTAINER
------------------------------------------------------------------
That is the design: your code runs in $ENV_RUNTIME_REPO,
not in OpenHands itself. deploy.sh pre-pulled it so the first run is
not a long silent wait.

Watch it happen:

    docker ps --filter ancestor=$ENV_RUNTIME_REPO:$ENV_RUNTIME_TAG


4. IF YOU SEND A MESSAGE AND NOTHING EVER COMES BACK
------------------------------------------------------------------
The symptom is distinctive: no error, no spinner that stops, no red
text. The message is simply never answered. It looks like a broken
model, and it usually is not.

That runtime container does not just receive work — it POSTS every
result back to the app over HTTP:

    $DOCKER0_GW:$ENV_PORT   (as host.docker.internal, from inside it)

If that leg is down, the app never learns the agent said anything. It
files your message in a queue instead. Confirm in the app's log:

    docker logs openhands 2>&1 | grep -i pending_message

  "Queued pending message ... (position: 2)"  = the callback is broken,
  not the model.

Then read the runtime's own log, which is where the truth is:

    RT=\$(docker ps --filter ancestor=$ENV_RUNTIME_REPO:$ENV_RUNTIME_TAG --format '{{.Names}}')
    docker logs "\$RT" 2>&1 | grep -i webhook

  "Failed to post events to webhook ... All connection attempts failed"
  means the gateway binding is missing or on the wrong port. Check it:

    docker port openhands

  Exactly these two lines are expected — note the DIFFERENT host ports:

    3000/tcp -> 127.0.0.1:$ENV_PORT
    3000/tcp -> $DOCKER0_GW:3000

  The second MUST read 3000, whatever you chose for the first. Runtimes
  dial host.docker.internal:3000 and that number comes from the app, not
  from your .env — a gateway binding on $ENV_PORT is a door nobody knocks
  on. If the second line is missing or shows any other port, delete
  $INSTALL_DIR/docker-compose.override.yml and rerun this script.

  To see it from where it matters, ask a live runtime directly:

    RT=\$(docker ps --filter name=oh-agent-server --format '{{.Names}}' | head -1)
    docker exec "\$RT" wget -qO- --timeout=3 http://host.docker.internal:3000/ | head -c 80

  HTML back = the callback path is open. Nothing back = it is not.

Do NOT "fix" this by binding the port to 0.0.0.0. That publishes an
unauthenticated agent holding the Docker socket to your whole network.


WHAT THIS DEPLOY DID NOT PROVE
------------------------------------------------------------------
The self-test only showed that the web server answers. It could not
check the model, the credentials, or whether the agent can run a single
command — none of that exists until you configure it in the UI.

For an agent, the only real test is the round trip: give it a task,
watch it act. Nothing in a deploy script can do that for you.


IF YOU PUT IT BEHIND NGINX PROXY MANAGER
------------------------------------------------------------------
Only possible if you answered yes to 'main-net'. Add an Access List on
the proxy host — OpenHands brings no login, so without one you have
published a privileged agent to anyone who finds the domain.
EOF
chmod 644 "$NEXT_STEPS"

echo
echo "📌 TWO STEPS:"
echo
echo "   1. SOCKS proxy — a plain -L tunnel is NOT enough for this service:"
echo "        ssh -D 1080 $(whoami)@$SERVER_IP"
echo "      Firefox: Network Settings → SOCKS Host 127.0.0.1, Port 1080, v5"
echo "      about:config → network.proxy.allow_hijacking_localhost = true"
echo "      then open  http://localhost:$ENV_PORT"
echo "      (each session publishes random ports the browser must reach;"
echo "       -L cannot forward numbers you don't know yet. See NEXT-STEPS.)"
echo
echo "   2. Set the model in the UI — no environment variable can do it."
echo "      Settings → LLM → Advanced. All THREE fields, or it fails:"
if [[ -n "$OH_MODEL_URL" ]]; then
    echo "        Custom Model   openai/<model>   ← the openai/ prefix is required"
    echo "        Base URL       $OH_MODEL_URL"
    echo "        API Key        anything, e.g.  ollama   ← must not be empty"
    echo "      NOT http://$AI_PROVIDER_NAME:... — that name does not resolve"
    echo "      inside the session container where the model is actually called."
    echo "      No dropdown lists your models. Names:"
    echo "        docker exec -it $AI_PROVIDER_NAME ollama list"
elif [[ -n "$AI_PROVIDER_NAME" ]]; then
    echo "      ⚠️  $AI_PROVIDER_NAME is running but publishes no host port, so"
    echo "         sessions cannot reach it. Rerun services/AI/$AI_PROVIDER_NAME/"
    echo "         and accept the host-port question, then redeploy this."
else
    echo "      ⚠️  No provider running. Deploy services/AI/ollama/ first."
fi
echo
echo "📄 Why the tunnel, what the second container is, and what this deploy"
echo "   could not verify:"
echo "     $NEXT_STEPS"
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

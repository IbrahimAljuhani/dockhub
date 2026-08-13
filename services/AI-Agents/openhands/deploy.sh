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

OVERRIDE_BODY=$(
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    echo "    ports:"
    # 127.0.0.1 explicitly. Without the prefix Docker binds 0.0.0.0 and
    # publishes an unauthenticated privileged agent to the whole LAN.
    echo "      - \"127.0.0.1:$ENV_PORT:3000\""
    # Second binding, on the docker0 gateway — NOT a convenience.
    #
    # Session runtimes are started on the default bridge network, where
    # the name `openhands` does not resolve. Their only route back to the
    # app is host.docker.internal, which is this gateway. With loopback
    # alone the callback finds nothing listening, every agent event is
    # dropped, and messages queue in pending_messages with no visible
    # error. See block 6 of docker-compose.yml.
    #
    # Still not the LAN: the gateway is reachable from containers on this
    # host, not from your network. The tunnel rule for humans is intact.
    echo "      - \"$DOCKER0_GW:$ENV_PORT:3000\""
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
(cd "$INSTALL_DIR" && $COMPOSE_CMD pull 2>&1 | tee -a "$LOGFILE") \
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

echo
echo "──────────────────────────────────────────────"
echo "🌐 Web UI:        127.0.0.1:$ENV_PORT on the server — tunnel to reach it"
echo "🕸️  Networks:      $( [[ "$ENV_MAIN_NET" == "1" ]] && echo "ai-net + main-net" || echo "ai-net only" )"
echo "🔌 Docker socket: MOUNTED ⚠️  (required by this service)"
echo "↩️  Callback:      $DOCKER0_GW:$ENV_PORT — session runtimes answer here"
echo "🔓 Login:         none — OpenHands has no authentication of its own"
echo "📦 Session image: $ENV_RUNTIME_REPO:$ENV_RUNTIME_TAG"
if [[ -n "$AI_PROVIDER_NAME" ]]; then
    echo "🧠 Provider:      $AI_PROVIDER_NAME  ($AI_PROVIDER_BASE_URL)"
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


1. REACH IT — SSH TUNNEL, NOT THE SERVER'S IP
------------------------------------------------------------------
The port is bound to 127.0.0.1 ON THE SERVER. Browsing to the server's
LAN address will not reach it, and that is deliberate:

  OpenHands has NO login. Anyone who reaches the port gets an agent
  that holds the Docker socket. On a LAN binding that is everyone on
  your network; upstream's own advice is the same loopback binding.

    ssh -L $ENV_PORT:localhost:$ENV_PORT $(whoami)@$SERVER_IP

Leave that open, then browse to  http://localhost:$ENV_PORT


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

$( if [[ -n "$AI_PROVIDER_NAME" ]]; then
echo "    $AI_PROVIDER_BASE_URL/v1"
echo
echo "  (found running on ai-net: $AI_PROVIDER_NAME)"
else
echo "    http://ollama:11434/v1"
echo
echo "  No provider is running yet — deploy one first:"
echo "      services/AI/ollama/"
fi )

  >>> Use the CONTAINER NAME. Not localhost, not the server's IP, not
  >>> host.docker.internal — inside this container those mean the wrong
  >>> machine. The compose file does set host.docker.internal, but for
  >>> the session runtime's callback (section 4), not for your model.


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
  means the gateway binding is missing. Check it is really there:

    docker port openhands

  Two lines are expected — 127.0.0.1 and $DOCKER0_GW. If the second is
  absent, delete $INSTALL_DIR/docker-compose.override.yml and rerun this
  script.

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
echo "   1. Tunnel — the port is loopback-bound because there is no login:"
echo "        ssh -L $ENV_PORT:localhost:$ENV_PORT $(whoami)@$SERVER_IP"
echo "      then open  http://localhost:$ENV_PORT"
echo
echo "   2. Set the model in the UI — no environment variable can do it."
echo "      Settings → LLM → Advanced. All THREE fields, or it fails:"
if [[ -n "$AI_PROVIDER_NAME" ]]; then
    echo "        Custom Model   openai/<model>   ← the openai/ prefix is required"
    echo "        Base URL       $AI_PROVIDER_BASE_URL/v1"
    echo "        API Key        anything, e.g.  ollama   ← must not be empty"
    echo "      No dropdown lists your models. Names:"
    echo "        docker exec -it $AI_PROVIDER_NAME ollama list"
else
    echo "      ⚠️  No provider running. Deploy services/AI/ollama/ first."
fi
echo
echo "📄 Why the tunnel, what the second container is, and what this deploy"
echo "   could not verify:"
echo "     $NEXT_STEPS"
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

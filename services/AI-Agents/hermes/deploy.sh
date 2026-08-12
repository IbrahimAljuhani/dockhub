#!/bin/bash
# deploy.sh (services/AI-Agents/hermes)
# Purpose: Deploy Hermes Agent — the second AGENT in DockHub, and the first
# one this repo can configure without an interactive wizard. See
# docker-compose.yml for why uid 10000 and mandatory auth shape this file,
# and ../README.md for the category's threat model.
#
# This is a single-instance service, under ~/docker/hermes/.

set -euo pipefail

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Deploy Hermes Agent on the shared 'ai-net' network."
            exit 0
            ;;
    esac
fi

if [[ $EUID -eq 0 ]]; then
    echo "This script must NOT be run as root. Please run as a regular user in the docker group." >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/docker/hermes"
LOGFILE="$INSTALL_DIR/deploy.log"
SECRETS_FILE="$INSTALL_DIR/.hermes-docker-secrets.txt"
NEXT_STEPS="$INSTALL_DIR/NEXT-STEPS.txt"

LIB_DIR="$SOURCE_DIR/../../../lib"
if [[ ! -f "$LIB_DIR/common.sh" ]]; then
    LIB_DIR="$(mktemp -d)"
    curl -fsSL -o "$LIB_DIR/common.sh" "https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/lib/common.sh"
fi
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

check_prerequisites

# Agents are alternatives, not companions — and not for the providers'
# VRAM reason. See ensure_single_agent() in lib/common.sh.
ensure_single_agent "hermes" || exit 0

mkdir -p "$INSTALL_DIR"

# ai-net always: the model provider is what it actually needs.
ensure_ai_net

# No lib/gpu.sh: an agent never loads a model, the provider does.

# ── Ask the provider what it actually serves ────────────────────────────
# All three DockHub providers expose an OpenAI-compatible /v1, so one query
# works for any of them. Done from a throwaway container ON ai-net, because
# that is the only vantage point whose answer means anything — the host can
# often reach a published port while the network between containers is
# broken, and it is the container's view that Hermes will have.
#
# alpine because backup_service_generic already uses it, so it is usually
# cached, and its busybox wget needs no extra image.
list_provider_models() {
    local base="$1"
    docker run --rm --network ai-net alpine \
        wget -qO- --timeout=5 "$base/v1/models" 2>/dev/null \
        | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/.*"\([^"]*\)"$/\1/' || true
}

# ── Hermes needs a 64K context window, and will not start without one ───
# Found the hard way: a deploy that passed every check still refused to
# answer, with
#   "Model qwen2.5-coder:7b has a context window of 32,768 tokens, which
#    is below the minimum 64,000 required by Hermes Agent."
# A 7B coding model was a perfectly reasonable pick and is simply
# ineligible. Better to say so while choosing than after the first message.
#
# Only Ollama publishes this: /api/tags carries context_length per model,
# while the OpenAI-compatible /v1/models does not. So the check is real
# where it can be and honest ("unknown") where it cannot.
HERMES_MIN_CONTEXT=64000

ollama_context_lengths() {
    local base="$1"
    # RS='"name":"' starts every record at a model, so a context_length
    # found in a record belongs to that model and cannot bleed in from
    # its neighbour — which a flat grep over the whole document would.
    docker run --rm --network ai-net alpine \
        wget -qO- --timeout=5 "$base/api/tags" 2>/dev/null \
        | awk -v RS='"name":"' 'NR>1 {
              name = substr($0, 1, index($0, "\"") - 1)
              cl = "?"
              if (match($0, /"context_length"[[:space:]]*:[[:space:]]*[0-9]+/)) {
                  seg = substr($0, RSTART, RLENGTH)
                  sub(/.*:[[:space:]]*/, "", seg)
                  cl = seg
              }
              print name "\t" cl
          }' || true
}

# Echoes the context length for one model, or nothing if unknown.
context_length_of() {
    local model="$1" line name cl
    while IFS=$'\t' read -r name cl; do
        [[ "$name" == "$model" ]] || continue
        [[ "$cl" == "?" ]] && return 0
        echo "$cl"
        return 0
    done <<< "${MODEL_CONTEXTS:-}"
    return 0
}

if [[ -f "$INSTALL_DIR/.env" ]]; then
    print_info "Existing deployment found at $INSTALL_DIR — reusing its .env (not regenerated)."
else
    echo
    print_info "Hermes is an AGENT: it acts on what it reads, using tools, and it"
    print_info "keeps memory between conversations. See ../README.md."

    # The one decision with a real security consequence, asked first.
    prompt_agent_network "Hermes"

    # ── The Docker socket ───────────────────────────────────────────────
    # Optional, exactly as for OpenClaw: upstream ships docker-cli in the
    # image and suggests the mount so the agent's tools can drive the host
    # daemon. Convenience, not a requirement.
    echo
    print_info "Hermes can drive the host's Docker daemon — its image ships docker-cli"
    print_info "so the agent can inspect containers, build and run things."
    print_warn "That needs the Docker socket. The trade, plainly:"
    print_warn "  gained — the agent can use Docker as a tool"
    print_warn "  given  — anything reaching that socket can start a privileged"
    print_warn "           container, which is root-equivalent on this host"
    print_warn "Hermes runs fine WITHOUT it. This is not required."
    read -rp "Mount /var/run/docker.sock? (y/N): " sock_answer
    HERMES_SANDBOX_VALUE=0
    if [[ "${sock_answer,,}" == "y" ]]; then
        HERMES_SOCK_VALUE=1
        print_warn "Docker socket enabled. Keep this host behind a firewall."

        # ── The follow-up question, and why it exists ────────────────────
        # Saying yes above creates a chain that is easy to miss: the agent's
        # shell runs INSIDE this container (terminal.backend defaults to
        # 'local'), this container now holds the Docker socket, and so the
        # agent can start a privileged container and reach the whole host.
        # Hermes says so itself at every startup:
        #
        #   API server is network-accessible (0.0.0.0) AND the terminal
        #   backend is 'local' (unsandboxed). Agent work dispatched through
        #   this endpoint runs as the host user with full terminal/file
        #   access. Strongly consider a sandboxed backend
        #   (terminal.backend: docker).
        #
        # Leaving that as the silent default is the real problem — not that
        # sandboxing is missing, but that the weakest combination is what
        # you get for answering one 'y'. So ask.
        echo >&2
        print_warn "That alone leaves the agent's own shell inside THIS container —"
        print_warn "the one now holding the socket. Hermes warns about it on every"
        print_warn "start, and the way out is its 'docker' terminal backend:"
        print_warn "  local  (default) — agent commands run here, beside the socket"
        print_warn "  docker           — each tool call runs in a separate hardened"
        print_warn "                     container: ALL capabilities dropped, then"
        print_warn "                     only DAC_OVERRIDE/CHOWN/FOWNER added back,"
        print_warn "                     no-new-privileges, 256-process limit,"
        print_warn "                     nosuid tmpfs for /tmp and /var/tmp"
        echo >&2
        read -rp "Run agent commands in a sandbox container (recommended)? (Y/n): " sandbox_answer
        if [[ "${sandbox_answer,,}" == "n" ]]; then
            print_warn "Sandbox declined. The agent's shell shares this container with the"
            print_warn "socket — the widest reach of the three possible setups."
        else
            HERMES_SANDBOX_VALUE=1
            print_info "Sandbox enabled. deploy.sh will set terminal.backend=docker."
        fi
    else
        HERMES_SOCK_VALUE=0
        print_info "No Docker socket. Tools run inside the Hermes container, which"
        print_info "cannot reach the host — the strongest option, and free."
    fi

    # ── The dashboard ───────────────────────────────────────────────────
    # Off by default, and that is not timidity: Hermes reaches YOU outbound
    # over Telegram/Slack/email, so in normal use there is nothing to open.
    # The dashboard is for inspecting memory, skills and cron.
    echo
    print_info "Hermes talks to you OUTBOUND over messaging — Telegram, Discord,"
    print_info "Slack, WhatsApp, Signal, email. In normal use you never open a page."
    print_info "Its web dashboard is for inspecting memory, skills and cron jobs."
    read -rp "Enable the web dashboard on port 9119? (y/N): " dash_answer
    if [[ "${dash_answer,,}" == "y" ]]; then
        HERMES_DASHBOARD_VALUE=1
        print_info "Dashboard enabled. A username and password are generated below —"
        print_info "it refuses to start on a container bind without them."
    else
        HERMES_DASHBOARD_VALUE=0
        print_info "No dashboard. The API on 8642 is still there for other services."
    fi

    # ── The model ───────────────────────────────────────────────────────
    # This is where Hermes differs from OpenClaw in the way that matters:
    # config.yaml is a file, so the model can be set at deploy time instead
    # of in a wizard nobody can script.
    echo
    detect_ai_provider
    HERMES_MODEL_VALUE=""
    HERMES_BASE_URL_VALUE=""
    if [[ -n "$AI_PROVIDER_NAME" ]]; then
        print_info "Found a model provider on 'ai-net': $AI_PROVIDER_NAME"
        HERMES_BASE_URL_VALUE="$AI_PROVIDER_BASE_URL/v1"
        print_info "Asking it which models it serves..."
        mapfile -t PROVIDER_MODELS < <(list_provider_models "$AI_PROVIDER_BASE_URL")

        MODEL_CONTEXTS=""
        if [[ "$AI_PROVIDER_NAME" == "ollama" ]]; then
            MODEL_CONTEXTS=$(ollama_context_lengths "$AI_PROVIDER_BASE_URL")
        fi

        echo
        print_warn "Hermes requires a context window of at least ${HERMES_MIN_CONTEXT} tokens"
        print_warn "and refuses to run below it. Many good small models are under that —"
        print_warn "qwen2.5-coder:7b reports 32,768, for example, and is rejected."

        if (( ${#PROVIDER_MODELS[@]} == 1 )); then
            HERMES_MODEL_VALUE="${PROVIDER_MODELS[0]}"
            print_info "It serves exactly one model: $HERMES_MODEL_VALUE"
        elif (( ${#PROVIDER_MODELS[@]} > 1 )); then
            echo
            echo "Which model should Hermes use?"
            # LocalAI's AIO set lists every capability it serves, so this
            # menu can contain whisper-1, tts-1 and stablediffusion — real
            # models, but not ones an agent can hold a conversation with.
            [[ "$AI_PROVIDER_NAME" == "localai" ]] && \
                print_warn "Pick a CHAT model. This list also has speech and image ones."
            i=1
            for m in "${PROVIDER_MODELS[@]}"; do
                mctx=$(context_length_of "$m")
                if [[ -z "$mctx" ]]; then
                    echo "   $i) $m"
                elif (( mctx < HERMES_MIN_CONTEXT )); then
                    echo "   $i) $m   — ${mctx} ctx  ❌ too small for Hermes"
                else
                    echo "   $i) $m   — ${mctx} ctx  ✅"
                fi
                i=$((i + 1))
            done
            read -rp "Choice (1-${#PROVIDER_MODELS[@]}): " model_choice
            if [[ "$model_choice" =~ ^[0-9]+$ ]] \
               && (( model_choice >= 1 && model_choice <= ${#PROVIDER_MODELS[@]} )); then
                HERMES_MODEL_VALUE="${PROVIDER_MODELS[$((model_choice - 1))]}"
            else
                print_warn "Not a valid choice — using the first one."
                HERMES_MODEL_VALUE="${PROVIDER_MODELS[0]}"
            fi
        else
            # Reachable but silent, or an unexpected response shape. Not
            # fatal: ask rather than guess a name that fails on first use.
            print_warn "Could not read a model list from $AI_PROVIDER_BASE_URL/v1/models."
            print_warn "The provider may have none installed yet. Check with:"
            print_warn "  docker exec $AI_PROVIDER_NAME sh -c 'command -v ollama >/dev/null && ollama list'"
            read -rp "Model name to configure anyway (blank to skip): " HERMES_MODEL_VALUE
        fi

        # Verify whatever was settled on, however it was settled on — the
        # single-model path never saw a menu, and that is exactly the case
        # that bit us: one model, taken without comment, rejected later.
        HERMES_CONTEXT_OVERRIDE=""
        if [[ -n "$HERMES_MODEL_VALUE" ]]; then
            CHOSEN_CTX=$(context_length_of "$HERMES_MODEL_VALUE")
            if [[ -n "$CHOSEN_CTX" ]] && (( CHOSEN_CTX < HERMES_MIN_CONTEXT )); then
                echo
                print_warn "$HERMES_MODEL_VALUE reports ${CHOSEN_CTX} tokens — below Hermes'"
                print_warn "minimum of ${HERMES_MIN_CONTEXT}. Deployed as-is it will start, then answer"
                print_warn "every message with 'agent init failed'."
                echo >&2
                print_info "Two ways forward:"
                print_info "  1) Pull a bigger-context model and rerun. llama3.1:8b reports"
                print_info "     131,072 and is a similar size:"
                print_info "       docker exec -it ollama ollama pull llama3.1:8b"
                print_info "  2) Override it — but ONLY if you know the server is"
                print_info "     under-reporting and the model's true window is 64K+."
                print_info "     Hermes' own error message suggests this."
                echo >&2
                read -rp "Set model.context_length anyway? Enter a number, or blank to continue unchanged: " HERMES_CONTEXT_OVERRIDE
                if [[ -n "$HERMES_CONTEXT_OVERRIDE" ]]; then
                    if [[ ! "$HERMES_CONTEXT_OVERRIDE" =~ ^[0-9]+$ ]] \
                       || (( HERMES_CONTEXT_OVERRIDE < HERMES_MIN_CONTEXT )); then
                        print_warn "Not a number, or still below ${HERMES_MIN_CONTEXT} — ignoring it."
                        HERMES_CONTEXT_OVERRIDE=""
                    else
                        print_info "config.yaml will declare context_length: $HERMES_CONTEXT_OVERRIDE"
                    fi
                fi
            fi
        fi
    else
        print_warn "No model provider is running on 'ai-net'."
        echo
        echo "   1) Point Hermes at a cloud endpoint instead (needs a base URL and key)"
        echo "   2) Skip — configure the model later"
        echo "   0) Stop here — I'll deploy Ollama first"
        read -rp "Choice (0-2): " backend_choice
        case "$backend_choice" in
            1)
                read -rp "API base URL (e.g. https://api.openai.com/v1): " HERMES_BASE_URL_VALUE
                read -rp "Model name: " HERMES_MODEL_VALUE
                read -rsp "API key: " HERMES_CLOUD_KEY; echo
                ;;
            2) print_info "Skipped. Edit data/config.yaml later, or run the setup wizard." ;;
            *)
                echo
                print_info "Nothing was deployed. Deploy a provider first:"
                print_info "  Ollama is the simplest — services/AI/ollama/"
                exit 0
                ;;
        esac
    fi

    echo
    prompt_mem_limit "hermes" "2g"

    echo
    print_info "Hermes serves an OpenAI-compatible API on 8642, protected by a key"
    print_info "generated below. Other DockHub services reach it as hermes:8642."
    prompt_host_port "8642"

    # ── Credentials ─────────────────────────────────────────────────────
    # Not optional hardening: upstream requires the API key whatever the
    # bind, and refuses to serve a gated dashboard without a provider.
    API_KEY_VALUE=$(generate_secret_hex 32)
    DASH_USER_VALUE=""
    DASH_PASS_VALUE=""
    DASH_SECRET_VALUE=""
    if (( HERMES_DASHBOARD_VALUE )); then
        DASH_USER_VALUE="admin"
        DASH_PASS_VALUE=$(generate_secret_hex 12)
        # Upstream wants 32+ bytes; 32 hex-encoded bytes is 64 characters.
        DASH_SECRET_VALUE=$(generate_secret_hex 32)
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
HERMES_TAG=latest
PUID=$(id -u)
PGID=$(id -g)
API_SERVER_KEY=$API_KEY_VALUE
HERMES_DASHBOARD=$HERMES_DASHBOARD_VALUE
HERMES_SOCK=$HERMES_SOCK_VALUE
HERMES_SANDBOX=$HERMES_SANDBOX_VALUE
AGENT_ON_MAIN_NET=$AGENT_ON_MAIN_NET
EOF
    if (( HERMES_DASHBOARD_VALUE )); then
        {
            echo "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$DASH_USER_VALUE"
            echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$DASH_PASS_VALUE"
            echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$DASH_SECRET_VALUE"
        } >> "$INSTALL_DIR/.env"
    fi
    [[ -n "$MEM_LIMIT" ]] && echo "MEM_LIMIT=$MEM_LIMIT" >> "$INSTALL_DIR/.env"
    [[ -n "$HOST_PORT" ]] && echo "HOST_PORT=$HOST_PORT" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    {
        echo "# Auto-generated Hermes secrets - DO NOT SHARE"
        echo "$(date '+%F %T')"
        echo
        echo "  API key (8642):  $API_KEY_VALUE"
        echo "    Required by upstream whatever the bind address — there is no"
        echo "    exception for loopback. Send it as: Authorization: Bearer <key>"
        if (( HERMES_DASHBOARD_VALUE )); then
            echo
            echo "  Dashboard (9119)"
            echo "    Username: $DASH_USER_VALUE"
            echo "    Password: $DASH_PASS_VALUE"
            echo
            echo "    The dashboard refuses to start on a non-loopback bind without"
            echo "    an auth provider — inside a container the bind is never"
            echo "    loopback, so these are what make it run at all."
        fi
        echo
        if (( HERMES_DASHBOARD_VALUE )); then
            echo "  All of these live in .env. Changing one means editing .env and"
            echo "  restarting; changing the session secret signs everyone out."
        else
            # Says "three" only when there are three. The dashboard is off by
            # default, and a secrets file that miscounts its own contents is
            # a small thing that costs trust in the larger ones.
            echo "  This lives in .env. Changing it means editing .env and restarting."
            echo "  The dashboard is off, so there is no username or password to keep."
        fi
    } > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    print_info "Generated .env and saved the credentials to $SECRETS_FILE."
fi

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    print_info "Existing docker-compose.yml found at $INSTALL_DIR — keeping it (not overwritten). Delete it yourself first if you want the latest version from this repo."
else
    cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
fi

ENV_MEM_LIMIT=$(read_env_value "MEM_LIMIT" "$INSTALL_DIR/.env")
ENV_HOST_PORT=$(read_env_value "HOST_PORT" "$INSTALL_DIR/.env")
ENV_SOCK=$(read_env_value "HERMES_SOCK" "$INSTALL_DIR/.env")
ENV_SANDBOX=$(read_env_value "HERMES_SANDBOX" "$INSTALL_DIR/.env")
ENV_MAIN_NET=$(read_env_value "AGENT_ON_MAIN_NET" "$INSTALL_DIR/.env")
ENV_DASHBOARD=$(read_env_value "HERMES_DASHBOARD" "$INSTALL_DIR/.env")
ENV_API_KEY=$(read_env_value "API_SERVER_KEY" "$INSTALL_DIR/.env")

# ── The data directory ──────────────────────────────────────────────────
# Owned by you, written by uid 10000 unless PUID/PGID say otherwise — see
# docker-compose.yml. Created here so the ownership is ours from the start
# rather than root's, which is what Docker would do on first mount.
mkdir -p "$INSTALL_DIR/data"
chmod 700 "$INSTALL_DIR/data"

# ── PUID/PGID are re-asserted, not frozen at first deploy ───────────────
# Baking `id -u` into .env once is right until the deployment moves. Restore
# is the case that makes it real, and this repo has proven restore works: a
# backup taken here and unpacked on a host whose account is 1001 would carry
# PUID=1000, so the container would run as a user that does not own its own
# data directory — and the failure surfaces as an opaque permission error
# rather than anything naming uids.
#
# So compare every run and correct the drift. Note that fixing PUID alone is
# only half the job: the FILES still belong to the old uid, and a chown
# across another user's files needs root, which this script deliberately
# does not have. Hence: detect, correct what we can, and hand over the exact
# command for what we cannot.
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)
ENV_PUID=$(read_env_value "PUID" "$INSTALL_DIR/.env")
if [[ -n "$ENV_PUID" && "$ENV_PUID" != "$CURRENT_UID" ]]; then
    echo
    print_warn "This deployment was created by uid $ENV_PUID, but you are $CURRENT_UID."
    print_warn "Updating PUID/PGID so the container runs as you."
    set_env_value "PUID" "$CURRENT_UID" "$INSTALL_DIR/.env"
    set_env_value "PGID" "$CURRENT_GID" "$INSTALL_DIR/.env"

    # -print -quit stops at the first offender: this is a question with a
    # yes/no answer, and the data tree can hold thousands of session files.
    if [[ -n "$(find "$INSTALL_DIR/data" -maxdepth 2 ! -user "$CURRENT_UID" -print -quit 2>/dev/null)" ]]; then
        print_warn "Some files under data/ are still owned by the old user, and only"
        print_warn "root can hand them over. Hermes will fail to write until you run:"
        print_warn "  sudo chown -R $CURRENT_UID:$CURRENT_GID $INSTALL_DIR/data"
    fi
elif [[ -z "$ENV_PUID" ]]; then
    # A .env from before this key existed. Append rather than leave the
    # compose file interpolating an empty value into the container.
    set_env_value "PUID" "$CURRENT_UID" "$INSTALL_DIR/.env"
    set_env_value "PGID" "$CURRENT_GID" "$INSTALL_DIR/.env"
fi

# ── config.yaml, written rather than wizarded ───────────────────────────
# The whole reason this service can deploy in one pass. Written ONLY when
# absent: after first run this file is the agent's own — the setup wizard,
# the dashboard and the agent itself all write to it, and clobbering that
# on a rerun would throw away channels, skills configuration and any model
# change made since.
CONFIG_YAML="$INSTALL_DIR/data/config.yaml"
if [[ -f "$CONFIG_YAML" ]]; then
    print_info "Existing data/config.yaml — left alone (it is the agent's own now)."
elif [[ -n "${HERMES_MODEL_VALUE:-}" && -n "${HERMES_BASE_URL_VALUE:-}" ]]; then
    # provider: custom is upstream's shape for any OpenAI-compatible
    # endpoint, which is what all three DockHub providers are. api_key must
    # be non-empty even where it is ignored, hence the placeholder.
    cat > "$CONFIG_YAML" <<EOF
# Generated by DockHub's deploy.sh on $(date '+%F %T').
# This file is yours from now on — deploy.sh will not overwrite it.
model:
  provider: custom
  model: ${HERMES_MODEL_VALUE}
  base_url: ${HERMES_BASE_URL_VALUE}
  api_key: "${HERMES_CLOUD_KEY:-none}"
EOF
    # Only written when you asked for it: Hermes reads the model's own
    # reported window otherwise, and declaring a number larger than the
    # truth buys an "agent init failed" for a context overflow later.
    if [[ -n "${HERMES_CONTEXT_OVERRIDE:-}" ]]; then
        echo "  context_length: ${HERMES_CONTEXT_OVERRIDE}" >> "$CONFIG_YAML"
    fi
    chmod 600 "$CONFIG_YAML"
    print_info "Wrote data/config.yaml — model ${HERMES_MODEL_VALUE} via ${HERMES_BASE_URL_VALUE}"
else
    print_warn "No model configured. Hermes will start but cannot answer until you"
    print_warn "set one — see NEXT-STEPS.txt."
fi

# docker-compose.override.yml is fully owned by this script (never hand-edit
# it), so it is always safe to regenerate from what .env says.
OVERRIDE_BODY=$(
    [[ -n "$ENV_MEM_LIMIT" ]] && echo "    mem_limit: $ENV_MEM_LIMIT"
    if [[ -n "$ENV_HOST_PORT" || "$ENV_DASHBOARD" == "1" ]]; then
        echo "    ports:"
        [[ -n "$ENV_HOST_PORT" ]] && echo "      - \"$ENV_HOST_PORT:8642\""
        # The dashboard is bound to localhost on the host on purpose. It is
        # a management surface for one person, its only bundled auth is a
        # password, and an SSH tunnel costs nothing. Reach it with:
        #   ssh -L 9119:localhost:9119 you@server
        [[ "$ENV_DASHBOARD" == "1" ]] && echo "      - \"127.0.0.1:9119:9119\""
    fi
    if [[ "$ENV_SOCK" == "1" ]]; then
        # Compose MERGES volume lists rather than replacing them, unlike
        # ports — so this adds the socket to the data mount in the base
        # file instead of wiping it out.
        echo "    volumes:"
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
        echo "  hermes:"
        printf '%s\n' "$OVERRIDE_BODY"
        if [[ "$ENV_MAIN_NET" == "1" ]]; then
            echo "networks:"
            echo "  main-net:"
            echo "    external: true"
        fi
    } > "$INSTALL_DIR/docker-compose.override.yml"
else
    rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

[[ -n "$ENV_MEM_LIMIT" ]] && print_info "Memory limit $ENV_MEM_LIMIT applied to the 'hermes' container."
[[ "$ENV_SOCK" == "1" ]] && print_warn "Docker socket mounted (root-equivalent on host)."
if [[ "$ENV_MAIN_NET" == "1" ]]; then
    ensure_main_net
    print_warn "On 'main-net' — it can reach every other DockHub service by name."
else
    print_info "On 'ai-net' only — it cannot reach your other services."
fi
print_info "Running as uid $(id -u):$(id -g) inside the container (PUID/PGID)."

# Pulled with visible progress rather than silently inside a later step —
# a multi-hundred-megabyte download under a message about something else
# reads as a hang.
print_info "Pulling the image (first run downloads it)..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD pull 2>&1 | tee -a "$LOGFILE") \
    || print_warn "Pull failed — the start below will report the real error."

# ── The sandbox setting, written with Hermes' own CLI ───────────────────
# `hermes config set` rather than hand-edited YAML, for the reason OpenClaw
# taught: the tool knows its own schema, a guessed nesting does not. And it
# is idempotent, so this is safe to reassert on every run.
#
# Written only when the socket is mounted, because the docker backend needs
# the socket to create its containers — asking Hermes to sandbox without it
# would swap a working setup for a broken one.
#
# Not verified from upstream docs, so NOT assumed here: whether the sandbox
# container itself receives the socket. Reasoning says it should not — the
# whole point is moving the agent's shell off the container that has it —
# but the security page is silent on it. If you rely on that boundary,
# confirm it yourself:
#   docker exec -it hermes hermes config get terminal
print_info "Starting Hermes..."
(cd "$INSTALL_DIR" && $COMPOSE_CMD up -d 2>&1 | tee -a "$LOGFILE") \
    || print_error "Failed to start Hermes. Check log: $LOGFILE"

# SANDBOX_STATE is what actually happened, not what was asked for. The
# summary box reads THIS, never ENV_SANDBOX — a first cut printed
# "sandboxed" from the user's answer while the command that would have made
# it true had failed three lines earlier. That is the same class of lie this
# category's README warns about in "a green self-test does not mean a
# working agent", and it is worse than the failure it hid.
SANDBOX_STATE="off"

# ── Self-test ───────────────────────────────────────────────────────────
# /v1/models WITH the key: it proves the API server is up, that the key
# works, and that the model configuration parsed — three claims one probe
# can settle. An unauthenticated probe would prove only the first.
#
# Which HTTP client the image actually has is not something to assume. This
# is a Python image, so curl and wget may both be absent — and a probe that
# fails because the tool is missing looks exactly like a service that never
# came up. Detect once, then build the probe from what is really there.
# Python is the one thing an application written in Python must ship.
#
# A note on the key travelling in this command line. wait_for_container_ready
# runs `docker exec hermes sh -c "$probe"`, so the bearer token is visible in
# the container's own process list for the moment the probe runs. Judged
# acceptable rather than overlooked: the same token is already in
# $INSTALL_DIR/.env and in /opt/data/.env inside the container, readable by
# the same user and by the agent itself, so this discloses nothing new to
# anyone. Nothing tees it to deploy.log either.
#
# The alternative — probing WITHOUT the key and accepting 401 as proof of
# life, the way Open WebUI does — would remove even that, but it would only
# prove something is listening. Sending the key proves three things at once:
# the server is up, the key is right, and config.yaml parsed. That is worth
# more here than closing a window onto a secret its holder already has.
print_info "Waiting for the API to answer..."
if docker exec hermes sh -c 'command -v curl' >/dev/null 2>&1; then
    HERMES_PROBE="curl -fsS -H 'Authorization: Bearer $ENV_API_KEY' http://localhost:8642/v1/models"
    PROBE_TOOL="curl"
elif docker exec hermes sh -c 'command -v wget' >/dev/null 2>&1; then
    HERMES_PROBE="wget -q --spider --header='Authorization: Bearer $ENV_API_KEY' http://localhost:8642/v1/models"
    PROBE_TOOL="wget"
else
    # urlopen raises HTTPError on 4xx/5xx, so a bad key or an unparsed
    # config still fails the probe rather than passing silently.
    HERMES_PROBE="python3 -c \"import urllib.request as u; u.urlopen(u.Request('http://localhost:8642/v1/models', headers={'Authorization':'Bearer $ENV_API_KEY'}), timeout=5)\""
    PROBE_TOOL="python3"
fi
print_info "  (probing with $PROBE_TOOL — whichever the image ships)"

set +e
wait_for_container_ready "hermes" "$HERMES_PROBE" 45 4
WAIT_RC=$?
set -e

if (( WAIT_RC == 1 )); then
    FAILLOG=$(docker logs --tail 30 hermes 2>&1 || true)
    case "$FAILLOG" in
        *"Permission denied"*|*"EACCES"*|*"Read-only"*)
            echo
            print_warn "A permissions problem on $INSTALL_DIR/data."
            print_warn "The container runs as uid 10000 unless PUID/PGID redirect it."
            print_warn "Check they reached the container:"
            print_warn "  grep -E '^(PUID|PGID)=' $INSTALL_DIR/.env"
            print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD config | grep -iE 'puid|pgid'"
            ;;
        *"auth provider"*|*"dashboard"*|*"never starts"*)
            echo
            print_warn "The dashboard refused to start. It fails closed on a non-loopback"
            print_warn "bind with no auth provider — which is the container's normal bind."
            print_warn "Check the username and password reached it:"
            print_warn "  grep BASIC_AUTH $INSTALL_DIR/.env"
            ;;
        *"API_SERVER_KEY"*|*"api key"*|*"unauthorized"*)
            echo
            print_warn "The API server is unhappy about its key. Upstream requires one"
            print_warn "whatever the bind address — there is no loopback exception."
            print_warn "  grep API_SERVER_KEY $INSTALL_DIR/.env"
            ;;
        *"setup"*|*"config"*)
            echo
            print_warn "Hermes wants configuration that data/config.yaml did not satisfy."
            print_warn "Writing that file is meant to replace the wizard; if it did not,"
            print_warn "run the wizard directly and tell us what it asked:"
            print_warn "  docker exec -it hermes hermes setup"
            ;;
    esac
    print_error "Hermes did not start. Full log: cd $INSTALL_DIR && $COMPOSE_CMD logs hermes"
fi

# ── The sandbox, set only once the container is genuinely up ────────────
# This used to run immediately after `up -d` and failed on a live host with:
#
#   PermissionError: [Errno 13] Permission denied: '/opt/data/.env'
#
# — because s6's cont-init was still running. Its own log narrates the race:
# "[stage2] Changing hermes UID to 1000", "chowned supervise/ trees". The
# CLI does only write a file, so the earlier comment claiming it need not
# wait for the gateway was true and useless: it does need to wait for the
# INIT. The self-test above is exactly the proof that init has finished, so
# the work belongs here, after it.
#
# Written ONLY when config.yaml does not already name a backend — the same
# rule as OpenClaw's origin allow-list. Someone who moved to `local` on
# purpose keeps it, and reruns do not force an unnecessary restart that
# would drop live sessions.
if [[ "$ENV_SOCK" == "1" && "$ENV_SANDBOX" == "1" ]]; then
    if grep -qE '^[[:space:]]*backend:' "$CONFIG_YAML" 2>/dev/null; then
        SANDBOX_STATE=$(grep -E '^[[:space:]]*backend:' "$CONFIG_YAML" | tail -1 | sed 's/.*backend:[[:space:]]*//' | tr -d '"')
        print_info "Terminal backend already set to '$SANDBOX_STATE' — left alone."
    else
        print_info "Setting terminal.backend=docker (agent commands run sandboxed)..."
        if docker exec hermes hermes config set terminal.backend docker 2>&1 | tee -a "$LOGFILE"; then
            SANDBOX_STATE="docker"
            (cd "$INSTALL_DIR" && $COMPOSE_CMD restart hermes >/dev/null 2>&1) \
                || print_warn "Set the backend but could not restart — do it yourself."
            # An earlier version warned here that the sandbox IMAGE might be
            # unset, because upstream's docs show `terminal.docker_image` in an
            # example without stating a default. Checking a live deployment
            # settled it — there IS one, and the whole terminal block comes
            # pre-populated:
            #
            #   docker_image: nikolaik/python-nodejs:python3.11-nodejs20
            #   docker_volumes: []          <- and so: no Docker socket inside
            #   container_memory: 5120      <- 5 GB, worth knowing on a small host
            #   container_persistent: true
            #
            # The warning was removed rather than softened: pointing a user at
            # a setting that is already correct costs attention for nothing,
            # and this deploy has enough real warnings competing for it.
            print_info "Sandbox ready. Its container image, limits and (empty) volume"
            print_info "list are Hermes' own defaults — inspect with:"
            print_info "  docker exec -it hermes hermes config get terminal"
        else
            # SANDBOX_STATE stays "off" — the summary must report the failure,
            # not the intention.
            print_warn "Could not set terminal.backend, so the agent's shell stays in THIS"
            print_warn "container, beside the Docker socket. Retry once it has settled:"
            print_warn "  docker exec -it hermes hermes config set terminal.backend docker"
            print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD restart hermes"
        fi
    fi
fi

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"
# ── Reading the model back is not as simple as it looks ────────────────
# deploy.sh writes `model: <name>` on first run, which upstream accepts —
# and then REWRITES the file in its own shape, where the name lives under
# `default:` and `model:` is a bare section header:
#
#   model:
#     provider: custom
#     base_url: http://ollama:11434/v1
#     default: gemma4:e4b        <-- the name is here
#   _config_version: 34
#
# Grepping `model:` against that returns the header and an empty value, so
# a rerun would report "none configured" for a perfectly working agent.
# Try the canonical key first, then the one we write.
CONFIGURED_MODEL=$(grep -E '^[[:space:]]*default:[[:space:]]*[^[:space:]]' "$CONFIG_YAML" 2>/dev/null \
    | tail -1 | sed 's/.*default:[[:space:]]*//' | tr -d '"' || true)
if [[ -z "$CONFIGURED_MODEL" ]]; then
    CONFIGURED_MODEL=$(grep -E '^[[:space:]]*model:[[:space:]]*[^[:space:]]' "$CONFIG_YAML" 2>/dev/null \
        | tail -1 | sed 's/.*model:[[:space:]]*//' | tr -d '"' || true)
fi

echo
echo "──────────────────────────────────────────────"
echo "🔌 API (internal):  http://hermes:8642/v1   ← how other services reach it"
[[ -n "$ENV_HOST_PORT" ]] && echo "🔌 API (host):      http://$SERVER_IP:$ENV_HOST_PORT/v1"
if [[ "$ENV_DASHBOARD" == "1" ]]; then
    echo "🖥️  Dashboard:       127.0.0.1:9119 on the server — tunnel to reach it"
else
    echo "🖥️  Dashboard:       off"
fi
echo "🕸️  Networks:        $( [[ "$ENV_MAIN_NET" == "1" ]] && echo "ai-net + main-net" || echo "ai-net only" )"
if [[ "$ENV_SOCK" == "1" ]]; then
    echo "🔌 Docker socket:   MOUNTED ⚠️"
    # SANDBOX_STATE, never ENV_SANDBOX: one is what happened, the other is
    # what was asked for, and they are not the same line.
    case "$SANDBOX_STATE" in
        docker) echo "🧱 Agent shell:     sandboxed (terminal.backend=docker)" ;;
        off)    if [[ "$ENV_SANDBOX" == "1" ]]; then
                    echo "🧱 Agent shell:     ⚠️ SANDBOX REQUESTED BUT NOT APPLIED — see above"
                else
                    echo "🧱 Agent shell:     ⚠️ UNSANDBOXED, in this container beside the socket"
                fi ;;
        *)      echo "🧱 Agent shell:     terminal.backend=$SANDBOX_STATE" ;;
    esac
else
    echo "🔌 Docker socket:   not mounted ✅"
fi
echo "🧠 Model:           ${CONFIGURED_MODEL:-none configured}"
echo "📁 Agent data:      $INSTALL_DIR/data  (memory, skills, sessions)"
echo "🔑 Credentials:     $SECRETS_FILE"
echo "📜 Log:             $LOGFILE"
echo "──────────────────────────────────────────────"
echo
if (( WAIT_RC == 0 )); then
    print_info "Self-test passed — the API answered with its key, so the server is up,"
    print_info "the key works, and config.yaml parsed."
else
    print_warn "The API did not answer within 3 minutes. Watch it with:"
    print_warn "  cd $INSTALL_DIR && $COMPOSE_CMD logs -f hermes"
fi

# ── Long-form guidance to a file, short pointer to the terminal ─────────
# Same pattern as OpenClaw, and for the same reason: a deploy that ends in
# sixty lines of instructions ends in nobody reading them.
cat > "$NEXT_STEPS" <<EOF
Hermes Agent — what to do next
Generated $(date '+%F %T') by deploy.sh

Unlike OpenClaw, the model was configured at deploy time, so the agent is
usable now. What remains is giving it a way to reach you.


1. TALK TO IT
------------------------------------------------------------------
Hermes' natural interface is OUTBOUND messaging, not a web page. Add a
channel — Telegram is the quickest, via a bot token from @BotFather:

    docker exec -it hermes hermes channels add

Discord, Slack, WhatsApp, Signal and email are all supported the same way,
and each has its own shortcut — 'hermes whatsapp', 'hermes telegram'.

>>> USE 'docker exec', NOT 'docker compose run'.
>>>
>>> This image is supervised by s6: its entrypoint starts the gateway AND
>>> the dashboard whatever command you pass. So 'compose run' quietly
>>> brings up a SECOND, competing Hermes beside the one already running,
>>> then floods your interactive prompt with its startup banner —
>>>
>>>     Choose [1/2]: → Using web dist from HERMES_WEB_DIST: ...
>>>     ⚕ Hermes Gateway Starting...
>>>
>>> and leaves an "exited UNCLEANLY" note in the lifecycle ledger when the
>>> extra one is killed. 'docker exec' runs inside the container that is
>>> already up, which is what these commands actually want.

When a wizard finishes it may tell you to "start the gateway: hermes
gateway". DON'T — it is already running as the container's main process,
and that advice is written for a host install. To pick up the channel you
just added, restart the container:

    cd $INSTALL_DIR && $COMPOSE_CMD restart hermes

Then message the bot. Replies are prefixed '⚕ Hermes Agent'.

For a quick check without any channel, talk to the API directly:

    curl -H "Authorization: Bearer <key from $(basename "$SECRETS_FILE")>" \\
         http://localhost:${ENV_HOST_PORT:-8642}/v1/models


2. THE DASHBOARD (only if you enabled it)
------------------------------------------------------------------
Bound to 127.0.0.1 on the SERVER, not your LAN — it is a single-user
management surface whose bundled auth is a password. Reach it over SSH:

    ssh -L 9119:localhost:9119 $(whoami)@$SERVER_IP

then open  http://localhost:9119  and log in with the username and
password in $SECRETS_FILE.

Note this is a CHOICE, not a workaround. Hermes' dashboard has no browser
secure-context requirement — the previous agent in this category does, and
there a tunnel is mandatory. Here it is simply the more private default.


3. IF EVERY MESSAGE COMES BACK "agent init failed"
------------------------------------------------------------------
Hermes requires a context window of at least ${HERMES_MIN_CONTEXT} tokens and says so
only when you talk to it — the container starts and the API answers
regardless:

    Model <name> has a context window of 32,768 tokens, which is below
    the minimum 64,000 required by Hermes Agent.

deploy.sh checks this while you choose, but a model swapped in afterwards
is not checked. Pull one with a bigger window:

    docker exec -it ollama ollama pull llama3.1:8b     # reports 131,072

then set it in config.yaml as below. If instead your server under-reports
a window the model genuinely has, override it:

    model:
      context_length: 131072

Only when the true window really is 64K+. A number larger than the truth
just moves the failure to a context overflow later.


4. CHANGING THE MODEL
------------------------------------------------------------------
    nano $INSTALL_DIR/data/config.yaml
    docker restart hermes

deploy.sh writes that file only when it is absent, so your edits and
anything the agent or wizard writes there survive future reruns.

The base_url must be the CONTAINER NAME, not localhost — inside the
container localhost is Hermes itself:

    base_url: http://ollama:11434/v1

(Upstream's docs say this correctly, which is worth noting because the
other agent in this category has documentation that does not.)


$( if [[ "$ENV_SOCK" == "1" ]]; then cat <<SANDBOX_EOF
5. THE DOCKER SOCKET YOU MOUNTED
------------------------------------------------------------------
You said yes to /var/run/docker.sock, so the agent can use Docker as a
tool. That also means:

    agent runs a command
      └─ inside the hermes container
           └─ which holds docker.sock
                └─ docker run --privileged -v /:/host …
                     └─ root on this whole host

Current state: agent commands run $( [[ "$ENV_SANDBOX" == "1" ]] && echo "in a SANDBOX container" || echo "UNSANDBOXED, in this container" ).

$( if [[ "$ENV_SANDBOX" == "1" ]]; then cat <<INNER_EOF
The sandbox (terminal.backend=docker) drops ALL Linux capabilities, adds
back only DAC_OVERRIDE/CHOWN/FOWNER, sets no-new-privileges, limits
processes to 256, and mounts /tmp and /var/tmp as nosuid tmpfs.

  >>> deploy.sh sets the BACKEND but not the IMAGE those containers run.
  >>> 'terminal.docker_image' has no value here that is known-correct, so
  >>> it was left alone rather than guessed. If the agent fails the moment
  >>> it tries to run a command, look there first:
  >>>     docker exec -it hermes hermes config get terminal

Upstream notes its usual dangerous-command checks are SKIPPED under this
backend, because the container is the boundary instead.
INNER_EOF
else cat <<INNER_EOF
You declined the sandbox, so the agent's shell shares this container with
the socket — the widest reach of the three possible setups. To change it:

    docker exec -it hermes hermes config set terminal.backend docker
    docker restart hermes
INNER_EOF
fi )

If the agent does not actually need Docker as a tool, redeploying without
the socket is stronger than any sandbox and costs nothing.

SANDBOX_EOF
fi )

WORTH KNOWING
------------------------------------------------------------------
* $INSTALL_DIR/data holds memory, skills, sessions and SOUL.md — the
  agent's personality file. That is real user data: the Backup option in
  the menu captures it, and it is worth using before you experiment.
* The container runs as uid 10000 by default; PUID/PGID in .env redirect
  it to you so the bind mount stays writable. Do not "fix" permission
  errors with chmod 777 — that directory holds your API keys.
* Give the agent its OWN credentials — a bot token and an API key created
  for it. An agent holding your primary key can spend it.
EOF
chmod 644 "$NEXT_STEPS"

echo
echo "📌 NEXT — the model is already configured, so this is about reaching it:"
echo
echo "   Add a messaging channel (Telegram is quickest):"
echo "     docker exec -it hermes hermes channels add"
echo "   ⚠️  'docker exec', never 'compose run' — this image is s6-supervised,"
echo "       so 'run' starts a SECOND gateway and buries the prompt."
if [[ "$ENV_DASHBOARD" == "1" ]]; then
    echo
    echo "   Dashboard — bound to the server's localhost, so tunnel in:"
    echo "     ssh -L 9119:localhost:9119 $(whoami)@$SERVER_IP"
    echo "     then open  http://localhost:9119   (credentials in the file below)"
fi
echo
echo "📄 Channels, changing the model, and what the data directory holds:"
echo "     $NEXT_STEPS"
echo
echo "To manage: cd $INSTALL_DIR && $COMPOSE_CMD [ps|logs -f|stop|restart]"

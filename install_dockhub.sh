#!/bin/bash
#
# install_dockhub.sh
# Author: Ibrahim Aljuhani
# GitHub: https://github.com/IbrahimAljuhani/dockhub
# Purpose: Install Docker CE, Docker Compose, NGINX Proxy Manager, and Portainer-CE
#          — the core infrastructure every service under services/ builds on top of.
#
# Environment overrides (export before running, e.g.:
#   NPM_HTTP_PORT=8080 sudo -E bash install_dockhub.sh):
#
#   NPM_IMAGE             default: jc21/nginx-proxy-manager:latest
#   NPM_HTTP_PORT         default: 80
#   NPM_HTTPS_PORT        default: 443
#   NPM_ADMIN_PORT        default: 81
#   PORTAINER_IMAGE       default: portainer/portainer-ce:latest
#   PORTAINER_HTTP_PORT   default: 9000
#   PORTAINER_HTTPS_PORT  default: 9443
#   PORTAINER_EDGE_PORT   default: 8000
#
# Fixed (this revision):
#   1. Portainer no longer marked "unhealthy" while actually running fine.
#      `docker run --health-cmd` always wraps the check in CMD-SHELL (i.e.
#      `/bin/sh -c ...`), but the default portainer-ce image ships no
#      /bin/sh at all -> the healthcheck itself could never succeed.
#      Portainer is now installed via docker-compose (like NPM) with an
#      exec-form healthcheck (["CMD", "wget", ...]) that never needs a
#      shell.
#   2. NPM_IMAGE now defaults to `:latest` instead of a pinned version.
#      Trade-off: less reproducible across installs, but always current.
#      Pin it yourself via NPM_IMAGE=jc21/nginx-proxy-manager:2.x.y if you
#      need a stable, repeatable version.
#   3. NPM's ./data and ./letsencrypt folders (created by the Docker
#      daemon as root the first time `docker compose up` runs them into
#      existence) are now re-chowned to the real user afterwards, so they
#      don't end up silently root-owned despite the rest of the directory
#      being handed to the user.
#   4. NPM healthcheck path corrected to /usr/bin/check-health to match
#      upstream docs (the previous /bin/check-health likely worked too on
#      this Debian-based image via the usr-merge symlink, but this removes
#      any doubt).

set -Eeuo pipefail

# --- Require root ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run with sudo (e.g. 'sudo bash install_dockhub.sh')." >&2
    exit 1
fi

# --- Configurable via env vars (pin images, override ports) ---
NPM_IMAGE="${NPM_IMAGE:-jc21/nginx-proxy-manager:latest}"
NPM_HTTP_PORT="${NPM_HTTP_PORT:-80}"
NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-443}"
NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-81}"
PORTAINER_IMAGE="${PORTAINER_IMAGE:-portainer/portainer-ce:latest}"
PORTAINER_HTTP_PORT="${PORTAINER_HTTP_PORT:-9000}"
PORTAINER_HTTPS_PORT="${PORTAINER_HTTPS_PORT:-9443}"
PORTAINER_EDGE_PORT="${PORTAINER_EDGE_PORT:-8000}"

# --- Validate env-var inputs (prevent command injection via heredoc expansion) ---
_valid_image() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/-]*:[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; }
_valid_port()  { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 && 10#$1 < 65536 )); }

# The host's LAN address, for the summary this script prints at the end.
#
# THIS IS A DELIBERATE DUPLICATE of host_lan_ip() in lib/common.sh, and it has
# to be. This file does not source that library — see the note above the banner
# for why: lib/common.sh redefines every print_* with a different format and a
# different stream, and this script must also run from a bare `curl` with no
# repo beside it. A shared helper it cannot reach is not a shared helper.
#
# It went missing exactly that way. A repo-wide rollout replaced this idiom
# with a call to host_lan_ip in all 40-odd files that DO source the library,
# and in this one, which does not. `bash -n` accepts a call to an undefined
# function, so nothing caught it until a real install died at the last line
# with "host_lan_ip: command not found" — after the install had succeeded.
#
# If you change the logic here, change lib/common.sh:host_lan_ip too.
_host_lan_ip() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*[[:space:]]src[[:space:]]\+\([0-9.]\+\).*/\1/p' | head -1)"
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }

    ip="$(ip -o -4 addr show scope global 2>/dev/null \
          | awk '$2 !~ /^(docker|br-|veth|virbr|cni|flannel|kube)/ {print $4}' \
          | cut -d/ -f1 | head -1)"
    [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return 0; }

    hostname -I 2>/dev/null | awk '{print $1}'
}

for v in NPM_IMAGE PORTAINER_IMAGE; do
    if ! _valid_image "${!v}"; then
        echo "ERROR: $v='${!v}' is not a valid image reference (name:tag)." >&2
        exit 2
    fi
done
for v in NPM_HTTP_PORT NPM_HTTPS_PORT NPM_ADMIN_PORT \
         PORTAINER_HTTP_PORT PORTAINER_HTTPS_PORT PORTAINER_EDGE_PORT; do
    if ! _valid_port "${!v}"; then
        echo "ERROR: $v='${!v}' is not a valid TCP port (1-65535)." >&2
        exit 2
    fi
done

# --- Resolve real user/home (so running under sudo doesn't turn $HOME into /root) ---
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
: "${REAL_HOME:=${HOME:-/root}}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")"

# All state this script and services/ deploy scripts create lives under one
# ~/docker/ root, so backing up that single folder covers everything.
mkdir -p "$REAL_HOME/docker"
chown "$REAL_USER":"$REAL_GROUP" "$REAL_HOME/docker" 2>/dev/null || true

LOGFILE="$REAL_HOME/docker/install_dockhub.log"

# --- Color codes ---
INFO='\033[0;36m'
OK='\033[0;32m'
WARN='\033[0;33m'
ERROR='\033[0;31m'
NC='\033[0m'

# ── The masthead ────────────────────────────────────────────────────────
# Guarded, never required. lib/banner.sh defines four `dockhub_*` functions,
# a handful of `_BN_*` colour variables, and
# touches nothing else, which is why it is safe to take here — sourcing
# lib/common.sh instead would silently replace every print_* below it, since
# that file writes "[✓]" to stderr where this one writes "[INFO]" to stdout.
# A curl-only run with no repo beside it simply gets no banner, and that is
# a cosmetic loss, never a failure.
_DH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_DH_DIR/lib/banner.sh" ]]; then
    # shellcheck source=lib/banner.sh
    source "$_DH_DIR/lib/banner.sh"
fi
declare -F dockhub_banner >/dev/null || dockhub_banner() { :; }
# These two are NOT no-op fallbacks. A missing banner is cosmetic; a missing
# menu is the script. Without lib/banner.sh they print the same menu without
# the colours.
declare -F dockhub_ask  >/dev/null || dockhub_ask()  { printf '\n%s\n' "$1"; }
declare -F dockhub_item >/dev/null || dockhub_item() { printf '[ %s ] %s\n' "$1" "$2"; }

print_info()    { echo -e "${INFO}[INFO]${NC} $1"; }
print_ok()      { echo -e "${OK}[OK]${NC} $1"; }
print_warn()    { echo -e "${WARN}[WARN]${NC} $1" >&2; }
print_error()   { echo -e "${ERROR}[ERROR]${NC} $1" >&2; }

# --- Rotate previous log, create fresh one owned by the real user ---
if [[ -s "$LOGFILE" ]]; then
    mv "$LOGFILE" "$LOGFILE.old" 2>/dev/null || true
fi
touch "$LOGFILE"
chown "$REAL_USER":"$REAL_GROUP" "$LOGFILE" 2>/dev/null || true
[[ -f "$LOGFILE.old" ]] && chown "$REAL_USER":"$REAL_GROUP" "$LOGFILE.old" 2>/dev/null || true

# --- Global error trap (reports source:line + function for easier debugging) ---
trap 'rc=$?; print_error "Failed at ${BASH_SOURCE[0]}:${LINENO} in ${FUNCNAME[0]:-main} (exit $rc). Log: $LOGFILE"; exit $rc' ERR

spinner() {
    local pid=$1
    local spinstr='|/-\'
    local first=1
    while kill -0 "$pid" 2>/dev/null; do
        if (( first )); then
            printf "%s" "${spinstr:0:1}"
            first=0
        else
            printf "\b%s" "${spinstr:0:1}"
        fi
        spinstr=${spinstr:1}${spinstr:0:1}
        sleep 0.1
    done
    if (( first == 0 )); then
        printf "\b \b"
    fi
}

# Port conflict check — warns the user before docker tries to bind.
# Matches ":<port>$" to cover IPv4 (0.0.0.0:80), IPv6 ([::]:80), and wildcard (*:80).
check_port() {
    local port=$1
    if command -v ss &>/dev/null && ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"; then
        return 1
    elif command -v netstat &>/dev/null && netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | grep -qE ":${port}$"; then
        return 1
    fi
    return 0
}

# check_ports_or_warn <service-label> <own-container|""> <port>...
#
# A port held by the very container we are about to recreate is not a
# conflict — it is the previous run of this same service. Warning about it
# turns every rerun into a question that means nothing, which is exactly the
# kind of prompt this project removes elsewhere. If `docker port` cannot
# answer, we fall back to treating the port as busy: a needless warning is
# survivable, a missed collision is not.
check_ports_or_warn() {
    local svc=$1 own=$2; shift 2
    local busy=()
    for p in "$@"; do
        if ! check_port "$p"; then
            if [[ -n "$own" ]] && docker port "$own" 2>/dev/null | grep -qE ":${p}\$"; then
                continue
            fi
            busy+=("$p")
        fi
    done
    if (( ${#busy[@]} > 0 )); then
        print_warn "$svc needs ports ${busy[*]} but they are already in use on the host."
        read -rp "$(print_info 'Continue anyway? (y/n): ')" ans || ans=""
        [[ "${ans,,}" == "y" ]] || return 1
    fi
    return 0
}

# Ask a yes/no question with an explicit default. Returns 0 for yes.
#
# Two things it deliberately does NOT do. It does not loop forever on a
# missing terminal — a provisioning script piping into this installer would
# hang, so no TTY means take the stated default and say so out loud. And it
# does not accept a bare Enter as agreement to something dangerous: the
# caller chooses the default, and for anything root-equivalent that default
# is 'n'.
prompt_yes_no() {
    local question="$1" default="${2:-y}" ans hint
    if [[ "${default,,}" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi

    if [[ ! -t 0 ]]; then
        print_info "$question ($hint) — no terminal attached, taking the default: $default"
        [[ "${default,,}" == "y" ]]
        return
    fi

    # The separating space lives OUTSIDE the command substitution. Inside it
    # depends on nothing eating trailing whitespace between print_info, echo
    # and $( ) — a live run showed the re-asked prompt losing it. Out here it
    # is part of the read prompt itself and cannot be lost.
    local prompt
    prompt="$(print_info "$question ($hint):")"
    while true; do
        read -rp "$prompt " ans || ans=""
        # Strip carriage returns and surrounding whitespace before matching.
        # `read -r` removes the newline but not a \r, so input that arrives
        # CRLF-terminated yields "y\r", which matches neither `y` nor `yes`
        # and is refused as though the user had typed something else. Seen
        # once in a live run: a `y` rejected, then the identical `y` accepted
        # on the retry. The cause was NOT proven, so this is not claimed as
        # the fix — it removes the one class of invisible input that would
        # produce exactly that symptom, and costs nothing if it was not.
        ans="${ans//$'\r'/}"
        ans="${ans#"${ans%%[![:space:]]*}"}"
        ans="${ans%"${ans##*[![:space:]]}"}"
        ans="${ans,,}"
        [[ -z "$ans" ]] && ans="${default,,}"
        case "$ans" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     print_warn "Please answer y or n." ;;
        esac
    done
}

# Run a command in the background with a spinner, then propagate its exit code.
run_with_spinner() {
    ("$@") >> "$LOGFILE" 2>&1 &
    local pid=$!
    spinner "$pid"
    wait "$pid"
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        # ${ID:-} , not $ID. Every mainstream distribution sets it, but the
        # file is not required to and a stripped container image may not.
        # Under `set -u` a bare $ID would abort the whole script with
        # "ID: unbound variable" — instead of falling through to the manual
        # picker below, which is the behaviour the README promises: "if
        # detection fails you get a manual picker, the install never silently
        # guesses wrong". ID_LIKE on the next branch was already guarded this
        # way; this one was not, which is what gave it away.
        case "${ID:-}" in
            ubuntu)
                [[ "$(uname -m)" == "aarch64" ]] && echo "ubuntu-arm64" || echo "ubuntu"
                ;;
            debian)
                echo "debian"
                ;;
            raspbian) echo "raspbian" ;;
            centos|fedora|rhel|rocky|almalinux) echo "centos" ;;
            arch) echo "arch" ;;
            opensuse-leap|opensuse-tumbleweed) echo "opensuse" ;;
            *)
                for like in ${ID_LIKE:-}; do
                    case "$like" in
                        debian) echo "debian"; return ;;
                        rhel|fedora) echo "centos"; return ;;
                    esac
                done
                echo "unknown"
                ;;
        esac
    else
        echo "unknown"
    fi
}

map_os() {
    case "$1" in
        debian|ubuntu) echo "debian" ;;
        ubuntu-arm64) echo "ubuntu-arm64" ;;
        raspbian) echo "raspbian" ;;
        centos) echo "centos" ;;
        arch) echo "arch" ;;
        opensuse) echo "opensuse" ;;
        *) echo "unknown" ;;
    esac
}

# Drawn here, before OS detection, and not again on the first menu pass.
# Detection can print a warning and open a manual picker, and a banner that
# arrived afterwards would wipe the very question the operator just answered.
dockhub_banner

DETECTED=$(detect_os)
OS=$(map_os "$DETECTED")
# Detection is deliberately silent on success — the banner directly above
# already printed the distribution, and saying it twice in two different
# formats invites the reader to wonder which one is authoritative. Failure
# still speaks, loudly, immediately below.
if [[ "$OS" == "unknown" ]]; then
    echo
    print_warn "Could not auto-detect your OS. Please choose manually."
    PS3="Select your OS: "
    options=(
        "Debian / Ubuntu (x86_64)"
        "Ubuntu (ARM64)"
        "Raspbian (ARM64)"
        "CentOS / Fedora / RHEL"
        "Arch Linux"
        "openSUSE"
        "Cancel"
    )
    select opt in "${options[@]}"; do
        case $REPLY in
            1) OS="debian"; break ;;
            2) OS="ubuntu-arm64"; break ;;
            3) OS="raspbian"; break ;;
            4) OS="centos"; break ;;
            5) OS="arch"; break ;;
            6) OS="opensuse"; break ;;
            7) exit 0 ;;
            *) print_error "Invalid selection." ;;
        esac
    done
fi

# --- Install deps ---
install_deps() {
    case "$OS" in
        debian|ubuntu-arm64|raspbian)
            DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$LOGFILE" 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget git ca-certificates >> "$LOGFILE" 2>&1
            ;;
        centos)
            if command -v dnf &>/dev/null; then
                dnf install -y curl wget git ca-certificates >> "$LOGFILE" 2>&1
            else
                yum install -y curl wget git ca-certificates >> "$LOGFILE" 2>&1
            fi
            ;;
        arch)
            pacman -Sy --noconfirm curl wget git ca-certificates >> "$LOGFILE" 2>&1
            ;;
        opensuse)
            zypper --non-interactive refresh >> "$LOGFILE" 2>&1
            zypper --non-interactive install -y curl wget git ca-certificates >> "$LOGFILE" 2>&1
            ;;
    esac
}

install_docker() {
    print_info "Installing Docker-CE... "
    # Use pipefail inside the subshell so a failing curl is detected.
    run_with_spinner bash -c "set -o pipefail; curl -fsSL https://get.docker.com | sh"
    systemctl enable --now docker >> "$LOGFILE" 2>&1
    usermod -aG docker "$REAL_USER" >> "$LOGFILE" 2>&1
    print_ok "Docker installed and '$REAL_USER' added to the 'docker' group."
}

install_compose() {
    # Docker's official installer already ships the compose plugin on most distros.
    if docker compose version &>/dev/null; then
        print_ok "Docker Compose plugin already present."
        return 0
    fi

    print_info "Installing Docker Compose plugin..."
    case "$OS" in
        arch)
            pacman -Sy --noconfirm docker-compose >> "$LOGFILE" 2>&1
            ;;
        centos)
            if command -v dnf &>/dev/null; then
                dnf install -y docker-compose-plugin >> "$LOGFILE" 2>&1
            else
                yum install -y docker-compose-plugin >> "$LOGFILE" 2>&1
            fi
            ;;
        opensuse)
            # openSUSE ships the v2 plugin as 'docker-compose'.
            zypper --non-interactive install -y docker-compose >> "$LOGFILE" 2>&1
            ;;
        debian|ubuntu-arm64|raspbian)
            DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin >> "$LOGFILE" 2>&1
            ;;
    esac

    if ! docker compose version &>/dev/null; then
        print_error "Docker Compose plugin did not install correctly."
        exit 1
    fi
    print_ok "Docker Compose is ready."
}

# --- One-time environment detection (home server vs VPS) -------------------
# Asked once, ever — the answer just decides which reminder text services/
# deploy.sh scripts print after deploying (e.g. the Cloudflare Tunnel +
# Force-SSL gotcha). It never gates or changes how anything actually
# deploys: main-net + NPM work identically either way. Skips silently if
# already answered (including after a Reset NPM & Portainer, which has
# nothing to do with network topology).
# The answers detect_environment() collects, kept for the rest of the run.
#
# They were being written to disk and never read back — not by this script,
# which is the one that asked. lib/common.sh has read_dockhub_env() for the
# service scripts, and this file cannot source it (see _host_lan_ip above for
# why), so the reader is duplicated here for the same reason.
#
# `grep -a` is not decoration: a plain grep over a file it decides is binary
# prints "Binary file … matches" and hands that back as the value.
DOCKHUB_ENVIRONMENT=""
DOCKHUB_ACCESS_METHOD=""
_read_dockhub_env() {
    local env_file="$REAL_HOME/docker/.dockhub-env"
    [[ -f "$env_file" ]] || return 0
    # `tr -d '\r'` because this file is plain text a user may well open in an
    # editor, and one saved with CRLF yields "tunnel\r", which matches neither
    # "tunnel" nor anything else — the value looks right in every dump and
    # silently fails every comparison. Same class as the carriage return that
    # made a typed `y` get rejected at a prompt. Cheap, and it removes a
    # failure that is invisible when you go looking for it.
    DOCKHUB_ENVIRONMENT=$(grep -a '^ENVIRONMENT=' "$env_file" 2>/dev/null | cut -d= -f2 | tr -d '\r')
    DOCKHUB_ACCESS_METHOD=$(grep -a '^ACCESS_METHOD=' "$env_file" 2>/dev/null | cut -d= -f2 | tr -d '\r')
}

detect_environment() {
    local env_file="$REAL_HOME/docker/.dockhub-env"
    # Already answered on a previous run: load it rather than returning blind.
    # The early return here is why every later warning in this file was generic.
    #
    # And SAY what was loaded. Neither "Reset" nor "Reconfigure" re-asks these
    # — this return fires first — and nothing in the project documented how to
    # change them. Someone who moves from direct exposure to a tunnel, or the
    # other way, would otherwise keep getting advice for an architecture they
    # no longer run, including the default for where NPM's admin panel listens.
    # These answers are inputs to everything printed below, so show them.
    if [[ -f "$env_file" ]]; then
        _read_dockhub_env
        if [[ -n "$DOCKHUB_ENVIRONMENT" ]]; then
            print_info "Using your saved answers: ${DOCKHUB_ENVIRONMENT}${DOCKHUB_ACCESS_METHOD:+ / $DOCKHUB_ACCESS_METHOD}"
            print_info "  Changed setup? Delete $env_file and rerun to answer again."
        fi
        return 0
    fi

    # No terminal: ask nothing, record nothing, and say so.
    #
    # The questions below now re-ask until they get a valid answer, which is
    # right at a keyboard and a hang anywhere else — `read` returns immediately
    # at EOF, the answer is empty, and the loop spins forever. This script is
    # meant to survive `curl ... | bash`, so that would be a hang on the very
    # first prompt. prompt_yes_no has guarded this from the start; these loops
    # were added later and did not copy it.
    #
    # Writing nothing is deliberate: an empty ENVIRONMENT recorded now would
    # look answered forever, because this function returns early whenever the
    # file exists. Leaving it absent means the next interactive run still asks.
    # Every later branch already treats "unknown" as its neutral case —
    # lib/common.sh states that rule for this exact value.
    if [[ ! -t 0 ]]; then
        print_info "No terminal attached — skipping the one-time environment questions."
        print_info "They only shape advice; run this interactively to record them."
        return 0
    fi

    dockhub_ask "One-time setup question: what kind of server is this?"
    dockhub_item 1 "Home server (behind a home router — no public IP guaranteed)"
    dockhub_item 2 "VPS / cloud server (has a public IP)"
    local choice environment access_method=""
    # Re-ask rather than falling through. This was `if 1 then home; else vps`,
    # so a bare Enter, a typo, or a "3" silently classified the host as a VPS
    # — and lib/common.sh's own note on this file says callers must treat an
    # unknown value as unknown and "never assume vps as a default". The rule
    # was being broken at the source that writes the file.
    while true; do
        read -rp "Choice [ 1-2 ]: " choice || choice=""
        choice="${choice//$'\r'/}"; choice="${choice//[[:space:]]/}"
        case "$choice" in
            1) environment="home"; break ;;
            2) environment="vps";  break ;;
            *) print_warn "Please answer 1 or 2." ;;
        esac
    done

    # ASKED FOR BOTH ENVIRONMENTS, and it used to be asked only for "home".
    #
    # That single `if` was the root of several wrong answers. It meant a VPS
    # could never record ACCESS_METHOD=tunnel, so the 31 service scripts that
    # end their summary with print_tunnel_reminder_if_relevant() were no-ops
    # for every VPS user — and this script, having no way to tell a tunnelled
    # host from a directly exposed one, assumed the second and told everyone to
    # open ports.
    #
    # The assumption is simply wrong. A tunnel is not a workaround for lacking
    # a public IP; on a VPS that has one it is the stronger option, because it
    # is the only way to have no inbound port at all — which also happens to be
    # the only arrangement Docker cannot publish its way past.
    dockhub_ask "How do you plan to reach your services from the internet?"
    if [[ "$environment" == "home" ]]; then
        dockhub_item 1 "Port forwarding (forward 80/443 on your router to this server)"
    else
        dockhub_item 1 "Directly (this host's public IP, with ports open to the internet)"
    fi
    dockhub_item 2 "Cloudflare Tunnel (no inbound ports opened at all)"
    local sub
    while true; do
        read -rp "Choice [ 1-2 ]: " sub || sub=""
        sub="${sub//$'\r'/}"; sub="${sub//[[:space:]]/}"
        case "$sub" in
            # "port_forward" for home, "direct" for a VPS: the same answer means
            # different work, and a VPS forwards nothing. Only "tunnel" is read
            # by anything today, but a value that lies is a trap for whoever
            # adds the next reader.
            1) [[ "$environment" == "home" ]] && access_method="port_forward" \
                                              || access_method="direct"; break ;;
            2) access_method="tunnel"; break ;;
            *) print_warn "Please answer 1 or 2." ;;
        esac
    done

    cat > "$env_file" <<EOF
ENVIRONMENT=$environment
ACCESS_METHOD=$access_method
EOF
    chown "$REAL_USER":"$REAL_GROUP" "$env_file" 2>/dev/null || true
    # Publish the fresh answers to the rest of this run too, so the first
    # install gets the same tailored advice a later one does.
    DOCKHUB_ENVIRONMENT="$environment"
    DOCKHUB_ACCESS_METHOD="$access_method"
    print_ok "Saved to $env_file — shapes the advice this script and the services/ deploy.sh scripts give you."

    # Branch on the ACCESS METHOD first, because it decides how many ports are
    # open — which is the thing all of this advice is actually about. The
    # environment then only changes the wording.
    echo
    if [[ "$access_method" == "tunnel" ]]; then
        print_info "Cloudflare Tunnel: 'cloudflared' dials OUT, so no inbound port is opened"
        print_info "at all. Install and configure it yourself — not automated here."
        echo
        print_info "  Route every hostname to NPM itself: Service URL 'http://localhost:80',"
        print_info "  never straight at a service's container. NPM reads the hostname and"
        print_info "  decides where it goes — that is its whole job."
        print_warn "  And leave Force SSL OFF on tunnel-routed Proxy Hosts. cloudflared"
        print_warn "  delivers plain HTTP by design; forcing a redirect fights Cloudflare's"
        print_warn "  own HTTPS and surfaces as '400 Request Header Or Cookie Too Large'."
        echo
        if [[ "$environment" == "vps" ]]; then
            # The real prize, and the reason a tunnel beats a firewall here: with
            # nothing bound to an external interface, Docker has nothing to
            # publish past ufw, and there is no allow-list to keep correct.
            print_info "  On a VPS this is the strongest posture available: your provider's"
            print_info "  firewall needs SSH and nothing else. Once it works, bind NPM to"
            print_info "  loopback in ~/docker/npm/docker-compose.yml as well —"
            print_info "  '127.0.0.1:80:80' and '127.0.0.1:81:81', dropping 443 — and reach"
            print_info "  the admin panel over an SSH tunnel:"
            echo "     ssh -L 8181:127.0.0.1:81 $REAL_USER@<this-server>"
            print_info "  A port bound to loopback is not blocked; it is not there."
        fi
        print_info "  See docs/cloudflare-tunnel.md."

    elif [[ "$environment" == "home" ]]; then
        print_warn "Remember to forward ports 80 and 443 on your router to this server's LAN IP."
        print_warn "No static public IP from your ISP? You'll also need Dynamic DNS."

    else
        # VPS, exposed directly. There was no branch here at all until now: home
        # got two, and the one environment with no NAT in front of it got
        # silence.
        print_info "Exposed directly, every published port is the public internet. The"
        print_info "posture that follows, and what the rest of this run assumes:"
        echo
        print_info "  Open exactly three: 80 and 443 for NGINX Proxy Manager to proxy and to"
        print_info "  issue certificates, and 81 for its admin panel. Nothing else."
        print_info "  Every other service — Portainer included — takes NO host port. It joins"
        print_info "  'main-net', and NPM reaches it by container name behind HTTPS."
        echo
        print_warn "Port 81 is the admin panel, and it ships with admin@example.com / changeme."
        print_warn "On this host that pair is reachable from the internet the moment NPM starts."
        print_warn "Change it before you do anything else."
        echo
        print_info "  And note ufw will not enforce any of this: Docker publishes past it."
        print_info "  Use your provider's firewall, or DOCKER-USER rules. See"
        print_info "  docs/troubleshooting.md."
    fi
}

# --- Core install/reset flow (called from the menu below) ---
run_core_install() {
    detect_environment

    # --- Check existing installations (we run as root, so no sudo needed) ---
    DOCKER_ACTIVE=false
    COMPOSE_INSTALLED=false

    if command -v docker &>/dev/null; then
        if systemctl is-active --quiet docker; then
            DOCKER_ACTIVE=true
        else
            print_warn "Docker is installed but not running. Attempting to start it..."
            systemctl enable --now docker >> "$LOGFILE" 2>&1 || true
            systemctl is-active --quiet docker && DOCKER_ACTIVE=true || true
        fi
    fi

    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        COMPOSE_INSTALLED=true
    fi

    # Choosing "Install / manage core infrastructure" from the menu already
    # is the confirmation — install the full bundle (whatever's missing)
    # without re-asking per component. Only skip pieces already active/present.
    echo
    if [[ "$DOCKER_ACTIVE" == true ]]; then
        print_ok "Docker is already installed and running."
        INSTALL_DOCKER="n"
    else
        print_info "Docker-CE will be installed."
        INSTALL_DOCKER="y"
    fi

    if [[ "$COMPOSE_INSTALLED" == true ]]; then
        print_ok "Docker Compose (plugin) is already installed."
        INSTALL_COMPOSE="n"
    else
        print_info "Docker Compose will be installed."
        INSTALL_COMPOSE="y"
    fi

    # Docker and Compose are settled above without a question, because there
    # is no version of this project that works without them — offering a
    # choice you cannot decline is theatre, not consent. These two are a
    # different matter: a host that only ever uses LAN ports needs neither.
    echo
    print_info "Docker is the foundation and is not optional. These two are:"
    if prompt_yes_no "  Install NGINX Proxy Manager? (domain names + free HTTPS)" y; then
        INSTALL_NPM="y"
    else
        INSTALL_NPM="n"
        print_info "  Skipped. Services will be reachable by host port only."
    fi

    # ── Where NPM's admin panel listens ──────────────────────────────────────
    #
    # This was published on every interface unconditionally, and never asked
    # about. Portainer — which is harder to abuse, because an attacker still has
    # to claim an account nobody has created — gets a whole paragraph, a default
    # of no, and a warning. NPM's admin panel ships with admin@example.com /
    # changeme, a pair printed in this project's own documentation, and got one
    # line telling you to change it later.
    #
    # There are deliberately only two answers, not three. "No port at all" is
    # the option that looks safest and is unusable: you cannot proxy the admin
    # panel behind NPM without first reaching the admin panel to configure it.
    # Loopback is the honest floor — invisible to every network, still reachable
    # over SSH, and it can never lock you out.
    NPM_ADMIN_BIND=""
    # Initialised here, not where it is measured. It is assigned inside the
    # install block, which `check_ports_or_warn` can skip entirely when a port
    # is already taken — while INSTALL_NPM stays "y", so the summary still reads
    # it. Under `set -Eeuo pipefail` an unset read aborts the run, and it would
    # abort at the summary: work finished, then the script dies reporting it.
    # That is the exact failure this script already shipped once.
    NPM_ADMIN_BOUND=""
    if [[ "$INSTALL_NPM" == "y" ]]; then
        echo
        local admin_default="y"
        if [[ "$DOCKHUB_ACCESS_METHOD" == "tunnel" ]]; then
            # Nothing needs to reach it over the network: cloudflared talks to
            # NPM over loopback, and the panel itself goes behind a Proxy Host.
            admin_default="n"
            print_info "  You chose a tunnel, so nothing needs to reach this host directly."
        elif [[ "$DOCKHUB_ENVIRONMENT" == "vps" ]]; then
            print_warn "  NPM's admin panel ships with admin@example.com / changeme, and on a"
            print_warn "  VPS a published port is the public internet. Those credentials are"
            print_warn "  in this project's README — assume they are already known."
        fi
        print_info "  Saying no binds it to 127.0.0.1, reachable only over an SSH tunnel:"
        echo "     ssh -L 8181:127.0.0.1:$NPM_ADMIN_PORT $REAL_USER@<this-server>"
        if prompt_yes_no "  Publish NPM's admin panel (port $NPM_ADMIN_PORT) on this host's interfaces?" "$admin_default"; then
            NPM_ADMIN_BIND=""
            [[ "$DOCKHUB_ENVIRONMENT" == "vps" ]] && \
                print_warn "  Published. Change those credentials before you do anything else."
        else
            NPM_ADMIN_BIND="127.0.0.1:"
            print_ok "  Admin panel bound to 127.0.0.1 only."
        fi
    fi
    if prompt_yes_no "  Install Portainer CE? (web view of your containers)" y; then
        INSTALL_PORTAINER="y"
    else
        INSTALL_PORTAINER="n"
    fi

    # Whether Portainer gets a host port is a separate, harder question than
    # whether to install it. It mounts the Docker socket, so reaching its web
    # UI is equivalent to root on this host. Vaultwarden had its host-port
    # option removed outright for being a password store; Portainer is the
    # more dangerous of the two and kept its ports open by default. That was
    # an inconsistency in this project, not a considered decision.
    PORTAINER_PUBLISH="n"
    if [[ "$INSTALL_PORTAINER" == "y" ]]; then
        echo
        print_warn "Portainer mounts /var/run/docker.sock. Anything that reaches its web"
        print_warn "interface can start a container as root on this host. It is not a"
        print_warn "dashboard — it is a key to the machine."
        echo
        print_info "  Saying no keeps it on 'main-net' only, reachable by container name."
        print_info "  You then publish it deliberately, behind NGINX Proxy Manager and HTTPS."
        if prompt_yes_no "  Publish Portainer's ports on this host anyway?" n; then
            PORTAINER_PUBLISH="y"
            # This said "On a VPS that is the internet" to everyone, which is
            # both alarmist for one reader and wrong for the other — and it was
            # unnecessary, because THIS SCRIPT ALREADY KNOWS. detect_environment()
            # asked the question minutes ago and wrote the answer to
            # ~/docker/.dockhub-env; nothing here ever read it back. The advice
            # is now the answer the user actually gave.
            print_warn "  Ports will be published on ALL interfaces, IPv4 and IPv6."
            case "$DOCKHUB_ENVIRONMENT" in
                vps)
                    print_warn "  You told this script this is a VPS. That means the public internet,"
                    print_warn "  right now, on a service that is root on this machine."
                    ;;
                home)
                    # NAT is real protection for IPv4 and it is fair to say so.
                    # What it does not cover is the LAN itself, and it does not
                    # exist for IPv6 — where a global address is reachable unless
                    # the router blocks inbound, which this script cannot see.
                    print_warn "  You told this script this is a home server, so NAT keeps IPv4 off"
                    print_warn "  the internet unless you forwarded this port — but every device on"
                    print_warn "  your LAN reaches it, guests and IoT included."
                    if hostname -I 2>/dev/null | tr ' ' '\n' | grep -qiE '^[23][0-9a-f]{3}:'; then
                        print_warn "  This host also has a GLOBAL IPv6 address, and IPv6 has no NAT."
                        print_warn "  There, only your router's inbound firewall is in the way."
                    fi
                    ;;
                *)  print_warn "  On a VPS that is the internet." ;;
            esac
        else
            print_ok "  Portainer will have no host ports."
        fi
    fi

    # Only touch the package manager if we're actually about to install something —
    # an all-already-installed rerun (e.g. just adding NPM/Portainer later) should
    # not force an apt-get update/install every time.
    if [[ "${INSTALL_DOCKER,,}" == "y" || "${INSTALL_COMPOSE,,}" == "y" ]]; then
        install_deps
    fi

    if [[ "${INSTALL_DOCKER,,}" == "y" ]]; then
        install_docker
    fi

    if [[ "${INSTALL_COMPOSE,,}" == "y" ]]; then
        install_compose
    fi

    if ! systemctl is-active --quiet docker; then
        print_error "Docker service is not running. Aborting."
        exit 1
    fi

    # Ensure the real user is in the docker group (idempotent). Skip for pure root.
    if [[ "$REAL_USER" != "root" ]]; then
        if ! id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx docker; then
            usermod -aG docker "$REAL_USER" >> "$LOGFILE" 2>&1
            print_info "Added '$REAL_USER' to the 'docker' group."
        fi
    else
        print_warn "Running as pure root (no SUDO_USER). Skipping docker group setup."
    fi

    # Create shared docker network.
    if ! docker network ls --format '{{.Name}}' | grep -qx "main-net"; then
        # '|| true': another service's deploy.sh may win a create race between the
        # check above and this line — that's harmless, but re-verify below so a
        # genuine failure (permissions, daemon issue) doesn't get reported as OK.
        docker network create main-net >> "$LOGFILE" 2>&1 || true
        if docker network ls --format '{{.Name}}' | grep -qx "main-net"; then
            print_ok "Created docker network 'main-net'."
        else
            print_error "Failed to create docker network 'main-net'. Check log: $LOGFILE"
            exit 1
        fi
    fi

    if [[ "${INSTALL_NPM,,}" == "y" ]]; then
    # 'npm-app-1' is what Compose names the 'app' service in the 'npm' folder.
    # If a future Compose names it differently the lookup simply fails and we
    # get the old, noisier behaviour — never a wrong one.
    if check_ports_or_warn "NGINX Proxy Manager" "npm-app-1" "$NPM_HTTP_PORT" "$NPM_HTTPS_PORT" "$NPM_ADMIN_PORT"; then
        print_info "Installing NGINX Proxy Manager ($NPM_IMAGE)..."
        NPM_DIR="$REAL_HOME/docker/npm"
        mkdir -p "$NPM_DIR"

        if [[ -f "$NPM_DIR/docker-compose.yml" ]]; then
            print_warn "Existing docker-compose.yml found at $NPM_DIR — keeping it (not overwritten)."
        else
            # Unquoted heredoc so env-var-configured ports/image are substituted.
            # NPM is attached to 'main-net' so other containers can be proxied by hostname.
            cat > "$NPM_DIR/docker-compose.yml" <<YAML
services:
  app:
    image: '$NPM_IMAGE'
    restart: unless-stopped
    ports:
      - '$NPM_HTTP_PORT:80'
      - '$NPM_HTTPS_PORT:443'
      # 80 and 443 stay on every interface: they are how NPM proxies and how
      # Let's Encrypt validates. The admin panel is a separate question, and
      # NPM_ADMIN_BIND carries the answer — empty for every interface, or
      # '127.0.0.1:' for loopback only. Change it here and recreate the
      # container; editing the mapping needs a new one, so 'up -d' alone will
      # report Started and change nothing. Use --force-recreate.
      - '$NPM_ADMIN_BIND$NPM_ADMIN_PORT:81'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - main-net
    healthcheck:
      test: ["CMD", "/usr/bin/check-health"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  main-net:
    external: true
YAML
        fi

        # Targeted chown: only the NPM directory (~/docker itself was already
        # created/chowned once, up top).
        chown -R "$REAL_USER":"$REAL_GROUP" "$NPM_DIR"

        (cd "$NPM_DIR" && docker compose up -d) >> "$LOGFILE" 2>&1
        # docker compose up creates ./data and ./letsencrypt (bind mount
        # targets) if they don't exist yet -- since the daemon runs as
        # root, those two folders come out root-owned even though we just
        # chowned everything else. Re-chown now that they exist so the
        # real user can actually manage their own NPM data/certs later.
        chown -R "$REAL_USER":"$REAL_GROUP" "$NPM_DIR"
        sleep 3
        if (cd "$NPM_DIR" && docker compose ps --status=running --quiet | grep -q .); then
            print_ok "NGINX Proxy Manager is running."
        else
            print_warn "NPM started but no running container detected. Check: (cd $NPM_DIR && docker compose logs)"
        fi

        # Verify what was actually published rather than trusting the answer
        # given a minute ago. An existing docker-compose.yml is reused, never
        # overwritten — deliberately, so manual edits survive — which means a
        # rerun can accept "bind it to loopback" and change nothing at all.
        # Portainer has carried this check for a while; the admin panel, which
        # ships with published credentials, had none.
        NPM_ADMIN_BOUND=$(docker port npm-app-1 "81/tcp" 2>/dev/null | tr '\n' ' ' || true)
        if [[ -n "$NPM_ADMIN_BIND" && "$NPM_ADMIN_BOUND" == *"0.0.0.0"* ]]; then
            print_warn "You asked for the admin panel on loopback, but it is published on:"
            print_warn "  $NPM_ADMIN_BOUND"
            print_warn "That came from the existing $NPM_DIR/docker-compose.yml, which is kept"
            print_warn "rather than overwritten. Change the '81' line to '127.0.0.1:$NPM_ADMIN_PORT:81' and run:"
            echo   "     cd $NPM_DIR && docker compose up -d --force-recreate"
            print_warn "  A port change needs a NEW container — 'up -d' alone reports Started and does nothing."
        elif [[ -z "$NPM_ADMIN_BIND" && "$NPM_ADMIN_BOUND" == *"127.0.0.1"* ]]; then
            print_warn "You asked for the admin panel to be published, but it is bound to loopback."
            print_warn "That also came from the kept $NPM_DIR/docker-compose.yml."
            print_info "  Reach it meanwhile with: ssh -L 8181:127.0.0.1:$NPM_ADMIN_PORT $REAL_USER@<this-server>"
        fi
    else
        print_warn "Skipping NPM installation due to port conflicts."
        INSTALL_NPM="n"
    fi
fi

if [[ "${INSTALL_PORTAINER,,}" == "y" ]]; then
    # Only a published port can collide with something. With no ports there is
    # nothing to check, and asking about a conflict that cannot happen would
    # be one more question that means nothing.
    PORTAINER_PORTS_FREE=true
    if [[ "$PORTAINER_PUBLISH" == "y" ]]; then
        check_ports_or_warn "Portainer-CE" "portainer" "$PORTAINER_EDGE_PORT" "$PORTAINER_HTTP_PORT" "$PORTAINER_HTTPS_PORT" \
            || PORTAINER_PORTS_FREE=false
    fi
    if [[ "$PORTAINER_PORTS_FREE" == true ]]; then
        print_info "Installing Portainer-CE ($PORTAINER_IMAGE)..."
        PORTAINER_DIR="$REAL_HOME/docker/portainer"
        mkdir -p "$PORTAINER_DIR"

        # An existing compose file is reused, never overwritten — that promise
        # is in the README and it stays. But if the file on disk publishes
        # ports while the operator just asked for none, honouring the file
        # silently exposes a root-equivalent service against an explicit
        # instruction given seconds earlier. Warning afterwards, as this did
        # at first, tells you about it only once it is already listening.
        # So: detect it before deploying, ask, and keep a backup either way.
        if [[ -f "$PORTAINER_DIR/docker-compose.yml" && "$PORTAINER_PUBLISH" == "n" ]]; then
            # Lines inside the ports: block that are not bound to loopback.
            EXPOSED=$(awk '
                /^[[:space:]]*ports:/        { inp = 1; next }
                /^[[:space:]]*[a-z_]+:/      { inp = 0 }
                inp && /^[[:space:]]*-/      { print }
            ' "$PORTAINER_DIR/docker-compose.yml" | grep -v '127\.0\.0\.1' || true)

            if [[ -n "${EXPOSED//[$' \t\n']/}" ]]; then
                echo
                print_warn "The existing $PORTAINER_DIR/docker-compose.yml publishes:"
                printf '%s\n' "$EXPOSED" | sed 's/^/      /'
                print_warn "You just asked for no host ports. Deploying this file as-is would"
                print_warn "expose Portainer anyway."
                if prompt_yes_no "  Rewrite it without ports? (the current file is backed up)" y; then
                    PORTAINER_BAK="$PORTAINER_DIR/docker-compose.yml.bak.$(date +%Y%m%d-%H%M%S)"
                    cp -a "$PORTAINER_DIR/docker-compose.yml" "$PORTAINER_BAK"
                    rm -f "$PORTAINER_DIR/docker-compose.yml"
                    print_ok "  Backed up to $(basename "$PORTAINER_BAK") — a fresh file will be written."
                else
                    print_warn "  Keeping your file. Portainer WILL publish those ports."
                fi
            fi
        fi

        if [[ "$PORTAINER_PUBLISH" == "y" ]]; then
            PORTAINER_PORTS_BLOCK="    ports:
      - '$PORTAINER_EDGE_PORT:8000'
      - '$PORTAINER_HTTP_PORT:9000'
      - '$PORTAINER_HTTPS_PORT:9443'"
        else
            PORTAINER_PORTS_BLOCK="    # No host ports, by choice at install time. Portainer is reachable
    # only on 'main-net', by the container name 'portainer'. To open it:
    # add a Proxy Host in NGINX Proxy Manager pointing at portainer:9000
    # over http — NPM terminates TLS, so 9443 is not needed. Add the ports
    # back here and 'docker compose up -d' if you change your mind."
        fi

        if [[ -f "$PORTAINER_DIR/docker-compose.yml" ]]; then
            print_warn "Existing docker-compose.yml found at $PORTAINER_DIR — keeping it (not overwritten)."
        else
            # NOTE on the healthcheck: the default (non-alpine) portainer-ce
            # image ships no /bin/sh at all. `docker run --health-cmd` has
            # no way to avoid wrapping the check in CMD-SHELL (i.e. `sh -c
            # ...`), so that form ALWAYS fails on this image with "exec:
            # /bin/sh: no such file or directory" -- reporting a perfectly
            # working container as "unhealthy". Compose's array/exec form
            # (["CMD", "wget", ...]) execs wget directly, no shell involved,
            # so it works correctly. `wget --spider`'s own exit code is
            # already 0/1, so no `|| exit 1` shell logic is needed either.
            cat > "$PORTAINER_DIR/docker-compose.yml" <<YAML
services:
  portainer:
    image: '$PORTAINER_IMAGE'
    container_name: portainer
    command:
      - --no-setup-token
    restart: always
$PORTAINER_PORTS_BLOCK
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks:
      - main-net

volumes:
  portainer_data:
    external: true

networks:
  main-net:
    external: true
YAML
        fi

        # Pre-existing external volume so upgrades from older (docker run
        # -v portainer_data:/data) installs keep their data untouched.
        docker volume create portainer_data >> "$LOGFILE" 2>&1

        chown -R "$REAL_USER":"$REAL_GROUP" "$PORTAINER_DIR"

        (cd "$PORTAINER_DIR" && docker compose up -d) >> "$LOGFILE" 2>&1
        chown -R "$REAL_USER":"$REAL_GROUP" "$PORTAINER_DIR"
        sleep 3
        if (cd "$PORTAINER_DIR" && docker compose ps --status=running --quiet | grep -q .); then
            print_ok "Portainer-CE is running."
            # Verify what was actually published rather than trusting the
            # compose file we just wrote. A stale docker-compose.yml from an
            # earlier install is reused, not overwritten — so the answer given
            # a minute ago may not be the answer that is running.
            PORTAINER_BOUND=$(docker port portainer 2>/dev/null | tr '\n' ' ' || true)
            if [[ -n "${PORTAINER_BOUND// /}" ]]; then
                print_warn "Portainer is publishing: $PORTAINER_BOUND"
                # NOT just "firewall it", which is what this said and which sends
                # the reader straight to ufw — where it does nothing. Docker
                # publishes a port by DNAT in PREROUTING and filters it in
                # FORWARD via the DOCKER chain; ufw's rules live in INPUT and
                # never see the packet. Verified on a live host: three ufw rules
                # denying 9000 while DOCKER-USER sat completely empty and the
                # port stayed open. Naming the wrong remedy is worse than naming
                # none, because the user stops looking.
                print_warn "UFW WILL NOT BLOCK THIS. Docker publishes past it — a 'ufw deny 9000'"
                print_warn "looks applied and changes nothing. Either add a DOCKER-USER rule, or"
                print_warn "rerun this script, pick Reconfigure, and answer no to publishing."
                # Name the exposure instead of leaving the reader to notice
                # "[::]" in a list of port mappings. A global v6 address here
                # means the bind is reachable from outside unless the router
                # blocks it — and if Portainer's data was just wiped, its admin
                # account is unclaimed, so the first visitor to arrive owns it.
                if [[ "$PORTAINER_BOUND" == *"[::]"* ]] \
                   && hostname -I 2>/dev/null | tr ' ' '\n' | grep -qiE '^[23][0-9a-f]{3}:'; then
                    print_warn "This host has a GLOBAL IPv6 address and Portainer is bound on [::]."
                    print_warn "IPv6 is not behind NAT. Confirm your router blocks inbound v6, or"
                    print_warn "restrict the port now — and create the admin account before anyone else."
                fi
                [[ "$PORTAINER_PUBLISH" == "n" ]] && \
                    print_warn "You asked for no ports — this came from an existing docker-compose.yml at $PORTAINER_DIR."
            else
                print_ok "Portainer publishes no host ports — reachable on main-net as 'portainer'."
            fi
        else
            print_warn "Portainer started but no running container detected. Check: (cd $PORTAINER_DIR && docker compose logs)"
        fi
    else
        print_warn "Skipping Portainer installation due to port conflicts."
        INSTALL_PORTAINER="n"
    fi
fi

# --- Summary ---
echo
# A live run declined both optional components immediately after a reset had
# removed them, and this line still said "Installation completed
# successfully!" — congratulating the operator for ending up with less than
# they started with. Reporting success over an empty action is the exact
# failure this project names on its own front page.
CORE_CHANGED=false
[[ "${INSTALL_DOCKER,,}"    == "y" || "${INSTALL_COMPOSE,,}"   == "y" \
|| "${INSTALL_NPM,,}"       == "y" || "${INSTALL_PORTAINER,,}" == "y" ]] && CORE_CHANGED=true

if [[ "$CORE_CHANGED" == true ]]; then
    print_ok "Installation completed successfully!"
else
    print_warn "Nothing was installed — you declined both optional components."
    if [[ "${DID_RESET:-false}" == true ]]; then
        print_warn "The reset had already removed NPM and Portainer, so this host now has"
        print_warn "neither. Rerun and answer yes if that is not what you meant."
    fi
    echo
    print_info "Docker and the 'main-net' network are in place, which is all a service"
    print_info "actually needs. Deploy one with:  bash services/services.sh"
fi
echo

# `|| true` because this whole block is only a printed summary. The install has
# already finished by the time we get here, and the previous failure mode was
# exactly this: the work succeeded, then the script died reporting it, which
# reads to the user as a failed install. A summary must never be able to fail
# the run it is summarising.
SERVER_IP=$(_host_lan_ip || true)
[[ -z "${SERVER_IP:-}" ]] && SERVER_IP="<your-server-ip>"

# Gather additional non-loopback, non-docker-bridge IPs for the summary.
ALL_IPS=$(hostname -I 2>/dev/null \
    | tr ' ' '\n' \
    | grep -v '^$' \
    | grep -Ev '^(127\.|169\.254\.|172\.1[7-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)' \
    || true)

if [[ "${INSTALL_NPM,,}" == "y" ]]; then
    echo "-> NGINX Proxy Manager:"
    # Branch on the binding that was actually written, not on the environment
    # or the access method. Those only supplied the default; the user may have
    # answered against it, and a summary that prints http://<ip>:81 for a
    # loopback-bound panel hands out a dead link at the exact moment someone
    # has to change a default password — which is how it stops being changed.
    # Prefer the MEASURED binding over the answer. They can disagree — a kept
    # docker-compose.yml wins over anything asked this run — and the summary
    # must describe the server that exists, not the one that was requested.
    if [[ "$NPM_ADMIN_BOUND" == *"127.0.0.1"* ]] \
       || { [[ -z "$NPM_ADMIN_BOUND" ]] && [[ -n "$NPM_ADMIN_BIND" ]]; }; then
        echo "   Bound to 127.0.0.1 — reach it over an SSH tunnel:"
        echo "     ssh -L 8181:127.0.0.1:$NPM_ADMIN_PORT $REAL_USER@$SERVER_IP"
        echo "   then open http://localhost:8181"
    else
        echo "   URL:      http://$SERVER_IP:$NPM_ADMIN_PORT"
    fi
    echo "   Username: admin@example.com"
    echo "   Password: changeme"
    print_warn "Change the default NPM credentials immediately after first login."
    echo
fi

if [[ "${INSTALL_PORTAINER,,}" == "y" ]]; then
    echo "-> Portainer-CE:"
    if [[ "$PORTAINER_PUBLISH" == "y" ]]; then
        echo "   URL (HTTP):  http://$SERVER_IP:$PORTAINER_HTTP_PORT"
        echo "   URL (HTTPS): https://$SERVER_IP:$PORTAINER_HTTPS_PORT"
        echo "   (Create the admin account on first login — before anyone else does)"
    else
        echo "   No host port. Reachable on 'main-net' as: portainer:9000"
        if [[ "${INSTALL_NPM,,}" == "y" ]]; then
            echo "   To open it, add a Proxy Host in NGINX Proxy Manager:"
            echo "     Forward Hostname / IP : portainer"
            echo "     Forward Port          : 9000"
            echo "     Scheme                : http     (NPM handles the HTTPS)"
        else
            echo "   You declined NPM, so nothing can reach it yet. Either install NPM,"
            echo "   or add the ports back in $REAL_HOME/docker/portainer/docker-compose.yml."
        fi
        echo "   Whichever you choose, the admin account is claimed by the first"
        echo "   visitor — reach it yourself before it is reachable by anyone else."
    fi
    echo
fi

# If the host has more than one reachable IP, show them so the user picks the right one.
if [[ -n "$ALL_IPS" ]] && (( $(echo "$ALL_IPS" | wc -l) > 1 )); then
    echo "Reachable host IPs (pick the one matching your network):"
    while IFS= read -r ip; do echo "   - $ip"; done <<< "$ALL_IPS"
    echo
fi

echo "Log file: $LOGFILE"
[[ -f "$LOGFILE.old" ]] && echo "Previous log:  $LOGFILE.old"
echo

# Firewalld hint (Docker bypasses ufw via DOCKER-USER, but firewalld can still block).
#
# This printed one suggestion to everyone, which on a VPS amounted to telling
# the user to open the NPM admin panel — and its published default credentials
# — to the internet, with no caveat. The advice now follows the environment
# they declared.
if systemctl is-active --quiet firewalld 2>/dev/null; then
    print_warn "firewalld is active. If you cannot reach the services, open the ports, e.g.:"
    if [[ "${INSTALL_NPM,,}" == "y" ]]; then
        if [[ "$DOCKHUB_ENVIRONMENT" == "vps" ]]; then
            # 80/443 must be public: that is how NPM proxies and how ACME
            # validates. The admin panel is a different question entirely.
            echo "   sudo firewall-cmd --permanent --add-port=$NPM_HTTP_PORT/tcp --add-port=$NPM_HTTPS_PORT/tcp"
            print_warn "  Port $NPM_ADMIN_PORT is the ADMIN PANEL, shipping admin@example.com / changeme."
            print_warn "  Restrict it to your own address rather than opening it:"
            echo "   sudo firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=YOUR.IP.HERE port port=$NPM_ADMIN_PORT protocol=tcp accept'"
            echo "   # or open nothing and tunnel:  ssh -L $NPM_ADMIN_PORT:127.0.0.1:$NPM_ADMIN_PORT $REAL_USER@$SERVER_IP"
        else
            echo "   sudo firewall-cmd --permanent --add-port=$NPM_HTTP_PORT/tcp --add-port=$NPM_HTTPS_PORT/tcp --add-port=$NPM_ADMIN_PORT/tcp"
        fi
    fi
    if [[ "${INSTALL_PORTAINER,,}" == "y" && "$PORTAINER_PUBLISH" == "y" ]]; then
        if [[ "$DOCKHUB_ENVIRONMENT" == "vps" ]]; then
            print_warn "  Portainer is published on a VPS. It holds the Docker socket, so do not"
            print_warn "  open it — put it behind NPM. Rerun this script, pick Reconfigure, and"
            print_warn "  answer no to publishing its ports."
        else
            echo "   sudo firewall-cmd --permanent --add-port=$PORTAINER_HTTP_PORT/tcp --add-port=$PORTAINER_HTTPS_PORT/tcp"
        fi
    fi
    echo "   sudo firewall-cmd --reload"
fi

[[ "$REAL_USER" != "root" ]] && \
    print_warn "Log out and back in (or reboot) so '$REAL_USER' can use docker without sudo."

exit 0
}

# --- Reset flow: NPM + Portainer only. Never touches Docker Engine, Compose,
# main-net, or any other running container/service (confirmed scope). ---
reset_npm_portainer() {
    local wipe_data
    read -rp "Also permanently delete NPM/Portainer data (proxy configs, SSL certs, Portainer users/settings)? (y/N): " wipe_data || wipe_data="n"

    local npm_dir="$REAL_HOME/docker/npm"
    local portainer_dir="$REAL_HOME/docker/portainer"

    if [[ -d "$npm_dir" ]]; then
        print_info "Stopping and removing the NPM container..."
        (cd "$npm_dir" && docker compose down) >> "$LOGFILE" 2>&1 || true
        rm -f "$npm_dir/docker-compose.yml"
        if [[ "${wipe_data,,}" == "y" ]]; then
            rm -rf "$npm_dir/data" "$npm_dir/letsencrypt"
            print_warn "Deleted NPM data (proxy configs, SSL certs)."
        fi
    fi

    if [[ -d "$portainer_dir" ]]; then
        print_info "Stopping and removing the Portainer container..."
        (cd "$portainer_dir" && docker compose down) >> "$LOGFILE" 2>&1 || true
        rm -f "$portainer_dir/docker-compose.yml"
        if [[ "${wipe_data,,}" == "y" ]]; then
            docker volume rm -f portainer_data >> "$LOGFILE" 2>&1 || true
            print_warn "Deleted Portainer data (users, stacks, settings)."
        fi
    fi

    # Not "reinstalling fresh" — the questions that follow may decline both,
    # and a message that promises an install the user then refuses is a lie
    # the script tells itself.
    DID_RESET=true
    print_ok "NPM and Portainer removed. You will now be asked which to reinstall."
}

core_menu() {
    while true; do
        local core_installed=false
        if command -v docker &>/dev/null && systemctl is-active --quiet docker \
            && docker compose version &>/dev/null \
            && [[ -f "$REAL_HOME/docker/npm/docker-compose.yml" ]] \
            && [[ -f "$REAL_HOME/docker/portainer/docker-compose.yml" ]]; then
            core_installed=true
        fi

        if [[ "$core_installed" == true ]]; then
            echo
            print_ok "Core infrastructure is already installed (Docker, Compose, NPM, Portainer)."
            # Option 2 exists because making Portainer's ports a choice created
            # a trap: once both are installed, the only route back to that
            # question was a reset that tears down both services first. Being
            # asked to demolish a thing in order to reconfigure it is not a
            # choice anyone should have to make.
            dockhub_ask "Core infrastructure — what would you like to do?"
            dockhub_item 1 "Reset NPM & Portainer  (stop and recreate them; data wipe asked separately)"
            dockhub_item 2 "Reconfigure            (keep them running; answer the install questions again)"
            dockhub_item 0 "Back to main menu"
            local choice
            read -rp "Choice [ 0-2 ]: " choice || exit 0
            case "$choice" in
                1) reset_npm_portainer; run_core_install; return ;;
                2) run_core_install; return ;;
                0) return ;;
                *) echo "Invalid choice." ;;
            esac
        else
            run_core_install
            return
        fi
    done
}

# --- Services menu: hands off to services/services.sh if this script lives
# inside a full repo checkout; otherwise prints how to fetch it standalone. ---
show_services_menu() {
    local script_dir services_sh
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    services_sh="$script_dir/services/services.sh"

    if [[ "$REAL_USER" == "root" ]]; then
        print_warn "This script is running as pure root (no regular sudo user to drop to)."
        print_warn "services/deploy.sh scripts refuse to run as root by design — log in as a"
        print_warn "regular user in the 'docker' group and run services/services.sh yourself."
        return
    fi

    if [[ -f "$services_sh" ]]; then
        # Drop from root back to the invoking user: deploy.sh scripts refuse
        # to run as root by design. 'sudo -u' (not 'su') re-checks group
        # membership fresh from /etc/group, so this picks up a 'docker' group
        # add from earlier in *this same run* without needing a re-login.
        # 'bash <file>' instead of exec'ing it directly: a fresh git clone
        # doesn't guarantee the executable bit survived, and this works
        # either way.
        exec sudo -u "$REAL_USER" -H bash "$services_sh"
    fi
    echo
    print_info "Download the services picker and run it as your regular user (not root):"
    echo "  curl -fsSL -o services.sh https://raw.githubusercontent.com/IbrahimAljuhani/dockhub/main/services/services.sh"
    echo "  bash services.sh"
    echo "(Or browse services/ in the repo and run any <service>/deploy.sh directly.)"
}

main_menu() {
    # Clear on success, never on error. A valid choice is a step forward and
    # earns a clean screen; an invalid one leaves "Invalid choice." where it
    # can be read. The same reasoning keeps the banner out of every error
    # path in this script: the text on screen after a failure is the
    # diagnosis, and wiping it costs more than the tidiness is worth.
    #
    # Starts at 0 because the banner is already on screen from before OS
    # detection, and redrawing it now would erase that detection's output —
    # including the manual OS picker, if it ran.
    local redraw=0
    while true; do
        (( redraw )) && dockhub_banner
        redraw=1
        dockhub_ask "What would you like to do?"
        dockhub_item 1 "Install / manage core infrastructure (Docker CE, Compose, NPM, Portainer)"
        dockhub_item 2 "Install a service"
        dockhub_item 0 "Exit"
        local choice
        read -rp "Choice [ 0-2 ]: " choice || exit 0
        case "$choice" in
            # core_menu only ever returns here via its own "back to main menu"
            # choice (every other path inside it ends the script via exit 0
            # in run_core_install) — so loop back and show this menu again.
            1) core_menu ;;
            2) show_services_menu; return ;;
            0) exit 0 ;;
            *) echo "Invalid choice."; redraw=0 ;;
        esac
    done
}

main_menu

#!/bin/bash
# lib/banner.sh — the masthead and the screen-clearing rule.
#
# Deliberately its own file rather than part of lib/common.sh. Both entry
# points need it, but install_dockhub.sh is standalone by design: it defines
# its own print_info/print_warn writing "[INFO]" to stdout, while common.sh's
# write "[✓]" to stderr. Sourcing common.sh there to reach one function would
# silently rewrite every line the installer prints. This file defines four
# `dockhub_*` functions and some `_BN_*` colour variables, and touches
# nothing else, so either script can take it safely.
#
# Sourced with a guard, never required:
#     [[ -f "$DIR/lib/banner.sh" ]] && source "$DIR/lib/banner.sh"
# A missing banner must never be the reason a deploy fails — but note that
# both callers give `dockhub_ask`/`dockhub_item` real uncoloured fallbacks
# rather than no-ops. A missing masthead is cosmetic; a missing menu is not.

# ── The palette ─────────────────────────────────────────────────────────
# Local names, so nothing here collides with a caller's own colours.
#
# The brand tokens are exact hex values, so this asks for exact hex when the
# terminal can render it. The 256-colour approximations are visibly off —
# 209 is #FF875F where signal is #F0714A — so they are the fallback, not the
# default. COLORTERM is the only portable signal for 24-bit support; a
# terminal that lies about it renders a nearby colour, which is the same
# outcome as not asking.
if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
    _BN_SIG=$'\033[38;2;240;113;74m'    # --signal  #F0714A
    _BN_BEA=$'\033[38;2;85;188;176m'    # --beacon  #55BCB0
    _BN_RED=$'\033[38;2;229;72;77m'     #           #E5484D — leaving, not a brand moment
else
    _BN_SIG=$'\033[38;5;209m'
    _BN_BEA=$'\033[38;5;79m'
    _BN_RED=$'\033[38;5;203m'
fi
_BN_DIM=$'\033[2m'
_BN_B=$'\033[1m'
_BN_0=$'\033[0m'

# ── The clearing rule, in one place ─────────────────────────────────────
# Clears ONLY when clearing is safe:
#   · a real terminal (never when piped to a file, a log, or `tee`)
#   · not switched off by the operator
#   · called from a success path — enforced by the caller, because only the
#     caller knows whether the thing it just did worked
#
# The rule this obeys: clear on success, NEVER on error. The text on screen
# after a failure is the diagnosis; this project's entire method is reading
# it and pasting it back. A tidy screen that ate the error is worth less
# than the mess that kept it.
dockhub_clear() {
    [[ -t 1 ]] || return 0
    [[ "${DOCKHUB_NO_CLEAR:-0}" == "1" ]] && return 0
    printf '\033[2J\033[3J\033[H'
}

# ── The masthead ────────────────────────────────────────────────────────
# The mark is the full one drawn in text — the hexagon hub with its six
# service nodes, cargo knocked out of the hull, top bar in signal orange.
# Not the micro tier: a terminal has room for the real thing, so the shell
# and the website show the same mark rather than two cousins.
#
# Everything under it is a fact read from this host at this moment. Nothing
# is decorative and nothing is assumed — a field that cannot be determined
# says so rather than guessing.
#
# $1 = optional subtitle (e.g. "core infrastructure").
dockhub_banner() {
    local subtitle="${1:-}" home user os kernel arch mem_t mem_f disk dock cnt svc
    dockhub_clear

    # Do not re-derive who this is — the project already answers it twice.
    # install_dockhub.sh resolves REAL_USER/REAL_HOME because it runs as root
    # and must target the invoking user; services.sh and every deploy.sh just
    # use $HOME, because the handoff is `exec sudo -u <user> -H`.
    #
    # An earlier version of this banner guessed from SUDO_USER and got it
    # exactly backwards after that handoff: sudo sets SUDO_USER to the
    # INVOKER, which by then is root. It reported "user root · 0 services
    # under /root/docker" on a host with several under /home/test — a banner
    # of facts, stating a falsehood.
    home="${REAL_HOME:-$HOME}"
    user="${REAL_USER:-${USER:-$(id -un 2>/dev/null)}}"
    [[ -z "$home" ]] && home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    [[ -z "$home" ]] && home="/root"

    if [[ -r /etc/os-release ]]; then
        os="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$ID}")"
    else
        os="unknown"
    fi
    kernel="$(uname -r 2>/dev/null || echo unknown)"
    arch="$(uname -m 2>/dev/null || echo unknown)"

    mem_t="$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null)"
    mem_f="$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null)"
    disk="$(df -h --output=avail "$home" 2>/dev/null | tail -1 | tr -d ' ')"

    if command -v docker >/dev/null 2>&1; then
        dock="$(docker --version 2>/dev/null | sed 's/Docker version //; s/,.*//')"
        cnt="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
        dock="${dock:-installed} · ${cnt:-0} running"
    else
        dock="not installed yet"
    fi

    # Count only directories that actually carry a stack, so an empty folder
    # left behind by a removal is not reported as a deployment.
    svc=0
    if [[ -d "$home/docker" ]]; then
        svc="$(find "$home/docker" -mindepth 2 -maxdepth 2 -name docker-compose.yml 2>/dev/null | wc -l | tr -d ' ')"
    fi

    # ── The full mark, and the facts beside it ──────────────────────────
    # The hexagon hub with its six service nodes, not the micro tier — the
    # terminal has room for the real one. Hull spans columns 6-14, centre
    # 10; the caps are 7 wide at column 7; the top and bottom nodes sit on
    # column 10. The cargo narrows upward (3 then 5) with the top bar in
    # signal orange, the same taper the drawn mark uses.
    #
    # Nodes never share a row with the hull. That is not a style choice:
    # ● is East-Asian-ambiguous width, so a terminal that renders it double
    # would shift everything after it. Keeping it off the hull rows means
    # the worst case is wider spacing, never a broken hexagon.
    #
    # The facts run alongside rather than below because the whole block has
    # to fit above a fifteen-item category list on an 80x24 terminal. Eight
    # rows of mark, eight rows of text, one block.
    #
    # The wordmark is drawn in half-block letters rather than typed, because
    # a terminal has one font size and the name has to outrank the facts
    # beside it. Each letter is a 3x3 cell with a single space between, so
    # DOCK is 15 columns and HUB is 11 — the split falls on a character
    # boundary in all three rows, which is what lets 'hub' take the signal
    # colour it has everywhere else.
    local m1='          ●'            p1='           '
    local m2='   ●             ●'     p2='    '
    local m3='       ▄█████▄'         p3='        '
    local m6='       ▀█████▀'         p6='        '
    local d1='█▀▄ █▀█ █▀▀ █ █'  h1='█ █ █ █ █▀▄'
    local d2='█ █ █ █ █   █▀▄'  h2='█▀█ █ █ █▀▄'
    local d3='▀▀  ▀▀▀ ▀▀▀ ▀ ▀'  h3='▀ ▀ ▀▀▀ ▀▀ '
    printf '\n'
    printf '  %s%s%s\n'     "$_BN_DIM" "$m1" "$_BN_0"
    printf '  %s%s%s%s%s%s %s%s%s\n' \
           "$_BN_DIM" "$m2" "$_BN_0" "$p2" "$_BN_B" "$d1" "$_BN_SIG" "$h1" "$_BN_0"
    printf '  %s%s%s%s%s%s %s%s%s\n' \
           "$_BN_DIM" "$m3" "$_BN_0" "$p3" "$_BN_B" "$d2" "$_BN_SIG" "$h2" "$_BN_0"
    printf '        %s███%s▄▄▄%s███%s       %s%s %s%s%s\n' \
           "$_BN_DIM" "$_BN_SIG" "$_BN_DIM" "$_BN_0" "$_BN_B" "$d3" "$_BN_SIG" "$h3" "$_BN_0"
    printf '        %s██▄▄▄▄▄██%s       %sSELF-HOSTED · DEPLOYED PROPERLY%s\n' \
           "$_BN_DIM" "$_BN_0" "$_BN_BEA" "$_BN_0"
    printf '  %s%s%s%s\n'   "$_BN_DIM" "$m6" "$_BN_0" "$p6"
    printf '  %s%s%s%s%s%-8s%s %s · %s · %s\n' \
           "$_BN_DIM" "$m2" "$_BN_0" "$p2" "$_BN_DIM" "system" "$_BN_0" "$os" "$kernel" "$arch"
    printf '  %s%s%s%s%s%-8s%s %s\n' \
           "$_BN_DIM" "$m1" "$_BN_0" "$p1" "$_BN_DIM" "docker" "$_BN_0" "$dock"
    printf '                        %s%-8s%s %s · %s · %s services\n' \
           "$_BN_DIM" "user" "$_BN_0" "$user" "$home" "$svc"
    printf '                        %s%-8s%s %s GB free of %s GB · disk %s free\n' \
           "$_BN_DIM" "memory" "$_BN_0" "${mem_f:-?}" "${mem_t:-?}" "${disk:-?}"
    # No trailing blank line. `dockhub_ask` opens with one of its own, and
    # every caller reaches a question eventually, so emitting one here too
    # left a double gap. The one exception — the OS-detection warning, which
    # is not a question — prints its own blank at the call site.
    if [[ -n "$subtitle" ]]; then
        # Beacon teal, the same colour as the tagline: this line is a
        # breadcrumb telling you where in the menus you are, and it should
        # read as part of the identity rather than as another fact.
        printf '\n  %s▸%s %s%s%s%s\n' \
               "$_BN_DIM" "$_BN_0" "$_BN_B" "$_BN_BEA" "$subtitle" "$_BN_0"
    fi
}

# ── Menu colours ────────────────────────────────────────────────────────
# Every menu in the project prints through these two, so the scheme is
# defined once instead of being re-typed in each of the seven listing loops.
#
#   the question   signal, bold — it is the one thing being asked
#   odd numbers    plain
#   even numbers   signal
#   0              red, number AND word, because 0 always leaves
#   the labels     plain, always — the colour marks the key you press,
#                  not the words, so a long label never competes with it
#
# The alternation is a reading aid, not decoration: on a fifteen-item
# category list it gives the eye a rhythm to count by.

dockhub_ask() {
    printf '\n%s%s%s%s\n' "$_BN_B" "$_BN_SIG" "$1" "$_BN_0"
}

dockhub_item() {
    # $1 = key, $2 = label, $3 = optional item count, used only to right-align
    # the key. Without it `[ 9 ]` and `[ 10 ]` differ in width and every label
    # past nine shifts a column — visible on the fifteen-item category list,
    # which is the only menu long enough to reach two digits.
    local key="$1" label="$2" total="${3:-}" k
    if [[ "$total" =~ ^[0-9]+$ ]]; then
        printf -v k '%*s' "${#total}" "$key"
    else
        k="$key"
    fi
    if [[ "$key" == "0" ]]; then
        printf '%s[ %s ] %s%s\n' "$_BN_RED" "$k" "$label" "$_BN_0"
    elif [[ "$key" =~ ^[0-9]+$ ]] && (( key % 2 == 0 )); then
        printf '%s[ %s ]%s %s\n' "$_BN_SIG" "$k" "$_BN_0" "$label"
    else
        printf '[ %s ] %s\n' "$k" "$label"
    fi
}

#!/bin/bash
# wifi/auto.sh — unlimit control panel (white + orange)

PORTAL="http://172.20.175.201:8090/httpclient.html"
LOGOUT_URL="$PORTAL"
CREDS="$HOME/wifi/creds.txt"
LOG="$HOME/wifi/autologin.log"
LAST_USER_FILE="$HOME/wifi/.last_user"
INDEX_FILE="$HOME/wifi/.next_index"
TARGET="8.8.8.8"

# ── palette: white + orange ───────────────────────────
ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"
ITAL="${ESC}[3m"

WHITE="${ESC}[38;5;231m"    # pure bright white
SOFT="${ESC}[38;5;253m"     # softer white for body
MUTED="${ESC}[38;5;250m"    # labels
FAINT="${ESC}[38;5;245m"    # faint dividers
ORANGE="${ESC}[38;5;208m"   # main accent (Victor orange)
AMBER="${ESC}[38;5;214m"    # lighter orange
GREEN="${ESC}[38;5;114m"
RED="${ESC}[38;5;203m"

# ── state ─────────────────────────────────────────────
STATE="up"
CURRENT_USER="-"
STATUS="idle"
STOP=0

ORIG_STTY=$(stty -g 2>/dev/null)
cleanup() {
    STOP=1
    stty "$ORIG_STTY" 2>/dev/null
    printf "${ESC}[?25h${ESC}[2J${ESC}[H"
    printf "${ORANGE}◆${RESET} ${SOFT}session ended.${RESET}\n"
    exit 0
}
trap cleanup INT TERM

stty -echo -icanon min 1 time 0
printf "${ESC}[?25l"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# ── layout helpers ────────────────────────────────────
term_rows() { tput lines 2>/dev/null || echo 24; }
term_cols() { tput cols  2>/dev/null || echo 80; }

hr() {
    local n="$1"
    printf "${FAINT}"
    printf '─%.0s' $(seq 1 "$n")
    printf "${RESET}"
}

# ── draw ──────────────────────────────────────────────
draw() {
    local rows=$(term_rows)
    local cols=$(term_cols)
    local W=$((cols > 90 ? 90 : cols - 4))

    printf "${ESC}[2J${ESC}[H"

    # ── header ───────────────────────────────────────
    printf "\n"
    printf "  ${ORANGE}${BOLD}◆${RESET} ${WHITE}${BOLD}unlimit${RESET}  ${MUTED}hostel captive-portal controller${RESET}\n"
    printf "  "
    hr "$W"
    printf "\n"

    # ── state block ──────────────────────────────────
    local sc="$GREEN"
    [ "$STATE" = "down" ] && sc="$RED"
    local state_label
    [ "$STATE" = "up" ] && state_label="online" || state_label="offline"

    printf "  ${MUTED}network${RESET}   ${sc}${BOLD}● %s${RESET}\n" "$state_label"
    printf "  ${MUTED}user${RESET}      ${WHITE}%s${RESET}\n" "$CURRENT_USER"
    printf "  ${MUTED}status${RESET}    ${AMBER}%s${RESET}\n" "$STATUS"

    printf "\n  "
    hr "$W"
    printf "\n"

    # ── activity ─────────────────────────────────────
    printf "  ${ORANGE}${ITAL}recent activity${RESET}\n\n"

    local count=0
    while IFS= read -r line; do
        # color-code the log line by content
        local lc="$SOFT"
        case "$line" in
            *"✅"*|*"connected"*) lc="$GREEN" ;;
            *"✗"*|*"rejected"*|*"failed"*) lc="$RED" ;;
            *"⚠"*|*"drop"*) lc="$AMBER" ;;
            *"🔎"*) lc="$MUTED" ;;
        esac
        printf "  ${FAINT}│${RESET} ${lc}%s${RESET}\n" "${line:0:$((W-4))}"
        count=$((count+1))
    done < <(tail -n 8 "$LOG" 2>/dev/null | sed 's/^\[[^]]*\] //')

    while [ $count -lt 8 ]; do
        printf "  ${FAINT}│${RESET}\n"
        count=$((count+1))
    done

    printf "\n  "
    hr "$W"
    printf "\n"

    # ── hint bar ─────────────────────────────────────
    local r=$(term_rows)
    printf "${ESC}[%d;1H" $((r-1))
    printf "  ${FAINT}│${RESET} "
    printf "${ORANGE}${BOLD}n${RESET} ${SOFT}next${RESET}   "
    printf "${ORANGE}${BOLD}l${RESET} ${SOFT}logout${RESET}   "
    printf "${ORANGE}${BOLD}q${RESET} ${SOFT}quit${RESET}"
    printf "\n"
}

# ── portal whoami ─────────────────────────────────────
whoami_portal() {
    local resp
    resp=$(curl -k -s --max-time 4 -d "mode=192&a=$(date +%s)000&producttype=0" "$PORTAL")
    local u
    u=$(echo "$resp" | grep -oE 'username["=: ]+[A-Za-z0-9._-]+' | head -1 | sed -E 's/.*[":= ]//')
    [ -z "$u" ] && u=$(echo "$resp" | grep -oE '<user>([^<]+)</user>' | head -1 | sed -E 's/<\/?user>//g')
    echo "$u"
}

# ── login ─────────────────────────────────────────────
try_login() {
    mapfile -t lines < "$CREDS"
    local total=${#lines[@]}
    [ "$total" -eq 0 ] && { STATUS="no creds"; draw; return 1; }

    local start=0
    [ -f "$INDEX_FILE" ] && start=$(cat "$INDEX_FILE" 2>/dev/null)
    [ -z "$start" ] && start=0

    local n=0
    while [ $n -lt $total ]; do
        local idx=$(( (start + n) % total ))
        local line="${lines[$idx]}"
        n=$((n+1))

        local user="${line%%:*}"
        local pass="${line#*:}"
        [ -z "$user" ] && continue

        STATUS="authenticating as ${user}"
        draw
        log "trying $user (index $idx)"

        response=$(curl -k -s --max-time 5 \
            -d "mode=191&username=${user}&password=${pass}&a=$(date +%s)000&producttype=0" \
            "$PORTAL")

        if echo "$response" | grep -qiE "success|logged in|already"; then
            CURRENT_USER="$user"
            echo "$user" > "$LAST_USER_FILE"
            local next_idx=$(( (idx + 1) % total ))
            echo "$next_idx" > "$INDEX_FILE"
            STATUS="connected"
            log "✅ connected as $user — next index $next_idx"
            draw
            return 0
        else
            log "✗ rejected $user"
        fi
        sleep 1
    done
    STATUS="no credential worked"
    draw
    return 1
}

# ── logout ────────────────────────────────────────────
do_logout() {
    local u="${1:-$CURRENT_USER}"
    [ "$u" = "-" ] && u=$(cat "$LAST_USER_FILE" 2>/dev/null)
    [ -z "$u" ] && { STATUS="already offline"; draw; return; }

    log "logging out $u"
    curl -k -s --max-time 5 \
        -d "mode=193&username=${u}&btnSubmit=Logout" \
        "$LOGOUT_URL" > /dev/null 2>&1

    CURRENT_USER="-"
    rm -f "$LAST_USER_FILE"
    STATE="down"
}

# ── bootstrap ─────────────────────────────────────────
bootstrap_user() {
    local u
    u=$(whoami_portal)
    if [ -n "$u" ]; then
        CURRENT_USER="$u"; echo "$u" > "$LAST_USER_FILE"
        STATUS="connected"; log "session detected: $u"; return
    fi
    if [ -f "$LAST_USER_FILE" ]; then
        CURRENT_USER=$(cat "$LAST_USER_FILE"); STATUS="connected"
    else
        STATUS="waiting for network"
    fi
}

# ── main ──────────────────────────────────────────────
STATUS="probing session"
draw
bootstrap_user
draw

while [ "$STOP" -eq 0 ]; do
    if read -rsn1 -t 0.3 key; then
        case "$key" in
            n|N)
                STATUS="rotating — logging out current user"
                draw
                do_logout
                STATUS="standing by — next drop picks a new user"
                draw
                ;;
            l|L)
                STATUS="logging out"
                draw
                do_logout
                STATUS="offline"
                draw
                ;;
            q|Q) cleanup ;;
        esac
    fi

    if ping -c 1 -W 2 "$TARGET" > /dev/null 2>&1; then
        NEW_STATE="up"
    else
        NEW_STATE="down"
    fi

    if [ "$NEW_STATE" != "$STATE" ]; then
        STATE="$NEW_STATE"
        if [ "$STATE" = "down" ]; then
            log "network drop detected"
            CURRENT_USER="-"
            draw
            try_login
        else
            log "network restored"
            local_u=$(whoami_portal)
            [ -n "$local_u" ] && CURRENT_USER="$local_u"
            draw
        fi
    fi
done

cleanup

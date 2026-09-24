#!/bin/bash
# wifi/auto.sh — unlimit control panel (timer, toggle speed, min/max, real data, spinner)

PORTAL="http://172.20.175.201:8090/httpclient.html"
LOGOUT_URL="$PORTAL"
CREDS="$HOME/wifi/creds.txt"
LOG="$HOME/wifi/autologin.log"
LAST_USER_FILE="$HOME/wifi/.last_user"
INDEX_FILE="$HOME/wifi/.next_index"
TARGET="8.8.8.8"

# ── speed test config ─────────────────────────────────
SPEED_URL="https://speed.cloudflare.com/__down?bytes=25000000"
SPEED_DURATION=5
SAMPLE_INTERVAL=15
LAST_SAMPLE=0
SPEED_ENABLED=1

# ── data usage ────────────────────────────────────────
IFACE=""
BYTES_START=0
SPEED_BYTES_TOTAL=0
LAST_SPEED_BYTES=0

# ── palette ───────────────────────────────────────────
ESC=$'\033'
RESET="${ESC}[0m"; BOLD="${ESC}[1m"; DIM="${ESC}[2m"; ITAL="${ESC}[3m"
WHITE="${ESC}[38;5;231m"; SOFT="${ESC}[38;5;253m"; MUTED="${ESC}[38;5;250m"
FAINT="${ESC}[38;5;245m"; ORANGE="${ESC}[38;5;208m"; AMBER="${ESC}[38;5;214m"
GREEN="${ESC}[38;5;114m"; RED="${ESC}[38;5;203m"; BLUE="${ESC}[38;5;111m"

# ── state ─────────────────────────────────────────────
STATE="up"
CURRENT_USER="-"
NEXT_USER="-"
STATUS="idle"
STOP=0
SPEED_MBPS="0"
SPEED_STATUS="idle"
SPEED_MIN=""
SPEED_MAX=""
SESSION_START=$(date +%s)
SPIN_FRAME=0
SPIN_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPINNER_ACTIVE=0

ORIG_STTY=$(stty -g 2>/dev/null)
cleanup() {
    STOP=1
    stty "$ORIG_STTY" 2>/dev/null
    printf "${ESC}[?25h${ESC}[2J${ESC}[H"
    printf "${ORANGE}◆${RESET} ${SOFT}session ended.${RESET}\n"
    exit 0
}
trap cleanup INT TERM EXIT

stty -echo -icanon min 1 time 0
printf "${ESC}[?25l"

touch "$LOG" 2>/dev/null
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# ── layout helpers ────────────────────────────────────
term_rows() { tput lines 2>/dev/null || echo 24; }
term_cols() { tput cols  2>/dev/null || echo 80; }
hr() { printf "${FAINT}"; printf '─%.0s' $(seq 1 "$1"); printf "${RESET}"; }

# ── interface byte counters ───────────────────────────
detect_iface() {
    local ifc
    ifc=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
    [ -z "$ifc" ] && ifc="wlan0"
    echo "$ifc"
}

iface_bytes() {
    [ -z "$IFACE" ] && { echo 0; return; }
    awk -v i="$IFACE" -F'[: ]+' '$2==i {print $3+$11}' /proc/net/dev 2>/dev/null
}

init_data_counter() {
    IFACE=$(detect_iface)
    BYTES_START=$(iface_bytes)
    [ -z "$BYTES_START" ] && BYTES_START=0
}

data_used_mb() {
    local now; now=$(iface_bytes)
    [ -z "$now" ] && now=0
    local total=$(( now - BYTES_START - SPEED_BYTES_TOTAL ))
    [ "$total" -lt 0 ] && total=0
    awk -v t="$total" 'BEGIN { printf "%.1f", t / 1048576 }'
}

speed_bytes_mb() {
    awk -v t="$SPEED_BYTES_TOTAL" 'BEGIN { printf "%.1f", t / 1048576 }'
}

# ── session duration ──────────────────────────────────
session_duration() {
    local now; now=$(date +%s)
    local d=$(( now - SESSION_START ))
    local h=$(( d / 3600 ))
    local m=$(( (d % 3600) / 60 ))
    local s=$(( d % 60 ))
    if [ $h -gt 0 ]; then
        printf "%dh %02dm" "$h" "$m"
    else
        printf "%02dm %02ds" "$m" "$s"
    fi
}

# ── midnight rotation ─────────────────────────────────
LAST_ROTATE_FILE="$HOME/wifi/.last_rotate"
maybe_rotate_log() {
    local today; today=$(date +%F)
    local last=""
    [ -f "$LAST_ROTATE_FILE" ] && last=$(cat "$LAST_ROTATE_FILE" 2>/dev/null)
    if [ "$last" != "$today" ]; then
        : > "$LOG"
        echo "[$(date '+%F %T')] ─── log rotated ───" >> "$LOG"
        echo "$today" > "$LAST_ROTATE_FILE"
    fi
}

# ── speed measurement (tracks its own bytes) ──────────
measure_speed() {
    local before after bps
    before=$(iface_bytes); [ -z "$before" ] && before=0

    bps=$(curl -4 -A "Mozilla/5.0" -L -s -o /dev/null \
        --max-time "$SPEED_DURATION" \
        -w '%{speed_download}' \
        "$SPEED_URL" 2>/dev/null)

    after=$(iface_bytes); [ -z "$after" ] && after=0

    LAST_SPEED_BYTES=$(( after - before ))
    [ "$LAST_SPEED_BYTES" -lt 0 ] && LAST_SPEED_BYTES=0

    bps="${bps%.*}"
    [ -z "$bps" ] && bps=0
    echo "$bps"
}

sample_speed() {
    local bps
    bps=$(measure_speed)
    SPEED_BYTES_TOTAL=$(( SPEED_BYTES_TOTAL + LAST_SPEED_BYTES ))

    if [ -z "$bps" ] || ! [[ "$bps" =~ ^[0-9]+$ ]] || [ "$bps" -le 0 ]; then
        SPEED_MBPS="0"
        SPEED_STATUS="fail"
        return
    fi
    SPEED_MBPS=$(awk -v b="$bps" 'BEGIN { printf "%.2f", b / 1048576 }')

    if [ -z "$SPEED_MIN" ] || awk -v a="$SPEED_MBPS" -v b="$SPEED_MIN" 'BEGIN { exit !(a < b) }'; then
        SPEED_MIN="$SPEED_MBPS"
    fi
    if [ -z "$SPEED_MAX" ] || awk -v a="$SPEED_MBPS" -v b="$SPEED_MAX" 'BEGIN { exit !(a > b) }'; then
        SPEED_MAX="$SPEED_MBPS"
    fi

    SPEED_STATUS="ok"
    log "speed sample: ${SPEED_MBPS} MB/s"
}

# ── speed bar ─────────────────────────────────────────
draw_bar() {
    local width=32
    local filled=0

    if [ "$SPEED_ENABLED" -eq 0 ]; then
        printf "${FAINT}╭"; printf '░%.0s' $(seq 1 "$width"); printf "╮${RESET}  "
        printf "${MUTED}paused${RESET}"
        return
    fi
    if [ "$SPEED_STATUS" = "fail" ]; then
        printf "${FAINT}╭"; printf '░%.0s' $(seq 1 "$width"); printf "╮${RESET}  "
        printf "${RED}${BOLD}unreachable${RESET}"
        return
    fi
    if [ "$SPEED_STATUS" = "idle" ]; then
        printf "${FAINT}╭"; printf '░%.0s' $(seq 1 "$width"); printf "╮${RESET}  "
        printf "${MUTED}measuring…${RESET}"
        return
    fi

    filled=$(awk -v s="$SPEED_MBPS" -v w="$width" \
        'BEGIN { f = s / 30 * w; if (f > w) f = w; if (f < 0) f = 0; printf "%d", f }')
    local empty=$(( width - filled ))

    local color="$RED"
    awk -v s="$SPEED_MBPS" 'BEGIN { exit !(s >= 1) }'  && color="$AMBER"
    awk -v s="$SPEED_MBPS" 'BEGIN { exit !(s >= 5) }'  && color="$ORANGE"
    awk -v s="$SPEED_MBPS" 'BEGIN { exit !(s >= 15) }' && color="$GREEN"

    printf "${FAINT}╭${RESET}"
    if [ "$filled" -gt 0 ]; then
        printf "${color}"
        printf '█%.0s' $(seq 1 "$filled")
    fi
    if [ "$empty" -gt 0 ]; then
        printf "${FAINT}"
        printf '░%.0s' $(seq 1 "$empty")
    fi
    printf "${FAINT}╮${RESET}  "
    printf "${color}${BOLD}%6s MB/s${RESET}" "$SPEED_MBPS"
}

# ── next user preview ─────────────────────────────────
compute_next_user() {
    mapfile -t lines < "$CREDS" 2>/dev/null
    local total=${#lines[@]}
    [ "$total" -eq 0 ] && { NEXT_USER="-"; return; }
    local start=0
    [ -f "$INDEX_FILE" ] && start=$(cat "$INDEX_FILE" 2>/dev/null)
    [ -z "$start" ] && start=0
    local idx=$(( start % total ))
    local line="${lines[$idx]}"
    NEXT_USER="${line%%:*}"
    [ -z "$NEXT_USER" ] && NEXT_USER="-"
}

# ── draw ──────────────────────────────────────────────
draw() {
    local rows=$(term_rows)
    local cols=$(term_cols)
    local W=$((cols > 90 ? 90 : cols - 4))

    printf "${ESC}[2J${ESC}[H"

    printf "\n"
    printf "  ${ORANGE}${BOLD}◆${RESET} ${WHITE}${BOLD}unlimit${RESET}  ${MUTED}hostel captive-portal controller${RESET}\n"
    printf "  "; hr "$W"; printf "\n"

    local sc="$GREEN"
    [ "$STATE" = "down" ] && sc="$RED"
    local state_label
    [ "$STATE" = "up" ] && state_label="online" || state_label="offline"

    local status_label="$STATUS"
    if [ "$SPINNER_ACTIVE" -eq 1 ]; then
        local ch="${SPIN_CHARS[$((SPIN_FRAME % ${#SPIN_CHARS[@]}))]}"
        status_label="${ch} ${STATUS}"
    fi

    printf "  ${MUTED}network${RESET}   ${sc}${BOLD}● %s${RESET}\n" "$state_label"
    printf "  ${MUTED}user${RESET}      ${WHITE}%s${RESET}\n" "$CURRENT_USER"
    printf "  ${MUTED}next${RESET}      ${BLUE}%s${RESET}\n" "$NEXT_USER"
    printf "  ${MUTED}status${RESET}    ${AMBER}%s${RESET}\n" "$status_label"
    printf "  ${MUTED}session${RESET}   ${SOFT}%s${RESET}\n" "$(session_duration)"
    printf "  ${MUTED}data${RESET}      ${SOFT}%s MB${RESET} ${FAINT}(speed tests: %s MB)${RESET}\n" \
        "$(data_used_mb)" "$(speed_bytes_mb)"

    printf "\n  ${MUTED}speed${RESET}     "
    draw_bar
    if [ "$SPEED_STATUS" = "ok" ]; then
        printf "   ${FAINT}min${RESET} ${SOFT}%s${RESET}  ${FAINT}max${RESET} ${SOFT}%s${RESET}" \
            "${SPEED_MIN:-—}" "${SPEED_MAX:-—}"
    fi
    printf "\n"

    printf "\n  "; hr "$W"; printf "\n"

    printf "  ${ORANGE}${ITAL}recent activity${RESET}\n\n"

    local count=0
    while IFS= read -r line; do
        local lc="$SOFT"
        case "$line" in
            *"✅"*|*"connected"*) lc="$GREEN" ;;
            *"✗"*|*"rejected"*) lc="$RED" ;;
            *"⚠"*|*"drop"*) lc="$AMBER" ;;
        esac
        printf "  ${FAINT}│${RESET} ${lc}%s${RESET}\n" "${line:0:$((W-4))}"
        count=$((count+1))
    done < <(tail -n 5 "$LOG" 2>/dev/null | sed 's/^\[[^]]*\] //')

    while [ $count -lt 5 ]; do
        printf "  ${FAINT}│${RESET}\n"
        count=$((count+1))
    done

    printf "\n  "; hr "$W"; printf "\n"

    local r=$(term_rows)
    printf "${ESC}[%d;1H" $((r-1))
    printf "  ${FAINT}│${RESET} "
    printf "${ORANGE}${BOLD}n${RESET} ${SOFT}next${RESET}   "
    printf "${ORANGE}${BOLD}l${RESET} ${SOFT}logout${RESET}   "
    printf "${ORANGE}${BOLD}m${RESET} ${SOFT}toggle-speed${RESET}   "
    printf "${ORANGE}${BOLD}s${RESET} ${SOFT}stop${RESET}   "
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

# ── login (random) ────────────────────────────────────
try_login() {
    mapfile -t lines < "$CREDS"
    local total=${#lines[@]}
    [ "$total" -eq 0 ] && { STATUS="no creds"; draw; return 1; }

    local order=()
    local i
    for ((i=0; i<total; i++)); do order+=("$i"); done
    for ((i=total-1; i>0; i--)); do
        local j=$(( RANDOM % (i+1) ))
        local t="${order[$i]}"; order[$i]="${order[$j]}"; order[$j]="$t"
    done

    SPINNER_ACTIVE=1
    local n=0
    while [ $n -lt $total ]; do
        local idx="${order[$n]}"
        local line="${lines[$idx]}"
        n=$((n+1))
        local user="${line%%:*}"
        local pass="${line#*:}"
        [ -z "$user" ] && continue

        STATUS="authenticating as ${user}"
        SPIN_FRAME=$((SPIN_FRAME+1))
        draw
        log "trying $user (random #$n/$total)"

        response=$(curl -k -s --max-time 4 \
            -d "mode=191&username=${user}&password=${pass}&a=$(date +%s)000&producttype=0" \
            "$PORTAL")

        if echo "$response" | grep -qiE "success|logged in|already"; then
            SPINNER_ACTIVE=0
            CURRENT_USER="$user"
            echo "$user" > "$LAST_USER_FILE"
            echo $(( (idx + 1) % total )) > "$INDEX_FILE"
            compute_next_user
            STATUS="connected"
            log "✅ connected as $user"
            draw
            return 0
        else
            log "✗ rejected $user"
        fi
    done
    SPINNER_ACTIVE=0
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
    curl -k -s --max-time 4 \
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
        CURRENT_USER=$(cat "$LAST_USER_FILE"); STATUS="connected (cached)"
        log "restored session: $CURRENT_USER"
    else
        STATUS="waiting for network"
        log "started — waiting for session"
    fi
}

# ── main ──────────────────────────────────────────────
init_data_counter
log "─── session started ───"
compute_next_user
STATUS="probing session"
draw
bootstrap_user
draw

while [ "$STOP" -eq 0 ]; do
    maybe_rotate_log

    if read -rsn1 -t 0.3 key; then
        case "$key" in
            n|N)
                STATUS="rotating"
                draw
                do_logout
                STATUS="standing by"
                compute_next_user
                draw
                ;;
            l|L)
                STATUS="logging out"
                draw
                do_logout
                STATUS="offline"
                draw
                ;;
            m|M)
                if [ "$SPEED_ENABLED" -eq 1 ]; then
                    SPEED_ENABLED=0
                    STATUS="speed test paused"
                else
                    SPEED_ENABLED=1
                    STATUS="speed test enabled"
                    LAST_SAMPLE=0
                fi
                draw
                ;;
            s|S)
                STATUS="stopped — press q to exit"
                draw
                log "session stopped by user"
                STOP=1
                ;;
            q|Q) cleanup ;;
        esac
    fi

    NOW=$(date +%s)
    if [ "$SPEED_ENABLED" -eq 1 ] && [ "$STATE" = "up" ] && \
       [ $((NOW - LAST_SAMPLE)) -ge "$SAMPLE_INTERVAL" ]; then
        LAST_SAMPLE=$NOW
        sample_speed
        draw
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

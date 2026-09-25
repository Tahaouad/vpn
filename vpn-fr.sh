#!/usr/bin/env bash
#
# vpn-fr.sh — connect to a French VPNBook server, verify the exit IP is in
# France, keep the best connection, and fail over automatically if it drops.
#
# Usage:
#   ./vpn-fr.sh            # benchmark configs, connect to the best, then monitor
#   ./vpn-fr.sh start      # same as above
#   ./vpn-fr.sh test       # benchmark every config, print a table, don't stay connected
#   ./vpn-fr.sh status     # show whether the VPN is up and the current exit IP
#   ./vpn-fr.sh stop       # tear the VPN down cleanly
#   ./vpn-fr.sh restart    # stop, then start
#
# Options:
#   -f, --force-bench   ignore the cached benchmark and re-test every config
#   -q, --quick         skip benchmarking, just connect to the first working config
#   -n, --no-monitor    connect and exit (no failover monitoring)
#
set -euo pipefail

# --- configuration ----------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR"
AUTH_FILE="$SCRIPT_DIR/vpnbook.auth"
RUN_DIR="$SCRIPT_DIR/.run"
PID_FILE="$RUN_DIR/openvpn.pid"
LOG_FILE="$RUN_DIR/openvpn.log"
CURRENT_FILE="$RUN_DIR/current.conf"
BENCH_FILE="$RUN_DIR/bench.tsv"
MONITOR_PID_FILE="$RUN_DIR/monitor.pid"
STOP_FLAG="$RUN_DIR/stop.flag"

# Country the exit IP must resolve to.
EXPECT_COUNTRY="FR"
# How the exit IP / country is checked. Cloudflare's trace endpoint is a fixed
# anycast IP (no DNS needed — important, since the VPN doesn't set up a resolver)
# and reports the country of whatever IP the request exits from.
TRACE_URL="https://1.1.1.1/cdn-cgi/trace"
# Seconds to wait for a tunnel to come up before giving up on a config.
CONNECT_TIMEOUT=45
# Benchmark cache is considered fresh for this many hours.
BENCH_MAX_AGE_HOURS=24
# Monitor loop: seconds between health checks, and consecutive failures tolerated.
MONITOR_INTERVAL=15
MONITOR_FAILURES=2

OPENVPN_TAG="vpn-fr"   # --daemon name, used to find/kill stray processes

# Don't hammer vpnbook.com with headless-Chrome renders: wait at least this
# long between auto-refresh attempts (state kept in-process, so it's per run).
CREDS_REFRESH_COOLDOWN=300
LAST_CREDS_REFRESH=0

# --- helpers ---------------------------------------------------------------

c_reset=$'\e[0m'; c_info=$'\e[36m'; c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'
say()  { printf '%s[*]%s %s\n' "$c_info" "$c_reset" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_ok"   "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_warn" "$c_reset" "$*"; }
die()  { printf '%s[x]%s %s\n' "$c_err"  "$c_reset" "$*" >&2; exit 1; }

# "vpnbook-fr200-udp25000.ovpn" -> "fr200 UDP 25000"
label_for() {
    local base; base="$(basename "$1" .ovpn)"
    base="${base#vpnbook-}"
    local host="${base%%-*}" tail="${base#*-}"
    local proto="${tail%%[0-9]*}"
    local port="${tail#"$proto"}"
    printf '%s %s %s' "$host" "$(printf '%s' "$proto" | tr '[:lower:]' '[:upper:]')" "$port"
}

list_configs() {
    local f
    for f in "$CONFIG_DIR"/*.ovpn; do
        [ -e "$f" ] || continue
        printf '%s\n' "$f"
    done
}

need_root() {
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        say "openvpn needs root — you may be prompted for your sudo password."
    fi
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

check_auth() {
    [ -f "$AUTH_FILE" ] || die "Missing $AUTH_FILE — create it with two lines: your VPNBook username on line 1, password on line 2 (current credentials: https://www.vpnbook.com/freevpn)."
    if [ "$(stat -c '%a' "$AUTH_FILE")" != "600" ]; then
        chmod 600 "$AUTH_FILE" || true
    fi
    [ "$(wc -l < "$AUTH_FILE")" -ge 2 ] || [ "$(wc -c < "$AUTH_FILE")" -gt 0 ] \
        || die "$AUTH_FILE looks empty — it needs username on line 1 and password on line 2."
}

# raw trace output (key=value lines), empty on failure
_trace() { curl -sf --max-time 10 "$TRACE_URL" 2>/dev/null; }
# current public country / ip as seen from the exit, empty on failure
exit_country() { _trace | sed -n 's/^loc=//p' | tr -d '[:space:]'; }
exit_ip()      { _trace | sed -n 's/^ip=//p'  | tr -d '[:space:]'; }
# round-trip time to the check endpoint, in seconds (e.g. 0.184); empty on failure
exit_latency() { curl -sf --max-time 10 -o /dev/null -w '%{time_total}' "$TRACE_URL" 2>/dev/null; }

# openvpn (run as root) writes its --log file mode 0600, so a non-root grep can't
# read it — always fall back to a privileged read.
log_has()  { grep -q  "$1" "$LOG_FILE" 2>/dev/null || as_root grep -q  "$1" "$LOG_FILE" 2>/dev/null; }
log_err()  { { grep -iE 'AUTH_FAILED|TLS Error|error|cannot|RESOLVE' "$LOG_FILE" 2>/dev/null \
               || as_root grep -iE 'AUTH_FAILED|TLS Error|error|cannot|RESOLVE' "$LOG_FILE" 2>/dev/null; } | tail -1; }

openvpn_running() {
    [ -f "$PID_FILE" ] && as_root kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# Best-effort: scrape the current VPNBook password from their site and
# overwrite $AUTH_FILE. Rate-limited by CREDS_REFRESH_COOLDOWN. Returns 1
# (without touching $AUTH_FILE) if the fetch script is missing, times out, or
# the page layout doesn't match what it expects.
maybe_refresh_creds() {
    local now; now=$(date +%s)
    [ $((now - LAST_CREDS_REFRESH)) -ge "$CREDS_REFRESH_COOLDOWN" ] || return 1
    LAST_CREDS_REFRESH=$now

    local script="$SCRIPT_DIR/fetch-vpnbook-creds.sh"
    [ -x "$script" ] || return 1
    say "AUTH_FAILED — trying to auto-fetch current VPNBook credentials..." >&2
    if "$script" "$AUTH_FILE"; then
        return 0
    fi
    warn "Auto-fetch failed — update $AUTH_FILE manually from https://www.vpnbook.com/freevpn/openvpn" >&2
    return 1
}

# --- connection lifecycle ------------------------------------------------------

stop_openvpn() {
    local had=1
    if [ -f "$PID_FILE" ]; then
        local pid; pid="$(cat "$PID_FILE")"
        if as_root kill -0 "$pid" 2>/dev/null; then
            as_root kill -TERM "$pid" 2>/dev/null || true
            for _ in $(seq 1 20); do
                as_root kill -0 "$pid" 2>/dev/null || break
                sleep 0.5
            done
            as_root kill -KILL "$pid" 2>/dev/null || true
            had=0
        fi
        rm -f "$PID_FILE"
    fi
    # sweep any stray instance started by this script
    if pgrep -f "openvpn .*--daemon $OPENVPN_TAG" >/dev/null 2>&1; then
        as_root pkill -f "openvpn .*--daemon $OPENVPN_TAG" 2>/dev/null || true
        had=0
    fi
    rm -f "$CURRENT_FILE"
    return $had
}

# connect_to <config> : bring up the tunnel and confirm the exit IP is French.
# returns 0 and prints the measured latency on success, 1 on failure.
connect_to() {
    local cfg="$1" label; label="$(label_for "$cfg")"
    say "Testing $label..." >&2

    stop_openvpn >/dev/null 2>&1 || true
    # openvpn (run as root) owns these; drop them so it can recreate them cleanly
    as_root rm -f "$LOG_FILE" "$PID_FILE" 2>/dev/null || rm -f "$LOG_FILE" "$PID_FILE"

    as_root openvpn \
        --config "$cfg" \
        --auth-user-pass "$AUTH_FILE" \
        --auth-nocache \
        --daemon "$OPENVPN_TAG" \
        --writepid "$PID_FILE" \
        --log "$LOG_FILE" \
        --connect-timeout 20 \
        --connect-retry-max 3 \
        --ping 10 --ping-restart 30 \
        --verb 3 || { warn "openvpn failed to launch for $label" >&2; return 1; }
    sleep 1; as_root chmod 0644 "$LOG_FILE" 2>/dev/null || true

    # phase 1: wait for the tunnel handshake to complete
    local waited=0 up=0
    while [ "$waited" -lt "$CONNECT_TIMEOUT" ]; do
        if ! openvpn_running; then
            if log_has "AUTH_FAILED" && maybe_refresh_creds; then
                connect_to "$cfg"; return $?
            fi
            warn "$label: openvpn exited early — $(log_err)" >&2
            return 1
        fi
        if log_has "Initialization Sequence Completed"; then up=1; break; fi
        sleep 2; waited=$((waited + 2))
    done
    [ "$up" -eq 1 ] || { warn "$label: tunnel did not come up within ${CONNECT_TIMEOUT}s" >&2
                         stop_openvpn >/dev/null 2>&1 || true; return 1; }

    # phase 2: routes are in place a moment after "Completed" — confirm the exit IP
    sleep 3
    local country="" tries=0
    while [ "$tries" -lt 6 ]; do
        openvpn_running || { warn "$label: tunnel dropped right after connecting" >&2; return 1; }
        country="$(exit_country)"
        [ -n "$country" ] && break
        sleep 2; tries=$((tries + 1))
    done

    if [ "$country" = "$EXPECT_COUNTRY" ]; then
        local lat; lat="$(exit_latency)"; : "${lat:=9.999}"
        ok "Connected - $country - $(exit_ip)  (${lat}s)" >&2
        printf '%s' "$lat"
        return 0
    elif [ -n "$country" ]; then
        warn "$label: tunnel up but exit country is '$country', not $EXPECT_COUNTRY — rejecting" >&2
    else
        warn "$label: tunnel up but could not reach $TRACE_URL to verify the exit IP" >&2
    fi
    stop_openvpn >/dev/null 2>&1 || true
    return 1
}

# --- benchmarking ------------------------------------------------------------

bench_fresh() {
    [ -f "$BENCH_FILE" ] || return 1
    local age; age=$(( ($(date +%s) - $(stat -c %Y "$BENCH_FILE")) / 3600 ))
    [ "$age" -lt "$BENCH_MAX_AGE_HOURS" ]
}

# Test every config, write "latency<TAB>config" lines sorted fastest-first.
run_bench() {
    say "Benchmarking $(list_configs | wc -l) configuration(s)..."
    local tmp; tmp="$(mktemp "$RUN_DIR/bench.XXXXXX")"
    local cfg lat
    while IFS= read -r cfg; do
        if lat="$(connect_to "$cfg")"; then
            printf '%s\t%s\n' "$lat" "$cfg" >> "$tmp"
        fi
    done < <(list_configs)
    stop_openvpn >/dev/null 2>&1 || true

    [ -s "$tmp" ] || { rm -f "$tmp"; die "No configuration produced a working French connection. Check $AUTH_FILE and $LOG_FILE."; }
    sort -n "$tmp" > "$BENCH_FILE"
    rm -f "$tmp"
}

# Ordered list of configs to try: best-known first, then any not yet benchmarked.
preferred_order() {
    local seen=""
    if [ -f "$BENCH_FILE" ]; then
        while IFS=$'\t' read -r _ cfg; do
            [ -e "$cfg" ] || continue
            printf '%s\n' "$cfg"; seen="$seen|$cfg"
        done < "$BENCH_FILE"
    fi
    local cfg
    while IFS= read -r cfg; do
        case "$seen" in *"|$cfg"*) ;; *) printf '%s\n' "$cfg";; esac
    done < <(list_configs)
}

# --- monitoring / failover -------------------------------------------------

monitor_loop() {
    echo $$ > "$MONITOR_PID_FILE"
    trap 'rm -f "$MONITOR_PID_FILE"; exit 0' TERM INT

    say "VPN active"
    say "Monitoring connection (Ctrl-C or './vpn-fr.sh stop' to quit)..."

    local fails=0
    while true; do
        sleep "$MONITOR_INTERVAL"
        [ -f "$STOP_FLAG" ] && { rm -f "$MONITOR_PID_FILE"; return 0; }

        if openvpn_running && [ "$(exit_country)" = "$EXPECT_COUNTRY" ]; then
            fails=0
            continue
        fi

        fails=$((fails + 1))
        [ "$fails" -lt "$MONITOR_FAILURES" ] && continue

        warn "Connection lost"
        local current="" cfg
        [ -f "$CURRENT_FILE" ] && current="$(cat "$CURRENT_FILE")"

        local reconnected=0
        # try other configs first, then the current one again, wrapping around
        while IFS= read -r cfg; do
            [ -f "$STOP_FLAG" ] && { rm -f "$MONITOR_PID_FILE"; return 0; }
            [ "$cfg" = "$current" ] && continue
            say "Switching to $(label_for "$cfg")..."
            if connect_to "$cfg" >/dev/null; then
                printf '%s' "$cfg" > "$CURRENT_FILE"
                ok "Connected"
                fails=0; reconnected=1; break
            fi
        done < <(preferred_order)

        if [ "$reconnected" -eq 0 ] && [ -n "$current" ]; then
            say "Retrying $(label_for "$current")..."
            if connect_to "$current" >/dev/null; then
                ok "Connected"; fails=0; reconnected=1
            fi
        fi

        [ "$reconnected" -eq 0 ] && warn "No French server reachable right now — retrying in ${MONITOR_INTERVAL}s"
    done
}

# --- subcommands ----------------------------------------------------------

cmd_start() {
    local quick=0 monitor=1 force=0
    for a in "$@"; do
        case "$a" in
            -q|--quick) quick=1 ;;
            -n|--no-monitor) monitor=0 ;;
            -f|--force-bench) force=1 ;;
        esac
    done

    mkdir -p "$RUN_DIR"
    check_auth
    need_root
    rm -f "$STOP_FLAG"

    if openvpn_running; then
        warn "VPN already running ($(label_for "$(cat "$CURRENT_FILE" 2>/dev/null || echo '?')"))."
        warn "Use './vpn-fr.sh restart' or './vpn-fr.sh stop' first."
        exit 1
    fi

    if [ "$quick" -eq 0 ]; then
        if [ "$force" -eq 1 ] || ! bench_fresh; then
            run_bench
        else
            say "Using cached benchmark ($(basename "$BENCH_FILE"), < ${BENCH_MAX_AGE_HOURS}h old — '-f' to refresh)."
        fi
    fi

    local cfg connected=""
    while IFS= read -r cfg; do
        if connect_to "$cfg" >/dev/null; then connected="$cfg"; break; fi
    done < <(preferred_order)

    [ -n "$connected" ] || die "Could not establish a French connection with any config. See $LOG_FILE."
    printf '%s' "$connected" > "$CURRENT_FILE"
    echo
    ok "VPN up via $(label_for "$connected") — exit IP $(exit_ip) ($EXPECT_COUNTRY)"

    if [ "$monitor" -eq 1 ]; then
        echo
        monitor_loop
    fi
}

cmd_stop() {
    mkdir -p "$RUN_DIR"
    touch "$STOP_FLAG"
    if [ -f "$MONITOR_PID_FILE" ]; then
        kill -TERM "$(cat "$MONITOR_PID_FILE")" 2>/dev/null || true
        rm -f "$MONITOR_PID_FILE"
    fi
    if stop_openvpn; then
        ok "VPN stopped."
    else
        say "VPN was not running."
    fi
    rm -f "$STOP_FLAG"
}

cmd_status() {
    if openvpn_running; then
        local cfg; cfg="$(cat "$CURRENT_FILE" 2>/dev/null || echo '?')"
        ok "VPN is UP via $(label_for "$cfg")"
        local country ip; country="$(exit_country)"; ip="$(exit_ip)"
        if [ "$country" = "$EXPECT_COUNTRY" ]; then
            ok "Exit IP $ip — $country"
        else
            warn "Exit IP $ip — country '${country:-unknown}' (expected $EXPECT_COUNTRY)"
        fi
        [ -f "$MONITOR_PID_FILE" ] && say "Failover monitor running (pid $(cat "$MONITOR_PID_FILE"))." || true
    else
        warn "VPN is DOWN"
        local ip; ip="$(exit_ip)"
        [ -n "$ip" ] && say "Current public IP: $ip ($(exit_country))" || true
    fi
}

cmd_test() {
    mkdir -p "$RUN_DIR"; check_auth; need_root
    run_bench
    stop_openvpn >/dev/null 2>&1 || true
    echo
    say "Results (fastest first):"
    printf '     %-22s %s\n' "SERVER" "LATENCY"
    while IFS=$'\t' read -r lat cfg; do
        printf '     %-22s %ss\n' "$(label_for "$cfg")" "$lat"
    done < "$BENCH_FILE"
}

# --- dispatch ------------------------------------------------------------

cmd="${1:-start}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
    start)   cmd_start "$@" ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; echo; cmd_start "$@" ;;
    status)  cmd_status ;;
    test)    cmd_test ;;
    -h|--help|help)
        sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^#\( \|$\)//' ;;
    *) die "Unknown command '$cmd' — try: start | stop | restart | status | test" ;;
esac

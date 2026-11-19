#!/usr/bin/env bash
# Smoke test for zt9101 on Linux 7.x.
# Run detached so a dropped WiFi/session does not abort the test:
#   nohup sudo ./script/smoke_test_kernel7.sh > /tmp/zt-smoke.console 2>&1 &
# Results: /tmp/zt-smoke.log
# Non-root preflight: ./script/smoke_test_kernel7.sh --preflight

set -u

IFACE="${ZT_IFACE:-wlan0}"
LOG="/tmp/zt-smoke.log"
PREFLIGHT=0
[ "${1:-}" = "--preflight" ] && PREFLIGHT=1

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

run() {
    log "+ $*"
    "$@" 2>&1 | tee -a "$LOG"
    log "  exit=${PIPESTATUS[0]}"
}

log "=== zt9101 smoke test start ==="
log "iface=$IFACE  preflight=$PREFLIGHT"

if [ "$PREFLIGHT" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    log "ERROR: need root (sudo)"
    exit 1
fi

command -v nmcli >/dev/null || log "WARN: nmcli missing"
command -v wpa_cli >/dev/null || log "WARN: wpa_cli missing"
lsmod | grep -q zt9101 && log "driver loaded" || log "WARN: driver not loaded"
if [ -d "/sys/class/net/$IFACE" ]; then
    log "iface present"
else
    log "ERROR: iface missing"
fi

PHY="$(cat "/sys/class/net/$IFACE/phy80211/name" 2>/dev/null || true)"
log "phy=${PHY:-unknown}"
log "initial state: $(nmcli -g GENERAL.STATE device show "$IFACE" 2>/dev/null)"

if [ "$PREFLIGHT" -eq 1 ]; then
    log "=== preflight done ==="
    exit 0
fi

trap 'nmcli device connect "$IFACE" >/dev/null 2>&1 || true' EXIT

GW="$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')"
log "gateway=${GW:-none}"

test_reconnect() {
    local i state n
    for i in 1 2 3; do
        log "--- reconnect cycle $i ---"
        run nmcli device disconnect "$IFACE"
        sleep 2
        run nmcli device connect "$IFACE"
        state=""
        for n in $(seq 1 20); do
            state="$(nmcli -g GENERAL.STATE device show "$IFACE" 2>/dev/null)"
            [ "$state" = "100 (connected)" ] && break
            sleep 1
        done
        log "state=$state"
        if [ -n "$GW" ]; then
            run ping -c 3 -W 2 -I "$IFACE" "$GW"
        fi
    done
}

test_scan() {
    log "--- scan ---"
    run nmcli device wifi rescan ifname "$IFACE"
    sleep 3
    run nmcli -f IN-USE,SSID,SIGNAL device wifi list ifname "$IFACE"
}

test_p2p() {
    log "--- p2p remain-on-channel ---"
    local p2p
    p2p="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2 == "wifi-p2p" {print $1; exit}')"
    if [ -z "$p2p" ]; then
        log "SKIP: no p2p device"
        return
    fi
    log "p2p iface=$p2p"
    run timeout 15 wpa_cli -i "$p2p" p2p_find
    sleep 2
    run wpa_cli -i "$p2p" p2p_stop_find
}

test_monitor() {
    log "--- monitor interface ---"
    if ! command -v iw >/dev/null; then
        log "SKIP: iw not installed"
        return
    fi
    run iw phy "$PHY" interface add ztmon type monitor
    sleep 1
    ip link show ztmon 2>&1 | tee -a "$LOG"
    run iw dev ztmon del
}

test_reconnect
test_scan
test_p2p
test_monitor

log "--- kernel messages ---"
dmesg -T 2>/dev/null | grep -iE 'zt9101|cfg80211|wlan0|call trace|BUG:' | tail -50 | tee -a "$LOG" || true
log "=== done; full log: $LOG ==="

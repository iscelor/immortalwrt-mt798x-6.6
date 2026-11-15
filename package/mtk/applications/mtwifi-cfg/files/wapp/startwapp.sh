#!/bin/sh
#
# Start wapp/bs20 when at least one radio actually needs them, then push the
# 802.11v neighbour list down.
#
# Requirements are derived from the configuration instead of a single hardcoded
# UCI section name, so 2.4G-only steering, MT7988 and renamed radios all work:
#
#   - wifi-device: wapp=1 or bandsteering=1
#   - wifi-iface:  steeringthresold < 0
#
# 802.11r is deliberately not a trigger: it is mapped to the driver's FtSupport
# by mtwifi_cfg and never goes through wapp, so starting the daemon for it would
# only add a process and flip the radios into MAP mode for nothing.
#
# The script is idempotent: a state file records the interfaces wapp was
# started for, and a repeated hotplug event for an unchanged configuration
# does not restart the daemon.
#

LOG_TAG="wapp"
STATE_FILE="/var/run/wapp.state"

log_i() {
    logger -t "$LOG_TAG" "INFO: $*"
}

log_e() {
    logger -t "$LOG_TAG" "ERROR: $*"
}

run_cmd() {
    log_i "exec: $*"
    "$@"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        log_i "ok($rc): $*"
    else
        log_e "fail($rc): $*"
    fi
    return "$rc"
}

run_bg() {
    log_i "exec(bg): $*"
    "$@" >/dev/null 2>&1 &
    log_i "started pid=$!: $*"
}

# Band of a wifi-device, normalised to 2g/5g/6g.
dev_band() {
    local dev="$1" band hw

    band="$(uci -q get wireless.$dev.band)"
    if [ -z "$band" ]; then
        hw="$(uci -q get wireless.$dev.hwmode)"
        case "$hw" in
            11a|11ac|11ax) band="5g" ;;
            11g|11b|11bg) band="2g" ;;
        esac
    fi

    case "$band" in
        2g|2.4g) echo "2g" ;;
        5g) echo "5g" ;;
        6g) echo "6g" ;;
    esac
}

log_i "startwapp.sh start"

need_2g=0
need_5g=0

for dev in $(uci -q show wireless | sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p'); do
    [ "$(uci -q get wireless.$dev.type)" = "mtwifi" ] || continue

    band="$(dev_band "$dev")"
    [ -n "$band" ] || continue

    want=0
    [ "$(uci -q get wireless.$dev.wapp)" = "1" ] && want=1
    [ "$(uci -q get wireless.$dev.bandsteering)" = "1" ] && want=1

    for iface in $(uci -q show wireless | sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'); do
        [ "$(uci -q get wireless.$iface.device)" = "$dev" ] || continue

        thres="$(uci -q get wireless.$iface.steeringthresold)"
        case "$thres" in
            ''|0) ;;
            -*) want=1 ;;
        esac
    done

    [ "$want" = "1" ] || continue

    case "$band" in
        2g) need_2g=1 ;;
        5g) need_5g=1 ;;
        6g) log_i "radio $dev is 6GHz, wapp has no 6GHz control interface, ignored" ;;
    esac
done

want_state="ra0=${need_2g} rax0=${need_5g}"
log_i "requirements: $want_state"

if [ "$need_2g" = "0" ] && [ "$need_5g" = "0" ]; then
    log_i "no radio needs wapp, make sure it is stopped"
    rm -f "$STATE_FILE"
    killall bs20 2>/dev/null
    killall wapp 2>/dev/null
    exit 0
fi

# pidof alone is not enough: wapp forks twice and can lose one instance while
# still passing the check, after which every wappctrl call fails with rc=255.
# Require the expected process count plus a responsive control socket.
want_wapp=2
have_wapp=$(pidof wapp 2>/dev/null | wc -w)
if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$want_state" ] \
   && [ "$have_wapp" -ge "$want_wapp" ] && [ -S /tmp/wapp_ctrl ]; then
    log_i "wapp already running with $want_state ($have_wapp procs), nothing to do"
    exit 0
fi

run_cmd sh -c "killall bs20 2>/dev/null || true"
run_cmd sh -c "killall wapp 2>/dev/null || true"
# A killed wapp leaves its unix sockets behind, and a stale /tmp/wapp_ctrl makes
# every later wappctrl fail with "Connect to server address fail".
rm -f /tmp/wapp_ctrl /tmp/wapp_server

br0_mac="$(cat /sys/class/net/br-lan/address 2>/dev/null)"
ctrlr_al_mac="$br0_mac"
agent_al_mac="$br0_mac"

log_i "bridge mac: ${br0_mac:-<none>}"

if [ -n "$br0_mac" ] && [ -f /etc/map/1905d.cfg ]; then
    run_cmd sed -i "s/map_controller_alid=.*/map_controller_alid=${ctrlr_al_mac}/g" /etc/map/1905d.cfg
    run_cmd sed -i "s/map_agent_alid=.*/map_agent_alid=${agent_al_mac}/g" /etc/map/1905d.cfg
fi

sleep 2

if [ "$need_2g" = "1" ] && [ "$need_5g" = "1" ]; then
    run_bg wapp -d1 -v2 -cra0 -crax0
elif [ "$need_2g" = "1" ]; then
    run_bg wapp -d1 -v2 -cra0
else
    run_bg wapp -d1 -v2 -crax0
fi

sleep 1

# Fixed delays are unreliable: 3s was measured to be too short while 10s always
# worked. Wait for the control socket to actually appear.
wait_i=0
while [ "$wait_i" -lt 15 ]; do
    [ -S /tmp/wapp_ctrl ] && break
    sleep 1
    wait_i=$((wait_i + 1))
done
if [ "$wait_i" -ge 15 ]; then
    log_e "wapp control socket did not appear within 15s"
fi

if ! pidof wapp >/dev/null 2>&1; then
    log_e "wapp failed to start, is the mtwifi-wapp package selected in the image?"
    rm -f "$STATE_FILE"
    exit 1
fi

for dev in ra0 rax0; do
    [ -d "/sys/class/net/$dev" ] || continue
    run_cmd iwpriv "$dev" set mapR2Enable=0
    run_cmd iwpriv "$dev" set mapTSEnable=0
    run_cmd iwpriv "$dev" set mapR3Enable=0
    run_cmd iwpriv "$dev" set DppEnable=0
    run_cmd iwpriv "$dev" set mapEnable=2
done

run_bg bs20

[ -d /sys/class/net/rax0 ] && run_cmd wappctrl rax0 mbo reset_default
[ -d /sys/class/net/ra0 ] && run_cmd wappctrl ra0 mbo reset_default

for iface in $(uci -q show wireless | sed -n 's/^wireless\.\([^.]*\)=wifi-iface$/\1/p'); do
    bssid_list="$(uci -q get wireless.$iface.steeringbssid)"
    [ -n "$bssid_list" ] || continue

    case "$(dev_band "$(uci -q get wireless.$iface.device)")" in
        2g) target=ra0 ;;
        5g) target=rax0 ;;
        *) continue ;;
    esac

    [ -d "/sys/class/net/$target" ] || continue
    run_cmd /sbin/setbssid "$target" "$bssid_list"
done

echo "$want_state" > "$STATE_FILE"

log_i "startwapp.sh done"

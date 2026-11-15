#!/bin/sh
#
# Keep wapp/bs20 alive.
#
# wapp is a closed-source binary that occasionally dies with SIGSEGV, and a
# killed instance leaves /tmp/wapp_ctrl behind. When either happens every later
# wappctrl call fails with rc=255, and 802.11v / MAP silently stop working until
# the next hotplug event. This watchdog restores both the processes and a clean
# control socket. It never fights a startwapp.sh run that is already in flight.
#
# Tunables: WAPP_WATCHDOG_INTERVAL (seconds, default 20).

LOG_TAG="wapp-watchdog"
STATE_FILE="/var/run/wapp.state"
LOCK="/var/run/startwapp.lock"
INTERVAL="${WAPP_WATCHDOG_INTERVAL:-20}"

# wapp forks into two processes on this platform; bs20 is a single process.
EXPECT_WAPP=2
EXPECT_BS20=1

log_i() {
	logger -t "$LOG_TAG" "INFO: $*"
}

while true; do
	sleep "$INTERVAL"

	# Nothing to supervise when startwapp.sh decided wapp is not needed.
	[ -f "$STATE_FILE" ] || continue

	# A hotplug/startwapp.sh run is in progress, leave it alone.
	[ -d "$LOCK" ] && continue

	wapp_n=$(pidof wapp 2>/dev/null | wc -w)
	bs20_n=$(pidof bs20 2>/dev/null | wc -w)

	if [ "$wapp_n" -ge "$EXPECT_WAPP" ] && [ "$bs20_n" -ge "$EXPECT_BS20" ]; then
		continue
	fi

	log_i "wapp=$wapp_n bs20=$bs20_n (expect $EXPECT_WAPP/$EXPECT_BS20), restarting"
	killall wapp bs20 2>/dev/null
	sleep 1
	rm -f /tmp/wapp_ctrl /tmp/wapp_server "$STATE_FILE"
	/sbin/startwapp.sh
done

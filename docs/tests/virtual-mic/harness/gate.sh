#!/bin/sh
# Phase 0 virtual-mic gate tests, one command each (see ../README.md).
# Run from Terminal so macOS asks for consent; build first with `make`.
#
#   ./gate.sh b-muted | b-when-tapped | b-subdevice | a-install | a-signal | a-uninstall | list
#
# DURATION (probe seconds, default 10), LISTEN (seconds with nothing reading), LEVEL
# (burst volume) can be set in the environment. ANNOUNCE=1 speaks each phase aloud,
# so a listener can tell which phase the beeps come from.

set -u

announce() {
    if [ "${ANNOUNCE:-0}" = 1 ]; then say "$1"; fi
}
cd "$(dirname "$0")"
FEEDER=build/rd-mic-feeder
PROBE=build/rd-mic-probe
DURATION=${DURATION:-10}

# Starts the feeder with the given arguments, waits `$1` seconds, probes, stops the feeder.
with_feeder() {
    settle=$1
    shift
    announce "Phase one. Nothing is reading the microphone."
    "$FEEDER" "$@" &
    pid=$!
    echo ">>> PHASE 1: feeder running, nothing reading the device ($settle s)"
    sleep "$settle"
    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid"
        echo "RESULT: feeder exited early"
        return 1
    fi
    "$PROBE" --list | grep "Remote Display" || echo "(no Remote Display device listed)"
    echo ">>> PHASE 2: probe reading the device ($DURATION s)"
    "$PROBE" --seconds "$DURATION" &
    probe_pid=$!
    announce "Phase two. The probe is reading."
    wait "$probe_pid"
    rc=$?
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    echo ">>> DONE: feeder stopped"
    announce "Done."
    echo "RESULT: probe exit $rc"
    return $rc
}

case "${1:-}" in
b-muted)
    with_feeder "${LISTEN:-2}" --option b --mute muted --level "${LEVEL:-0.3}"
    ;;
b-when-tapped)
    echo "Listen: with muted-when-tapped, bursts may play from the speakers until the probe starts reading."
    with_feeder "${LISTEN:-5}" --option b --mute when-tapped --level "${LEVEL:-0.1}"
    ;;
b-subdevice)
    with_feeder 2 --option b --mute muted --with-output-subdevice --level "${LEVEL:-0.3}"
    ;;
a-install)
    sudo make install-driver || exit 1
    sleep 3
    "$PROBE" --list | grep "Remote Display" || echo "RESULT: no Remote Display device after install"
    ;;
a-signal)
    with_feeder 2 --option a --level "${LEVEL:-0.3}"
    ;;
a-uninstall)
    sudo make uninstall-driver || exit 1
    sleep 3
    "$PROBE" --list | grep "Remote Display" || echo "RESULT: device gone"
    ;;
list)
    "$PROBE" --list
    ;;
*)
    echo "usage: $0 b-muted|b-when-tapped|b-subdevice|a-install|a-signal|a-uninstall|list"
    exit 1
    ;;
esac

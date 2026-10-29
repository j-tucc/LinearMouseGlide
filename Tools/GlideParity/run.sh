#!/bin/bash -e
# Records one stack with the parity harness.
#
#   Tools/GlideParity/run.sh old <out.json>   LinearMouse + Mouse Glide
#   Tools/GlideParity/run.sh new <out.json>   LinearMouse Glide (Debug build)
#   Tools/GlideParity/run.sh again <out.json> record the running stack again (noise baseline)
#   Tools/GlideParity/run.sh compare <old.json> <new.json>

cd "$(dirname "$0")/../.."
HARNESS=build/glide-parity
NEW_APP=build/DerivedData/Build/Products/Debug/LinearMouse.app

mkdir -p build
if [[ ! -x $HARNESS || Tools/GlideParity/GlideParity.swift -nt $HARNESS ]]; then
    swiftc -O -o "$HARNESS" Tools/GlideParity/GlideParity.swift
fi

quit_all() {
    osascript -e 'tell application id "com.tinfine.MouseGlide" to quit' \
        -e 'tell application id "com.lujjjh.LinearMouse" to quit' \
        -e 'tell application id "app.linearmouseglide.dev.LinearMouseGlide" to quit' 2>/dev/null || true
    sleep 2
}

case $1 in
old)
    quit_all
    open -a /Applications/LinearMouse.app
    open -a "/Applications/Mouse Glide.app"
    ;;
new)
    quit_all
    open "$NEW_APP"
    ;;
again)
    # Record the already running stack again, keeping its last active device.
    GLIDE_PARITY_NOWAIT=1 exec "$HARNESS" record "$2"
    ;;
compare)
    exec "$HARNESS" compare "$2" "$3"
    ;;
*)
    echo "usage: $0 old|new|again <out.json> | compare <a.json> <b.json>" >&2
    exit 2
    ;;
esac

sleep 4
"$HARNESS" record "$2"

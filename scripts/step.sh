#!/bin/sh
# step.sh NAME BUTTON... - taps the buttons (see pad.sh), then saves a screenshot of the game as NAME.jpg.
# Screenshots go to $VSWS_SHOTS, or to a "vsws-shots" folder in the temp directory.
name="$1"; shift
dir="$(dirname "$0")"
out_dir="${VSWS_SHOTS:-${TEMP:-/tmp}/vsws-shots}"
mkdir -p "$out_dir"
sh "$dir/pad.sh" "$@"
sleep 0.8
powershell -NoProfile -ExecutionPolicy Bypass -File "$dir/shot.ps1" -Out "$(cygpath -w "$out_dir")\$name.jpg" 2>&1 | tail -1

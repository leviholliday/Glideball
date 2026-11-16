#!/bin/zsh
# Pictures of every Glideball screen, without running the real app: builds,
# makes a sandbox copy (scripts/sandbox-app.sh) and runs its --render-ui mode
# (Sources/Glide/Sandbox/RenderUI.swift), which draws each screen offscreen
# with demo data. Writes <screen>.<light|dark>.png, index.html (a contact
# sheet: open it in a browser) and manifest.json.
#
#   scripts/render-ui.sh [outdir] [options]       outdir defaults to build/screens
#     --appearance light|dark|both                default both
#     --only overview,settings-*,update-…         a name, its variants (name-…), or a glob
#     --scale 1|2                                 default 2
#     --lang de                                   any of the app's translations
#     --no-build                                  use the binary that's already built
#
#   scripts/render-ui.sh build/screens-de --lang de --only 'settings-*,tour-*'
#
# A run that crashes, stalls (no output for RENDER_UI_STALL s, default 120) or passes
# RENDER_UI_TIMEOUT s (default 3600) is stopped, says which scene it was on, and exits non-zero.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"

OUT=build/screens
BUILD=1
typeset -a pass
if [[ $# -gt 0 && $1 != --* ]]; then OUT=$1; shift; fi
for arg in "$@"; do
  case $arg in
    --no-build) BUILD=0 ;;
    *) pass+=("$arg") ;;
  esac
done

(( BUILD )) && swift build -c release
EXE=$(scripts/sandbox-app.sh)
mkdir -p "$OUT"
# Old pictures would linger in the contact sheet's folder; start clean unless --only picks a few.
if [[ ${pass[(Ie)--only]} -eq 0 ]]; then rm -f "$OUT"/*.png(N); fi
# Watchdog instead of a blind alarm: a fixed 600 s alarm used to kill a full run
# (200+ pictures at 2x) mid-way with no message and no exit status. Now the run
# is stopped only if it stalls (no new output for RENDER_UI_STALL s, default 120)
# or exceeds RENDER_UI_TIMEOUT s (default 3600), and either way the script says
# which scene it was on and exits non-zero. A crash is reported the same way.
STALL=${RENDER_UI_STALL:-120}
TOTAL=${RENDER_UI_TIMEOUT:-3600}
LOG=$(mktemp "${TMPDIR:-/tmp}/render-ui.XXXXXX")
trap 'rm -f "$LOG"' EXIT
"$EXE" --render-ui "$OUT" "${pass[@]}" >"$LOG" 2>&1 &
pid=$!
tail -n +1 -f "$LOG" 2>/dev/null &
tailpid=$!
start=$SECONDS; lastsize=-1; lastchange=$SECONDS; why=""
while kill -0 $pid 2>/dev/null; do
  sleep 2
  size=$(stat -f %z "$LOG")
  if [[ $size != $lastsize ]]; then lastsize=$size; lastchange=$SECONDS; fi
  if (( SECONDS - lastchange > STALL )); then why="stalled: no output for ${STALL} s"; break; fi
  if (( SECONDS - start > TOTAL )); then why="over the ${TOTAL} s limit"; break; fi
done
if [[ -n $why ]]; then kill -9 $pid 2>/dev/null || true; fi
code=0; wait $pid 2>/dev/null || code=$?
sleep 0.3; kill $tailpid 2>/dev/null || true; wait $tailpid 2>/dev/null || true
scene=$(grep '^  ▸ ' "$LOG" | tail -1 | sed 's/^  ▸ //' || true)
if [[ -n $why ]]; then
  print -u2 "render-ui FAILED: $why; last scene started: ${scene:-(none, before the first picture)}"
  exit 1
elif (( code >= 128 )); then
  print -u2 "render-ui FAILED: crashed (signal $((code - 128))); last scene started: ${scene:-(none)}"
  exit $code
elif (( code != 0 )); then
  print -u2 "render-ui FAILED: exit $code${scene:+; last scene started: $scene}"
  exit $code
fi
if [[ ! -f "$OUT/index.html" ]]; then
  print -u2 "render-ui FAILED: finished without writing index.html; last scene started: ${scene:-(none)}"
  exit 1
fi
print "Contact sheet: $OUT/index.html"

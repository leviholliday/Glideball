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
# More than RENDER_UI_BATCH screens (default 60) are drawn in batches, one process
# each, one after another (one process can't draw them all), then joined.
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
rm -f "$OUT"/.render-ui-part-*.json(N) "$OUT"/index.html(N) "$OUT"/manifest.json(N)
# Watchdog instead of a blind alarm: a fixed 600 s alarm used to kill a full run
# (200+ pictures at 2x) mid-way with no message and no exit status. Now a run
# is stopped only if it stalls (no new output for RENDER_UI_STALL s, default 120)
# or exceeds RENDER_UI_TIMEOUT s (default 3600), and either way the script says
# which scene it was on and exits non-zero. A crash is reported the same way.
STALL=${RENDER_UI_STALL:-120}
TOTAL=${RENDER_UI_TIMEOUT:-3600}
# SwiftUI's AttributeGraph runs out of table space after ~180 scenes in one
# process, so more than RENDER_UI_BATCH screens (default 60) are drawn in
# batches, one process each, one after another; --assemble then joins them
# into one index.html and manifest.json.
BATCH=${RENDER_UI_BATCH:-60}
LOG=$(mktemp "${TMPDIR:-/tmp}/render-ui.XXXXXX")
trap 'rm -f "$LOG"' EXIT
start=$SECONDS

# render_once <extra args…>: one --render-ui process under the watchdog.
# Returns its exit status; on a stall, timeout or crash, says so and exits.
render_once() {
  : >"$LOG"
  "$EXE" --render-ui "$OUT" "${pass[@]}" "$@" >"$LOG" 2>&1 &
  local pid=$!
  tail -n +1 -f "$LOG" 2>/dev/null &
  local tailpid=$! lastsize=-1 lastchange=$SECONDS why="" size code=0 scene
  while kill -0 $pid 2>/dev/null; do
    sleep 2
    size=$(stat -f %z "$LOG")
    if [[ $size != $lastsize ]]; then lastsize=$size; lastchange=$SECONDS; fi
    if (( SECONDS - lastchange > STALL )); then why="stalled: no output for ${STALL} s"; break; fi
    if (( SECONDS - start > TOTAL )); then why="over the ${TOTAL} s limit"; break; fi
  done
  if [[ -n $why ]]; then kill -9 $pid 2>/dev/null || true; fi
  wait $pid 2>/dev/null || code=$?
  sleep 0.3; kill $tailpid 2>/dev/null || true; wait $tailpid 2>/dev/null || true
  scene=$(grep '^  ▸ ' "$LOG" | tail -1 | sed 's/^  ▸ //' || true)
  if [[ -n $why ]]; then
    print -u2 "render-ui FAILED: $why; last scene started: ${scene:-(none, before the first picture)}"
    exit 1
  elif (( code >= 128 )); then
    print -u2 "render-ui FAILED: crashed (signal $((code - 128))); last scene started: ${scene:-(none)}"
    exit $code
  fi
  return $code
}

# How many screens the options pick (also catches an --only that matches nothing).
names=$("$EXE" --render-ui "$OUT" "${pass[@]}" --list 2>&1) || { print -u2 "$names"; print -u2 "render-ui FAILED: couldn't list the screens"; exit 2; }
count=${#${(f)names}}
code=0
if (( count <= BATCH )); then
  render_once || code=$?
else
  batches=$(( (count + BATCH - 1) / BATCH ))
  print "render-ui: $count screens in $batches batches of up to $BATCH, one process each"
  for (( from = 0; from < count; from += BATCH )); do
    c=0; render_once --slice "$from,$BATCH" || c=$?
    (( c == 2 )) && exit 2   # bad arguments: no point going on
    (( c != 0 )) && code=$c  # problems (blank pictures…): keep going, fail at the end
  done
  c=0; "$EXE" --render-ui "$OUT" --assemble || c=$?
  (( c != 0 )) && code=$c
fi
if (( code != 0 )); then
  print -u2 "render-ui FAILED: exit $code (see the problems above)"
  exit $code
fi
if [[ ! -f "$OUT/index.html" ]]; then
  print -u2 "render-ui FAILED: finished without writing index.html"
  exit 1
fi
print "render-ui: done in $(( SECONDS - start )) s"
print "Contact sheet: $OUT/index.html"

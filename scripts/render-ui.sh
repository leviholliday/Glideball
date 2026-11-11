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
perl -e 'alarm shift; exec @ARGV' 600 "$EXE" --render-ui "$OUT" "${pass[@]}"
print "Contact sheet: $OUT/index.html"

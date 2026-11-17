#!/bin/zsh
# How smoothly Glideball's own pages scroll while the trackball is in use, measured
# offscreen without running the real app: builds, makes a sandbox copy
# (scripts/sandbox-app.sh) and runs its --scroll-bench mode
# (Sources/Glide/Sandbox/ScrollBench.swift). Each page is scrolled fast, down and
# back up, at 120 Hz for 3 s with the live light, trackball, graphs and today's
# numbers fed as the engine would feed them, at 980x680 and 1440x900 (2x). Prints
# per-frame main-thread and compositing times and how often the heavy views were
# rebuilt. Offscreen numbers are for before/after comparisons, not frame rates.
#
#   scripts/scroll-bench.sh [options]
#     --pages overview,pointer,scrolling,buttons,apps,sync,settings-general,… | all
#     --sizes 980x680,1440x900     --seconds 3     --hz 120
#     --appearance dark|light      --performance smooth|efficient|minimal
#     --no-feed                    (nothing live: just the scroll)
#     --damage                     (composite only what changed, as WindowServer does)
#     --drive wheel|offset         (scroll events like Glideball's, or move the clip view)
#     --json file                  --no-build
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"

BUILD=1
typeset -a pass
for arg in "$@"; do
  case $arg in
    --no-build) BUILD=0 ;;
    *) pass+=("$arg") ;;
  esac
done

(( BUILD )) && swift build -c release
EXE=$(scripts/sandbox-app.sh)
perl -e 'alarm shift; exec @ARGV' 900 "$EXE" --scroll-bench "${pass[@]}"

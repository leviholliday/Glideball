#!/bin/zsh
# The engine fuzzer: compiles the REAL input engine (Engine.swift and everything it
# decides with) against a fake EngineIO, then plays long random sequences of
# trackball, mouse, trackpad and keyboard events, settings changes, pauses, unplugs,
# sleeps and the tap being switched off, checking the hard rules after every event.
# Nothing touches the real cursor, devices, taps or settings.
#
#   scripts/engine-fuzz/run.sh                         regression cases + seeds 1-40
#   scripts/engine-fuzz/run.sh --seed 123 [--events N] replay one seed
#   scripts/engine-fuzz/run.sh --minutes 10            fresh seeds until time's up
#   scripts/engine-fuzz/run.sh --random                also one random seed (printed)
#   scripts/engine-fuzz/run.sh --threads [--seconds S] the engine on its own threads, as in the app
#   scripts/engine-fuzz/run.sh --tsan … / --asan …     built with the thread / address sanitizer
#   FUZZ_TRACE=1 scripts/engine-fuzz/run.sh --seed N   a play-by-play of the minimized failure
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/glide-engine-fuzz-$$"   # per run: a long run and a check can overlap
trap 'rm -f "$OUT"' EXIT
FLAGS=(-O)
ARGS=()
for a in "$@"; do
  case $a in
    --tsan) FLAGS=(-Onone -g -sanitize=thread); OUT="$OUT-tsan" ;;
    --asan) FLAGS=(-Onone -g -sanitize=address); OUT="$OUT-asan" ;;
    *) ARGS+=("$a") ;;
  esac
done
(( ${#ARGS} )) || ARGS=(--seeds 1-40)
swiftc "${FLAGS[@]}" -swift-version 5 -o "$OUT" \
  Sources/Glide/Engine.swift \
  Sources/Glide/EngineIO.swift \
  Sources/Glide/SmoothScroller.swift \
  Sources/Glide/Gestures.swift \
  Sources/Glide/DisplayTracking.swift \
  Sources/Glide/DeviceBattery.swift \
  Sources/Glide/DeviceSupport.swift \
  Sources/Glide/PointerTuner.swift \
  Sources/Glide/Telemetry.swift \
  Sources/Glide/Diagnostics.swift \
  Sources/Glide/Config.swift \
  Sources/Glide/AppProfile.swift \
  scripts/engine-fuzz/main.swift
set +e
"$OUT" "${ARGS[@]}"
code=$?
(( code > 128 )) && echo "FAIL: the fuzzer crashed (signal $((code - 128)))."
exit $code

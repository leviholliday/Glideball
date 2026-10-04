#!/bin/zsh
# Compiles the real scroll engine with a simulator harness and runs it.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/glide-scroll-sim"
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/SmoothScroller.swift \
  Sources/Glide/Config.swift \
  Sources/Glide/Telemetry.swift \
  Sources/Glide/Diagnostics.swift \
  Sources/Glide/AppProfile.swift \
  scripts/scroll-sim/main.swift
"$OUT"

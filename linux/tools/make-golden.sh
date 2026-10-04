#!/bin/zsh
# Regenerates the Swift-derived test fixtures from the Mac sources (macOS only).
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/glideball-golden"
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/SmoothScroller.swift Sources/Glide/Config.swift Sources/Glide/Telemetry.swift \
  Sources/Glide/Diagnostics.swift Sources/Glide/AppProfile.swift linux/tools/golden/main.swift
"$OUT" linux/tests/fixtures
